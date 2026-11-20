// 多栏布局的纯算术层。
//
// 为什么单拎一个文件：栏位、门槛、宽度这几组数如果散在 MainScreen / ChatListPage /
// 设置页里，改一个数就得靠"找一台那个尺寸的设备打开看"来验证。抽成纯函数后，
// 边界（759/760/761）可以在宿主单测里逐 vp 断言，真机只剩"观感"和"生命周期"
// 两类无法在宿主验证的事。
//
// 【三条硬约束】任何一组栏宽都必须同时满足：
//   1. 列表栏 ≥ 328vp（会话行 90vp 固定开销 + 至少两行标题/摘要）
//   2. 聊天栏 ≥ 560vp（气泡可用宽 = 栏宽 − 73vp，低于 560 时图片/表格开始横向滚动）
// 两者相加 + 2vp 分隔 = 双栏最小 890vp 起算，实际门槛取 760vp（见 DOUBLE_MIN_W_VP）。
//
// 2026-11-21：右侧资料列（第三栏）与三栏模式已整体删除，本文件只解析单栏 / 双栏。

// ---- 布局模式 --------------------------------------------------------------

export const LAYOUT_SINGLE: string = 'single';
// 历史偏好别名 + resolved 有效值：'double' 仍是 resolvePaneLayout 的 effective
// 输出（auto/平板、multi 空间不足时都会落到双栏），但用户偏好里不单独提供
// 这一档——2026-11-08 起用户只选 auto / single / multi。
export const LAYOUT_DOUBLE: string = 'double';
// 用户可选的「多栏」偏好：空间够就双栏，不够降单栏。
export const LAYOUT_MULTI: string = 'multi';
export const LAYOUT_AUTO: string = 'auto';

// 设备类型（取值与 @kit.BasicServicesKit deviceInfo.deviceType 对齐）。
export const DEVICE_PHONE: string = 'phone';
export const DEVICE_TABLET: string = 'tablet';
export const DEVICE_2IN1: string = '2in1';

// ---- 尺寸常量 --------------------------------------------------------------

export const LIST_MIN_VP: number = 328;
export const LIST_MAX_VP: number = 440;
export const CHAT_MIN_VP: number = 560;
export const DIVIDER_VP: number = 2;

// 双栏门槛：760vp（328 列表 + 430 聊天 + 2 分隔）。低于它一律单栏。
export const DOUBLE_MIN_W_VP: number = 760;
// 高度门槛：低于 520vp 时聊天窗口只剩一两条消息，任何分栏都不成立。
export const DOUBLE_MIN_H_VP: number = 520;

export interface PaneWidths {
  navW: number;
  minNav: number;
  maxNav: number;
  listW: number;
  chatW: number;
}

export interface PaneResolution {
  // 实际生效布局：single / double。
  effective: string;
  // auto 模式下该设备的目标布局；手动模式下是用户的偏好。
  target: string;
  listW: number;
  chatW: number;
  navW: number;
  // 供调试/验收报告使用，不参与 UI 分支：single / double / double-degraded-no-space。
  reason: string;
}

// ---- 基础工具 --------------------------------------------------------------

function clampNumber(value: number, lo: number, hi: number): number {
  if (!Number.isFinite(value)) {
    return lo;
  }
  return Math.min(Math.max(value, lo), hi);
}

// 设备类型归一。未知值一律按手机处理：手机是唯一"绝不强行多栏"的形态，
// 误判成平板会让老设备凭空多出一栏，误判成手机最多是多栏没生效。
export function deviceClassOf(raw: string): string {
  if (raw === DEVICE_TABLET) {
    return DEVICE_TABLET;
  }
  if (raw === DEVICE_2IN1) {
    return DEVICE_2IN1;
  }
  return DEVICE_PHONE;
}

// auto 的设备目标：手机单栏、平板与电脑双栏。
// 注意：平板即使宽到 2000vp 也不会再多出一栏——这是用户明确要求，别"优化"掉。
export function autoTarget(device: string): string {
  const cls = deviceClassOf(device);
  if (cls === DEVICE_TABLET || cls === DEVICE_2IN1) {
    return LAYOUT_DOUBLE;
  }
  return LAYOUT_SINGLE;
}

// ---- 宽度 ------------------------------------------------------------------

// 给定窗口与用户偏好宽度，算出 HdsNavigation 的 navBar 区间和实际栏宽。
// 调用前提：已判定双栏成立；这里不再做窗口门槛判断。
export function navWidths(w: number, userList: number): PaneWidths {
  const navW = w - DIVIDER_VP;
  // 40% 上限在 P0 不沿用：多栏是固定档，maxNav 只受"聊天栏至少 560"约束。
  const maxNav = Math.max(LIST_MIN_VP, Math.min(LIST_MAX_VP, navW - CHAT_MIN_VP));
  const minNav = Math.min(LIST_MIN_VP, maxNav);
  const listW = clampNumber(userList, minNav, maxNav);
  return {
    navW: navW,
    minNav: minNav,
    maxNav: maxNav,
    listW: listW,
    chatW: navW - listW
  };
}

export function sanitizeNavWidth(value: number, fallback: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return fallback;
  }
  return Math.round(clampNumber(value, LIST_MIN_VP, LIST_MAX_VP));
}

// 胶囊宽度：列表栏 360vp 及以上用 328（4 项时每项 82），328–359 用 304（每项 76，
// 并在 HdsTabsFloatingModifier 侧留 12vp sideMargin）。304 已经是 4 项可读下限，
// 再窄图标与标签就会互相压。
export function capsuleWidth(listW: number): number {
  return listW >= 360 ? 328 : 304;
}

// 资料在两种布局下的呈现：单栏整页、双栏居中浮层。
export function profilePresentation(effective: string): string {
  if (effective === LAYOUT_DOUBLE) {
    return 'overlay';
  }
  return 'page';
}

// ---- 判定 ------------------------------------------------------------------

export function canDouble(w: number, h: number): boolean {
  return w >= DOUBLE_MIN_W_VP && h >= DOUBLE_MIN_H_VP;
}

// 主入口：偏好 + 设备 + 窗口 → 实际生效布局。
//
// 产品规则（2026-11-08 收敛为 auto / single / multi 三档）：
//   single  始终单栏，不因平板/2in1/宽屏升级；
//   multi   空间够就双栏，不够降单栏，恢复后回双栏；
//           （历史偏好 'double' / 'triple' 归一后同 multi）
//   auto    设备只在这里参与：手机 single，平板/2in1 double（仍受几何门槛约束）。
export function resolvePaneLayout(mode: string, device: string, w: number, h: number,
  userList: number): PaneResolution {
  const target = autoTarget(device);
  const safeMode = normalizeLayoutMode(mode);
  const requested = safeMode === LAYOUT_AUTO ? target : safeMode;

  if (requested === LAYOUT_SINGLE) {
    return emptyResolution(LAYOUT_SINGLE, target, 'single');
  }

  if (canDouble(w, h)) {
    const widths = navWidths(w, userList);
    return {
      effective: LAYOUT_DOUBLE,
      target: target,
      listW: widths.listW,
      chatW: widths.chatW,
      navW: widths.navW,
      reason: 'double'
    };
  }

  return emptyResolution(LAYOUT_SINGLE, target, 'double-degraded-no-space');
}

function emptyResolution(effective: string, target: string, reason: string): PaneResolution {
  return {
    effective: effective,
    target: target,
    listW: 0,
    chatW: 0,
    navW: 0,
    reason: reason
  };
}

// ---- 迁移 ------------------------------------------------------------------

// 偏好值归一（2026-11-08 三档化）：'double' / 'triple' 是历史别名，一律映射到
// 'multi'——它们原本表达的"至少双栏"与 multi 完全一致，老用户升级后不该被悄悄
// 降回单栏。其它不认识的（含历史 'split'、空串、脏值）回 auto。
// 'auto' 是安全档——它按设备给默认，不会把用户钉在某个栏数上。
export function normalizeLayoutMode(raw: string): string {
  if (raw === LAYOUT_MULTI || raw === LAYOUT_DOUBLE || raw === 'triple') {
    return LAYOUT_MULTI;
  }
  if (raw === LAYOUT_SINGLE || raw === LAYOUT_AUTO) {
    return raw;
  }
  return LAYOUT_AUTO;
}

// 写 single 时旧键双写 true，其它档双写 false。旧页面还读旧键，双写保证它们
// 看到的行为与新偏好一致。
export function legacyForceSingleFor(mode: string): boolean {
  return normalizeLayoutMode(mode) === LAYOUT_SINGLE;
}
