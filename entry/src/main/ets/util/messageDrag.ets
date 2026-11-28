import { TdObject } from '../tdkit/TdTypes';

export interface MessageDragPayload {
  type: string;
  text: string;
  fileId: number;
}

export function messageDragType(contentType: string): string {
  if (contentType === 'text' || contentType === 'emoji') { return 'general.plain-text'; }
  if (contentType === 'photo') { return 'general.image'; }
  if (contentType === 'video') { return 'general.video'; }
  if (contentType === 'audio' || contentType === 'voice') { return 'general.audio'; }
  if (contentType === 'file') { return 'general.file'; }
  return '';
}

// 媒体消息的说明文字随文件一起交付，图文混合消息不能只剩一张图。
function captionText(content: TdObject): string {
  const caption = content['caption'] as TdObject | undefined;
  return (caption?.['text'] as string | undefined) ?? '';
}

function completedLocalPath(file: TdObject): string {
  const local = file['local'] as TdObject | undefined;
  const path = (local?.['path'] as string | undefined) ?? '';
  return local?.['is_downloading_completed'] === true && path.startsWith('/') ? path : '';
}

// Resolve original TDLib files, never the renderer's thumbnail/poster paths.
export function messageDragPayload(message: TdObject, properties: TdObject): MessageDragPayload | null {
  if (message['has_protected_content'] === true ||
    properties['has_protected_content_by_current_user'] === true ||
    properties['has_protected_content_by_other_user'] === true || properties['can_be_forwarded'] !== true ||
    message['self_destruct_type'] || message['sending_state']) { return null; }
  const content = message['content'] as TdObject | undefined;
  if (!content) { return null; }
  const kind = content['@type'] as string;
  if (kind === 'messageText') {
    const formatted = content['text'] as TdObject | undefined;
    const text = (formatted?.['text'] as string | undefined) ?? '';
    return text === '' ? null : { type: 'general.plain-text', text, fileId: 0 };
  }
  if (properties['can_be_saved'] !== true) { return null; }
  let file: TdObject | undefined;
  let type: string = '';
  if (kind === 'messagePhoto') {
    const photo = content['photo'] as TdObject | undefined;
    const sizes = (photo?.['sizes'] as TdObject[] | undefined) ?? [];
    let largestArea: number = -1;
    let largest: TdObject | undefined;
    for (const size of sizes) {
      const candidate = size['photo'] as TdObject | undefined;
      if (candidate === undefined) { continue; }
      const area = (size['width'] as number) * (size['height'] as number);
      if (area > largestArea) { largestArea = area; largest = candidate; }
    }
    // 原图优先：没下载的尺寸由 MessageDragSource 在起拖后现场补下载，失败再逐级回退。
    file = largest;
    type = 'general.image';
  } else {
    let field: string = '';
    if (kind === 'messageVideo') { field = 'video'; type = 'general.video'; }
    if (kind === 'messageAnimation') { field = 'animation'; type = 'general.video'; }
    if (kind === 'messageAudio') { field = 'audio'; type = 'general.audio'; }
    if (kind === 'messageVoiceNote') { field = 'voice_note'; type = 'general.audio'; }
    if (kind === 'messageDocument') { field = 'document'; type = 'general.file'; }
    const media = content[field] as TdObject | undefined;
    file = media?.[field] as TdObject | undefined;
  }
  const fileId = (file?.['id'] as number | undefined) ?? 0;
  const caption = captionText(content);
  return type !== '' && fileId > 0 ? { type, text: caption, fileId } : null;
}

// 图片按面积从大到小给出文件 id：拖拽先试原图，下载失败再退到较小尺寸。
export function messageDragPhotoFileIds(message: TdObject): number[] {
  const content = message['content'] as TdObject | undefined;
  const photo = content?.['photo'] as TdObject | undefined;
  const sizes = (photo?.['sizes'] as TdObject[] | undefined) ?? [];
  const ranked: TdObject[] = sizes.slice();
  ranked.sort((a: TdObject, b: TdObject): number =>
    ((b['width'] as number) * (b['height'] as number)) - ((a['width'] as number) * (a['height'] as number)));
  const ids: number[] = [];
  for (const size of ranked) {
    const candidate = size['photo'] as TdObject | undefined;
    const id = (candidate?.['id'] as number | undefined) ?? 0;
    if (id > 0 && ids.indexOf(id) < 0) { ids.push(id); }
  }
  return ids;
}

export function completedDragFilePath(file: TdObject): string {
  return completedLocalPath(file);
}

export function messageDragNeedsLocalFile(type: string): boolean {
  return type !== '' && type !== 'general.plain-text';
}

// 没有本地文件就起拖，松手只会得到空内容。拖拽开始前先按会话条目里已下载的
// 路径做同步预检，不通过就提示先下载并取消拖拽。
export function messageDragContentReady(type: string, photoPath: string, photoFullPath: string,
  videoPath: string): boolean {
  if (!messageDragNeedsLocalFile(type)) { return true; }
  // 图片起拖后会现场补下载（原图优先），预检不拦它；视频/音频/文件仍要求先下载。
  if (type === 'general.image') { return true; }
  return videoPath !== '';
}
