// 左栏钻取态单测（P1-B7）。
//
// 只验纯函数：左栏形态归一、单栏（手机）不许开、多栏才能开、开/关判据。
// AppStorage 读写（openLeftPane / closeLeftPane / leftPaneSplitActive）依赖宿主
// 运行时，放到真机/模拟器批次验证，理由同 LayoutState.test.ets 头注释。
//
// 关键契约：
//   - 脏值一律归一成 'chats'（这个键跨页面、跨重建活着，宁可回列表）；
//   - split=false（手机单栏）时 nextLeftPane 原样返回当前值，绝不把左栏改成别的
//     东西——这是用户要求的「手机端维持原样」的硬约束；
//   - split=true（双栏/三栏）时才切到目标形态；
//   - isLeftPaneOpen 对 archive/profile 为真、对 chats 为假。

import { describe, expect, it } from '@ohos/hypium';
import {
  isLeftPaneOpen, LEFT_PANE_ARCHIVE, LEFT_PANE_CHATS, LEFT_PANE_PROFILE,
  leftPaneAllowed, nextLeftPane, normalizeLeftPane
} from '../main/ets/util/leftPaneState';

export default function leftPaneStateTest() {
  describe('leftPaneState', () => {
    it('normalizes_unknown_values_to_chats', 0, () => {
      expect(normalizeLeftPane('')).assertEqual(LEFT_PANE_CHATS);
      expect(normalizeLeftPane('nope')).assertEqual(LEFT_PANE_CHATS);
      expect(normalizeLeftPane('Chats')).assertEqual(LEFT_PANE_CHATS);
      // 历史键名残留（归档曾经是页签级的 destination 名）。
      expect(normalizeLeftPane('ArchivePage')).assertEqual(LEFT_PANE_CHATS);
    });

    it('keeps_the_two_drilldown_modes', 0, () => {
      expect(normalizeLeftPane(LEFT_PANE_CHATS)).assertEqual(LEFT_PANE_CHATS);
      expect(normalizeLeftPane(LEFT_PANE_ARCHIVE)).assertEqual(LEFT_PANE_ARCHIVE);
      expect(normalizeLeftPane(LEFT_PANE_PROFILE)).assertEqual(LEFT_PANE_PROFILE);
    });

    it('allows_drilldown_only_when_split', 0, () => {
      expect(leftPaneAllowed(true)).assertTrue();
      expect(leftPaneAllowed(false)).assertFalse();
    });

    it('single_column_never_changes_the_pane', 0, () => {
      // 手机：无论要什么都维持原值（包括本来残留的深钻值），让页面继续走整页老路。
      expect(nextLeftPane(LEFT_PANE_CHATS, LEFT_PANE_ARCHIVE, false)).assertEqual(LEFT_PANE_CHATS);
      expect(nextLeftPane(LEFT_PANE_CHATS, LEFT_PANE_PROFILE, false)).assertEqual(LEFT_PANE_CHATS);
      expect(nextLeftPane(LEFT_PANE_ARCHIVE, LEFT_PANE_PROFILE, false)).assertEqual(LEFT_PANE_ARCHIVE);
    });

    it('split_column_switches_to_the_wanted_mode', 0, () => {
      expect(nextLeftPane(LEFT_PANE_CHATS, LEFT_PANE_ARCHIVE, true)).assertEqual(LEFT_PANE_ARCHIVE);
      expect(nextLeftPane(LEFT_PANE_CHATS, LEFT_PANE_PROFILE, true)).assertEqual(LEFT_PANE_PROFILE);
      expect(nextLeftPane(LEFT_PANE_ARCHIVE, LEFT_PANE_PROFILE, true)).assertEqual(LEFT_PANE_PROFILE);
      // 回到列表也是同一个函数。
      expect(nextLeftPane(LEFT_PANE_PROFILE, LEFT_PANE_CHATS, true)).assertEqual(LEFT_PANE_CHATS);
    });

    it('split_column_still_normalizes_the_request', 0, () => {
      expect(nextLeftPane(LEFT_PANE_ARCHIVE, 'bogus', true)).assertEqual(LEFT_PANE_CHATS);
    });

    it('reports_whether_the_pane_is_open', 0, () => {
      expect(isLeftPaneOpen(LEFT_PANE_CHATS)).assertFalse();
      expect(isLeftPaneOpen(LEFT_PANE_ARCHIVE)).assertTrue();
      expect(isLeftPaneOpen(LEFT_PANE_PROFILE)).assertTrue();
      expect(isLeftPaneOpen('bogus')).assertFalse();
    });
  });
}
