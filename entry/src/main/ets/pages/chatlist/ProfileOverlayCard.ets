// 双栏资料浮层卡（P1-B4）。挂在 MainScreen 根 Stack 最上层，整窗 scrim + 居中卡。
// 三栏不使用本组件（右侧资料列），单栏不使用（整页）。
import { getChatStore, getTdClient } from '../../tdkit/Globals';
import { ProfileStore } from '../../store/ProfileStore';
import { setMute } from '../../store/ChatActions';
import { ChatEntry } from '../../store/ChatEntry';
import { navigateToChatProfile, navigateToProfile } from '../../util/profileNav';
import { beginOverlayBypass, endOverlayBypass } from '../../util/profileOverlay';
import { closeProfileOverlay, KEY_PROFILE_OVERLAY_OPEN, KEY_PROFILE_OVERLAY_TARGET, readProfileOverlayTarget } from '../../util/profileOverlay';
import { COLOR_SURFACE, COLOR_TEXT_PRIMARY, COLOR_TEXT_SECONDARY, COLOR_DIVIDER, COLOR_PRIMARY } from '../../util/theme';
import { str } from '../../util/strings';

const AVATAR_SIZE: number = 96;
const CARD_MAX_W: number = 560;
const CARD_MAX_H: number = 760;

@Component
export struct ProfileOverlayCard {
  @StorageProp(KEY_PROFILE_OVERLAY_OPEN) private overlayOpen: boolean = false;
  @StorageProp(KEY_PROFILE_OVERLAY_TARGET) @Watch('onTargetChanged') private targetJson: string = '';

  @State private kind: string = '';
  @State private targetId: number = 0;
  @State private title: string = '';
  @State private subtitle: string = '';
  @State private secondary: string = '';
  @State private bio: string = '';
  @State private initials: string = '?';
  @State private avatarPath: string = '';
  @State private muted: boolean = false;
  private store: ProfileStore | null = null;
  private unsub: (() => void) | null = null;

  aboutToAppear(): void {
    this.reload();
  }

  aboutToDisappear(): void {
    this.releaseStore();
  }

  private releaseStore(): void {
    if (this.unsub !== null) {
      this.unsub();
      this.unsub = null;
    }
    if (this.store !== null) {
      this.store.close();
      this.store = null;
    }
  }

  private onTargetChanged(): void {
    if (this.overlayOpen) {
      this.reload();
    }
  }

  private reload(): void {
    this.releaseStore();
    const target = readProfileOverlayTarget();
    if (target === null) {
      this.kind = '';
      this.targetId = 0;
      return;
    }
    this.kind = target.kind;
    this.targetId = target.id;
    if (target.kind === 'chat') {
      this.loadChat(target.id);
    } else {
      this.loadUser(target.id);
    }
  }

  private loadChat(chatId: number): void {
    const entry: ChatEntry | undefined = getChatStore().entryOf(chatId);
    if (entry !== undefined) {
      this.title = entry.title;
      this.initials = entry.initials !== '' ? entry.initials : '?';
      this.avatarPath = entry.avatarPath;
      this.muted = entry.isMuted;
      this.subtitle = this.kindLabel(entry.kind);
      const members: number = getChatStore().supergroupMemberCount(chatId);
      this.secondary = members > 0 ? `${members} 位成员` : '';
      this.bio = '';
    }
  }

  private kindLabel(kind: string): string {
    if (kind === 'channel') {
      return str('gn_channel');
    }
    if (kind === 'supergroup' || kind === 'basicGroup') {
      return str('gn_group');
    }
    if (kind === 'secret') {
      return str('cpp_secret_chat');
    }
    return str('cpp_user');
  }

  private loadUser(userId: number): void {
    const store = new ProfileStore(getTdClient(), userId);
    this.store = store;
    this.unsub = store.subscribe((): void => {
      this.title = store.name;
      this.initials = store.initials;
      this.avatarPath = store.avatarPath;
      this.subtitle = store.statusText;
      this.secondary = store.phone !== '' ? store.phone
        : (store.usernames.length > 0 ? '@' + store.usernames[0] : '');
      this.bio = store.bio;
    });
    store.open();
  }

  private openFull(): void {
    const kind: string = this.kind;
    const id: number = this.targetId;
    closeProfileOverlay();
    beginOverlayBypass();
    if (kind === 'chat') {
      navigateToChatProfile({ 'chatId': id } as Record<string, Object>);
    } else {
      navigateToProfile({ 'userId': id } as Record<string, Object>);
    }
    endOverlayBypass();
  }

  private toggleMute(): void {
    if (this.kind === 'chat' && this.targetId !== 0) {
      const nextMuted: boolean = !this.muted;
      this.muted = nextMuted;
      setMute(this.targetId, nextMuted ? 2147483647 : 0);
    }
  }

  @Builder
  private avatarView() {
    Stack() {
      Text(this.initials !== '' ? this.initials : '?')
        .fontSize(AVATAR_SIZE * 0.36)
        .fontColor(Color.White)
        .fontWeight(FontWeight.Medium)
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)
        .textAlign(TextAlign.Center)
        .borderRadius(AVATAR_SIZE / 2)
        .backgroundColor(COLOR_PRIMARY)
      if (this.avatarPath !== '') {
        Image(this.avatarPath)
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          .borderRadius(AVATAR_SIZE / 2)
          .objectFit(ImageFit.Cover)
      }
    }
    .width(AVATAR_SIZE)
    .height(AVATAR_SIZE)
  }

  @Builder
  private actionRow(icon: Resource, label: string, onTap: () => void) {
    Column({ space: 6 }) {
      SymbolGlyph(icon).fontSize(24).fontColor([COLOR_PRIMARY])
      Text(label).fontSize(12).fontColor(COLOR_PRIMARY)
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .borderRadius(14)
    .onClick(onTap)
  }

  @Builder
  private infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(14).fontColor(COLOR_TEXT_SECONDARY).layoutWeight(1)
      Text(value).fontSize(14).fontColor(COLOR_TEXT_PRIMARY).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Column() {
      Row() {
        Text(str('profile_tab_title'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT_PRIMARY)
          .layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([COLOR_TEXT_SECONDARY])
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          closeProfileOverlay();
        })
      }
      .width('100%')
      .padding({ left: 20, right: 12, top: 8, bottom: 0 })

      Column({ space: 6 }) {
        this.avatarView()
        Text(this.title !== '' ? this.title : '—')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle !== '') {
          Text(this.subtitle).fontSize(13).fontColor(COLOR_TEXT_SECONDARY).maxLines(1)
        }
        if (this.secondary !== '') {
          Text(this.secondary).fontSize(13).fontColor(COLOR_TEXT_SECONDARY).maxLines(1)
        }
      }
      .width('100%')
      .padding({ top: 14, bottom: 12 })

      Row() {
        this.actionRow($r('sys.symbol.message'), str('profile_action_message'), (): void => {
          this.openFull();
        })
        if (this.kind === 'chat') {
          this.actionRow($r('sys.symbol.bell'), this.muted ? str('cp_unmute') : str('cp_mute'), (): void => {
            this.toggleMute();
          })
        }
        this.actionRow($r('sys.symbol.person_fill'), str('profile_complete'), (): void => {
          this.openFull();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
      .backgroundColor(COLOR_SURFACE)
      .borderRadius(16)

      Column() {
        Divider().color(COLOR_DIVIDER).strokeWidth(0.5)
        if (this.bio !== '') {
          Text(this.bio)
            .fontSize(14)
            .fontColor(COLOR_TEXT_PRIMARY)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ top: 10, bottom: 10 })
          Divider().color(COLOR_DIVIDER).strokeWidth(0.5)
        }
        this.infoRow(str('profile_row_notifications'), this.muted ? str('cp_muted') : str('cp_notifications_on'))
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4 })
      .margin({ top: 12 })
      .backgroundColor(COLOR_SURFACE)
      .borderRadius(16)

    }
    .width('88%')
    .constraintSize({ maxWidth: CARD_MAX_W, maxHeight: CARD_MAX_H })
    .padding(20)
    .backgroundColor(COLOR_SURFACE)
    .borderRadius(28)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }
}
