// 导航的唯一权威入口（P0，2026-11-08 用户要求"做减法"）。
//
// 用户连着报了三个"个人资料"的问题：平板上点胶囊第 4 格会盖出整屏资料页；
// 连点两下会在「资料 / 会话」之间来回跳；左栏明明显示着自己的资料，胶囊亮的
// 却是「聊天」。根因不是某一处 if 写错，而是同一件事被三套状态各记了一遍：
//
//   1) mainTabIndex（页签）：tab === 3 时整窗渲染 MyProfilePage；
//   2) leftPaneMode === 'profile'（左栏钻取态）：多栏时只换左栏；
//   3) HdsTabs 内部的 index：没有 setter（HdsTabsController 没有 changeIndex，
//      见 MainScreen 的字段注释），只能靠 index 属性单向喂进去。
//
// 于是每个入口都各写了一遍：MainScreen.select() 里特判、redirectProfileTabToPane()
// 兜底、两个 .onChange 各写一次、appliedTab 影子状态去重、onLeftPaneChanged()
// 降级收尾。这些补丁互相不知道谁先跑，谁后跑谁就覆盖谁（用户报的"连点来回跳"
// 就是两次投影先后顺序不同造成的）。
//
// 这里把它们收成一份状态：place。place 是产品意图（"我要去资料"），投影
// project() 才是它在当前布局下的落地形态（几号页签 + 左栏显示什么）。所有入口
// 都走 requestPlace / requestTab / requestPane，没有第二个地方写这两个键。
//
// 三条不变式。reconcile() 对任意 (tab, pane, split) 都必须收敛到它们，且收敛
// 之后再调一次不再改任何键（幂等）：
//
//   I1  pane !== 'chats'  ⟹  tab === 0        // 左栏只存在于会话页签里
//   I2  split             ⟹  tab !== 3         // 分栏时资料在左栏，没有整页资料
//   I3  !split            ⟹  pane === 'chats'  // 单栏没有左栏
//
// 为什么投影是纯函数：HdsTabs 的 index 回写不了，页签 + 左栏只能被单向驱动。
// 只有把"意图"和"当前布局"分开，(place, split) → 组合 才是确定的；reconcile
// 因此才能是"读组合 → 还原 place → 重新投影"的全函数，而不是又一处 if 补丁。

import { TAB_CHATS, TAB_CONTACTS, TAB_PROFILE, TAB_SETTINGS } from './mainTabIndex';
import {
  closeLeftPane, LEFT_PANE_ARCHIVE, LEFT_PANE_CHATS, LEFT_PANE_PROFILE,
  leftPaneMode, leftPaneSplitActive, openLeftPane
} from './leftPaneState';

// 与 util/chatNav.KEY_MAIN_TAB、Index.ets 里手写的 'mainTabIndex' 是同一个
// AppStorage 键。这里不 import chatNav：那会把 tdkit/Globals 和整条会话路由
// 拖进这个纯决策模块，而 navState 只该依赖 leftPaneState / mainTabIndex。
const KEY_MAIN_TAB: string = 'mainTabIndex';

// 产品意图。注意 'me' 在两种布局下是同一个 place，只是投影不同（I2/I3）。
export type NavPlace = 'chats' | 'contacts' | 'settings' | 'me' | 'archive';

export interface NavProjection {
  tab: number;
  pane: string;
  // 单栏下归档是会话页签栈里的一层（profileNav.navigateToArchive 推 ArchivePage），
  // 投影只能提示"该推了"；本模块不碰路由栈，见 requestPlace 的说明。
  pushArchive: boolean;
}

function readTab(): number {
  return AppStorage.get<number>(KEY_MAIN_TAB) ?? 0;
}

// 只写变化：@StorageProp 的 @Watch 按值变化触发，写同值既不必要，也会让
// reconcile 的幂等性依赖框架实现。返回是否真写了，排查时能直接看出来。
function setTab(tab: number): boolean {
  if (tab === readTab()) {
    return false;
  }
  AppStorage.setOrCreate<number>(KEY_MAIN_TAB, tab);
  return true;
}

function applyPane(pane: string): void {
  const current: string = leftPaneMode();
  if (current === pane) {
    return;
  }
  if (pane === LEFT_PANE_CHATS) {
    closeLeftPane();
    return;
  }
  // openLeftPane 自己会挡单栏（leftPaneAllowed），这里不重复判 split：
  // 单栏的投影里根本不会出现非 chats 的 pane（I3）。
  openLeftPane(pane);
}

export function navSplitActive(): boolean {
  return leftPaneSplitActive();
}

// @StorageProp 是"只读镜像"：AppStorage 里没有这个键时它只用本地默认值，不会像
// @StorageLink 那样顺带 setOrCreate 出来。改动前 mainTabIndex 这个键正是
// MainScreen 的 @StorageLink 在装配时建出来的；改名成 @StorageProp 之后必须有人
// 在**主屏装配之前**把键建出来，否则主屏绑定的是一个不存在的键。
// Index 在 aboutToAppear 里调一次（那时主屏还没 build，见 Index.build 的
// stage 分支）。幂等，重复调用无副作用。
export function ensureNavKey(): void {
  if (AppStorage.get<number>(KEY_MAIN_TAB) === undefined) {
    AppStorage.setOrCreate<number>(KEY_MAIN_TAB, TAB_CHATS);
  }
}

// 标准表（改动前散落在 select / redirectProfileTabToPane / onLeftPaneChanged 三处）：
//   chats    → (0, 'chats', false)      contacts → (1, 'chats', false)
//   settings → (2, 'chats', false)      me       → 分栏 (0, 'profile', false)
//                                                  单栏 (3, 'chats', false)
//   archive  → 分栏 (0, 'archive', false)
//              单栏 (0, 'chats', true) —— 页签回会话，推栈由调用方做
export function project(place: NavPlace, split: boolean): NavProjection {
  if (place === 'contacts') {
    return { tab: TAB_CONTACTS, pane: LEFT_PANE_CHATS, pushArchive: false };
  }
  if (place === 'settings') {
    return { tab: TAB_SETTINGS, pane: LEFT_PANE_CHATS, pushArchive: false };
  }
  if (place === 'me') {
    // 分栏时资料只能待在左栏（I2）：页签退回会话，面板打开。
    if (split) {
      return { tab: TAB_CHATS, pane: LEFT_PANE_PROFILE, pushArchive: false };
    }
    // 单栏没有左栏（I3），资料就是第 4 个整页——手机端行为与改动前一个字不差。
    return { tab: TAB_PROFILE, pane: LEFT_PANE_CHATS, pushArchive: false };
  }
  if (place === 'archive') {
    if (split) {
      return { tab: TAB_CHATS, pane: LEFT_PANE_ARCHIVE, pushArchive: false };
    }
    return { tab: TAB_CHATS, pane: LEFT_PANE_CHATS, pushArchive: true };
  }
  return { tab: TAB_CHATS, pane: LEFT_PANE_CHATS, pushArchive: false };
}

// 当前组合还原成 place。页签优先于左栏：页签是真正渲染在屏幕上的那一格，
// 左栏只在 tab === 0 时才参与语义（I1）；两者矛盾时（脏状态）以页签为准。
export function currentPlace(): NavPlace {
  const tab: number = readTab();
  if (tab === TAB_CONTACTS) {
    return 'contacts';
  }
  if (tab === TAB_SETTINGS) {
    return 'settings';
  }
  if (tab === TAB_PROFILE) {
    return 'me';
  }
  const pane: string = leftPaneMode();
  if (pane === LEFT_PANE_ARCHIVE) {
    return 'archive';
  }
  if (pane === LEFT_PANE_PROFILE) {
    return 'me';
  }
  return 'chats';
}

// 唯一写页签 / 左栏的入口。只写"当前布局下的合法组合"，不推路由栈：
// 归档的单栏形态由 profileNav.navigateToArchive 负责（它自己判 split 再决定
// 是开面板还是 push ArchivePage），冷启动恢复之类的被动场景由 reconcile 兜。
export function requestPlace(place: NavPlace): void {
  const p: NavProjection = project(place, navSplitActive());
  // 顺序不能反：I1 要求 pane !== 'chats' 时 tab 已经是 0。先写页签再开面板，
  // 中间任何一帧的组合都是合法的；面板打开会触发 MainScreen 的 @Watch，
  // 那次 reconcile 读到的已经是收口后的组合。
  setTab(p.tab);
  applyPane(p.pane);
}

// 逻辑页签（全应用契约：0 聊天 / 1 联系人 / 2 设置 / 3 资料）。物理下标由渲染层
// 用 physicalTabIndex 换算，这里不碰。越界值一律回会话——导航入口不该让页面崩。
export function requestTab(logical: number): void {
  if (logical === TAB_CONTACTS) {
    requestPlace('contacts');
    return;
  }
  if (logical === TAB_SETTINGS) {
    requestPlace('settings');
    return;
  }
  if (logical === TAB_PROFILE) {
    requestPlace('me');
    return;
  }
  requestPlace('chats');
}

// 「把左栏换成某个面板」的入口。面板不是独立状态，它就是 me / archive 在分栏下
// 的投影，所以这里只做归一，落的还是 requestPlace。单栏下没有左栏：
// 'profile' 会落成整页资料（I3），'archive' 只把页签收回会话、不推栈——
// 单栏要进归档请走 profileNav.navigateToArchive()。
export function requestPane(kind: string): void {
  if (kind === LEFT_PANE_PROFILE) {
    requestPlace('me');
    return;
  }
  if (kind === LEFT_PANE_ARCHIVE) {
    requestPlace('archive');
    return;
  }
  requestPlace('chats');
}

// 自愈入口：布局变了（平板转竖屏、拖分割线、开强制单栏）或被外部写入之后，
// 把当前组合归一成合法组合。全函数 + 幂等：非法组合一步收敛，合法组合不再写键。
export function reconcile(): void {
  requestPlace(currentPlace());
}
