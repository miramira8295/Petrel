// P1 布局状态接入层单测。
//
// 只验纯函数：偏好快照 + 设备 + 窗口 + 上一轮三栏 → resolvedLayout 及其派生。
// AppStorage 发布/回收路径依赖宿主运行时，放到真机/模拟器批次验证（P1-B2 起）。
//
// 关键契约：
//   - 设备只影响 auto（手机单、平板双、2in1 三档随空间）；
//   - 手动 single / multi 不受设备目标影响；历史 double / triple 归一为 multi；
//   - infoVisible 恒等于 effective==='triple'；
//   - auto + 2in1 的 1262/1240 滞回只由 prevTriple 决定。

import { describe, expect, it } from '@ohos/hypium';
import {
  LAYOUT_AUTO, LAYOUT_DOUBLE, LAYOUT_MULTI, LAYOUT_SINGLE, LAYOUT_TRIPLE
} from '../main/ets/util/paneLayout';
import type { LayoutSettingsSnapshot } from '../main/ets/util/layoutModeSettings';
import {
  listWidthFor, resolveForSnapshot, resolvedCapsuleWidth, resolvedInfoVisible,
  resolvedLayoutActive, resolvedProfileMode, resolvedSplitActive
} from '../main/ets/util/layoutState';

function near(actual: number, expected: number): boolean {
  return Math.abs(actual - expected) < 0.05;
}

function snap(mode: string, navD: number, navT: number, info: number): LayoutSettingsSnapshot {
  return {
    mode: mode,
    navWidthDouble: navD,
    navWidthTriple: navT,
    infoWidth: info,
    infoVisible: false,
    enabled: true
  };
}

const PHONE: string = 'phone';
const TABLET: string = 'tablet';
const TWO_IN_ONE: string = '2in1';

export default function layoutStateTest() {
  describe('LayoutState', () => {
    // ---- 设备只影响 auto ------------------------------------------------
    it('auto：手机恒单栏，平板恒双栏，2in1 随空间', 0, () => {
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), PHONE, 391, 777, false).effective)
        .assertEqual(LAYOUT_SINGLE);
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TABLET, 1642, 920, false).effective)
        .assertEqual(LAYOUT_DOUBLE);
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TWO_IN_ONE, 1262, 920, false).effective)
        .assertEqual(LAYOUT_TRIPLE);
    });

    it('auto 平板 1642 也不进三栏（设备策略）', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TABLET, 1642, 920, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.infoVisible).assertFalse();
      expect(r.infoW).assertEqual(0);
    });

    it('auto 2in1：1262 进三栏、1261 双栏（首次）', 0, () => {
      const triple = resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TWO_IN_ONE, 1262, 920, false);
      expect(triple.effective).assertEqual(LAYOUT_TRIPLE);
      expect(triple.infoVisible).assertTrue();
      expect(near(triple.listW, 360)).assertTrue();
      expect(near(triple.chatW, 560)).assertTrue();
      const doubled = resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TWO_IN_ONE, 1261, 920, false);
      expect(doubled.effective).assertEqual(LAYOUT_DOUBLE);
      expect(doubled.infoVisible).assertFalse();
    });

    it('auto 2in1 滞回：prevTriple 时 1240 保持、1239 退出', 0, () => {
      const stay = resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TWO_IN_ONE, 1240, 920, true);
      expect(stay.effective).assertEqual(LAYOUT_TRIPLE);
      const exit = resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TWO_IN_ONE, 1239, 920, true);
      expect(exit.effective).assertEqual(LAYOUT_DOUBLE);
      // 滞回退出时 wantTriple=false，reason 就是普通 double（不是降级）。
      expect(exit.reason).assertEqual('double');
    });

    it('auto 2in1 1100 双栏、840 双栏、391 单栏', 0, () => {
      const w1100 = resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TWO_IN_ONE, 1100, 920, false);
      expect(w1100.effective).assertEqual(LAYOUT_DOUBLE);
      // 固定档：列表取用户值 360（clamp 328–440），聊天 1098-360=738。
      expect(near(w1100.listW, 360)).assertTrue();
      expect(near(w1100.chatW, 738)).assertTrue();
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TWO_IN_ONE, 840, 920, false).effective)
        .assertEqual(LAYOUT_DOUBLE);
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360, 360, 340), TWO_IN_ONE, 391, 777, false).effective)
        .assertEqual(LAYOUT_SINGLE);
    });

    // ---- 手动模式不受设备影响 -------------------------------------------
    it('手动 single：1642 2in1 也单栏', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_SINGLE, 360, 360, 340), TWO_IN_ONE, 1642, 920, true);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
      expect(r.infoVisible).assertFalse();
    });

    // 三档化前这里是「double 够三栏也不升」；现在 multi 的语义就是"有空间要
    // 三栏"，1642 的 2in1 必须升，且资料列随之出现。
    it('手动 multi：够三栏就升三栏', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_MULTI, 360, 360, 340), TWO_IN_ONE, 1642, 920, false);
      expect(r.effective).assertEqual(LAYOUT_TRIPLE);
      expect(r.infoVisible).assertTrue();
      expect(r.infoW).assertEqual(340);
    });

    it('历史别名 double 与新 multi 行为一致', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_DOUBLE, 360, 360, 340), TWO_IN_ONE, 1642, 920, false);
      expect(r.effective).assertEqual(LAYOUT_TRIPLE);
    });

    it('手动 multi：1190(info300) 进三栏、1189 降双栏、759 降单栏', 0, () => {
      const triple = resolveForSnapshot(snap(LAYOUT_MULTI, 360, 360, 300), TWO_IN_ONE, 1190, 920, false);
      expect(triple.effective).assertEqual(LAYOUT_TRIPLE);
      expect(near(triple.navW, 888)).assertTrue();
      expect(near(triple.listW, 328)).assertTrue();
      expect(near(triple.chatW, 560)).assertTrue();
      const doubled = resolveForSnapshot(snap(LAYOUT_MULTI, 360, 360, 300), TWO_IN_ONE, 1189, 920, false);
      expect(doubled.effective).assertEqual(LAYOUT_DOUBLE);
      expect(doubled.reason).assertEqual('triple-degraded-no-space');
      const single = resolveForSnapshot(snap(LAYOUT_MULTI, 360, 360, 300), TWO_IN_ONE, 759, 920, false);
      expect(single.effective).assertEqual(LAYOUT_SINGLE);
      expect(single.reason).assertEqual('double-degraded-no-space');
    });

    it('手动 multi：高度不足 520 直接单栏', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_MULTI, 360, 360, 340), TWO_IN_ONE, 1642, 519, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    // ---- 列表宽输入选择 ------------------------------------------------
    it('listWidthFor：multi / 三栏 / auto-2in1 用 triple 宽，其余用 double 宽', 0, () => {
      expect(listWidthFor(snap(LAYOUT_MULTI, 350, 400, 340), TABLET)).assertEqual(400);
      expect(listWidthFor(snap(LAYOUT_TRIPLE, 350, 400, 340), TABLET)).assertEqual(400);
      expect(listWidthFor(snap(LAYOUT_AUTO, 350, 400, 340), TWO_IN_ONE)).assertEqual(400);
      expect(listWidthFor(snap(LAYOUT_AUTO, 350, 400, 340), TABLET)).assertEqual(350);
      expect(listWidthFor(snap(LAYOUT_DOUBLE, 350, 400, 340), TWO_IN_ONE)).assertEqual(350);
      expect(listWidthFor(snap(LAYOUT_SINGLE, 350, 400, 340), TWO_IN_ONE)).assertEqual(350);
    });

    // ---- 派生 ----------------------------------------------------------
    it('resolvedSplitActive / resolvedInfoVisible 只认三值', 0, () => {
      expect(resolvedSplitActive(LAYOUT_SINGLE)).assertFalse();
      expect(resolvedSplitActive(LAYOUT_DOUBLE)).assertTrue();
      expect(resolvedSplitActive(LAYOUT_TRIPLE)).assertTrue();
      expect(resolvedInfoVisible(LAYOUT_DOUBLE)).assertFalse();
      expect(resolvedInfoVisible(LAYOUT_TRIPLE)).assertTrue();
    });

    it('资料呈现：单栏整页、双栏浮层、三栏列', 0, () => {
      expect(resolvedProfileMode(LAYOUT_SINGLE)).assertEqual('page');
      expect(resolvedProfileMode(LAYOUT_DOUBLE)).assertEqual('overlay');
      expect(resolvedProfileMode(LAYOUT_TRIPLE)).assertEqual('column');
    });

    it('胶囊宽度：单栏 0、列表 360→328、列表 328→304', 0, () => {
      expect(resolvedCapsuleWidth(LAYOUT_SINGLE, 360)).assertEqual(0);
      expect(resolvedCapsuleWidth(LAYOUT_DOUBLE, 360)).assertEqual(328);
      expect(resolvedCapsuleWidth(LAYOUT_TRIPLE, 328)).assertEqual(304);
    });

    it('resolvedLayoutActive 只认三种实际布局', 0, () => {
      expect(resolvedLayoutActive(LAYOUT_SINGLE)).assertTrue();
      expect(resolvedLayoutActive(LAYOUT_DOUBLE)).assertTrue();
      expect(resolvedLayoutActive(LAYOUT_TRIPLE)).assertTrue();
      // 'multi' 是偏好不是解析结果，不能当有效布局；Resolved 只写三值。
      expect(resolvedLayoutActive(LAYOUT_MULTI)).assertFalse();
      expect(resolvedLayoutActive('')).assertFalse();
      expect(resolvedLayoutActive('auto')).assertFalse();
    });
  });
}
