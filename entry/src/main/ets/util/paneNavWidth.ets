// 分栏左栏（列表/导航列）的宽度模型：全应用共用一条可拖动分隔线。
//
// 语义：
// - 宽度只记一份（KEY_SPLIT_NAV_WIDTH），三个页签共享；拖一次，其它页签跟着变。
// - 区间只由当前窗口宽决定；夹在 [328, 434]。
// - 双栏时给聊天留 >= 560vp。
export const NAV_MIN_VP: number = 328;
// 434 而非 440：再宽左栏会让底部悬浮胶囊在观感上明显偏右，用户要求锁在当前值。
export const NAV_MAX_VP: number = 434;
export const CHAT_MIN_VP: number = 560;

// 当前布局下左栏可拖动的最大宽：整窗减去聊天最小宽。
export function paneNavMax(screenW: number): number {
  const usable: number = screenW;
  if (!(usable > 0)) {
    return NAV_MIN_VP;
  }
  const capped: number = Math.min(NAV_MAX_VP, usable - CHAT_MIN_VP);
  return Math.max(NAV_MIN_VP, Math.round(capped));
}

// 最小宽不能大于最大宽，否则 HDS 会退回内部默认值。
export function paneNavMin(maxW: number): number {
  return Math.min(NAV_MIN_VP, maxW);
}

// 启动/重建时给 navBarWidth 的值：上次拖出来的宽夹进当前区间。
export function paneNavWidth(savedVp: number, minVp: number, maxVp: number): number {
  if (!(savedVp > 0)) {
    return minVp;
  }
  return Math.max(minVp, Math.min(maxVp, Math.round(savedVp)));
}
