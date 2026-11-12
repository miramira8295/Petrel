// 双栏资料浮层卡（P1-B4）。
//
// 双栏布局下打开资料不再把整页推进右栏，而是在 MainScreen 根 Stack 上叠一张
// 居中卡片；三栏继续用右侧资料列，单栏继续整页 push。
//
// 三个 AppStorage 键：
//   profileOverlayOpen   —— 浮层是否可见（布尔）
//   profileOverlayTarget —— 目标 JSON：{"kind":"chat"|"user","id":number}
//   profileOverlayBypass —— 点卡片里的「完整资料」时置 true，让 profileNav
//                           这一次仍然走整页 push，不被浮层再拦截
export const KEY_PROFILE_OVERLAY_OPEN: string = 'profileOverlayOpen';
export const KEY_PROFILE_OVERLAY_TARGET: string = 'profileOverlayTarget';
export const KEY_PROFILE_OVERLAY_BYPASS: string = 'profileOverlayBypass';

export type ProfileOverlayKind = 'chat' | 'user';

export interface ProfileOverlayTarget {
  kind: ProfileOverlayKind;
  id: number;
}

export function openProfileOverlay(kind: ProfileOverlayKind, id: number): void {
  if (id === 0) {
    return;
  }
  const target: ProfileOverlayTarget = { kind: kind, id: id };
  AppStorage.setOrCreate(KEY_PROFILE_OVERLAY_TARGET, JSON.stringify(target));
  AppStorage.setOrCreate(KEY_PROFILE_OVERLAY_OPEN, true);
}

export function closeProfileOverlay(): void {
  AppStorage.setOrCreate(KEY_PROFILE_OVERLAY_OPEN, false);
}

export function isProfileOverlayOpen(): boolean {
  return AppStorage.get<boolean>(KEY_PROFILE_OVERLAY_OPEN) ?? false;
}

export function readProfileOverlayTarget(): ProfileOverlayTarget | null {
  const raw: string = AppStorage.get<string>(KEY_PROFILE_OVERLAY_TARGET) ?? '';
  if (raw === '') {
    return null;
  }
  try {
    const obj = JSON.parse(raw) as Record<string, Object>;
    const kind: string = (obj['kind'] as string | undefined) ?? '';
    const id: number = (obj['id'] as number | undefined) ?? 0;
    if (id === 0 || (kind !== 'chat' && kind !== 'user')) {
      return null;
    }
    return { kind: kind as ProfileOverlayKind, id: id };
  } catch (e) {
    return null;
  }
}

export function beginOverlayBypass(): void {
  AppStorage.setOrCreate(KEY_PROFILE_OVERLAY_BYPASS, true);
}

export function endOverlayBypass(): void {
  AppStorage.setOrCreate(KEY_PROFILE_OVERLAY_BYPASS, false);
}

export function isOverlayBypassed(): boolean {
  return AppStorage.get<boolean>(KEY_PROFILE_OVERLAY_BYPASS) ?? false;
}
