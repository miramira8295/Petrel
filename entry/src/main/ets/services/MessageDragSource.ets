import { UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { unifiedDataChannel as udc } from '@kit.ArkData';
import { fileUri, fileIo } from '@kit.CoreFileKit';
import { messageDragOriginTag, setMessageDragActive } from '../util/messageDragOrigin';
import { getActiveTdAccountSlot, getTdClient } from '../tdkit/Globals';
import { TdObject, TdRequest } from '../tdkit/TdTypes';
import { completedDragFilePath, messageDragPayload, messageDragPhotoFileIds } from '../util/messageDrag';
import { logW } from '../util/log';

interface PreparedMessageDrag {
  dataLoadParams: udc.DataLoadParams;
  originTag: string;
}

function mediaRecord(type: string, uri: string): udc.File {
  if (type === 'general.image') { const imageRecord = new udc.Image(); imageRecord.imageUri = uri; return imageRecord; }
  if (type === 'general.video') { const video = new udc.Video(); video.videoUri = uri; return video; }
  if (type === 'general.audio') { const audio = new udc.Audio(); audio.audioUri = uri; return audio; }
  const file = new udc.File(); file.uri = uri; return file;
}

function textRecord(text: string): udc.PlainText {
  const textRecord = new udc.PlainText();
  textRecord.textContent = text;
  return textRecord;
}

function prepareMessageDragLoad(chatId: number, messageId: number, type: string,
  withText: boolean, text: string = ''): PreparedMessageDrag {
  const client = getTdClient();
  const originTag = messageDragOriginTag(getActiveTdAccountSlot(), chatId);
  // 纯文字随手就有，不要为它去走 TDLib（getMessage/getMessageProperties 各 3 秒，
  // 接收方取数据时会一直等到超时，表现为松手后拖拽残留两三秒才消失）。
  if (type === 'general.plain-text' && text !== '') {
    const types = new Set<string>([type]);
    const build = (): udc.UnifiedData => new udc.UnifiedData(textRecord(text));
    const syncParams: udc.DataLoadParams = {
      dataLoadInfo: { types, recordCount: 1 },
      loadHandler: (): udc.UnifiedData | null => build(),
      delayedDataLoadHandler: (): Promise<udc.UnifiedData | null> => Promise.resolve(build())
    };
    return { dataLoadParams: syncParams, originTag };
  }
  const filePathNow = async (fileId: number): Promise<string> => {
    const req: TdRequest = { '@type': 'getFile' };
    req['file_id'] = fileId;
    return completedDragFilePath(await client.send(req, 3000));
  };
  // 图片拖拽不要求提前下载：先找已落盘的尺寸，再按原图优先补下载（12 秒），
  // 超时逐级退到较小尺寸（各 6 秒），保证松手时一定有内容或明确的空结果。
  const downloadAndWait = async (fileId: number, budgetMs: number): Promise<string> => {
    try {
      const req: TdRequest = { '@type': 'downloadFile' };
      req['file_id'] = fileId;
      req['priority'] = 32;
      req['offset'] = 0;
      req['limit'] = 0;
      req['synchronous'] = false;
      await client.send(req, 3000);
    } catch (_) { return ''; }
    const start = Date.now();
    while (Date.now() - start < budgetMs) {
      if (client !== getTdClient()) { return ''; }
      const path = await filePathNow(fileId);
      if (path !== '') { return path; }
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 200); });
    }
    return '';
  };
  const imagePath = async (message: TdObject, fallbackId: number): Promise<string> => {
    const ids: number[] = messageDragPhotoFileIds(message);
    if (ids.length === 0 && fallbackId > 0) { ids.push(fallbackId); }
    if (ids.length === 0) { return ''; }
    // 原图优先：已在本地就直接用，没下载就现场补（12 秒）。
    const original = await filePathNow(ids[0]);
    if (original !== '') { return original; }
    const fresh = await downloadAndWait(ids[0], 12000);
    if (fresh !== '') { return fresh; }
    // 原图失败再回退：先找任意已落盘的尺寸，再逐级下载较小尺寸（各 6 秒）。
    for (const id of ids) {
      const path = await filePathNow(id);
      if (path !== '') { return path; }
    }
    for (let i = 1; i < ids.length; i++) {
      const path = await downloadAndWait(ids[i], 6000);
      if (path !== '') { return path; }
    }
    return '';
  };
  // 起拖瞬间就开始拉原图，别等接收方来要数据才下载：中转站/小艺取数据有超时，
  // 提前几秒往往就是「有内容」和「空拖拽」的区别。
  const warmImage = async (): Promise<void> => {
    try {
      const msgReq: TdRequest = { '@type': 'getMessage' };
      msgReq['chat_id'] = chatId; msgReq['message_id'] = messageId;
      const message = await client.send(msgReq, 3000);
      const ids: number[] = messageDragPhotoFileIds(message);
      if (ids.length === 0) { return; }
      for (const id of ids) {
        if (await filePathNow(id) !== '') { return; }
      }
      const req: TdRequest = { '@type': 'downloadFile' };
      req['file_id'] = ids[0]; req['priority'] = 32; req['offset'] = 0; req['limit'] = 0;
      req['synchronous'] = false;
      await client.send(req, 3000);
    } catch (_) { }
  };
  if (type === 'general.image') {
    warmImage().then((): void => { }, (): void => { });
  }
  const load = async (): Promise<udc.UnifiedData | null> => {
    try {
      if (client !== getTdClient()) { return null; }
      const req: TdRequest = { '@type': 'getMessage' };
      req['chat_id'] = chatId; req['message_id'] = messageId;
      const propsReq: TdRequest = { '@type': 'getMessageProperties' };
      propsReq['chat_id'] = chatId; propsReq['message_id'] = messageId;
      const results: TdObject[] = await Promise.all([client.send(req, 3000), client.send(propsReq, 3000)]);
      const payload = messageDragPayload(results[0], results[1]);
      if (!payload || payload.type !== type || client !== getTdClient()) { return null; }
      if (payload.fileId !== 0) {
        let path: string = '';
        if (type === 'general.image') {
          path = await imagePath(results[0], payload.fileId);
        } else {
          const fileReq: TdRequest = { '@type': 'getFile' };
          fileReq['file_id'] = payload.fileId;
          path = completedDragFilePath(await client.send(fileReq, 3000));
        }
        if (path === '' || !await fileIo.access(path) || client !== getTdClient()) {
          // 图片补下载失败时至少把说明文字送出去，不静默丢内容。
          return type === 'general.image' && payload.text !== ''
            ? new udc.UnifiedData(textRecord(payload.text)) : null;
        }
        const data = new udc.UnifiedData(mediaRecord(type, fileUri.getUriFromPath(path)));
        // 图文混合：文件之后紧跟说明文字，接收端两条记录都能拿到。
        if (payload.text !== '') { data.addRecord(textRecord(payload.text)); }
        return data;
      }
      return payload.text !== '' ? new udc.UnifiedData(textRecord(payload.text)) : null;
    } catch (_) {
      logW('[DragOut] content unavailable');
      return null;
    }
  };
  const types = new Set<string>([type]);
  const recordCount: number = withText && type !== 'general.plain-text' ? 2 : 1;
  if (recordCount > 1) { types.add('general.plain-text'); }
  const dataLoadParams: udc.DataLoadParams = {
    dataLoadInfo: { types, recordCount },
    loadHandler: (): udc.UnifiedData | null => null,
    delayedDataLoadHandler: (): Promise<udc.UnifiedData | null> => {
      // 每次被取数据都重新装配一份 UnifiedData：同一个实例被接收方消费后再交出去，
      // 第二次拖到小艺/中转站就会拿到空数据（表现为「小艺接收口只出现一次」）。
      // 文件已在本地，重装只是几次 TDLib 查询，不会重复下载。
      return load().then((data: udc.UnifiedData | null): udc.UnifiedData | null => {
        if (client !== getTdClient() || data === null) { return null; }
        const properties = data.properties;
        properties.tag = originTag;
        data.properties = properties;
        return data;
      });
    }
  };
  return { dataLoadParams, originTag };
}

// The system owns this one-shot provider after drag start. Do not bind its lifetime
// to a recycled bubble or to onDragEnd (receivers may still be reading then).
// 系统拖拽结束（onDragEnd）时清掉进程内标记；起拖标记由上面两个入口写入。
export function endMessageDrag(): void {
  setMessageDragActive(false);
}

export function configureMessageDrag(event: DragEvent, chatId: number, messageId: number, type: string,
  withText: boolean = false, text: string = ''): DragItemInfo {
  const prepared = prepareMessageDragLoad(chatId, messageId, type, withText, text);
  setMessageDragActive(true);
  event.setDataLoadParams(prepared.dataLoadParams);
  return { extraInfo: prepared.originTag };
}

// Proactive touch drag initiated only after finger travel crosses the large
// distance threshold, allowing stationary holds to open the context menu immediately.
export function startMessageTouchDrag(ui: UIContext, pointerId: number, chatId: number,
  messageId: number, type: string, nodeId: string, onEnd: () => void, withText: boolean = false,
  text: string = ''): boolean {
  if (type === '' || nodeId === '') { return false; }
  let pixelMap: image.PixelMap | undefined = undefined;
  try {
    pixelMap = ui.getComponentSnapshot().getSync(nodeId);
  } catch (_) {
    return false;
  }
  const prepared = prepareMessageDragLoad(chatId, messageId, type, withText, text);
  const item: DragItemInfo = { pixelMap, extraInfo: prepared.originTag };
  try {
    ui.getDragController().executeDrag(item, {
      pointerId,
      dataLoadParams: prepared.dataLoadParams,
      extraParams: JSON.stringify({ extraInfo: prepared.originTag })
    }).then((): void => {
      setMessageDragActive(false);
      onEnd();
    }, (): void => {
      setMessageDragActive(false);
      onEnd();
    });
    setMessageDragActive(true);
    return true;
  } catch (_) {
    return false;
  }
}
