// 统一布局状态接入层。
//
// 目标：页面不再自己拼「模式 + 设备 + 窗口」，也不各自读旧开关。唯一链路是
//   LayoutSettingsSnapshot（AppStorage 里的偏好）
//     → resolveForSnapshot / publishLayoutState（paneLayout.resolvePaneLayout）
//     → resolvedLayout（AppStorage，运行时派生，不落盘）
//     → 页面只读 resolvedLayout 决定分栏 / 资料呈现 / 胶囊宽度。
//
// 三条硬约束：
//   1. layoutMode 是唯一用户偏好；resolvedLayout 只解析、不写回 Preferences。
//   2. 2026-11-21 起右侧资料列（第三栏）已删除，resolvedLayout 只出 single / double。
//   3. 窗口几何不够时降回单栏，页面按 resolvedLayout 走单栏路径。

import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import {
  LAYOUT_DOUBLE, LAYOUT_SINGLE, PaneResolution, capsuleWidth, deviceClassOf,
  profilePresentation, resolvePaneLayout
} from './paneLayout';
import { LayoutSettingsSnapshot, readLayoutSettings } from './layoutModeSettings';

export const KEY_RESOLVED_LAYOUT: string = 'resolvedLayout';
export const KEY_RESOLVED_LIST_W: string = 'resolvedListW';
export const KEY_RESOLVED_CHAT_W: string = 'resolvedChatW';
export const KEY_RESOLVED_REASON: string = 'resolvedLayoutReason';

// 当前设备类别。deviceInfo.deviceType 失败时按手机处理（最保守）。
//
// 折叠屏手机（Pura X 这类）展开后 deviceType 仍是 'phone'。若照直返回手机，
// 「自动」布局会永远解析成单栏，用户看到的就是「折叠/分屏模式没了」。展开态
// 按平板处理：auto 目标变双栏；窗口几何不够时 resolvePaneLayout 的 canDouble
// 仍会把它降回单栏，所以外屏（折叠态）行为不变。
export function currentDeviceClass(): string {
  let raw: string = 'phone';
  try {
    raw = deviceInfo.deviceType;
  } catch (e) {
    return 'phone';
  }
  const cls: string = deviceClassOf(raw);
  if (cls !== 'phone') {
    return cls;
  }
  try {
    if (display.isFoldable() && display.getFoldStatus() === display.FoldStatus.FOLD_STATUS_EXPANDED) {
      return 'tablet';
    }
  } catch (e) {
    // 非折叠设备或老 API：按手机处理。
  }
  return 'phone';
}

// 解析时该用哪份列表宽：只有一份（双栏宽）。保留函数是为了让调用方不必知道
// 快照里有哪些字段，取值逻辑仍集中在快照里。
export function listWidthFor(snapshot: LayoutSettingsSnapshot): number {
  return snapshot.navWidthDouble;
}

// 纯函数：偏好快照 + 设备 + 窗口 → 实际布局。
export function resolveForSnapshot(snapshot: LayoutSettingsSnapshot, device: string,
  w: number, h: number): PaneResolution {
  return resolvePaneLayout(snapshot.mode, device, w, h, listWidthFor(snapshot));
}

// ---- 页面侧只读派生 --------------------------------------------------------

export function resolvedSplitActive(resolved: string): boolean {
  return resolved === LAYOUT_DOUBLE;
}

// 'page' / 'overlay'。单栏整页、双栏居中浮层。
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
    listW: 0,
    chatW: 0,
    navW: 0,
    reason: 'layout-inactive'
  };
}

export function clearResolvedLayout(): void {
  AppStorage.setOrCreate(KEY_RESOLVED_LAYOUT, '');
  AppStorage.setOrCreate(KEY_RESOLVED_LIST_W, 0);
  AppStorage.setOrCreate(KEY_RESOLVED_CHAT_W, 0);
  AppStorage.setOrCreate(KEY_RESOLVED_REASON, 'layout-inactive');
}

// 由 MainScreen 在窗口尺寸 / 断点 / 布局模式变化时调用。窗口无效时清空派生键
// 并返回单栏。actualListW 是布局回调里量到的真实列表宽（拖分割线后与配置值
// 不同），>0 时优先发布它，胶囊宽度才不会滞后。
export function publishLayoutState(device: string, w: number, h: number,
  actualListW: number = 0): PaneResolution {
  const snapshot: LayoutSettingsSnapshot = readLayoutSettings();
  if (w <= 0 || h <= 0) {
    clearResolvedLayout();
    return legacyResolution();
  }
  const resolution: PaneResolution = resolveForSnapshot(snapshot, device, w, h);
  const listW: number = resolvedSplitActive(resolution.effective) && actualListW > 0
    ? actualListW : resolution.listW;
  AppStorage.setOrCreate(KEY_RESOLVED_LAYOUT, resolution.effective);
  AppStorage.setOrCreate(KEY_RESOLVED_LIST_W, listW);
  AppStorage.setOrCreate(KEY_RESOLVED_CHAT_W, resolution.chatW);
  AppStorage.setOrCreate(KEY_RESOLVED_REASON, resolution.reason);
  return resolution;
}

export function readResolvedLayout(): string {
  return AppStorage.get<string>(KEY_RESOLVED_LAYOUT) ?? '';
}

// 页面里判断"新布局是否接管"的唯一谓词，避免各处自己拼空串。
export function resolvedLayoutActive(resolved: string): boolean {
  return resolved === LAYOUT_SINGLE || resolved === LAYOUT_DOUBLE;
}
