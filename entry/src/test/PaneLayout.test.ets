// P0 多栏布局纯函数单测。
//
// 覆盖 12_P0实施任务书 §5 与 2026-11-08 P0 修复任务书 §10：
//   设备三档、auto 六类宽点 + 滞回、手动 single/double/triple 边界、
//   宽度 8 组、迁移状态机 10 例、资料栏派生 6 例、boot 装载、sanitize、常量。
//
// 这些用例只验算术与状态机契约，不验布局观感与生命周期——后者在 P2/P3 真机验。
// 任何一条失败都意味着 05 规范与代码已经分叉，先改设计文档再改实现。
// 用例数量以 hvigor 测试输出为准（不在注释里写死，避免再次出现 36/41 不一致）。

import { describe, expect, it } from '@ohos/hypium';
import {
  AUTO_TRIPLE_ENTER_VP, AUTO_TRIPLE_EXIT_VP, LAYOUT_AUTO, LAYOUT_DOUBLE, LAYOUT_SINGLE,
  LAYOUT_TRIPLE, TRIPLE_ENTER_W_VP, TRIPLE_EXIT_W_VP, autoTarget, canDouble, canTriple,
  capsuleWidth, deviceClassOf, infoVisibleDefault, legacyForceSingleFor, normalizeLayoutMode,
  profilePresentation, resolvePaneLayout, sanitizeInfoWidth, sanitizeNavWidth
} from '../main/ets/util/paneLayout';
import {
  bootLayoutValues, effectiveInfoVisible, INFO_WIDTH_DEFAULT, infoVisibleFor,
  KEY_LAYOUT_MIGRATED_V1, LAYOUT_MODE_DEFAULT, NAV_WIDTH_DOUBLE_DEFAULT,
  NAV_WIDTH_TRIPLE_DEFAULT, planLayoutMigration
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

    it('信息栏默认只在 2in1 打开（旧布局兼容语义）', 0, () => {
      expect(infoVisibleDefault(TWO_IN_ONE)).assertTrue();
      expect(infoVisibleDefault(TABLET)).assertFalse();
      expect(infoVisibleDefault(PHONE)).assertFalse();
    });

    // ---- auto --------------------------------------------------------------
    it('auto 手机 1317.6 仍单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, PHONE, 1317.6, 865.9, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
      expect(r.infoVisible).assertFalse();
    });

    it('auto 平板 865.9 双栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TABLET, 865.9, 865.9, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.infoVisible).assertFalse();
    });

    it('auto 平板 1642 也不进三栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TABLET, 1642, 1094.7, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.reason).assertEqual('double');
    });

    it('auto 2in1 首次 1262 进三栏', 0, () => {
      expect(AUTO_TRIPLE_ENTER_VP).assertEqual(1262);
      expect(TRIPLE_ENTER_W_VP).assertEqual(1262);
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1262, 920, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_TRIPLE);
      expect(r.infoVisible).assertTrue();
    });

    it('auto 2in1 1261 首次仍双栏（进门槛边界）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1261, 920, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.reason).assertEqual('double');
    });

    it('auto 2in1 1240 已三栏则保持', 0, () => {
      expect(AUTO_TRIPLE_EXIT_VP).assertEqual(1240);
      expect(TRIPLE_EXIT_W_VP).assertEqual(1240);
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1240, 920, 360, 340, true);
      expect(r.effective).assertEqual(LAYOUT_TRIPLE);
    });

    it('auto 2in1 1239 已三栏则退出（滞回）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1239, 920, 360, 340, true);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
    });

    it('auto 2in1 1240 未三栏不提前进入（滞回）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1240, 920, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
    });

    it('auto 2in1 1262 高 519 单栏（高度约束）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 1262, 519, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
      expect(r.reason).assertEqual('double-degraded-no-space');
    });

    it('auto 2in1 840 双栏 list 328 / chat 510', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 840, 920, 328, 340, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(510);
    });

    it('auto 2in1 391 单栏（降级）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_AUTO, TWO_IN_ONE, 391, 900, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
      expect(r.reason).assertEqual('double-degraded-no-space');
    });

    // ---- 手动模式 ----------------------------------------------------------
    it('手动 single 在 1642 也单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_SINGLE, TABLET, 1642, 1094.7, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    it('手动 single 在 2in1 宽窗也单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_SINGLE, TWO_IN_ONE, 1642, 1094.7, 360, 340, true);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    it('手动 double 759 单栏、760 双栏', 0, () => {
      const a = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 759, 900, 360, 340, false);
      const b = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 760, 900, 328, 340, false);
      expect(a.effective).assertEqual(LAYOUT_SINGLE);
      expect(b.effective).assertEqual(LAYOUT_DOUBLE);
    });

    it('手动 double 即使空间够三栏也不升级', 0, () => {
      const r = resolvePaneLayout(LAYOUT_DOUBLE, TWO_IN_ONE, 1642, 1094.7, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_DOUBLE);
      expect(r.infoVisible).assertFalse();
    });

    it('手动 double 高 519 降单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 1200, 519, 360, 340, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    it('手动 triple 1189 降双栏、1190 三栏（info 300）', 0, () => {
      const a = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1189, 900, 328, 300, false);
      const b = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1190, 900, 328, 300, false);
      expect(a.effective).assertEqual(LAYOUT_DOUBLE);
      expect(b.effective).assertEqual(LAYOUT_TRIPLE);
      expect(b.navW).assertEqual(888);
      expect(b.listW).assertEqual(328);
      expect(b.chatW).assertEqual(560);
    });

    it('手动 triple 1230 默认 info 340 三栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1230, 900, 328, 340, false);
      expect(r.effective).assertEqual(LAYOUT_TRIPLE);
    });

    it('手动 triple 高 519 降单栏', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1642, 519, 328, 340, false);
      expect(r.effective).assertEqual(LAYOUT_SINGLE);
    });

    it('手动 triple 三→双→单后恢复回三栏', 0, () => {
      const down = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 900, 900, 328, 340, true);
      const up = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1262, 900, 328, 340, false);
      expect(down.effective).assertEqual(LAYOUT_DOUBLE);
      expect(up.effective).assertEqual(LAYOUT_TRIPLE);
    });

    it('手动 triple 的 reason 在空间不足时标 triple-degraded', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 900, 900, 328, 340, false);
      expect(r.reason).assertEqual('triple-degraded-no-space');
    });

    // ---- 宽度 --------------------------------------------------------------
    it('1317.6：navW 975.6 / list 360 / chat 615.6', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1317.6, 865.9, 360, 340, false);
      expect(near(r.navW, 975.6)).assertTrue();
      expect(r.listW).assertEqual(360);
      expect(near(r.chatW, 615.6)).assertTrue();
    });

    it('1262：list 360 / chat 560', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1262, 900, 360, 340, false);
      expect(r.listW).assertEqual(360);
      expect(r.chatW).assertEqual(560);
    });

    it('1190：navW 888 / list 328 / chat 560', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1190, 900, 328, 300, false);
      expect(r.navW).assertEqual(888);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(560);
    });

    it('840：list 328 / chat 510', 0, () => {
      const r = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 840, 900, 328, 340, false);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(510);
    });

    it('1100：list 373 / chat 725', 0, () => {
      const r = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 1100, 900, 373, 340, false);
      expect(r.listW).assertEqual(373);
      expect(r.chatW).assertEqual(725);
    });

    it('760：list 328 / chat 430', 0, () => {
      const r = resolvePaneLayout(LAYOUT_DOUBLE, TABLET, 760, 900, 328, 340, false);
      expect(r.listW).assertEqual(328);
      expect(r.chatW).assertEqual(430);
    });

    it('1200：list 328 / chat 570（info 300）', 0, () => {
      const r = resolvePaneLayout(LAYOUT_TRIPLE, TABLET, 1200, 900, 328, 300, false);
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

    // ---- 迁移状态机 --------------------------------------------------------
    it('迁移：新布局关闭时不迁移、不写盘', 0, () => {
      const plan = planLayoutMigration({
        enabled: false, modePersisted: false, modeValid: false, modeValue: '',
        flagPersisted: false, hasLegacy: true, legacyTrue: true, legacyDirty: false
      });
      expect(plan.mode).assertEqual('auto');
      expect(plan.writeMode).assertFalse();
      expect(plan.writeFlag).assertFalse();
      expect(plan.reason).assertEqual('v2-disabled');
    });

    it('迁移：关闭时保留已存在的新配置', 0, () => {
      const plan = planLayoutMigration({
        enabled: false, modePersisted: true, modeValid: true, modeValue: 'triple',
        flagPersisted: false, hasLegacy: true, legacyTrue: true, legacyDirty: false
      });
      expect(plan.mode).assertEqual('triple');
      expect(plan.writeMode).assertFalse();
      expect(plan.writeFlag).assertFalse();
    });

    it('迁移 M1：旧 true → single，写模式与标记', 0, () => {
      const plan = planLayoutMigration({
        enabled: true, modePersisted: false, modeValid: false, modeValue: '',
        flagPersisted: false, hasLegacy: true, legacyTrue: true, legacyDirty: false
      });
      expect(plan.mode).assertEqual('single');
      expect(plan.writeMode).assertTrue();
      expect(plan.writeFlag).assertTrue();
      expect(plan.reason).assertEqual('migrate-legacy-true');
    });

    it('迁移 M2：旧 false → auto', 0, () => {
      const plan = planLayoutMigration({
        enabled: true, modePersisted: false, modeValid: false, modeValue: '',
        flagPersisted: false, hasLegacy: true, legacyTrue: false, legacyDirty: false
      });
      expect(plan.mode).assertEqual('auto');
      expect(plan.reason).assertEqual('migrate-legacy-false');
    });

    it('迁移 M3：旧缺失 → auto', 0, () => {
      const plan = planLayoutMigration({
        enabled: true, modePersisted: false, modeValid: false, modeValue: '',
        flagPersisted: false, hasLegacy: false, legacyTrue: false, legacyDirty: false
      });
      expect(plan.mode).assertEqual('auto');
      expect(plan.reason).assertEqual('migrate-missing');
    });

    it('迁移 M4：旧脏值 → auto', 0, () => {
      const plan = planLayoutMigration({
        enabled: true, modePersisted: false, modeValid: false, modeValue: '',
        flagPersisted: false, hasLegacy: true, legacyTrue: false, legacyDirty: true
      });
      expect(plan.mode).assertEqual('auto');
      expect(plan.reason).assertEqual('migrate-dirty');
    });

    it('迁移 M7：新配置有效则保留，不读旧配置', 0, () => {
      const plan = planLayoutMigration({
        enabled: true, modePersisted: true, modeValid: true, modeValue: 'double',
        flagPersisted: true, hasLegacy: true, legacyTrue: true, legacyDirty: false
      });
      expect(plan.mode).assertEqual('double');
      expect(plan.writeMode).assertFalse();
      expect(plan.writeFlag).assertFalse();
      expect(plan.reason).assertEqual('keep-valid');
    });

    it('迁移 M8：有效但标记缺失只补标记', 0, () => {
      const plan = planLayoutMigration({
        enabled: true, modePersisted: true, modeValid: true, modeValue: 'triple',
        flagPersisted: false, hasLegacy: true, legacyTrue: true, legacyDirty: false
      });
      expect(plan.mode).assertEqual('triple');
      expect(plan.writeMode).assertFalse();
      expect(plan.writeFlag).assertTrue();
      expect(plan.reason).assertEqual('backfill-flag');
    });

    it('迁移 M9：标记存在但配置无效 → 恢复 auto', 0, () => {
      const plan = planLayoutMigration({
        enabled: true, modePersisted: true, modeValid: false, modeValue: '',
        flagPersisted: true, hasLegacy: true, legacyTrue: true, legacyDirty: false
      });
      expect(plan.mode).assertEqual('auto');
      expect(plan.writeMode).assertTrue();
      expect(plan.writeFlag).assertFalse();
      expect(plan.reason).assertEqual('recover-corrupt');
    });

    it('迁移标记常量固定，避免改名后旧数据失效', 0, () => {
      expect(KEY_LAYOUT_MIGRATED_V1).assertEqual('layoutMigratedV1');
    });

    it('旧键双写值：只有 single 为 true', 0, () => {
      expect(legacyForceSingleFor('single')).assertTrue();
      expect(legacyForceSingleFor('auto')).assertFalse();
      expect(legacyForceSingleFor('double')).assertFalse();
      expect(legacyForceSingleFor('triple')).assertFalse();
    });

    // ---- boot 装载 ---------------------------------------------------------
    it('boot 装载：宽度钳制一起生效', 0, () => {
      const boot = bootLayoutValues('single', 100, 999, 500, false, false);
      expect(boot.mode).assertEqual('single');
      expect(boot.navWidthDouble).assertEqual(328);
      expect(boot.navWidthTriple).assertEqual(440);
      expect(boot.infoWidth).assertEqual(400);
      expect(boot.enabled).assertFalse();
    });

    it('boot 装载：脏 mode 归一为 auto', 0, () => {
      const boot = bootLayoutValues('split', 360, 360, 340, false, true);
      expect(boot.mode).assertEqual('auto');
    });

    // ---- 资料栏派生（P0-2） ------------------------------------------------
    it('infoVisibleFor：只有 triple 为 true', 0, () => {
      expect(infoVisibleFor('triple')).assertTrue();
      expect(infoVisibleFor('double')).assertFalse();
      expect(infoVisibleFor('single')).assertFalse();
    });

    it('新布局：resolved=triple 显示资料栏', 0, () => {
      expect(effectiveInfoVisible(true, 'triple', false, TABLET)).assertTrue();
    });

    it('新布局：resolved=double 即使是 2in1 且旧值 true 也隐藏', 0, () => {
      expect(effectiveInfoVisible(true, 'double', true, TWO_IN_ONE)).assertFalse();
    });

    it('新布局：resolved=single 隐藏资料栏', 0, () => {
      expect(effectiveInfoVisible(true, 'single', true, TWO_IN_ONE)).assertFalse();
    });

    it('旧布局回滚：保留设备默认 + 用户值', 0, () => {
      expect(effectiveInfoVisible(false, 'double', false, TWO_IN_ONE)).assertTrue();
      expect(effectiveInfoVisible(false, 'double', true, TABLET)).assertTrue();
      expect(effectiveInfoVisible(false, 'double', false, TABLET)).assertFalse();
    });

    // ---- 门槛 --------------------------------------------------------------
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
