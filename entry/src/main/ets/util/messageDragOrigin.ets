const ORIGIN_PREFIX: string = 'petrelgram-message-drag-v1:';
interface MessageDragOrigin { account: string; chatId: number; }
interface DragExtra { extraInfo?: string; }

export function messageDragOriginTag(account: string, chatId: number): string {
  if (account === '' || !Number.isFinite(chatId) || chatId === 0) { return ''; }
  const origin: MessageDragOrigin = { account, chatId };
  return ORIGIN_PREFIX + JSON.stringify(origin);
}

export function isSameChatMessageDrag(tag: string, account: string, chatId: number): boolean {
  if (account === '' || chatId === 0 || tag.length > 4096 || !tag.startsWith(ORIGIN_PREFIX)) { return false; }
  try {
    const origin = JSON.parse(tag.substring(ORIGIN_PREFIX.length)) as MessageDragOrigin | null;
    return origin !== null && origin.account === account && origin.chatId === chatId;
  } catch (_) { return false; }
}

// ArkUI wraps DragItemInfo.extraInfo in the drop callback's JSON extraParams.
export function isSameChatMessageDragExtra(extra: string | undefined, account: string, chatId: number): boolean {
  if (!extra || extra.length > 8192) { return false; }
  try {
    const parsed = JSON.parse(extra) as DragExtra | null;
    return parsed !== null && typeof parsed.extraInfo === 'string' &&
      isSameChatMessageDrag(parsed.extraInfo, account, chatId);
  } catch (_) { return false; }
}

// 只要拖拽源是本应用的消息（任意会话），聊天页就不再画自己的接收提示：
// 这种拖拽的目标（中转站、小艺、别的会话）在起拖时就已经确定。
export function isMessageDragExtra(extra: string | undefined): boolean {
  if (!extra || extra.length > 8192) { return false; }
  try {
    const parsed = JSON.parse(extra) as DragExtra | null;
    return parsed !== null && typeof parsed.extraInfo === 'string' &&
      parsed.extraInfo.startsWith(ORIGIN_PREFIX);
  } catch (_) { return false; }
}

// 系统起拖路径上 extraParams 可能拿不到 extraInfo，进程内再留一条兜底信号：
// 消息拖拽进行中时聊天页同样不画接收提示。onDragEnd 可能不来，30 秒自动复位。
let messageDragActive: boolean = false;
let messageDragResetTimer: number = -1;

export function setMessageDragActive(active: boolean): void {
  messageDragActive = active;
  if (messageDragResetTimer !== -1) {
    clearTimeout(messageDragResetTimer);
    messageDragResetTimer = -1;
  }
  if (active) {
    messageDragResetTimer = setTimeout((): void => {
      messageDragActive = false;
      messageDragResetTimer = -1;
    }, 30000);
  }
}

export function isMessageDragActive(): boolean {
  return messageDragActive;
}
