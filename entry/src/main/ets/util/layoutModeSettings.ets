// 布局模式的持久化键、读取封装与迁移状态机。
//
// 4 个键、默认值、迁移判据集中在这里，页面与 store 不直接写字符串：
//   layoutMode           auto / single / multi（默认 auto；历史 double / triple 归一为 multi）
//   navWidthDouble       双栏列表宽，328–440（默认 360）
//   layout_v2_enabled    新多栏外壳总开关（历史键，现已恒为单一布局系统）
//   layoutMigratedV1     迁移标记：旧 forceSingleColumn 是否已迁移过一次
//
// 【唯一数据源】layoutMode 是唯一用户偏好；resolvedLayout 只在运行时由
// paneLayout.resolvePaneLayout 解析。2026-11-21 起右侧资料列（第三栏）已删除，
// 不再有 infoWidth / infoVisible / infoColumnOpen 这些键。
//
// 【读路径禁止回写】本文件只读 AppStorage，不 persist、不写旧键。迁移只发生在
// AppSettings.initSettings 启动装载时；迁移写盘由 AppSettings 负责（必须 await
// Preferences 的 put/flush 才能分辨成功与失败）。用户改模式时才由 setLayoutMode
// 落盘并双写旧键。

import {
  DEVICE_2IN1, DEVICE_PHONE, DEVICE_TABLET, LAYOUT_AUTO, LAYOUT_SINGLE,
  autoTarget, deviceClassOf, legacyForceSingleFor, normalizeLayoutMode, sanitizeNavWidth
} from './paneLayout';

export const KEY_LAYOUT_MODE: string = 'layoutMode';
export const KEY_NAV_WIDTH_DOUBLE: string = 'navWidthDouble';
export const KEY_LAYOUT_V2: string = 'layout_v2_enabled';
export const KEY_LAYOUT_MIGRATED_V1: string = 'layoutMigratedV1';

export const LAYOUT_MODE_DEFAULT: string = LAYOUT_AUTO;
export const NAV_WIDTH_DOUBLE_DEFAULT: number = 360;
export const LAYOUT_V2_DEFAULT: boolean = false;

export interface LayoutSettingsSnapshot {
  mode: string;
  navWidthDouble: number;
  enabled: boolean;
}

// 只读快照。组件可以在 aboutToAppear 里取一次；需要响应变化时仍应各自用
// @StorageProp 绑单个键（不要绑整个快照对象，AppStorage 不做深比较）。
export function readLayoutSettings(): LayoutSettingsSnapshot {
  return {
    mode: normalizeLayoutMode(AppStorage.get<string>(KEY_LAYOUT_MODE) ?? LAYOUT_MODE_DEFAULT),
    navWidthDouble: sanitizeNavWidth(
      AppStorage.get<number>(KEY_NAV_WIDTH_DOUBLE) ?? NAV_WIDTH_DOUBLE_DEFAULT,
      NAV_WIDTH_DOUBLE_DEFAULT),
    enabled: true // 单一布局系统：运行时无新旧布局总开关
  };
}

// 启动装载用的最终值。不写盘，只返回应该放进 AppStorage 的值。
export interface LayoutBootValues {
  mode: string;
  navWidthDouble: number;
  enabled: boolean;
}

export function bootLayoutValues(planMode: string, storedDouble: number,
  enabled: boolean): LayoutBootValues {
  return {
    mode: normalizeLayoutMode(planMode),
    navWidthDouble: sanitizeNavWidth(storedDouble, NAV_WIDTH_DOUBLE_DEFAULT),
    enabled: enabled
  };
}

// ---- 迁移状态机 ------------------------------------------------------------
//
// 输入必须来自 Preferences 的真实持久化状态，不能拿 AppStorage 的 setOrCreate
// 默认值冒充「用户已配置」。
export interface LayoutMigrationState {
  enabled: boolean;
  // Preferences 里是否存在 layoutMode（hasSync），以及它的值是否属于四模式之一。
  modePersisted: boolean;
  modeValid: boolean;
  modeValue: string;
  // Preferences 里是否存在迁移标记。
  flagPersisted: boolean;
  // 旧 forceSingleColumn：是否存在 / 是否为 true / 是否类型异常。
  hasLegacy: boolean;
  legacyTrue: boolean;
  legacyDirty: boolean;
}

// writeMode / writeFlag 描述本次启动需要落盘的动作；mode 是应写入并放进
// AppStorage 的值。AppSettings 必须「先写 mode、成功后再写 flag」，任何一步
// 失败都只记录异常，下次启动由本状态机重新判定。
export interface LayoutMigrationPlan {
  mode: string;
  writeMode: boolean;
  writeFlag: boolean;
  reason: string;
}

export function planLayoutMigration(state: LayoutMigrationState): LayoutMigrationPlan {
  // 新布局关闭：不迁移、不写 layoutMode、不写标记、不清空已有新配置。
  if (!state.enabled) {
    return {
      mode: state.modeValid ? state.modeValue : LAYOUT_AUTO,
      writeMode: false,
      writeFlag: false,
      reason: 'v2-disabled'
    };
  }

  // 新配置有效：最高优先级；只补写缺失的迁移标记，不读旧配置覆盖。
  if (state.modeValid) {
    return {
      mode: state.modeValue,
      writeMode: false,
      writeFlag: !state.flagPersisted,
      reason: state.flagPersisted ? 'keep-valid' : 'backfill-flag'
    };
  }

  // 标记存在但新配置无效：恢复安全默认 auto，保留标记，不再按旧配置反复迁移。
  if (state.flagPersisted) {
    return {
      mode: LAYOUT_AUTO,
      writeMode: true,
      writeFlag: false,
      reason: 'recover-corrupt'
    };
  }

  // 首次迁移：旧 true→single；false/缺失/脏值→auto。
  if (state.hasLegacy && !state.legacyDirty && state.legacyTrue) {
    return {
      mode: LAYOUT_SINGLE,
      writeMode: true,
      writeFlag: true,
      reason: 'migrate-legacy-true'
    };
  }
  let reason: string = 'migrate-missing';
  if (state.hasLegacy) {
    reason = state.legacyDirty ? 'migrate-dirty' : 'migrate-legacy-false';
  }
  return {
    mode: LAYOUT_AUTO,
    writeMode: true,
    writeFlag: true,
    reason: reason
  };
}

// 设备目标，供设置页显示「自动 = 手机单栏 / 平板与电脑双栏」文案。
export function autoTargetFor(device: string): string {
  return autoTarget(device);
}

// 旧键双写值，供 AppSettings.setLayoutMode 使用。
export function legacyValueFor(mode: string): boolean {
  return legacyForceSingleFor(mode);
}

// 设备类型，供调用方在不方便直接 import @kit 时复用同一套归一规则。
export function deviceClass(deviceType: string): string {
  return deviceClassOf(deviceType);
}

export { DEVICE_PHONE, DEVICE_TABLET, DEVICE_2IN1 };
