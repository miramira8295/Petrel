// 布局模式的持久化键与读取封装（P0）。
//
// 6 个键、默认值、迁移判据集中在这里，页面与 store 不直接写字符串：
//   layoutMode        single / double / triple / auto（默认 auto）
//   navWidthDouble    双栏列表宽，328–440（默认 360）
//   navWidthTriple    三栏列表宽，328–440（默认 360）
//   infoWidth         信息栏宽，300–400（默认 340）
//   infoVisible       信息栏开合（2in1 首次默认开，其余默认关）
//   layout_v2_enabled 新多栏外壳总开关（实施期默认 false）
//
// 【读路径禁止回写】本文件只读 AppStorage，不 persist、不写旧键。迁移只发生在
// AppSettings.initSettings 启动装载时，而且只写 AppStorage（内存镜像），不落盘；
// 用户第一次在设置页改模式时才由 setLayoutMode 落盘并双写旧键。
//
// 【双键并存期】P0–P4 期间旧页面仍读 KEY_FORCE_SINGLE_COLUMN（13 处），所以
// setLayoutMode 要双写；读旧键的页面不需要感知新模式，它们只关心"是否强制单栏"。

import {
  DEVICE_2IN1, DEVICE_PHONE, DEVICE_TABLET, LAYOUT_AUTO, autoTarget, deviceClassOf,
  infoVisibleDefault, legacyForceSingleFor, migrateLegacyLayoutMode, normalizeLayoutMode,
  sanitizeInfoWidth, sanitizeNavWidth
} from './paneLayout';

export const KEY_LAYOUT_MODE: string = 'layoutMode';
export const KEY_NAV_WIDTH_DOUBLE: string = 'navWidthDouble';
export const KEY_NAV_WIDTH_TRIPLE: string = 'navWidthTriple';
export const KEY_INFO_WIDTH: string = 'infoWidth';
export const KEY_INFO_VISIBLE: string = 'infoVisible';
export const KEY_LAYOUT_V2: string = 'layout_v2_enabled';

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

// 当前生效的信息栏开合：用户手动关过就尊重；没关过时按设备默认（2in1 开）。
// 参数 visible 来自 @StorageProp(KEY_INFO_VISIBLE)，raw 用于区分"从未写过"。
export function effectiveInfoVisible(visible: boolean, device: string): boolean {
  return visible || infoVisibleDefault(device);
}

// 启动装载用的迁移结果。不写盘，只返回应该放进 AppStorage 的值。
export interface LayoutBootValues {
  mode: string;
  navWidthDouble: number;
  navWidthTriple: number;
  infoWidth: number;
  infoVisible: boolean;
  enabled: boolean;
}

export function bootLayoutValues(hasLegacy: boolean, legacyTrue: boolean, legacyDirty: boolean,
  existingMode: string, storedDouble: number, storedTriple: number, storedInfo: number,
  storedVisible: boolean, enabled: boolean): LayoutBootValues {
  const migrated = migrateLegacyLayoutMode(hasLegacy, legacyTrue, legacyDirty, existingMode, true);
  return {
    mode: normalizeLayoutMode(migrated),
    navWidthDouble: sanitizeNavWidth(storedDouble, NAV_WIDTH_DOUBLE_DEFAULT),
    navWidthTriple: sanitizeNavWidth(storedTriple, NAV_WIDTH_TRIPLE_DEFAULT),
    infoWidth: sanitizeInfoWidth(storedInfo),
    infoVisible: storedVisible,
    enabled: enabled
  };
}

// 设备目标，供设置页显示"自动 = 手机单栏 / 平板双栏 / 电脑三栏"文案。
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
