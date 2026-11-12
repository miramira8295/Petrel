// 多栏布局的纯算术层（P0）。
//
// 为什么单拎一个文件：栏位、门槛、宽度这几组数如果散在 MainScreen / ChatListPage /
// 设置页里，改一个数就得靠"找一台那个尺寸的设备打开看"来验证。抽成纯函数后，
// 边界（759/760/761、1189/1190、1261/1262）可以在宿主单测里逐 vp 断言，
// 真机只剩"观感"和"生命周期"两类无法在宿主验证的事。
//
// 【权威来源】tablet-redesign/05_多栏布局与窗口适配规范.md（v0.2 及后续修订）、
// 10_最终设计决策记录.md（D-105/D-106/D-121/D-122/D-123/D-127）。
// 任何数字改动必须先改设计文档、再改这里、再改单测，不允许反过来。
//
// 【三条硬约束】任何一组栏宽都必须同时满足：
//   1. 列表栏 ≥ 328vp（会话行 90vp 固定开销 + 至少两行标题/摘要）
//   2. 聊天栏 ≥ 560vp（气泡可用宽 = 栏宽 − 73vp，低于 560 时图片/表格开始横向滚动）
//   3. 信息栏 300–400vp（低于 300 资料卡只剩标题，高于 400 聊天被挤）
// 三者相加 + 2vp 分隔 = 三栏最小 1190vp；默认配置（328/340/560）为 1262vp。
// 双栏没有信息栏，门槛只有 760vp（328 + 430 + 2）。

// ---- 布局模式 --------------------------------------------------------------

export const LAYOUT_SINGLE: string = 'single';
// 历史偏好别名 + resolved 有效值：'double' 仍是 resolvePaneLayout 的 effective
// 输出（auto/平板、multi 空间不足时都会落到双栏），但用户偏好里已不再单独提供
// 这一档——2026-11-08 起用户只选 auto / single / multi。
export const LAYOUT_DOUBLE: string = 'double';
// 历史偏好别名 + resolved 有效值：'triple' 是三栏实际生效的 effective 值，
// auto 的 2in1 目标也仍返回它；用户偏好统一写 'multi'，旧值由 normalize 归一。
export const LAYOUT_TRIPLE: string = 'triple';
// 用户可选的「多栏」偏好（2026-11-08 三档化）：空间够就三栏，不够降双栏，再
// 不够降单栏。用户原话「三栏只有在聊天页面会出现」，所以不再单独暴露三栏档位，
// 第三栏本身保留，由聊天页顶栏的资料列开关控制开合。
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
export const INFO_MIN_VP: number = 300;
export const INFO_MAX_VP: number = 400;
export const DIVIDER_VP: number = 2;

// 双栏门槛：760vp（328 列表 + 430 聊天 + 2 分隔）。低于它一律单栏。
export const DOUBLE_MIN_W_VP: number = 760;
// 高度门槛：低于 520vp 时聊天窗口只剩一两条消息，任何分栏都不成立。
export const DOUBLE_MIN_H_VP: number = 520;

// 2in1 auto 进/出三栏的滞回。进 1262（默认 360+340+560+2），退 1240。
// 只对 auto 生效：手动三栏用几何判断（1190），不设滞回，否则用户拖宽会看到
// "拖到 1262 还没进三栏"的怪异行为。
export const AUTO_TRIPLE_ENTER_VP: number = 1262;
export const AUTO_TRIPLE_EXIT_VP: number = 1240;

// 语义别名：验收报告用 ENTER/EXIT 表述，避免读代码时把 AUTO_ 前缀当成"仅自动
// 模式的唯一门槛"。两个常量是同一个值，改一个必须同时改另一个。
export const TRIPLE_ENTER_W_VP: number = AUTO_TRIPLE_ENTER_VP;
export const TRIPLE_EXIT_W_VP: number = AUTO_TRIPLE_EXIT_VP;

// 三栏的 navW 下限：328 + 560 = 888。低于它时 list/chat 无论如何都有一边不达标，
// 直接判定"不能三栏"，不要交给下面的钳制去凑一个看似合法但实际挤压的区间。
export const TRIPLE_NAV_MIN_VP: number = 888;

export interface PaneWidths {
  navW: number;
  minNav: number;
  maxNav: number;
  listW: number;
  chatW: number;
}

export interface PaneResolution {
  // 实际生效布局：single / double / triple。
  effective: string;
  // auto 模式下该设备的目标布局；手动模式下是用户的偏好。
  target: string;
  infoW: number;
  listW: number;
  chatW: number;
  navW: number;
  // 资料栏是否显示。新布局启用时必须恒等于 (effective === 'triple')，
  // 不允许任何设备默认值或独立开关覆盖它（D-123/P0-2）。
  infoVisible: boolean;
  // 供调试/验收报告使用，不参与 UI 分支：single / double / triple /
  // triple-degraded-no-space / double-degraded-no-space。
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

// auto 的设备目标（D-121）：手机单栏、平板双栏、2in1 三栏。
// 注意：平板即使宽到 2000vp 也不自动三栏——这是用户明确要求，别"优化"掉。
export function autoTarget(device: string): string {
  const cls = deviceClassOf(device);
  if (cls === DEVICE_2IN1) {
    return LAYOUT_TRIPLE;
  }
  if (cls === DEVICE_TABLET) {
    return LAYOUT_DOUBLE;
  }
  return LAYOUT_SINGLE;
}

// 信息栏的默认开合：2in1 默认开（三栏目标），其余默认关（双栏/单栏下没有列）。
// 它在"自动"且用户没手动关过时生效；手动模式仍尊重用户上次开合。
export function infoVisibleDefault(device: string): boolean {
  return deviceClassOf(device) === DEVICE_2IN1;
}

// ---- 宽度 ------------------------------------------------------------------

// 给定窗口与信息栏宽，算出 HdsNavigation 的 navBar 区间和实际栏宽。
// 调用前提：已判定 double 或 triple 成立；这里不再做窗口门槛判断。
export function navWidths(w: number, infoW: number, userList: number): PaneWidths {
  const navW = w - infoW - DIVIDER_VP;
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

export function sanitizeInfoWidth(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return 340;
  }
  return Math.round(clampNumber(value, INFO_MIN_VP, INFO_MAX_VP));
}

// 胶囊宽度：列表栏 360vp 及以上用 328（4 项时每项 82），328–359 用 304（每项 76，
// 并在 HdsTabsFloatingModifier 侧留 12vp sideMargin）。304 已经是 4 项可读下限，
// 再窄图标与标签就会互相压。
export function capsuleWidth(listW: number): number {
  return listW >= 360 ? 328 : 304;
}

// 资料在三种布局下的呈现（D-101/D-123）：单栏整页、双栏居中浮层、三栏第三列。
export function profilePresentation(effective: string): string {
  if (effective === LAYOUT_DOUBLE) {
    return 'overlay';
  }
  if (effective === LAYOUT_TRIPLE) {
    return 'column';
  }
  return 'page';
}

// ---- 判定 ------------------------------------------------------------------

export function canDouble(w: number, h: number): boolean {
  return w >= DOUBLE_MIN_W_VP && h >= DOUBLE_MIN_H_VP;
}

export function canTriple(w: number, h: number, infoW: number, userList: number): boolean {
  if (h < DOUBLE_MIN_H_VP) {
    return false;
  }
  const info = sanitizeInfoWidth(infoW);
  const navW = w - info - DIVIDER_VP;
  if (navW < TRIPLE_NAV_MIN_VP) {
    return false;
  }
  const widths = navWidths(w, info, userList);
  return widths.chatW >= CHAT_MIN_VP;
}

// 主入口：偏好 + 设备 + 窗口 → 实际生效布局。
//
// 产品规则（2026-11-08 收敛为 auto / single / multi 三档）：
//   single  始终单栏，不因平板/2in1/宽屏升级；
//   multi   空间够三栏时三栏，不够降双栏，再不够降单栏，恢复后回三栏；
//           （历史偏好 'double' / 'triple' 归一后同 multi）
//   auto    设备只在这里参与：手机 single、平板 double、2in1 按空间 double/triple。
//
// 【资料栏】不接收独立的 infoOpen 参数。新布局下 infoVisible 是派生结果：
// effective === 'triple'。聊天页顶栏的资料列开关只决定"第三栏画不画"，
// 不参与这里解析（否则收起/展开会重算布局，窗口没变却会抖一下）。
//
// prevTriple 只影响 auto 的 2in1：从三栏退到双栏要跌破 1240，从双栏升到三栏要
// 涨到 1262，中间 22vp 是防抖带。手动模式忽略它（用户已经明确表态）。
export function resolvePaneLayout(mode: string, device: string, w: number, h: number,
  userList: number, infoW: number, prevTriple: boolean): PaneResolution {
  const target = autoTarget(device);
  const safeMode = normalizeLayoutMode(mode);
  const requested = safeMode === LAYOUT_AUTO ? target : safeMode;

  if (requested === LAYOUT_SINGLE) {
    return emptyResolution(LAYOUT_SINGLE, target, 'single');
  }

  // 'multi' 与历史别名 'triple' 都表达"有空间就要第三栏"。triple 分支必须保留：
  // auto 路径下 requested 来自 autoTarget()，2in1 返回的仍是 'triple'。
  let wantTriple = requested === LAYOUT_MULTI || requested === LAYOUT_TRIPLE;
  if (safeMode === LAYOUT_AUTO && requested === LAYOUT_TRIPLE) {
    wantTriple = prevTriple ? w >= AUTO_TRIPLE_EXIT_VP : w >= AUTO_TRIPLE_ENTER_VP;
  }

  if (wantTriple && canTriple(w, h, infoW, userList)) {
    const info = sanitizeInfoWidth(infoW);
    const widths = navWidths(w, info, userList);
    return {
      effective: LAYOUT_TRIPLE,
      target: target,
      infoW: info,
      listW: widths.listW,
      chatW: widths.chatW,
      navW: widths.navW,
      infoVisible: true,
      reason: 'triple'
    };
  }

  if (canDouble(w, h)) {
    const widths = navWidths(w, 0, userList);
    return {
      effective: LAYOUT_DOUBLE,
      target: target,
      infoW: 0,
      listW: widths.listW,
      chatW: widths.chatW,
      navW: widths.navW,
      infoVisible: false,
      reason: wantTriple ? 'triple-degraded-no-space' : 'double'
    };
  }

  return emptyResolution(LAYOUT_SINGLE, target, 'double-degraded-no-space');
}

function emptyResolution(effective: string, target: string, reason: string): PaneResolution {
  return {
    effective: effective,
    target: target,
    infoW: 0,
    listW: 0,
    chatW: 0,
    navW: 0,
    infoVisible: false,
    reason: reason
  };
}

// ---- 迁移 ------------------------------------------------------------------

// 偏好值归一（2026-11-08 三档化）：'double' / 'triple' 是历史别名，一律映射到
// 'multi'——它们原本表达的"至少双栏、有空间就三栏"与 multi 完全一致，老用户
// 升级后不该被悄悄降回双栏。其它不认识的（含历史 'split'、空串、脏值）回 auto。
// 'auto' 是安全档——它按设备给默认，不会把用户钉在某个栏数上。
export function normalizeLayoutMode(raw: string): string {
  if (raw === LAYOUT_MULTI || raw === LAYOUT_DOUBLE || raw === LAYOUT_TRIPLE) {
    return LAYOUT_MULTI;
  }
  if (raw === LAYOUT_SINGLE || raw === LAYOUT_AUTO) {
    return raw;
  }
  return LAYOUT_AUTO;
}

// 写 single 时旧键双写 true，其它三档双写 false。旧页面在 P0–P2 期间还读旧键，
// 双写保证它们看到的行为与新偏好一致；P5 迁移完成后旧键只保留兼容写入。
export function legacyForceSingleFor(mode: string): boolean {
  return normalizeLayoutMode(mode) === LAYOUT_SINGLE;
}
