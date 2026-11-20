// 布局状态接入层单测。
//
// 只验纯函数：偏好快照 + 设备 + 窗口 → resolvedLayout 及其派生。
// AppStorage 发布/回收路径依赖宿主运行时，放到真机/模拟器批次验证。
//
// 关键契约：
//   - 设备只影响 auto（手机单栏、平板/2in1 双栏，仍受几何门槛约束）；
//   - 手动 single / multi 不受设备目标影响；历史 double / triple 归一为 multi；
//   - 2026-11-21 起没有右侧资料列，解析结果只有 single / double。

import { describe, expect, it } from '@ohos/hypium';
import { LAYOUT_AUTO, LAYOUT_DOUBLE, LAYOUT_MULTI, LAYOUT_SINGLE } from '../main/ets/util/paneLayout';
import type { LayoutSettingsSnapshot } from '../main/ets/util/layoutModeSettings';
import {
  listWidthFor, resolveForSnapshot, resolvedCapsuleWidth, resolvedLayoutActive,
  resolvedProfileMode, resolvedSplitActive
} from '../main/ets/util/layoutState';

function near(actual: number, expected: number): boolean {
  return Math.abs(actual - expected) < 0.05;
}

function snap(mode: string, navD: number): LayoutSettingsSnapshot {
  return {
    mode: mode,
    navWidthDouble: navD,
    enabled: true
  };
}

const PHONE: string = 'phone';
const TABLET: string = 'tablet';
const TWO_IN_ONE: string = '2in1';

export default function layoutStateTest() {
  describe('LayoutState', () => {
    // ---- 设备只影响 auto ------------------------------------------------
    it('auto：手机恒单栏，平板与 2in1 双栏', 0, () => {
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360), PHONE, 391, 777).effective)
        .assertEqual(LAYOUT_SINGLE);
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360), TABLET, 1642, 920).effective)
        .assertEqual(LAYOUT_DOUBLE);
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360), TWO_IN_ONE, 1262, 920).effective)
        .assertEqual(LAYOUT_DOUBLE);
    });

    it('auto 平板 1642：宽但仍是双栏（设备策略）', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_AUTO, 360), TABLET, 1642, 920);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.reason).assertEqual('double');
    });

    it('auto 2in1 1100：列表取用户值，聊天吃满剩余', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_AUTO, 360), TWO_IN_ONE, 1100, 920);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(near(r.listW, 360)).assertTrue();
      expect(near(r.chatW, 738)).assertTrue();
    });

    it('auto 2in1 840 双栏、391 单栏', 0, () => {
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360), TWO_IN_ONE, 840, 920).effective)
        .assertEqual(LAYOUT_DOUBLE);
      expect(resolveForSnapshot(snap(LAYOUT_AUTO, 360), TWO_IN_ONE, 391, 777).effective)
        .assertEqual(LAYOUT_SINGLE);
    });

    // ---- 手动模式不受设备影响 -------------------------------------------
    it('手动 single：1642 2in1 也单栏', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_SINGLE, 360), TWO_IN_ONE, 1642, 920);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    it('手动 multi：759 降单栏、760 双栏', 0, () => {
      expect(resolveForSnapshot(snap(LAYOUT_MULTI, 360), TWO_IN_ONE, 759, 920).effective)
        .assertEqual(LAYOUT_SINGLE);
      expect(resolveForSnapshot(snap(LAYOUT_MULTI, 360), TWO_IN_ONE, 760, 920).effective)
        .assertEqual(LAYOUT_DOUBLE);
    });

    it('手动 multi：高度不足 520 直接单栏', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_MULTI, 360), TWO_IN_ONE, 1642, 519);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
      expect(r.reason).assertEqual('double-degraded-no-space');
    });

    it('手动 multi：900 窄窗降单栏', 0, () => {
      const r = resolveForSnapshot(snap(LAYOUT_MULTI, 360), TABLET, 900, 900);
      // 900 > 760，所以仍是双栏；列表 360、聊天 538。
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(near(r.chatW, 538)).assertTrue();
    });

    // ---- 列表宽输入 ----------------------------------------------------
    it('listWidthFor：只有一份双栏宽', 0, () => {
      expect(listWidthFor(snap(LAYOUT_MULTI, 350))).assertEqual(350);
      expect(listWidthFor(snap(LAYOUT_AUTO, 350))).assertEqual(350);
      expect(listWidthFor(snap(LAYOUT_SINGLE, 350))).assertEqual(350);
    });

    // ---- 派生 ----------------------------------------------------------
    it('resolvedSplitActive 只认 double', 0, () => {
      expect(resolvedSplitActive(LAYOUT_SINGLE)).assertFalse();
      expect(resolvedSplitActive(LAYOUT_DOUBLE)).assertTrue();
      expect(resolvedSplitActive('')).assertFalse();
    });

    it('资料呈现：单栏整页、双栏浮层', 0, () => {
      expect(resolvedProfileMode(LAYOUT_SINGLE)).assertEqual('page');
      expect(resolvedProfileMode(LAYOUT_DOUBLE)).assertEqual('overlay');
    });

    it('胶囊宽度：单栏 0、列表 360→328、列表 328→304', 0, () => {
      expect(resolvedCapsuleWidth(LAYOUT_SINGLE, 360)).assertEqual(0);
      expect(resolvedCapsuleWidth(LAYOUT_DOUBLE, 360)).assertEqual(328);
      expect(resolvedCapsuleWidth(LAYOUT_DOUBLE, 328)).assertEqual(304);
    });

    it('resolvedLayoutActive 只认 single / double', 0, () => {
      expect(resolvedLayoutActive(LAYOUT_SINGLE)).assertTrue();
      expect(resolvedLayoutActive(LAYOUT_DOUBLE)).assertTrue();
      // 'multi' 是偏好不是解析结果。
      expect(resolvedLayoutActive(LAYOUT_MULTI)).assertFalse();
      expect(resolvedLayoutActive('')).assertFalse();
      expect(resolvedLayoutActive('auto')).assertFalse();
    });
  });
}
