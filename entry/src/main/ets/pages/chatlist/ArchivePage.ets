import { collapseFloatingVideo } from '../../util/floatingVideoRuntime';
import { ChatListView } from './ChatListView';
import { CHAT_LIST_NOW } from './ChatListFreeze';
import { ChatEntry } from '../../store/ChatEntry';
import { getChatStore, getUnreadCountStore } from '../../tdkit/Globals';
import { COLOR_PRIMARY, COLOR_TEXT_PRIMARY, COLOR_TEXT_SECONDARY } from '../../util/theme';
import { plural, str } from '../../util/strings';
import { LANGUAGE_EPOCH } from '../../util/appLanguage';
import { allocChatDestToken, markChatDestHidden, markChatDestShown } from '../../util/chatDestTracker';
import { closeLeftPane } from '../../util/leftPaneState';
import { BLUR_MAX_VP, EDGE_OVERLAY_VP, edgeBlurStops } from '../../util/scrollEdgeBlur';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { logE } from '../../util/log';

// 路由表（router_map.json）的 buildFunction 指向这里。系统在跳转时动态加载
// 本模块并调用它，页面因此不再需要进 main_pages.json。
@Builder
export function ArchivePageBuilder(): void {
  ArchivePage();
}

@Preview
@Component
export struct ArchivePage {
  // 本页所在的 Navigation 栈，onReady 时拿到。返回按钮要靠它出栈——迁成
  // NavDestination 之后 router.back() 弹的是 router 页栈，而本页已经不是
  // router 页了，弹不到自己。
  private navStack: NavPathStack | undefined = undefined;
  private readonly chatDestToken: number = allocChatDestToken();

  // 多栏（平板/电脑）下的左栏钻取态：本页不再是一层 NavDestination，而是直接铺在
  // 会话列表栏里（04:205 / D-108）。两种壳共用同一份 pageBody，内容一个字不改，
  // 差别只有三处：不要 HDS 标题栏、返回等于关左栏钻取、列表要给悬浮胶囊留位置。
  @Prop paneMode: boolean = false;

  @StorageProp(LANGUAGE_EPOCH) langEpoch: number = 0;
  @StorageProp('topSafeHeight') topSafe: number = 0;
  // 本页在不在眼前。被会话页盖住时置 false，退回来置 true——归档列表的发布闸
  // 跟这个走而不是跟全局那道（理由见 ChatListView.obeyGlobalGate：全局那道由
  // 首页导航栏的显隐驱动，而归档页在时导航栏自始至终是盖着的，开不回来）。
  @State private pageVisible: boolean = true;
  // 页体实测高度：linearGradientBlur 的 fractionStops 要按实际高度归一化。
  @State private bodyH: number = 0;
  @State archivedCount: number = 0;
  @State unreadCount: number = 0;
  private clockTimer: number = -1;
  private unsubscribeChats: (() => void) | null = null;
  private unsubscribeUnread: (() => void) | null = null;

  @Styles
  backNormalStyle() {
    .backgroundColor(Color.Transparent)
  }

  @Styles
  backPressedStyle() {
    .backgroundColor($r('app.color.surface_alt'))
  }

  // 本页不读路由参数（归档列表没有入参），所以没有 ChatPage 那套
  // applyRouteParams()/paramsApplied 的拆分——aboutToAppear 原样保留。
  aboutToAppear(): void {
    this.unsubscribeChats = getChatStore().subscribe((chats: ChatEntry[]): void => {
      this.archivedCount = chats.length;
    }, 'archive');
    this.unsubscribeUnread = getUnreadCountStore().subscribe((): void => {
      this.unreadCount = getUnreadCountStore().getUnread('archive');
    });
    AppStorage.setOrCreate(CHAT_LIST_NOW, Math.floor(Date.now() / 1000));
    this.clockTimer = setInterval((): void => {
      AppStorage.setOrCreate(CHAT_LIST_NOW, Math.floor(Date.now() / 1000));
    }, 60000);
  }

  aboutToDisappear(): void {
    markChatDestHidden(this.chatDestToken, true);
    if (this.unsubscribeChats !== null) {
      this.unsubscribeChats();
      this.unsubscribeChats = null;
    }
    if (this.unsubscribeUnread !== null) {
      this.unsubscribeUnread();
      this.unsubscribeUnread = null;
    }
    if (this.clockTimer !== -1) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }

  // 返回上一层。**不能用 router.back()**：本页是 HdsNavDestination，router 页栈里
  // 只剩 Index 一层，router.back() 弹掉的是 Index——平板模拟器实测（Task 7 修复轮 1）
  // 的现象是「点返回箭头直接退到桌面」。要出的是 Navigation 栈。
  private goBack(): void {
    if (this.paneMode) {
      // 左栏钻取态没有栈层可出：返回 = 左栏回到会话列表，中栏聊天不动。
      closeLeftPane();
      return;
    }
    const stack = this.navStack;
    if (stack === undefined) {
      // navStack 由 onReady(ctx.pathStack) 填，而 onReady 必先于本页可见，所以
      // 这一支不该发生。这里**故意不回退到 router.back()**：那正是会退出应用的
      // 那条路，把返回键做成"什么都不做 + 一条日志"远比把应用关掉好。
      logE('ArchivePage.goBack: navStack missing, back ignored');
      return;
    }
    // pop() 弹的就是本页这一层。栈空时它返回 undefined，但那意味着"本页正显示
    // 却不在栈里"，不可能发生，故不另做处理。
    stack.pop();
  }

  private archiveSummary(): string {
    if (this.archivedCount === 0) { return str('ap_subtitle'); }
    if (this.unreadCount > 0) {
      return str('ap_chats_and_unread', this.archivedCount, this.unreadCount);
    }
    return plural('ap_chats_n', this.archivedCount, this.archivedCount);
  }

  // 标题条的上内缩：整页壳要让状态栏（页体自己 expandSafeArea 到系统区），
  // 左栏壳挂在 HdsNavigation 的 navBar 里，状态栏已经由外层让过一次，再加一遍
  // 就是凭空多出一条空白。
  private headerTopInset(): number {
    // 左栏壳也贴在窗口 y=0 上画（整棵树是全屏布局，安全区由各控件自己让），
    // 所以这里同样是 topSafe。早先按 0 处理过一版，真机上标题条直接压进状态栏
    // 和时钟叠在一起（2026-11-08 实测截图）。
    return this.topSafe;
  }

  // 标题条整条高度（含状态栏那一段）。列表要让出这么多才开始放第一条。
  private headerHeight(): number {
    return this.headerTopInset() + 62;
  }

  // 页体：自绘标题条（‹ 返回 + 「归档」+ 条数摘要）+ 归档列表。
  // 整页壳与左栏壳共用同一份，内容不因为壳不同而分叉。
  //
  // 标题条浮在列表上方而不是压在列表上头：列表从窗口最上沿开始铺，内容滚到标题
  // 底下时靠 linearGradientBlur 逐渐糊掉，标题本身始终清晰（联系人页 / 个人资料页
  // / 设置页都是这套，2026-11-08 用户要求归档页也改成一致）。
  @Builder
  pageBody() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 外面再套一层容器：linearGradientBlur 是**容器级**属性，挂在包裹列表的这层
      // 上才作用到整棵列表（含溢出到标题条底下的那一截）；挂在自定义组件上不生效
      //（ChatListView 内部同样的注释：挂在 List 上时几版截图一模一样）。
      Column() {
        ChatListView({
          listKey: 'archive',
          // 左栏壳下悬浮胶囊就压在这条栏的底部，列表要让位；整页壳下胶囊是藏着的。
          reserveDockSpace: this.paneMode,
          obeyGlobalGate: false,
          pageVisible: this.pageVisible,
          // 列表自己已经上顶 EDGE_OVERLAY_VP、内容起点按 EDGE_OVERLAY_VP + 本值
          // 计算，所以这里直接给标题条整条高度，首行就落在标题条下沿。
          contentTopInset: this.headerHeight()
        })
          .width('100%').height('100%');
      }
      .width('100%').height('100%')
      // 顶部/底部边缘渐变虚化：内容穿透到标题条底下，边缘自己变糊。
      .linearGradientBlur(BLUR_MAX_VP, {
        fractionStops: edgeBlurStops(this.bodyH),
        direction: GradientDirection.Bottom
      })
      .clip(false)
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        const h: number = Number(newArea.height);
        if (h > 0 && Math.abs(h - this.bodyH) > 0.5) {
          this.bodyH = h;
        }
      });
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(24).fontColor([COLOR_TEXT_PRIMARY]);
        }
        .width(44).height(44).borderRadius(22)
        .justifyContent(FlexAlign.Center)
        .stateStyles({
          normal: this.backNormalStyle,
          pressed: this.backPressedStyle
        })
        .onClick(() => { this.goBack(); });
        Column({ space: 1 }) {
          Text($r('app.string.ap_title'))
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT_PRIMARY);
          Text(this.archiveSummary())
            .fontSize(11).fontColor(this.unreadCount > 0 ? COLOR_PRIMARY : COLOR_TEXT_SECONDARY)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 4 });
      }
      .width('100%').height(this.headerHeight())
      .padding({ left: 6, right: 16, top: this.headerTopInset() })
      // 底色全透明：标题条底下透出来的是被虚化过的列表内容 / 壁纸。
      .backgroundColor(Color.Transparent)
      // 这一条只是标题，别把滚动接管走；返回按钮自己吃点击。
      .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.page_bg'))
    // 整页壳要把底色和标题条伸进系统区（状态栏底下那条），左栏壳不能伸。
    .expandSafeArea(this.paneMode ? [] : [SafeAreaType.SYSTEM],
      this.paneMode ? [] : [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
  }

  build() {
    if (this.paneMode) {
      // 左栏钻取态：铺满会话列表栏。这里**不再套 HdsNavDestination**——本页此时
      // 就长在一个 HdsNavigation 的 navBar 里，再套一层会和外壳抢返回键和标题栏。
      this.pageBody();
    } else {
      HdsNavDestination() {
        this.pageBody();
      }
      // 本页自绘标题栏（返回键 + 「归档」标题那一条），不要 HDS 的。
      .hideTitleBar(true)
      .onBackPressed((): boolean => collapseFloatingVideo())
      .onReady((ctx: NavDestinationContext): void => {
        this.navStack = ctx.pathStack;
      })
      // 盖住时停发、露出时补发。归档列表的未读角标就靠这一对回来
      //（2026-09-18：点进会话看完退回来，角标一直挂着）。
      .onWillShow((): void => { markChatDestShown(this.chatDestToken); })
      .onShown((): void => {
        markChatDestShown(this.chatDestToken);
        this.pageVisible = true;
      })
      .onHidden((): void => {
        markChatDestHidden(this.chatDestToken);
        this.pageVisible = false;
      })
      .width('100%').height('100%');
    }
  }
}
