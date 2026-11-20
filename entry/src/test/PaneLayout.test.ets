// 多栏布局纯函数单测。
//
// 覆盖：设备两档目标、auto/manual 边界（759/760、519/520、高度门槛）、
// 宽度分配、sanitize、模式归一、迁移状态机、启动装载。
//
// 2026-11-21：右侧资料列（第三栏）已删除，resolved 只出 single / double。
// 历史偏好值 double / triple 仍归一为 multi。
//
// 这些用例只验算术与状态机契约，不验布局观感与生命周期——后者在真机验。

import { describe, expect, it } from '@ohos/hypium';
import {
  LAYOUT_AUTO, LAYOUT_DOUBLE, LAYOUT_MULTI, LAYOUT_SINGLE, autoTarget, canDouble,
  capsuleWidth, deviceClassOf, legacyForceSingleFor, normalizeLayoutMode,
  profilePresentation, resolvePaneLayout, sanitizeNavWidth
} from '../main/ets/util/paneLayout';
import {
  bootLayoutValues, KEY_LAYOUT_MIGRATED_V1, LAYOUT_MODE_DEFAULT, NAV_WIDTH_DOUBLE_DEFAULT,
  planLayoutMigration
} from '../main/ets/util/layoutModeSettings';

function near(actual: number, expected: number): boolean {
  return Math.abs(actual - expected) < 0.05;
}

const PHONE: string = 'phone';
const TABLET: string = 'tablet';
const TWO_IN_ONE: string = '2in1';

export default function paneLayoutTest() {
  describe('PaneLayout', () => {
    // ---- 设备与目标 --------------------------------------------------------
    it('autoTarget：手机单栏、平板与 2in1 双栏', 0, () => {
      expect(autoTarget(PHONE)).assertEqual(LAYOUT_SINGLE);
      expect(autoTarget(TABLET)).assertEqual(LAYOUT_DOUBLE);
      expect(autoTarget(TWO_IN_ONE)).assertEqual(LAYOUT_DOUBLE);
    });

    it('设备类型未知按手机处理', 0, () => {
      expect(deviceClassOf('tv')).assertEqual(PHONE);
      expect(deviceClassOf('')).assertEqual(PHONE);
      expect(deviceClassOf(TABLET)).assertEqual(TABLET);
    });

    it('canDouble：759/760 与 519/520 边界', 0, () => {
      expect(canDouble(759, 900)).assertFalse();
      expect(canDouble(760, 900)).assertTrue();
      expect(canDouble(1200, 519)).assertFalse();
      expect(canDouble(1200, 520)).assertTrue();
    });

    // ---- auto --------------------------------------------------------------
    it('auto 手机 1317.6 仍单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, PHONE, 1317.6, 865.9, 360);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
      expect(r.reason).assertEqual('single');
    });

    it('auto 平板 865.9 双栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TABLET, 865.9, 865.9, 360);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.reason).assertEqual('double');
    });

    it('auto 平板 1642 仍只有双栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TABLET, 1642, 1094.7, 360);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.reason).assertEqual('double');
    });

    it('auto 2in1 840 双栏 list 328 / chat 510', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 840, 920, 328);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(510);
    });

    it('auto 2in1 391 单栏（降级）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 391, 900, 360);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
      expect(r.reason).assertEqual('double-degraded-no-space');
    });

    it('auto 2in1 1262 高 519 单栏（高度约束）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1262, 519, 360);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
      expect(r.reason).assertEqual('double-degraded-no-space');
    });

    // ---- 手动模式 ----------------------------------------------------------
    it('手动 single 在 1642 也单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_SINGLE, TABLET, 1642, 1094.7, 360);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    it('手动 single 在 2in1 宽窗也单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_SINGLE, TWO_IN_ONE, 1642, 1094.7, 360);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    it('手动 multi 759 单栏、760 双栏', 0, () => {
      const a = resolvePaneLayout(LAYOUT_MULTI, TABLET, 759, 900, 360);
      const b = resolvePaneLayout(LAYOUT_MULTI, TABLET, 760, 900, 328);
      expect(a.effective).assertEqual(LAYOUT_SINGLE);
      expect(b.effective).assertEqual(LAYOUT_DOUBLE);
    });

    it('历史别名 double 按 multi 处理（宽窗双栏）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_DOUBLE, TWO_IN_ONE, 1642, 1094.7, 360);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
    });

    it('手动 multi 高 519 降单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_MULTI, TABLET, 1200, 519, 360);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    // ---- 宽度 --------------------------------------------------------------
    it('1317.6：navW 1315.6 / list 360 / chat 955.6', 0, () => {
      const r = resolvePaneLayout(LAYOUT_MULTI, TABLET, 1317.6, 865.9, 360);
      expect(near(r.navW, 1315.6)).assertTrue();
      expect(near(r.listW, 360)).assertTrue();
      expect(near(r.chatW, 955.6)).assertTrue();
    });

    it('列表宽夹在 [328, 440]', 0, () => {
      const lo = resolvePaneLayout(LAYOUT_MULTI, TABLET, 1000, 900, 100);
      const hi = resolvePaneLayout(LAYOUT_MULTI, TABLET, 1400, 900, 900);
      expect(lo.listW).assertEqual(328);
      expect(hi.listW).assertEqual(440);
      expect(hi.chatW).assertEqual(958);
    });

    it('sanitizeNavWidth：非法值回默认，越界夹紧', 0, () => {
      expect(sanitizeNavWidth(NaN, 360)).assertEqual(360);
      expect(sanitizeNavWidth(0, 360)).assertEqual(360);
      expect(sanitizeNavWidth(-5, 360)).assertEqual(360);
      expect(sanitizeNavWidth(100, 360)).assertEqual(328);
      expect(sanitizeNavWidth(900, 360)).assertEqual(440);
      expect(sanitizeNavWidth(371.4, 360)).assertEqual(371);
    });

    it('胶囊宽度：≥360 用 328，328–359 用 304', 0, () => {
      expect(capsuleWidth(360)).assertEqual(328);
      expect(capsuleWidth(359)).assertEqual(304);
      expect(capsuleWidth(328)).assertEqual(304);
    });

    it('资料呈现：单栏整页、双栏浮层', 0, () => {
      expect(profilePresentation(LAYOUT_SINGLE)).assertEqual('page');
      expect(profilePresentation(LAYOUT_DOUBLE)).assertEqual('overlay');
    });

    // ---- 模式归一 ----------------------------------------------------------
    it('normalizeLayoutMode：历史值归 multi，脏值回 auto', 0, () => {
      expect(normalizeLayoutMode('double')).assertEqual(LAYOUT_MULTI);
      expect(normalizeLayoutMode('triple')).assertEqual(LAYOUT_MULTI);
      expect(normalizeLayoutMode('multi')).assertEqual(LAYOUT_MULTI);
      expect(normalizeLayoutMode('single')).assertEqual(LAYOUT_SINGLE);
      expect(normalizeLayoutMode('auto')).assertEqual(LAYOUT_AUTO);
      expect(normalizeLayoutMode('split')).assertEqual(LAYOUT_AUTO);
      expect(normalizeLayoutMode('')).assertEqual(LAYOUT_AUTO);
    });

    it('legacyForceSingleFor：只有 single 写 true', 0, () => {
      expect(legacyForceSingleFor(LAYOUT_SINGLE)).assertTrue();
      expect(legacyForceSingleFor(LAYOUT_MULTI)).assertFalse();
      expect(legacyForceSingleFor(LAYOUT_AUTO)).assertFalse();
    });

    // ---- 启动装载 ----------------------------------------------------------
    it('bootLayoutValues：非法 double 宽回默认、模式归一', 0, () => {
      const v = bootLayoutValues('triple', 0, true);
      expect(v.mode).assertEqual(LAYOUT_MULTI);
      expect(v.navWidthDouble).assertEqual(NAV_WIDTH_DOUBLE_DEFAULT);
      expect(bootLayoutValues(LAYOUT_SINGLE, 371.4, true).navWidthDouble).assertEqual(371);
      expect(bootLayoutValues('', 360, true).mode).assertEqual(LAYOUT_AUTO);
    });

    // ---- 迁移状态机 --------------------------------------------------------
    it('迁移：已有效配置只补标记，不覆盖', 0, () => {
      const plan = planLayoutMigration({
        enabled: true, modePersisted: true, modeValid: true, modeValue: LAYOUT_SINGLE,
        flagPersisted: false, hasLegacy: true, legacyTrue: true, legacyDirty: false
      });
      expect(plan.mode).assertEqual(LAYOUT_SINGLE);
      expect(plan.writeMode).assertFalse();
      expect(plan.writeFlag).assertTrue();
      expect(plan.reason).assertEqual('backfill-flag');
    });

    it('迁移：配置无效但标记在 → 恢复 auto', 0, () => {
      const plan = planLayoutMigration({
        enabled: true, modePersisted: true, modeValid: false, modeValue: '',
        flagPersisted: true, hasLegacy: false, legacyTrue: false, legacyDirty: false
      });
      expect(plan.mode).assertEqual(LAYOUT_AUTO);
      expect(plan.writeMode).assertTrue();
      expect(plan.reason).assertEqual('recover-corrupt');
    });

    it('迁移：旧 true → single，旧 false/缺失 → auto', 0, () => {
      const t = planLayoutMigration({
        enabled: true, modePersisted: false, modeValid: false, modeValue: '',
        flagPersisted: false, hasLegacy: true, legacyTrue: true, legacyDirty: false
      });
      expect(t.mode).assertEqual(LAYOUT_SINGLE);
      expect(t.reason).assertEqual('migrate-legacy-true');
      const f = planLayoutMigration({
        enabled: true, modePersisted: false, modeValid: false, modeValue: '',
        flagPersisted: false, hasLegacy: true, legacyTrue: false, legacyDirty: false
      });
      expect(f.mode).assertEqual(LAYOUT_MODE_DEFAULT);
      expect(f.reason).assertEqual('migrate-legacy-false');
    });

    it('迁移：关掉总开关时不迁移、不写盘', 0, () => {
      const plan = planLayoutMigration({
        enabled: false, modePersisted: false, modeValid: false, modeValue: '',
        flagPersisted: false, hasLegacy: true, legacyTrue: true, legacyDirty: false
      });
      expect(plan.writeMode).assertFalse();
      expect(plan.writeFlag).assertFalse();
      expect(plan.reason).assertEqual('v2-disabled');
    });

    it('迁移标记键名固定（老数据兼容）', 0, () => {
      expect(KEY_LAYOUT_MIGRATED_V1).assertEqual('layoutMigratedV1');
    });
  });
}
