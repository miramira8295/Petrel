// 当前正被打开的会话。通知层用它实现官方语义里的「前台免打扰」：
// 只有应用在前台、并且屏幕亮着、并且用户正停在这个会话里，才不弹这条消息；
// 在别的页面或别的会话时照常通知。
//
// 只放 AppStorage：ChatPage 是 V2 组件，NotificationService 读的时候也不订阅，
// 谁需要谁现取，不需要镜像到 chatEnv。

export const KEY_ACTIVE_CHAT_ID: string = 'activeChatId';

export function setActiveChatId(chatId: number): void {
  const current: number = AppStorage.get<number>(KEY_ACTIVE_CHAT_ID) ?? 0;
  if (current === chatId) {
    return;
  }
  AppStorage.setOrCreate<number>(KEY_ACTIVE_CHAT_ID, chatId);
}

export function activeChatId(): number {
  return AppStorage.get<number>(KEY_ACTIVE_CHAT_ID) ?? 0;
}
