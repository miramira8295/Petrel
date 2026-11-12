// 左栏钻取态（P1-B7）。
//
// 设计依据：tablet-redesign/04_Petrel信息架构重设计.md
//   · 第 205 行（归档）：「进入 = 左栏钻取（‹ 会话），中栏聊天与资料列不动；
//     点归档内会话 → 中栏打开、左栏退出归档并恢复原列表。」
//   · 第 206 行（个人资料）：「胶囊第 4 项 → 左栏显示自己的资料；编辑在左栏内
//     展开；中栏保持当前聊天；资料列隐藏。」
//   · 第 23 行：「归档、个人资料、全局搜索都只在左栏（钻取/页内态），不占中栏、
//     不占资料列。」
// 10_最终设计决策记录.md D-108 / D-109 是同一件事的决策条目。
//
// 为什么需要这个文件：多栏（双栏/三栏）下「左栏现在显示什么」是一份**页内态**，
// 不是路由栈——它不参与 splitRouting 的 decidePush，也不该在返回键链里被当成
// 页面栈的一层。原来归档是往聊天页签栈里推一层 ArchivePage，结果整个中栏被换成
// 归档列表，聊天消失；个人资料是第 4 个页签，整窗铺满、左栏列表也跟着没了。
//
// 这里只做三件事：
//   1) 一个 AppStorage 键记录左栏当前形态（chats / archive / profile）；
//   2) 纯函数决定「该不该改、改成什么」，让手机端（单栏）行为一个字都不变；
//   3) 给页面一个 closeLeftPane() 布尔返回，方便接进返回键链
//      （与 util/forumDrawerState.closeForumDrawer 同形）。
//
// 单栏（手机）是硬约束：leftPaneAllowed() 为 false 时 openLeftPane() 什么都不做，
// 页面拿不到左栏形态，自然继续走「整页」老路。

import {
  HEIGHT_BP_LG, isSplitByBreakpoint,
  KEY_HEIGHT_BREAKPOINT, KEY_WINDOW_PORTRAIT, KEY_WIDTH_BREAKPOINT, WIDTH_BP_SM
} from './layoutBreakpoint';
import { KEY_FORCE_SINGLE_COLUMN } from '../store/AppSettings';

export const KEY_LEFT_PANE_MODE: string = 'leftPaneMode';

// 左栏形态取值。'chats' 是常态（会话列表），另两个是钻取态。
export const LEFT_PANE_CHATS: string = 'chats';
export const LEFT_PANE_ARCHIVE: string = 'archive';
export const LEFT_PANE_PROFILE: string = 'profile';

// ---- 纯函数（宿主单测覆盖这一层） ------------------------------------------

// 脏值一律归一成 chats：这个键会跟着 AppStorage 跨页面、跨热重载活着，
// 收到历史脏值或不认识的串时宁可回列表，也不要让左栏停在一个渲染不出来的态上。
export function normalizeLeftPane(raw: string): string {
  if (raw === LEFT_PANE_ARCHIVE || raw === LEFT_PANE_PROFILE) {
    return raw;
  }
  return LEFT_PANE_CHATS;
}

// 左栏钻取只在多栏下成立。单栏下归档/个人资料继续按整页走（手机端维持原样）。
// split 由调用方给（页面自己已经有一份 splitActive() 判据，别在这里重算一遍）。
export function leftPaneAllowed(split: boolean): boolean {
  return split;
}

// 打开左栏钻取态后的新值。不允许时**原样返回 current**（而不是把它清成 chats）：
// 手机上本来就没有这个态，当前值多半是残留的，动它只会让返回键链多点一次。
export function nextLeftPane(current: string, want: string, split: boolean): string {
  if (!leftPaneAllowed(split)) {
    return normalizeLeftPane(current);
  }
  return normalizeLeftPane(want);
}

export function isLeftPaneOpen(mode: string): boolean {
  return normalizeLeftPane(mode) !== LEFT_PANE_CHATS;
}

// ---- AppStorage 读写 -------------------------------------------------------

// 与页面里 splitActive() 同一套兜底：resolvedLayout 已发布时它说了算，
// 否则回退旧断点判据（isSplitByBreakpoint 内部就是这么分的）。
export function leftPaneSplitActive(): boolean {
  return isSplitByBreakpoint(
    AppStorage.get<number>(KEY_WIDTH_BREAKPOINT) ?? WIDTH_BP_SM,
    AppStorage.get<number>(KEY_HEIGHT_BREAKPOINT) ?? HEIGHT_BP_LG,
    AppStorage.get<boolean>(KEY_FORCE_SINGLE_COLUMN) ?? false,
    AppStorage.get<boolean>(KEY_WINDOW_PORTRAIT) ?? true);
}

export function leftPaneMode(): string {
  return normalizeLeftPane(AppStorage.get<string>(KEY_LEFT_PANE_MODE) ?? LEFT_PANE_CHATS);
}

// 返回是否真的改了值。手机（单栏）下恒 false，调用方据此走老路。
export function openLeftPane(want: string): boolean {
  const current: string = leftPaneMode();
  const next: string = nextLeftPane(current, want, leftPaneSplitActive());
  if (next === current) {
    return false;
  }
  AppStorage.setOrCreate<string>(KEY_LEFT_PANE_MODE, next);
  return true;
}

// 与 closeForumDrawer() 同形：开着就关掉并返回 true，供返回键链短路用。
export function closeLeftPane(): boolean {
  if (!isLeftPaneOpen(leftPaneMode())) {
    return false;
  }
  AppStorage.setOrCreate<string>(KEY_LEFT_PANE_MODE, LEFT_PANE_CHATS);
  return true;
}
