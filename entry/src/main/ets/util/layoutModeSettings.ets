// 布局模式的持久化键、读取封装与迁移状态机（P0）。
//
// 7 个键、默认值、迁移判据集中在这里，页面与 store 不直接写字符串：
//   layoutMode           single / double / triple / auto（默认 auto）
//   navWidthDouble       双栏列表宽，328–440（默认 360）
//   navWidthTriple       三栏列表宽，328–440（默认 360）
//   infoWidth            信息栏宽，300–400（默认 340）
//   infoVisible          旧布局资料栏显隐（兼容键，新布局不读它做判据）
//   layout_v2_enabled    新多栏外壳总开关（实施期默认 false）
//   layoutMigratedV1     迁移标记：旧 forceSingleColumn 是否已迁移过一次
//
// 【唯一数据源】新布局启用后：layoutMode 是唯一用户偏好；resolvedLayout 只在
// 运行时由 paneLayout.resolvePaneLayout 解析；infoVisible 是
// (resolvedLayout === 'triple') 的派生结果，不再有独立开关。
//
// 【读路径禁止回写】本文件只读 AppStorage，不 persist、不写旧键。迁移只发生在
// AppSettings.initSettings 启动装载时；迁移写盘由 AppSettings 负责（必须 await
// Preferences 的 put/flush 才能分辨成功与失败）。用户改模式时才由 setLayoutMode
// 落盘并双写旧键。
//
// 【双键并存期】P0–P4 期间旧页面仍读 KEY_FORCE_SINGLE_COLUMN（13 处），所以
// setLayoutMode 要双写；读旧键的页面不需要感知新模式。

import {
  DEVICE_2IN1, DEVICE_PHONE, DEVICE_TABLET, LAYOUT_AUTO, LAYOUT_SINGLE, LAYOUT_TRIPLE,
  autoTarget, deviceClassOf, infoVisibleDefault, legacyForceSingleFor, normalizeLayoutMode,
  sanitizeInfoWidth, sanitizeNavWidth
} from './paneLayout';

export const KEY_LAYOUT_MODE: string = 'layoutMode';
export const KEY_NAV_WIDTH_DOUBLE: string = 'navWidthDouble';
export const KEY_NAV_WIDTH_TRIPLE: string = 'navWidthTriple';
export const KEY_INFO_WIDTH: string = 'infoWidth';
export const KEY_INFO_VISIBLE: string = 'infoVisible';
export const KEY_LAYOUT_V2: string = 'layout_v2_enabled';
export const KEY_LAYOUT_MIGRATED_V1: string = 'layoutMigratedV1';

export const LAYOUT_MODE_DEFAULT: string = LAYOUT_AUTO;
export const NAV_WIDTH_DOUBLE_DEFAULT: number = 360;
export const NAV_WIDTH_TRIPLE_DEFAULT: number = 360;
export const INFO_WIDTH_DEFAULT: number = 340;
export const INFO_VISIBLE_DEFAULT: boolean = false;
export const LAYOUT_V2_DEFAULT: boolean = false;

export interface LayoutSettingsSnapshot {
  mode: string;
  navWidthDouble: number;
  navWidthTriple: number;
  infoWidth: number;
  infoVisible: boolean;
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
    navWidthTriple: sanitizeNavWidth(
      AppStorage.get<number>(KEY_NAV_WIDTH_TRIPLE) ?? NAV_WIDTH_TRIPLE_DEFAULT,
      NAV_WIDTH_TRIPLE_DEFAULT),
    infoWidth: sanitizeInfoWidth(AppStorage.get<number>(KEY_INFO_WIDTH) ?? INFO_WIDTH_DEFAULT),
    infoVisible: AppStorage.get<boolean>(KEY_INFO_VISIBLE) ?? INFO_VISIBLE_DEFAULT,
    enabled: AppStorage.get<boolean>(KEY_LAYOUT_V2) ?? LAYOUT_V2_DEFAULT
  };
}

// 资料栏派生（新布局）：只由实际生效布局决定，没有第二数据源。
export function infoVisibleFor(resolvedLayout: string): boolean {
  return resolvedLayout === LAYOUT_TRIPLE;
}

// 当前生效的信息栏开合。
//   enabled=true ：严格等于 resolvedLayout==='triple'；设备默认值与
//                  KEY_INFO_VISIBLE 一律不参与（P0-2）。
//   enabled=false：旧布局回滚路径，保留旧版「设备默认 + 用户显式值」表达式；
//                  新 UI 不读这条分支，只为回滚兼容保留。
export function effectiveInfoVisible(enabled: boolean, resolvedLayout: string,
  storedVisible: boolean, device: string): boolean {
  if (enabled) {
    return infoVisibleFor(resolvedLayout);
  }
  return storedVisible || infoVisibleDefault(device);
}

// 启动装载用的最终值。不写盘，只返回应该放进 AppStorage 的值。
export interface LayoutBootValues {
  mode: string;
  navWidthDouble: number;
  navWidthTriple: number;
  infoWidth: number;
  infoVisible: boolean;
  enabled: boolean;
}

export function bootLayoutValues(planMode: string, storedDouble: number, storedTriple: number,
  storedInfo: number, storedVisible: boolean, enabled: boolean): LayoutBootValues {
  return {
    mode: normalizeLayoutMode(planMode),
    navWidthDouble: sanitizeNavWidth(storedDouble, NAV_WIDTH_DOUBLE_DEFAULT),
    navWidthTriple: sanitizeNavWidth(storedTriple, NAV_WIDTH_TRIPLE_DEFAULT),
    infoWidth: sanitizeInfoWidth(storedInfo),
    infoVisible: storedVisible,
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

// 设备目标，供设置页显示「自动 = 手机单栏 / 平板双栏 / 电脑三栏」文案。
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
