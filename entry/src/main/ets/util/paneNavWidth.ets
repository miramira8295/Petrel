// 分栏左栏（列表/导航列）的宽度模型：全应用共用一条可拖动分隔线。
//
// 语义：
// - 宽度只记一份（KEY_SPLIT_NAV_WIDTH），三个页签共享；拖一次，其它页签跟着变。
// - 区间由当前窗口宽、是否三栏（右侧资料列占宽）共同决定；夹在 [328, 440]。
// - 三栏时给聊天留 >= 560vp；双栏时整窗都可用。
// 详情页（资料列）不参与这条线，它是第三栏，不属于导航分栏。
export const NAV_MIN_VP: number = 328;
export const NAV_MAX_VP: number = 440;
export const CHAT_MIN_VP: number = 560;
export const INFO_DIVIDER_VP: number = 2;

// 当前布局下左栏可拖动的最大宽。三栏要扣掉资料列与聊天最小宽。
export function paneNavMax(screenW: number, triple: boolean, infoW: number): number {
  const usable: number = triple ? screenW - infoW - INFO_DIVIDER_VP : screenW;
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
