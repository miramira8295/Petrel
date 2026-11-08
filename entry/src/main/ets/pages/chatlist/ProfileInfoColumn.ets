import { ChatEntry } from '../../store/ChatEntry';
import { getChatStore } from '../../tdkit/Globals';
import { router } from '@kit.ArkUI';
import { PROFILE_TAB_MEDIA, PROFILE_TAB_MEMBERS } from '../../store/ChatProfileStore';
import { setMute } from '../../store/ChatActions';
import { KEY_INFO_WIDTH } from '../../util/layoutModeSettings';
import { navigateToChatProfile } from '../../util/profileNav';
import { AVATAR_PALETTE, COLOR_PRIMARY, COLOR_TEXT_PRIMARY, COLOR_TEXT_SECONDARY } from '../../util/theme';

// 三栏布局右侧的资料摘要列（P1-B4/B6 最小接线）。
//
// 只做「当前会话是谁 + 两个真实可执行入口」，不复制完整资料页：完整资料仍走
// navigateToChatProfile（单栏整页 / 双栏浮层 / 三栏由页面自己决定呈现）。
// 数据只读 ChatStore 的会话条目，不额外订阅 TDLib，也不持有第二份会话状态。
@Component
export struct ProfileInfoColumn {
  @StorageProp('activeChatId') @Watch('reload') private chatId: number = 0;
  @StorageProp(KEY_INFO_WIDTH) private widthVp: number = 340;
  @StorageProp('topSafeHeight') private topSafe: number = 0;
  @State private title: string = '';
  @State private avatarPath: string = '';
  @State private initials: string = '';
  @State private kind: string = '';
  @State private muted: boolean = false;
  @State private rawKind: string = '';
  @State private memberCount: number = 0;
  private unsubscribe: (() => void) | null = null;

  aboutToAppear(): void {
    this.reload();
    this.unsubscribe = getChatStore().subscribeChanges((): void => { this.reload(); });
  }

  aboutToDisappear(): void {
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
  }

  private reload(): void {
    if (this.chatId === 0) {
      this.title = '';
      this.avatarPath = '';
      this.initials = '';
      this.kind = '';
      this.muted = false;
      return;
    }
    const c: ChatEntry | undefined = getChatStore().entryOf(this.chatId);
    if (c !== undefined) {
      this.title = c.title;
      this.avatarPath = c.avatarPath;
      this.initials = c.initials !== '' ? c.initials : c.title.charAt(0);
      this.kind = this.kindName(c.kind);
      this.muted = c.isMuted;
      this.rawKind = c.kind;
      this.memberCount = getChatStore().supergroupMemberCount(this.chatId);
    }
  }

  private kindName(kind: string): string {
    if (kind === 'private') { return '私聊'; }
    if (kind === 'secret') { return '私聊'; }
    if (kind === 'basicGroup') { return '群组'; }
    if (kind === 'supergroup') { return '群组'; }
    if (kind === 'channel') { return '频道'; }
    return '会话';
  }

  private paletteColor(): ResourceColor {
    const idx: number = Math.abs(this.chatId) % AVATAR_PALETTE.length;
    return AVATAR_PALETTE[idx];
  }

  @Builder
  private identity(): void {
    Column({ space: 8 }) {
      Stack() {
        Text(this.initials)
          .width(72).height(72).borderRadius(36)
          .backgroundColor(this.paletteColor())
          .fontColor(Color.White).fontSize(28).textAlign(TextAlign.Center);
        if (this.avatarPath !== '') {
          Image(this.avatarPath).width(72).height(72).borderRadius(36).objectFit(ImageFit.Cover);
        }
      }.width(72).height(72);
      Text(this.title === '' ? '当前会话' : this.title)
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(COLOR_TEXT_PRIMARY)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center);
      Text(this.kind)
        .fontSize(12).fontColor(COLOR_TEXT_SECONDARY);
    }
    .width('100%').padding({ top: 18, bottom: 14 });
  }

  @Builder
  private actionRow(label: string, value: string, onTap: () => void): void {
    Row() {
      Text(label).fontSize(14).fontColor(COLOR_TEXT_PRIMARY).layoutWeight(1);
      Text(value).fontSize(13).fontColor(COLOR_TEXT_SECONDARY);
    }
    .width('100%')
    .height(48)
    .padding({ left: 14, right: 14 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
    .onClick(onTap);
  }

  build(): void {
    Column() {
      Text('资料')
        .fontSize(16).fontWeight(FontWeight.Medium).fontColor(COLOR_TEXT_PRIMARY)
        .width('100%')
        .padding({ left: 14, top: Math.max(this.topSafe, 26) + 10, bottom: 6 });
      if (this.chatId === 0) {
        Column({ space: 8 }) {
          Text('选择一个会话').fontSize(14).fontColor(COLOR_TEXT_SECONDARY);
          Text('这里会显示当前会话的资料摘要').fontSize(12).fontColor(COLOR_TEXT_SECONDARY);
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
      } else {
        this.identity();
        Column({ space: 8 }) {
          this.actionRow('通知', this.muted ? '已静音' : '开启', (): void => {
            setMute(this.chatId, this.muted ? 0 : 2147483647);
          });
          if (this.memberCount > 0) {
            this.actionRow('成员', `${this.memberCount} ›`, (): void => {
              navigateToChatProfile({ 'chatId': this.chatId, 'tab': PROFILE_TAB_MEMBERS });
            });
          }
          this.actionRow('共享媒体', '打开 ›', (): void => {
            navigateToChatProfile({ 'chatId': this.chatId, 'tab': PROFILE_TAB_MEDIA });
          });
          if (this.rawKind === 'basicGroup' || this.rawKind === 'supergroup' || this.rawKind === 'channel') {
            this.actionRow('管理', '打开 ›', (): void => {
              router.pushUrl({ url: 'pages/main/GroupAdminPage', params: { 'chatId': this.chatId } })
                .catch((e: Error): void => { console.error(`GroupAdminPage push failed: ${e.message}`); });
            });
          }
          this.actionRow('完整资料', '打开 ›', (): void => {
            navigateToChatProfile({ 'chatId': this.chatId });
          });
        }
        .width('100%')
        .padding({ left: 10, right: 10 });
        Blank();
        Text('共享媒体、成员与管理入口在完整资料页')
          .fontSize(11).fontColor(COLOR_TEXT_SECONDARY)
          .width('100%').padding({ left: 16, right: 16, bottom: 16 });
      }
    }
    .width(this.widthVp)
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .border({ width: { left: 0.5 }, color: $r('app.color.divider') });
  }
}
