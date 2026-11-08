// 统一布局状态接入层（P1）。
//
// 目标：页面不再自己拼「模式 + 设备 + 窗口」，也不各自读旧开关。唯一链路是
//   LayoutSettingsSnapshot（AppStorage 里的偏好）
//     → resolveForSnapshot / publishLayoutState（paneLayout.resolvePaneLayout）
//     → resolvedLayout（AppStorage，运行时派生，不落盘）
//     → 页面只读 resolvedLayout 决定分栏 / 资料呈现 / 胶囊宽度。
//
// 三条硬约束（与 10 号 D-121～D-126 一致）：
//   1. layoutMode 是唯一用户偏好；resolvedLayout 只解析、不写回 Preferences。
//   2. infoVisible 新布局下恒等于 resolvedLayout === 'triple'，没有独立开关。
//   3. v2 关闭时不发布派生键，页面继续走旧 isSplitByBreakpoint 路径；这保证
//      P0 的回滚语义（关掉开关后旧布局原样）不被 P1 接线破坏。
//
// 迟滞只在 auto + 2in1 生效：上一轮是 triple 时用退出阈值，否则用进入阈值。
// prevTriple 从已发布的 resolvedLayout 读取，不额外加持久化键。

import { deviceInfo } from '@kit.BasicServicesKit';
import {
  DEVICE_2IN1, LAYOUT_AUTO, LAYOUT_DOUBLE, LAYOUT_SINGLE, LAYOUT_TRIPLE,
  PaneResolution, capsuleWidth, deviceClassOf, profilePresentation, resolvePaneLayout
} from './paneLayout';
import { LayoutSettingsSnapshot, readLayoutSettings } from './layoutModeSettings';

export const KEY_RESOLVED_LAYOUT: string = 'resolvedLayout';
export const KEY_RESOLVED_INFO_VISIBLE: string = 'resolvedInfoVisible';
export const KEY_RESOLVED_LIST_W: string = 'resolvedListW';
export const KEY_RESOLVED_CHAT_W: string = 'resolvedChatW';
export const KEY_RESOLVED_REASON: string = 'resolvedLayoutReason';

// 当前设备类别。deviceInfo.deviceType 失败时按手机处理（最保守）。
export function currentDeviceClass(): string {
  try {
    return deviceClassOf(deviceInfo.deviceType);
  } catch (e) {
    return 'phone';
  }
}

// 解析时该用哪份列表宽：三栏（含 auto 的 2in1 目标）用 navWidthTriple，
// 其余用 navWidthDouble。它是"输入偏好"，不是持久化判据。
export function listWidthFor(snapshot: LayoutSettingsSnapshot, device: string): number {
  const cls: string = deviceClassOf(device);
  const wantsTripleWidth: boolean = snapshot.mode === LAYOUT_TRIPLE ||
    (snapshot.mode === LAYOUT_AUTO && cls === DEVICE_2IN1);
  return wantsTripleWidth ? snapshot.navWidthTriple : snapshot.navWidthDouble;
}

// 纯函数：偏好快照 + 设备 + 窗口 + 上一轮是否三栏 → 实际布局。
export function resolveForSnapshot(snapshot: LayoutSettingsSnapshot, device: string,
  w: number, h: number, prevTriple: boolean): PaneResolution {
  return resolvePaneLayout(snapshot.mode, device, w, h,
    listWidthFor(snapshot, device), snapshot.infoWidth, prevTriple);
}

// ---- 页面侧只读派生 --------------------------------------------------------

export function resolvedSplitActive(resolved: string): boolean {
  return resolved === LAYOUT_DOUBLE || resolved === LAYOUT_TRIPLE;
}

export function resolvedInfoVisible(resolved: string): boolean {
  return resolved === LAYOUT_TRIPLE;
}

// 'page' / 'overlay' / 'column'。v2 关闭时调用方应自行走旧逻辑。
export function resolvedProfileMode(resolved: string): string {
  return profilePresentation(resolved);
}

// 单栏没有胶囊；多栏按列表宽给 304/328。
export function resolvedCapsuleWidth(resolved: string, listW: number): number {
  return resolvedSplitActive(resolved) ? capsuleWidth(listW) : 0;
}

// ---- 发布 / 读取 ------------------------------------------------------------

function legacyResolution(): PaneResolution {
  return {
    effective: LAYOUT_SINGLE,
    target: LAYOUT_SINGLE,
    infoW: 0,
    listW: 0,
    chatW: 0,
    navW: 0,
    infoVisible: false,
    reason: 'layout-v2-disabled'
  };
}

export function clearResolvedLayout(): void {
  AppStorage.setOrCreate(KEY_RESOLVED_LAYOUT, '');
  AppStorage.setOrCreate(KEY_RESOLVED_INFO_VISIBLE, false);
  AppStorage.setOrCreate(KEY_RESOLVED_LIST_W, 0);
  AppStorage.setOrCreate(KEY_RESOLVED_CHAT_W, 0);
  AppStorage.setOrCreate(KEY_RESOLVED_REASON, 'layout-v2-disabled');
}

// 由 MainScreen 在窗口尺寸 / 断点 / 布局模式变化时调用。v2 关闭时清空派生键
// 并返回单栏，页面据此继续读旧判据。actualListW 是布局回调里量到的真实列表宽
// （拖分割线后与配置值不同），>0 时优先发布它，胶囊宽度才不会滞后。
export function publishLayoutState(device: string, w: number, h: number,
  actualListW: number = 0): PaneResolution {
  const snapshot: LayoutSettingsSnapshot = readLayoutSettings();
  if (w <= 0 || h <= 0) {
    clearResolvedLayout();
    return legacyResolution();
  }
  const prevTriple: boolean = AppStorage.get<string>(KEY_RESOLVED_LAYOUT) === LAYOUT_TRIPLE;
  const resolution: PaneResolution = resolveForSnapshot(snapshot, device, w, h, prevTriple);
  const listW: number = resolvedSplitActive(resolution.effective) && actualListW > 0
    ? actualListW : resolution.listW;
  AppStorage.setOrCreate(KEY_RESOLVED_LAYOUT, resolution.effective);
  AppStorage.setOrCreate(KEY_RESOLVED_INFO_VISIBLE, resolution.infoVisible);
  AppStorage.setOrCreate(KEY_RESOLVED_LIST_W, listW);
  AppStorage.setOrCreate(KEY_RESOLVED_CHAT_W, resolution.chatW);
  AppStorage.setOrCreate(KEY_RESOLVED_REASON, resolution.reason);
  return resolution;
}

export function readResolvedLayout(): string {
  return AppStorage.get<string>(KEY_RESOLVED_LAYOUT) ?? '';
}

// 页面里判断"新布局是否接管"的唯一谓词，避免各处自己拼 v2 开关 + 空串。
export function resolvedLayoutActive(resolved: string): boolean {
  return resolved === LAYOUT_SINGLE || resolved === LAYOUT_DOUBLE || resolved === LAYOUT_TRIPLE;
}
