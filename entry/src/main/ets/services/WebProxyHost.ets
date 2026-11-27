import { webview } from '@kit.ArkWeb';
import { TdClient } from '../tdkit/TdClient';
import { TdError, TdObject, TdRequest } from '../tdkit/TdTypes';
import { KEY_CURRENT_NETWORK_TYPE } from '../store/AppSettings';
import { logI, logW } from '../util/log';

// TDLib 1.8.71 原生 proxyTypeWeb 载体管理器。
//
// TDLib 负责构造 bridge URL、管理重连、obfuscated2/MTProto 封装以及 ping/test 临时载体；
// App 这边只做三件薄事：
//   1. 订阅 updateWebProxyCarrierOpened / Data / Closed，按 carrier.id 维护隐藏 WebView 列表；
//   2. 把页面通过 window[bridge_object_name].postMessage() 发来的文本/二进制转给
//      processWebProxyCarrierMessage；
//   3. 把 updateWebProxyCarrierData 按序投递给页面 onmessage，并在加载失败或渲染进程
//      退出时调用 reportWebProxyCarrierError。
//
// 安全约束（对齐 td_api.tl webProxyCarrier 说明）：
//   · 永不在日志或错误消息里输出 carrier.url；
//   · 仅在顶层文档且精确匹配 carrier.origin 时注入只读桥接对象；
//   · 收到 updateWebProxyCarrierClosed 后立即忽略页面后续消息；若页面曾发过消息，
//     先向 onmessage 投递 {"t":"close"} 并在 200ms 后销毁 WebView，否则立即销毁。

export const KEY_WEB_PROXY_CARRIERS: string = 'tdWebProxyCarriers';

export interface WebProxyCarrierSpec {
  id: number;
  proxyId: number;
  url: string;
  origin: string;
  pathPrefix: string;
  bridgeObjectName: string;
  isTemporary: boolean;
}

interface QueuedDelivery {
  kind: 'binary' | 'text';
  payload: string;
}

interface CarrierRecord {
  spec: WebProxyCarrierSpec;
  client: TdClient;
  controller: webview.WebviewController | null;
  hasSentMessage: boolean;
  closed: boolean;
  errorReported: boolean;
  queue: QueuedDelivery[];
  queueBytes: number;
  pumping: boolean;
  // 文档代次：页面重载/控制器更换后，旧 runJavaScript 的结果必须作废。
  pageEpoch: number;
  closeTimer: number;
  shimReady: boolean;
  openSeq: number;
  openedAt: number;
  controllerAt: number;
  pageBeginAt: number;
  pageEndAt: number;
  shimReadyAt: number;
  firstDownAt: number;
  firstUpAt: number;
  firstBinaryAt: number;
  // 数据面统计：只用于判断 P2 是否值得做，不参与调度。
  deliveredFrames: number;
  deliveredBytes: number;
  deliverMs: number;
  maxDeliverMs: number;
}

const MAX_DELIVERY_QUEUE: number = 512;
// 队列字节上限按 base64 解码后的原始字节估算；JS 字符串常驻内存约为它的两倍。
// 4 MiB 足够覆盖两个 2 MiB 长轮询批次，同时避免页面卡死时无界增长。
const MAX_DELIVERY_QUEUE_BYTES: number = 4 * 1024 * 1024;
const CLOSE_GRACE_MS: number = 200;
// WebProxyHost 在应用启动早期被 Globals 引入，此时间近似进程起点。
const MODULE_STARTED_AT: number = Date.now();
let webEngineInitialized: boolean = false;

class TdWebProxyCarrierManager {
  private carriers: Map<number, CarrierRecord> = new Map();
  private unsubByClient: Map<TdClient, (() => void)[]> = new Map();
  private carrierSeq: number = 0;

  attach(client: TdClient): void {
    if (this.unsubByClient.has(client)) {
      return;
    }
    const offs: (() => void)[] = [
      client.onUpdate('updateWebProxyCarrierOpened', (u: TdObject): void => {
        this.onCarrierOpened(client, u);
      }),
      client.onUpdate('updateWebProxyCarrierData', (u: TdObject): void => {
        this.onCarrierData(u);
      }),
      client.onUpdate('updateWebProxyCarrierClosed', (u: TdObject): void => {
        this.onCarrierClosed(u);
      })
    ];
    this.unsubByClient.set(client, offs);
    this.prewarmIfWebProxyEnabled(client);
  }

  // 1.6.3 的 WEB 代理开关只在 TDLib 里，App 没有本地键可读。启动后异步问一次
  // getProxies：只有已启用的 proxyTypeWeb 才加载 ArkWeb，避免所有用户都付
  // 引擎初始化/内存成本。延时 300ms，让首帧先出来。
  private prewarmIfWebProxyEnabled(client: TdClient): void {
    setTimeout((): void => {
      if (!this.unsubByClient.has(client)) {
        return;
      }
      const req: TdRequest = { '@type': 'getProxies' };
      client.send(req, 5000).then((result: TdObject): void => {
        if (!this.unsubByClient.has(client)) {
          return;
        }
        const proxies: TdObject[] = (result['proxies'] as TdObject[] | undefined) ?? [];
        for (const item of proxies) {
          if (item['is_enabled'] !== true) {
            continue;
          }
          const proxy: TdObject | undefined = item['proxy'] as TdObject | undefined;
          if (proxy === undefined) {
            continue;
          }
          const type: TdObject | undefined = proxy['type'] as TdObject | undefined;
          if (type !== undefined && type['@type'] === 'proxyTypeWeb') {
            logI('[WebProxyTiming] event=startup_prewarm');
            this.ensureWebEngine();
            return;
          }
        }
      }).catch((): void => {});
    }, 300);
  }

  detach(client: TdClient): void {
    const offs: (() => void)[] | undefined = this.unsubByClient.get(client);
    if (offs !== undefined) {
      for (const off of offs) {
        off();
      }
      this.unsubByClient.delete(client);
    }
    let removed: boolean = false;
    const toRemove: number[] = [];
    this.carriers.forEach((record: CarrierRecord, id: number): void => {
      if (record.client === client) {
        toRemove.push(id);
      }
    });
    for (const id of toRemove) {
      const record: CarrierRecord | undefined = this.carriers.get(id);
      if (record !== undefined) {
        this.disposeRecord(record);
        this.carriers.delete(id);
        removed = true;
      }
    }
    if (removed) {
      this.publishSpecs();
    }
  }

  attachController(carrierId: number, controller: webview.WebviewController): void {
    const record: CarrierRecord | undefined = this.carriers.get(carrierId);
    if (record === undefined || record.closed) {
      return;
    }
    record.controller = controller;
    record.pageEpoch += 1;
    record.pumping = false;
    record.controllerAt = Date.now();
    this.logTiming(record, 'controller_attached', `queue=${record.queue.length} shim=${record.shimReady}`);
    this.pump(record);
  }

  detachController(carrierId: number): void {
    const record: CarrierRecord | undefined = this.carriers.get(carrierId);
    if (record === undefined) {
      return;
    }
    record.pageEpoch += 1;
    record.pumping = false;
    record.controller = null;
    record.shimReady = false;
  }

  onPageBegin(carrierId: number): void {
    const record: CarrierRecord | undefined = this.carriers.get(carrierId);
    if (record === undefined || record.closed) {
      return;
    }
    const staleFrames: number = record.queue.length;
    const staleBytes: number = record.queueBytes;
    // 首个文档在加载期间，TDLib 发来的 tproxy-android-init 必须保留在队列里。
    // 只有「上一个文档已经 shim ready」之后再 begin，才是真正的重载；
    // 初始 about:blank -> 真实 URL 不算。
    const previousDocumentLive: boolean = record.pageBeginAt > 0 && record.shimReadyAt > 0;
    // 极快页面上 shim 的 ready 可能先于 onPageBegin 回调到达；这时不能把
    // 刚建立的 shim 状态清掉，否则不会再收到第二条 ready，握手只能等超时。
    const lateShimReady: boolean = record.pageBeginAt === 0 && record.shimReady;
    if (!lateShimReady) {
      record.pageEpoch += 1;
      record.pumping = false;
      record.shimReady = false;
    }
    record.pageBeginAt = Date.now();
    record.pageEndAt = 0;
    if (previousDocumentLive) {
      record.queue = [];
      record.queueBytes = 0;
      this.logTiming(record, 'page_begin', `queue=${staleFrames} bytes=${staleBytes} reload=1`);
      this.onPageError(carrierId, 'load_failed', 'page reloaded');
      return;
    }
    this.logTiming(record, 'page_begin', `queue=${staleFrames} bytes=${staleBytes} reload=0 late=${lateShimReady ? 1 : 0}`);
    this.pump(record);
  }

  onPageEnd(carrierId: number): void {
    const record: CarrierRecord | undefined = this.carriers.get(carrierId);
    if (record === undefined || record.closed) {
      return;
    }
    record.pageEndAt = Date.now();
    this.logTiming(record, 'page_end', `shim=${record.shimReady} queue=${record.queue.length}`);
  }

  onPageMessage(carrierId: number, kind: string, data: string): void {
    const record: CarrierRecord | undefined = this.carriers.get(carrierId);
    if (record === undefined || record.closed) {
      return;
    }
    if (kind === 'text' && this.isShimReadyMessage(data)) {
      const first: boolean = !record.shimReady;
      record.shimReady = true;
      if (record.shimReadyAt === 0) {
        record.shimReadyAt = Date.now();
      }
      if (first) {
        this.logTiming(record, 'shim_ready', `queue=${record.queue.length} bytes=${record.queueBytes}`);
        this.pump(record);
      }
      return;
    }
    if (kind === 'text' && this.isShimOverflowMessage(data)) {
      record.shimReady = false;
      this.onPageError(carrierId, 'load_failed', 'shim pending overflow');
      return;
    }
    if (record.firstUpAt === 0) {
      record.firstUpAt = Date.now();
      this.logTiming(record, 'first_up', `kind=${kind} chars=${data.length}`);
    }
    if (kind === 'binary' && record.firstBinaryAt === 0) {
      record.firstBinaryAt = Date.now();
      this.logTiming(record, 'first_up_binary', `chars=${data.length} bytes=${this.payloadBytes('binary', data)}`);
    }
    let message: TdObject;
    if (kind === 'text') {
      message = { '@type': 'webProxyCarrierMessageText', 'text': data };
    } else if (kind === 'binary') {
      message = { '@type': 'webProxyCarrierMessageBinary', 'data': data };
    } else {
      return;
    }
    record.hasSentMessage = true;
    const req: TdRequest = { '@type': 'processWebProxyCarrierMessage' };
    req['carrier_id'] = carrierId;
    req['message'] = message;
    record.client.send(req).catch((err: TdError): void => {
      logW(`[WebProxy] processWebProxyCarrierMessage(${carrierId}) failed: ${err.message}`);
    });
  }

  onPageError(carrierId: number, errorKind: string, message: string = ''): void {
    const record: CarrierRecord | undefined = this.carriers.get(carrierId);
    if (record === undefined || record.closed || record.errorReported) {
      return;
    }
    record.errorReported = true;
    // 页面已经报错，旧队列不可能再被这个文档消费；继续留着只会占内存，
    // 等 carrier_closed 才清也不符合「错误即刻止损」的预期。
    const droppedFrames: number = record.queue.length;
    const droppedBytes: number = record.queueBytes;
    record.queue = [];
    record.queueBytes = 0;
    record.shimReady = false;
    if (droppedFrames > 0) {
      logW(`[WebProxy] carrier ${carrierId} dropped ${droppedFrames} queued frames`
        + ` (${droppedBytes} bytes) after ${errorKind}`);
    }
    let errorObj: TdObject;
    if (errorKind === 'terminated') {
      errorObj = { '@type': 'webProxyCarrierErrorTerminated' };
    } else if (errorKind === 'refused') {
      errorObj = { '@type': 'webProxyCarrierErrorRefused' };
    } else if (errorKind === 'unsupported') {
      errorObj = { '@type': 'webProxyCarrierErrorUnsupported' };
    } else if (errorKind === 'paused') {
      errorObj = { '@type': 'webProxyCarrierErrorPaused' };
    } else {
      errorObj = { '@type': 'webProxyCarrierErrorLoadFailed', 'message': message };
    }
    logW(`[WebProxy] carrier error id=${carrierId} kind=${errorKind}`
      + (message.length > 0 ? ` msg=${message}` : ''));
    const req: TdRequest = { '@type': 'reportWebProxyCarrierError' };
    req['carrier_id'] = carrierId;
    req['error'] = errorObj;
    record.client.send(req).catch((err: TdError): void => {
      logW(`[WebProxy] reportWebProxyCarrierError(${carrierId}) failed: ${err.message}`);
    });
  }

  private onCarrierOpened(client: TdClient, u: TdObject): void {
    const carrier = u['carrier'] as TdObject | undefined;
    if (carrier === undefined) {
      return;
    }
    const id: number = (carrier['id'] as number | undefined) ?? 0;
    const proxyId: number = (carrier['proxy_id'] as number | undefined) ?? 0;
    const url: string = (carrier['url'] as string | undefined) ?? '';
    const origin: string = (carrier['origin'] as string | undefined) ?? '';
    const pathPrefix: string = (carrier['path_prefix'] as string | undefined) ?? '';
    const bridgeObjectName: string = (carrier['bridge_object_name'] as string | undefined) ?? 'TelegramWebProxy';
    const isTemporary: boolean = carrier['is_temporary'] === true;
    if (id <= 0 || url.length === 0 || origin.length === 0) {
      logW(`[WebProxy] ignoring malformed carrier id=${id}`);
      return;
    }
    const existing: CarrierRecord | undefined = this.carriers.get(id);
    if (existing !== undefined) {
      this.disposeRecord(existing);
    }
    const spec: WebProxyCarrierSpec = {
      id: id,
      proxyId: proxyId,
      url: url,
      origin: origin,
      pathPrefix: pathPrefix,
      bridgeObjectName: bridgeObjectName.length > 0 ? bridgeObjectName : 'TelegramWebProxy',
      isTemporary: isTemporary
    };
    this.ensureWebEngine();
    this.preconnect(spec);
    this.carrierSeq += 1;
    const openedAt: number = Date.now();
    const record: CarrierRecord = {
      spec: spec,
      client: client,
      controller: null,
      hasSentMessage: false,
      closed: false,
      errorReported: false,
      queue: [],
      queueBytes: 0,
      pumping: false,
      pageEpoch: 0,
      closeTimer: -1,
      shimReady: false,
      openSeq: this.carrierSeq,
      openedAt: openedAt,
      controllerAt: 0,
      pageBeginAt: 0,
      pageEndAt: 0,
      shimReadyAt: 0,
      firstDownAt: 0,
      firstUpAt: 0,
      firstBinaryAt: 0,
      deliveredFrames: 0,
      deliveredBytes: 0,
      deliverMs: 0,
      maxDeliverMs: 0
    };
    this.carriers.set(id, record);
    logI(`[WebProxy] carrier opened id=${id} proxy=${proxyId} temp=${isTemporary} origin=${origin}`);
    this.logTiming(record, 'carrier_opened', `first=${record.openSeq === 1} proxy=${proxyId}`);
    this.publishSpecs();
  }

  private onCarrierData(u: TdObject): void {
    const carrierId: number = (u['carrier_id'] as number | undefined) ?? 0;
    const data: string = (u['data'] as string | undefined) ?? '';
    const record: CarrierRecord | undefined = this.carriers.get(carrierId);
    if (record === undefined || record.closed || data.length === 0) {
      return;
    }
    const incomingBytes: number = this.payloadBytes('binary', data);
    if (record.queue.length >= MAX_DELIVERY_QUEUE
      || record.queueBytes + incomingBytes > MAX_DELIVERY_QUEUE_BYTES) {
      const droppedFrames: number = record.queue.length;
      const droppedBytes: number = record.queueBytes;
      record.queue = [];
      record.queueBytes = 0;
      logW(`[WebProxy] carrier ${carrierId} delivery queue overflow (${droppedFrames} frames, ${droppedBytes} bytes), reporting load_failed`);
      this.onPageError(carrierId, 'load_failed', 'delivery queue overflow');
      return;
    }
    record.queue.push({ kind: 'binary', payload: data });
    record.queueBytes += incomingBytes;
    if (record.firstDownAt === 0) {
      record.firstDownAt = Date.now();
      this.logTiming(record, 'first_down', `chars=${data.length} bytes=${incomingBytes}`
        + ` queue=${record.queue.length} queueBytes=${record.queueBytes}`);
    }
    this.pump(record);
  }

  private onCarrierClosed(u: TdObject): void {
    const carrierId: number = (u['carrier_id'] as number | undefined) ?? 0;
    const record: CarrierRecord | undefined = this.carriers.get(carrierId);
    if (record === undefined || record.closed) {
      return;
    }
    record.closed = true;
    const queuedFrames: number = record.queue.length;
    const queuedBytes: number = record.queueBytes;
    const hadShim: boolean = record.shimReady;
    const avgDeliverMs: number = record.deliveredFrames > 0
      ? Math.round(record.deliverMs / record.deliveredFrames) : 0;
    record.queue = [];
    record.queueBytes = 0;
    record.shimReady = false;
    logI(`[WebProxy] carrier closed id=${carrierId} sent=${record.hasSentMessage}`);
    this.logTiming(record, 'carrier_closed', `sent=${record.hasSentMessage} queued=${queuedFrames} bytes=${queuedBytes}`
      + ` delivered=${record.deliveredFrames} deliverBytes=${record.deliveredBytes}`
      + ` avgDeliverMs=${avgDeliverMs} maxDeliverMs=${record.maxDeliverMs}`);
    if (record.hasSentMessage && record.controller !== null && hadShim) {
      const controller: webview.WebviewController = record.controller;
      const closeScript: string =
        'window.__petrelTdWebProxyDeliver&&window.__petrelTdWebProxyDeliver(\'text\',\'{"t":"close"}\')';
      controller.runJavaScript(closeScript).catch((): void => {});
      record.closeTimer = setTimeout((): void => {
        record.closeTimer = -1;
        this.removeCarrier(carrierId);
      }, CLOSE_GRACE_MS);
    } else {
      this.removeCarrier(carrierId);
    }
  }

  private removeCarrier(carrierId: number): void {
    const record: CarrierRecord | undefined = this.carriers.get(carrierId);
    if (record === undefined) {
      return;
    }
    this.disposeRecord(record);
    this.carriers.delete(carrierId);
    this.publishSpecs();
  }

  private disposeRecord(record: CarrierRecord): void {
    record.closed = true;
    record.queue = [];
    record.queueBytes = 0;
    record.shimReady = false;
    record.controller = null;
    if (record.closeTimer >= 0) {
      clearTimeout(record.closeTimer);
      record.closeTimer = -1;
    }
  }

  private pump(record: CarrierRecord): void {
    if (record.pumping || record.closed || !record.shimReady) {
      return;
    }
    const controller: webview.WebviewController | null = record.controller;
    if (controller === null) {
      return;
    }
    const next: QueuedDelivery | undefined = record.queue[0];
    if (next === undefined) {
      return;
    }
    const epoch: number = record.pageEpoch;
    const startedAt: number = Date.now();
    record.pumping = true;
    const script: string = '(function(){'
      + 'if (typeof window.__petrelTdWebProxyDeliver !== "function") { return false; }'
      + 'try { window.__petrelTdWebProxyDeliver(' + JSON.stringify(next.kind) + ','
      + JSON.stringify(next.payload) + '); return true; } catch (e) { return false; }'
      + '})()';
    controller.runJavaScript(script).then((result: string): void => {
      if (record.closed || record.pageEpoch !== epoch) {
        return;
      }
      record.pumping = false;
      if (result !== 'true') {
        record.shimReady = false;
        logW(`[WebProxy] carrier ${record.spec.id} delivery not accepted, waiting for shim`);
        return;
      }
      if (record.queue.length === 0 || record.queue[0] !== next) {
        this.pump(record);
        return;
      }
      const deliverMs: number = Date.now() - startedAt;
      record.deliveredFrames += 1;
      record.deliveredBytes += this.payloadBytes(next.kind, next.payload);
      record.deliverMs += deliverMs;
      if (deliverMs > record.maxDeliverMs) { record.maxDeliverMs = deliverMs; }
      record.queue.shift();
      record.queueBytes -= this.payloadBytes(next.kind, next.payload);
      if (record.queueBytes < 0) {
        record.queueBytes = 0;
      }
      this.pump(record);
    }).catch((err: Error): void => {
      if (record.closed || record.pageEpoch !== epoch) {
        return;
      }
      record.pumping = false;
      if (!record.closed) {
        record.shimReady = false;
        logW(`[WebProxy] deliver to carrier ${record.spec.id} failed: ${err.message}`);
        this.onPageError(record.spec.id, 'load_failed', 'js delivery failed');
      }
    });
  }

  private isShimReadyMessage(data: string): boolean {
    if (data.indexOf('petrel-shim-ready') < 0) {
      return false;
    }
    try {
      const parsed: TdObject = JSON.parse(data) as TdObject;
      return parsed['t'] === 'petrel-shim-ready' && parsed['v'] === 1;
    } catch (e) {
      return false;
    }
  }

  private isShimOverflowMessage(data: string): boolean {
    if (data.indexOf('petrel-shim-pending-overflow') < 0) {
      return false;
    }
    try {
      const parsed: TdObject = JSON.parse(data) as TdObject;
      return parsed['t'] === 'petrel-shim-pending-overflow' && parsed['v'] === 1;
    } catch (e) {
      return false;
    }
  }

  private payloadBytes(kind: string, payload: string): number {
    if (kind === 'text') {
      return payload.length;
    }
    let padding: number = 0;
    if (payload.endsWith('==')) {
      padding = 2;
    } else if (payload.endsWith('=')) {
      padding = 1;
    }
    return Math.max(0, Math.floor(payload.length * 3 / 4) - padding);
  }

  private scenarioText(): string {
    const network: string = AppStorage.get<string>(KEY_CURRENT_NETWORK_TYPE) ?? 'other';
    const foreground: boolean = AppStorage.get<boolean>('appIsForeground') !== false;
    return `net=${network} fg=${foreground}`;
  }

  private logTiming(record: CarrierRecord, event: string, extra: string = ''): void {
    const now: number = Date.now();
    const rel: number = record.openedAt > 0 ? now - record.openedAt : 0;
    logI(`[WebProxyTiming] event=${event} id=${record.spec.id} temp=${record.spec.isTemporary}`
      + ` seq=${record.openSeq} rel=${rel}ms sinceStart=${now - MODULE_STARTED_AT}ms ${this.scenarioText()}`
      + (extra.length > 0 ? ` ${extra}` : ''));
  }

  prewarmEngine(): void {
    this.ensureWebEngine();
  }

  private ensureWebEngine(): void {
    if (webEngineInitialized) {
      return;
    }
    try {
      webview.WebviewController.initializeWebEngine();
      webEngineInitialized = true;
      logI(`[WebProxyTiming] event=engine_init sinceStart=${Date.now() - MODULE_STARTED_AT}ms`);
    } catch (e) {
      logW('[WebProxy] initializeWebEngine failed; continue without prewarm');
    }
  }

  private preconnect(spec: WebProxyCarrierSpec): void {
    try {
      webview.WebviewController.prepareForPageLoad(this.preconnectUrl(spec), true, 2);
      logI(`[WebProxyTiming] event=preconnect id=${spec.id} sinceStart=${Date.now() - MODULE_STARTED_AT}ms`);
    } catch (e) {
      logW(`[WebProxy] prepareForPageLoad failed for carrier ${spec.id}`);
    }
  }

  private preconnectUrl(spec: WebProxyCarrierSpec): string {
    const raw: string = spec.pathPrefix.trim();
    if (raw.length === 0) {
      return spec.origin + '/';
    }
    const lead: string = raw.startsWith('/') ? raw : '/' + raw;
    return spec.origin + (lead.endsWith('/') ? lead : lead + '/');
  }

  private publishSpecs(): void {
    const list: WebProxyCarrierSpec[] = [];
    this.carriers.forEach((record: CarrierRecord): void => {
      list.push(record.spec);
    });
    AppStorage.setOrCreate<WebProxyCarrierSpec[]>(KEY_WEB_PROXY_CARRIERS, list);
  }
}

export const webProxyCarrierManager: TdWebProxyCarrierManager = new TdWebProxyCarrierManager();

// 仅供代理设置页在用户选择 WEB 时提前初始化 ArkWeb 引擎。
// 不放在应用启动路径：只有用户明确进入 WEB 配置才付这份内存/启动成本。
export function prewarmWebProxyEngine(): void {
  webProxyCarrierManager.prewarmEngine();
}

export function attachWebProxyCarrier(client: TdClient): void {
  webProxyCarrierManager.attach(client);
}

export function detachWebProxyCarrier(client: TdClient): void {
  webProxyCarrierManager.detach(client);
}
