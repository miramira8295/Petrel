// P0 多栏布局纯函数单测。
//
// 覆盖 12_P0实施任务书 §5 的 32 条要求：设备三档、auto 六个宽度点 + 滞回、
// 手动 single/double/triple 边界、宽度 8 组、迁移 M1–M8；另加胶囊、资料呈现、
// sanitize、boot 装载四组，共 36 个 it。
//
// 这些用例只验算术契约，不验布局观感与生命周期——后者在 P2/P3 的真机上验。
// 任何一条失败都意味着 05 规范与代码已经分叉，先改设计文档再改实现。

import { describe, expect, it } from '@ohos/hypium';
import {
  AUTO_TRIPLE_ENTER_VP, AUTO_TRIPLE_EXIT_VP, LAYOUT_AUTO, LAYOUT_DOUBLE, LAYOUT_SINGLE,
  LAYOUT_TRIPLE, autoTarget, canDouble, canTriple, capsuleWidth, deviceClassOf,
  infoVisibleDefault, legacyForceSingleFor, migrateLegacyLayoutMode, normalizeLayoutMode,
  profilePresentation, resolvePaneLayout, sanitizeInfoWidth, sanitizeNavWidth
} from '../main/ets/util/paneLayout';
import {
  bootLayoutValues, effectiveInfoVisible, INFO_WIDTH_DEFAULT, LAYOUT_MODE_DEFAULT,
  NAV_WIDTH_DOUBLE_DEFAULT, NAV_WIDTH_TRIPLE_DEFAULT
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
    it('autoTarget：手机单栏、平板双栏、2in1 三栏', 0, () => {
      expect(autoTarget(PHONE)).assertEqual(LAYOUT_SINGLE);
      expect(autoTarget(TABLET)).assertEqual(LAYOUT_DOUBLE);
      expect(autoTarget(TWO_IN_ONE)).assertEqual(LAYOUT_TRIPLE);
    });

    it('设备类型未知按手机处理', 0, () => {
      expect(deviceClassOf('tv')).assertEqual(PHONE);
      expect(deviceClassOf('')).assertEqual(PHONE);
      expect(deviceClassOf(TABLET)).assertEqual(TABLET);
    });

    it('信息栏默认只在 2in1 打开', 0, () => {
      expect(infoVisibleDefault(TWO_IN_ONE)).assertTrue();
      expect(infoVisibleDefault(TABLET)).assertFalse();
      expect(infoVisibleDefault(PHONE)).assertFalse();
    });

    // ---- auto --------------------------------------------------------------
    it('auto 手机 1317.6 仍单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, PHONE, 1317.6, 865.9, 360, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    it('auto 平板 865.9 双栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TABLET, 865.9, 865.9, 360, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
    });

    it('auto 平板 1642 也不进三栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TABLET, 1642, 1094.7, 360, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.reason).assertEqual('double');
    });

    it('auto 2in1 1262 进三栏', 0, () => {
      expect(AUTO_TRIPLE_ENTER_VP).assertEqual(1262);
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1262, 920, 360, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_TRIPLE);
    });

    it('auto 2in1 1261 双栏（进门槛边界）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1261, 920, 360, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.reason).assertEqual('double');
    });

    it('auto 2in1 1240 已在三栏则保持', 0, () => {
      expect(AUTO_TRIPLE_EXIT_VP).assertEqual(1240);
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1240, 920, 360, 340, true, true);
      expect(r.effective).assertEqual(LAYOUT_TRIPLE);
    });

    it('auto 2in1 1239 已三栏则退出（滞回）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1239, 920, 360, 340, true, true);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
    });

    it('auto 2in1 840 双栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 840, 920, 360, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(510);
    });

    it('auto 2in1 391 单栏（降级）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 391, 900, 360, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
      expect(r.reason).assertEqual('double-degraded-no-space');
    });

    // ---- 手动 --------------------------------------------------------------
    it('手动 single 在 1642 也单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_SINGLE, TABLET, 1642, 1094.7, 360, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    it('手动 double 759 单栏、760 双栏', 0, () => {
      const a = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 759, 900, 360, 340, true, false);
      const b = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 760, 900, 328, 340, true, false);
      expect(a.effective).assertEqual(LAYOUT_SINGLE);
      expect(b.effective).assertEqual(LAYOUT_DOUBLE);
    });

    it('手动 triple 1189 降双栏、1190 三栏（info 300）', 0, () => {
      const a = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1189, 900, 328, 300, true, false);
      const b = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1190, 900, 328, 300, true, false);
      expect(a.effective).assertEqual(LAYOUT_DOUBLE);
      expect(b.effective).assertEqual(LAYOUT_TRIPLE);
      expect(b.navW).assertEqual(888);
      expect(b.listW).assertEqual(328);
      expect(b.chatW).assertEqual(560);
    });

    it('手动 triple 1230 默认 info 340 三栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1230, 900, 328, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_TRIPLE);
    });

    it('手动 triple 高 519 降单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1642, 519, 328, 340, true, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    // ---- 宽度 --------------------------------------------------------------
    it('1317.6：navW 975.6 / list 360 / chat 615.6', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1317.6, 865.9, 360, 340, true, false);
      expect(near(r.navW, 975.6)).assertTrue();
      expect(r.listW).assertEqual(360);
      expect(near(r.chatW, 615.6)).assertTrue();
    });

    it('1262：list 360 / chat 560', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1262, 900, 360, 340, true, false);
      expect(r.listW).assertEqual(360);
      expect(r.chatW).assertEqual(560);
    });

    it('1190：navW 888 / list 328 / chat 560', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1190, 900, 328, 300, true, false);
      expect(r.navW).assertEqual(888);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(560);
    });

    it('840：list 328 / chat 510', 0, () => {
      const r = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 840, 900, 328, 340, true, false);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(510);
    });

    it('1100：list 373 / chat 725', 0, () => {
      const r = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 1100, 900, 373, 340, true, false);
      expect(r.listW).assertEqual(373);
      expect(r.chatW).assertEqual(725);
    });

    it('760：list 328 / chat 430', 0, () => {
      const r = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 760, 900, 328, 340, true, false);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(430);
    });

    it('1200：list 328 / chat 570（info 300）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1200, 900, 328, 300, true, false);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(570);
    });

    // ---- 组件参数 ----------------------------------------------------------
    it('胶囊：列表 360 用 328，328 用 304', 0, () => {
      expect(capsuleWidth(360)).assertEqual(328);
      expect(capsuleWidth(440)).assertEqual(328);
      expect(capsuleWidth(328)).assertEqual(304);
      expect(capsuleWidth(340)).assertEqual(304);
    });

    it('资料呈现：单页 / 浮层 / 第三列', 0, () => {
      expect(profilePresentation(LAYOUT_SINGLE)).assertEqual('page');
      expect(profilePresentation(LAYOUT_DOUBLE)).assertEqual('overlay');
      expect(profilePresentation(LAYOUT_TRIPLE)).assertEqual('column');
    });

    it('列表宽 sanitize：下限 328、上限 440、非法回退', 0, () => {
      expect(sanitizeNavWidth(100, 360)).assertEqual(328);
      expect(sanitizeNavWidth(999, 360)).assertEqual(440);
      expect(sanitizeNavWidth(Number.NaN, 360)).assertEqual(360);
      expect(sanitizeNavWidth(0, 360)).assertEqual(360);
    });

    it('信息栏宽 sanitize：300–400、非法回退 340', 0, () => {
      expect(sanitizeInfoWidth(200)).assertEqual(300);
      expect(sanitizeInfoWidth(999)).assertEqual(400);
      expect(sanitizeInfoWidth(Number.NaN)).assertEqual(340);
    });

    it('模式归一：脏值回 auto', 0, () => {
      expect(normalizeLayoutMode('single')).assertEqual('single');
      expect(normalizeLayoutMode('triple')).assertEqual('triple');
      expect(normalizeLayoutMode('split')).assertEqual('auto');
      expect(normalizeLayoutMode('')).assertEqual('auto');
      expect(normalizeLayoutMode('AUTO')).assertEqual('auto');
    });

    // ---- 迁移 --------------------------------------------------------------
    it('迁移 M1：旧 true → single', 0, () => {
      expect(migrateLegacyLayoutMode(true, true, false, '', true)).assertEqual('single');
    });

    it('迁移 M2：旧 false → auto', 0, () => {
      expect(migrateLegacyLayoutMode(true, false, false, '', true)).assertEqual('auto');
    });

    it('迁移 M3：缺失 → auto', 0, () => {
      expect(migrateLegacyLayoutMode(false, false, false, '', true)).assertEqual('auto');
    });

    it('迁移 M4：脏值 → auto', 0, () => {
      expect(migrateLegacyLayoutMode(true, false, true, '', true)).assertEqual('auto');
    });

    it('迁移 M7：已有新键以新键为准', 0, () => {
      expect(migrateLegacyLayoutMode(true, true, false, 'triple', true)).assertEqual('triple');
    });

    it('迁移 M8：开关关闭不产生迁移', 0, () => {
      expect(migrateLegacyLayoutMode(true, true, false, '', false)).assertEqual('');
    });

    it('旧键双写值：只有 single 为 true', 0, () => {
      expect(legacyForceSingleFor('single')).assertTrue();
      expect(legacyForceSingleFor('auto')).assertFalse();
      expect(legacyForceSingleFor('double')).assertFalse();
      expect(legacyForceSingleFor('triple')).assertFalse();
    });

    it('boot 装载：迁移 + 宽度钳制一起生效', 0, () => {
      const boot = bootLayoutValues(true, true, false, '', 100, 999, 500, false, false);
      expect(boot.mode).assertEqual('single');
      expect(boot.navWidthDouble).assertEqual(328);
      expect(boot.navWidthTriple).assertEqual(440);
      expect(boot.infoWidth).assertEqual(400);
      expect(boot.enabled).assertFalse();
    });

    it('boot 装载：已有新键不被旧 true 覆盖', 0, () => {
      const boot = bootLayoutValues(true, true, false, 'double', 360, 360, 340, true, true);
      expect(boot.mode).assertEqual('double');
      expect(boot.infoVisible).assertTrue();
    });

    it('信息栏默认开：2in1 未关过时为 true', 0, () => {
      expect(effectiveInfoVisible(false, TWO_IN_ONE)).assertTrue();
      expect(effectiveInfoVisible(false, TABLET)).assertFalse();
      expect(effectiveInfoVisible(true, TABLET)).assertTrue();
    });

    it('canDouble / canTriple 门槛与常量一致', 0, () => {
      expect(canDouble(760, 520)).assertTrue();
      expect(canDouble(759, 520)).assertFalse();
      expect(canDouble(760, 519)).assertFalse();
      expect(canTriple(1262, 920, 340, 360)).assertTrue();
      expect(canTriple(1229, 920, 340, 360)).assertFalse();
      expect(canTriple(1400, 519, 340, 360)).assertFalse();
    });

    it('默认常量与任务书一致', 0, () => {
      expect(LAYOUT_MODE_DEFAULT).assertEqual('auto');
      expect(NAV_WIDTH_DOUBLE_DEFAULT).assertEqual(360);
      expect(NAV_WIDTH_TRIPLE_DEFAULT).assertEqual(360);
      expect(INFO_WIDTH_DEFAULT).assertEqual(340);
    });
  });
}
