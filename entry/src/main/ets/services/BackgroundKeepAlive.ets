import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { geoLocationManager } from '@kit.LocationKit';
import {
  KEY_BACKGROUND_KEEP_ALIVE, KEY_BACKGROUND_KEEP_ALIVE_MODE,
  KEEP_ALIVE_LOCATION, KEEP_ALIVE_OFF, KEEP_ALIVE_TASK_KEEPING,
  normalizeKeepAliveMode, setBoolean, setString
} from '../store/AppSettings';
import { logE, logI } from '../util/log';

// 后台保活：只有用户在「省电 → 后台持续运行」里主动选择才申请。
//
// 两个互斥模式：
//   · taskKeeping：计算任务保持（TASK_KEEPING）。保活最强、耗电最高。
//     非 PC 设备必须同时声明受限权限 KEEP_BACKGROUND_RUNNING_SYSTEM，并在
//     调试签名 profile 里带上对应 ACL；否则手机返回 9800005。
//   · location：低功耗定位（LOCATION）。保活弱一档，但只需要普通定位权限，
//     耗电低得多。官方允许「LOCATION 长时任务 + 前台定位权限」在后台取位置，
//     不需要 LOCATION_IN_BACKGROUND，也从不记录/上传坐标。
//
// 两件事都做对，后台才不会骗人：
//   1. 用带 continuousTaskId 的新接口申请，停止时只停自己那一条；
//   2. 取消回调按 taskId 过滤——否则音频/实时位置的长时任务被取消时，会把
//      这里的开关也误关掉。
export interface KeepAliveResult {
  ok: boolean;
  code: number;
  message: string;
  reason: string;
}

export const KEEP_ALIVE_REASON_NONE: string = '';
export const KEEP_ALIVE_REASON_UNSUPPORTED: string = 'unsupported';
export const KEEP_ALIVE_REASON_PERMISSION: string = 'permission';
export const KEEP_ALIVE_REASON_LOCATION_OFF: string = 'locationOff';
export const KEEP_ALIVE_REASON_FAILED: string = 'failed';

class BackgroundKeepAlive {
  private context: common.UIAbilityContext | null = null;
  private running: boolean = false;
  private mode: string = KEEP_ALIVE_OFF;
  private taskId: number = -1;
  private locationCallback: ((location: geoLocationManager.Location) => void) | null = null;
  private cancelHandler: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | null = null;
  // 进程正常退出时只是撤掉长时任务，不能把用户选过的模式写回 off——否则下次
  // 打开应用（initSettings 读持久化）看到的就是关闭。
  private shuttingDown: boolean = false;

  // 在 EntryAbility.onCreate 里尽早注入上下文。重复调用是幂等的。
  init(context: common.UIAbilityContext): void {
    this.context = context;
    if (this.cancelHandler !== null) {
      return;
    }
    this.cancelHandler = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      // 只认自己那条：同一应用里还有音频、实时位置等长时任务，它们被取消时
      // 不能把后台保活的状态一起改掉。
      if (this.taskId < 0 || info.id !== this.taskId) {
        return;
      }
      this.unsubscribeLocation();
      this.taskId = -1;
      this.running = false;
      this.mode = KEEP_ALIVE_OFF;
      logI(`[BackgroundKeepAlive] cancelled reason=${info.reason} id=${info.id}`);
      if (!this.shuttingDown) {
        this.persist(KEEP_ALIVE_OFF);
      }
    };
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelHandler);
    } catch (e) {
      // 没有权限或系统版本不支持监听：不影响主动 start/stop。
      logE(`[BackgroundKeepAlive] on(continuousTaskCancel) failed: ${(e as BusinessError).message}`);
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  currentMode(): string {
    return this.mode;
  }

  isLocationMode(): boolean {
    return this.running && this.mode === KEEP_ALIVE_LOCATION;
  }

  async start(mode: string): Promise<KeepAliveResult> {
    const target: string = normalizeKeepAliveMode(mode);
    if (target === KEEP_ALIVE_OFF) {
      await this.stop();
      return { ok: true, code: 0, message: '', reason: KEEP_ALIVE_REASON_NONE };
    }
    if (this.running && this.mode === target) {
      return { ok: true, code: 0, message: '', reason: KEEP_ALIVE_REASON_NONE };
    }
    // 两个模式互斥：先干净地停掉旧任务，再申请新任务。
    if (this.running) {
      await this.stopInternal(false);
    }
    const context = this.context;
    if (context === null) {
      this.persist(KEEP_ALIVE_OFF);
      return this.fail(-1, KEEP_ALIVE_REASON_FAILED, 'ability context is not ready');
    }
    if (target === KEEP_ALIVE_LOCATION) {
      let enabled: boolean = false;
      try {
        enabled = geoLocationManager.isLocationEnabled();
      } catch (e) {
        logE(`[BackgroundKeepAlive] isLocationEnabled failed: ${(e as BusinessError).message}`);
      }
      if (!enabled) {
        this.persist(KEEP_ALIVE_OFF);
        return this.fail(3301100, KEEP_ALIVE_REASON_LOCATION_OFF, 'location switch is off');
      }
      // 先订阅再申请长时任务：系统会检查 LOCATION 任务是否真的在使用定位，
      // 顺序反了可能刚申请就被 SYSTEM_CANCEL_NOT_USE_LOCATION 取消。
      try {
        this.subscribeLocation();
      } catch (e) {
        const err = e as BusinessError;
        const code: number = err.code ?? -1;
        this.persist(KEEP_ALIVE_OFF);
        return this.fail(code, this.reasonOf(code), err.message ?? `${e}`);
      }
    }
    try {
      const agent: WantAgent = await this.buildAgent(context);
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [target === KEEP_ALIVE_TASK_KEEPING
        ? backgroundTaskManager.BackgroundTaskMode.MODE_TASK_KEEPING
        : backgroundTaskManager.BackgroundTaskMode.MODE_LOCATION];
      // 官方示例要求同时给子类型；缺省时真机回报「continuousRequestInfo cannot be null」。
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION];
      request.wantAgent = agent;
      request.combinedTaskNotification = false;
      request.continuousTaskId = -1;
      const info: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, request);
      this.taskId = info.continuousTaskId ?? -1;
      this.running = true;
      this.mode = target;
      this.persist(target);
      logI(`[BackgroundKeepAlive] started mode=${target} taskId=${this.taskId}`);
      return { ok: true, code: 0, message: '', reason: KEEP_ALIVE_REASON_NONE };
    } catch (e) {
      this.unsubscribeLocation();
      this.taskId = -1;
      this.running = false;
      this.mode = KEEP_ALIVE_OFF;
      this.persist(KEEP_ALIVE_OFF);
      const err = e as BusinessError;
      const code: number = err.code ?? -1;
      const message: string = err.message ?? `${e}`;
      logE(`[BackgroundKeepAlive] start ${target} failed code=${code} message=${message}`);
      return this.fail(code, this.reasonOf(code), message);
    }
  }

  async stop(): Promise<void> {
    await this.stopInternal(true);
  }

  private async stopInternal(persistMode: boolean): Promise<void> {
    this.unsubscribeLocation();
    const context = this.context;
    const id: number = this.taskId;
    const wasRunning: boolean = this.running;
    this.taskId = -1;
    this.running = false;
    this.mode = KEEP_ALIVE_OFF;
    // 没有任何属于本服务的任务时不能调无 id 的 stop：那个重载会取消该 ability
    // 的全部长时任务，把正在播放的音乐/实时位置/通话一起停掉。
    if (context !== null && (wasRunning || id >= 0)) {
      try {
        if (id >= 0) {
          await backgroundTaskManager.stopBackgroundRunning(context, id);
          logI(`[BackgroundKeepAlive] stopped taskId=${id}`);
        } else {
          // 极少数系统不返回 id：只能退回整 ability 停止，避免任务残留。
          await backgroundTaskManager.stopBackgroundRunning(context);
          logI('[BackgroundKeepAlive] stopped without taskId');
        }
      } catch (e) {
        // 已经不在运行（例如用户先从通知栏取消）时这里会报错，属正常收尾。
        logE(`[BackgroundKeepAlive] stop failed: ${(e as BusinessError).message}`);
      }
    }
    if (persistMode) {
      this.persist(KEEP_ALIVE_OFF);
    }
  }

  private subscribeLocation(): void {
    if (this.locationCallback !== null) {
      return;
    }
    const request: geoLocationManager.LocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
      scenario: geoLocationManager.LocationRequestScenario.NO_POWER,
      timeInterval: 60
    };
    const callback = (_location: geoLocationManager.Location): void => {
      // 坐标在这里直接丢掉：低功耗模式只借定位请求维持长时任务，
      // 不落盘、不打印、不上传。
    };
    this.locationCallback = callback;
    geoLocationManager.on('locationChange', request, callback);
  }

  // 退出应用专用：撤任务但不改持久化，保留用户选择供下次启动恢复。
  async stopForShutdown(): Promise<void> {
    this.shuttingDown = true;
    await this.stopInternal(false);
  }

  private unsubscribeLocation(): void {
    const callback = this.locationCallback;
    this.locationCallback = null;
    if (callback === null) {
      return;
    }
    try {
      geoLocationManager.off('locationChange', callback);
    } catch (e) {
      logE(`[BackgroundKeepAlive] off(locationChange) failed: ${(e as BusinessError).message}`);
    }
  }

  private persist(mode: string): void {
    if (this.shuttingDown) {
      return;
    }
    // 模式是唯一真相源；旧布尔键只作迁移与兼容，避免两个开关各说各话。
    setString(KEY_BACKGROUND_KEEP_ALIVE_MODE, mode);
    setBoolean(KEY_BACKGROUND_KEEP_ALIVE, mode !== KEEP_ALIVE_OFF);
  }

  private reasonOf(code: number): string {
    if (code === 9800005) {
      return KEEP_ALIVE_REASON_UNSUPPORTED;
    }
    if (code === 201) {
      return KEEP_ALIVE_REASON_PERMISSION;
    }
    if (code === 3301100) {
      return KEEP_ALIVE_REASON_LOCATION_OFF;
    }
    return KEEP_ALIVE_REASON_FAILED;
  }

  private fail(code: number, reason: string, message: string): KeepAliveResult {
    return { ok: false, code: code, message: message, reason: reason };
  }

  private async buildAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.applicationInfo.name,
        abilityName: context.abilityInfo.name,
        parameters: { 'keepAlive': 1 }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 7301,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
  }
}

export const backgroundKeepAlive: BackgroundKeepAlive = new BackgroundKeepAlive();
