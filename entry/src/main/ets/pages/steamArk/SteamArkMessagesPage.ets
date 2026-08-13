import { HdsNavDestination } from '@kit.UIDesignKit';
import { webview } from '@kit.ArkWeb';
import {
  NGFControlStyleTokens,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import { SteamCredentialSet, SteamSessionState } from 'steam_core';
import {
  SteamArkLog,
  SteamArkMessageCacheReadResult,
  SteamArkMessageCacheStore,
  SteamArkMessageCategory,
  SteamArkMessageItem,
  SteamArkMessageSyncResult,
  SteamArkAccountSyncSnapshot,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  SteamArkSyncSnapshot,
  SteamArkSyncSnapshotListener,
  SteamArkSyncStage,
  steamArkSyncCoordinator,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { steamArkTabScrollers } from './SteamArkTabScrollers';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import { SteamArkBrowserRequest, SteamArkMessageNavigationRequest, SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';

const MESSAGE_CACHE_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
const MAX_CACHED_MESSAGE_COUNT: number = 500;
const MESSAGE_SILENT_REFRESH_INTERVAL_MS: number = 5 * 60 * 1000;

class SteamMessageTab {
  static readonly ALL: number = 0;
  static readonly PROMOTION: number = 1;
  static readonly SYSTEM: number = 2;
  static readonly FRIEND: number = 3;
  static readonly TRADE: number = 4;
}

@Component
export struct SteamArkMessagesPage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @Prop notificationRequest: SteamArkMessageNavigationRequest | null = null;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private stateReady: boolean = false;
  @State private selectedAccountId: string = '';
  @State private selectedAccountName: string = '';
  @State private sessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  @State private selectedTab: number = SteamMessageTab.ALL;
  @State private messages: Array<SteamArkMessageItem> = [];
  @State private syncing: boolean = false;
  @State private coordinatorSyncing: boolean = false;
  @State private synced: boolean = false;
  @State private syncFailed: boolean = false;
  @State private actionItemId: string = '';
  @State private friendRequestSheetVisible: boolean = false;
  @State private friendRequestLoading: boolean = false;
  @State private friendRequestFailed: boolean = false;
  @State private focusedMessageId: string = '';
  @State private statusMessage: ResourceStr = $r('app.string.steam_messages_status_idle');
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly scroller: Scroller = steamArkTabScrollers.messages;
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private accountScopeGeneration: number = 0;
  private loadedAccountId: string = '';
  private lastRemoteSyncAtEpochSeconds: number = 0;
  private coordinatorMessagesUpdatedAtEpochSeconds: number = 0;
  private refreshTimer: number = -1;
  private friendRequestAccountId: string = '';
  private friendRequestLifecycleGeneration: number = 0;
  private friendRequestScopeGeneration: number = 0;
  private notificationRequestApplied: boolean = false;
  private readonly friendRequestController: webview.WebviewController = new webview.WebviewController();
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (this.isPageActive) {
      this.applyStateSnapshot(snapshot);
    }
  };
  private readonly syncListener: SteamArkSyncSnapshotListener = (snapshot: SteamArkSyncSnapshot): void => {
    if (this.isPageActive) {
      this.applySyncSnapshot(snapshot);
    }
  };

  aboutToAppear(): void {
    this.isPageActive = true;
    this.lifecycleGeneration += 1;
    const generation: number = this.lifecycleGeneration;
    if (this.embedded) {
      this.topInsetVp = this.contentTopInsetVp;
    } else {
      SteamArkPageWindowSupport.loadDynamicTopInset(
        this.getUIContext(),
        108,
        SteamArkTheme.CONTENT_TOP_INSET,
        (inset: number): void => {
          if (this.isPageActive && this.lifecycleGeneration === generation) {
            this.topInsetVp = inset;
          }
        }
      );
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.HOME);
    }
    steamArkStateService.subscribe('SteamArkMessagesPage', this.stateListener);
    steamArkSyncCoordinator.subscribe('SteamArkMessagesPage', this.syncListener);
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    this.applyNotificationNavigationRequest();
    this.applySyncSnapshot(steamArkSyncCoordinator.getSnapshot());
    this.startSilentRefreshTimer();
    void this.initialize();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.lifecycleGeneration += 1;
    steamArkStateService.unsubscribe('SteamArkMessagesPage');
    steamArkSyncCoordinator.unsubscribe('SteamArkMessagesPage');
    this.stopSilentRefreshTimer();
    if (!this.embedded) {
      SteamArkPageWindowSupport.restoreHome();
    }
  }

  build() {
    if (this.embedded) {
      this.buildBody();
    } else {
      HdsNavDestination() {
        this.buildBody();
      }
      .titleBar(NGFHdsTitleBarOptionsFactory.buildOverContentWithTitleColors(
        $r('app.string.steam_messages_title'),
        $r('app.string.steam_messages_subtitle'),
        $r('app.color.background_transparent'),
        SteamArkTheme.textPrimary(this.isDarkMode),
        SteamArkTheme.textSecondary(this.isDarkMode),
        true,
        false
      ))
      .backgroundImage(this.profileBackgroundUrl)
      .backgroundImageSize(ImageSize.Cover)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .bindToScrollable([this.scroller])
      .onReady((context: NavDestinationContext): void => {
        this.pathStack = context.pathStack;
      });
    }
  }

  @Builder
  private buildBody(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.embedded) {
        SteamArkProfileBackground()
      }
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (!this.stateReady) {
            SteamArkStateUnavailableCard({ isDarkMode: this.isDarkMode, useSysMat: this.useSysMat })
          } else {
            this.buildHeaderCard();
            this.buildCategoryTabs();
            if (this.visibleMessages().length > 0) {
              ForEach(this.visibleMessages(), (item: SteamArkMessageItem) => {
                this.buildMessageCard(item);
              }, (item: SteamArkMessageItem): string => item.id)
            } else {
              this.buildEmptyCard();
            }
            this.buildBoundaryCard();
          }
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: this.embedded ? this.contentTopInsetVp : this.topInsetVp,
          bottom: this.embedded ? 84 : 92
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .backgroundColor($r('app.color.background_transparent'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.embedded
      ? $r('app.color.background_transparent') : SteamArkTheme.background(this.isDarkMode))
    .opacity(this.stateReady && !this.isRefreshVisible() ? 1 : 0.9)
    .animation({ duration: SteamArkExperiencePolicy.CONTENT_REFRESH_DURATION, curve: Curve.EaseOut })
    .bindSheet($$this.friendRequestSheetVisible, this.buildFriendRequestSheet(), {
      height: SheetSize.LARGE,
      showClose: true,
      preferType: SheetType.BOTTOM
    })
  }

  @Builder
  private buildFriendRequestSheet(): void {
    Column({ space: 10 }) {
      Text($r('app.string.steam_friend_requests_sheet_title'))
        .width('100%')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_friend_requests_sheet_desc'))
        .width('100%')
        .fontSize(13)
        .lineHeight(19)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Stack({ alignContent: Alignment.Center }) {
        Web({
          src: 'https://steamcommunity.com/my/friends/pending',
          controller: this.friendRequestController
        })
          .width('100%')
          .height('100%')
          .backgroundColor(SteamArkTheme.background(this.isDarkMode))
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .onPageBegin((): void => {
            if (this.isFriendRequestScopeCurrent()) {
              this.friendRequestLoading = true;
              this.friendRequestFailed = false;
            }
          })
          .onPageEnd((): void => {
            if (this.isFriendRequestScopeCurrent()) {
              this.friendRequestLoading = false;
            }
          })
          .onErrorReceive((event: OnErrorReceiveEvent): void => {
            if (event.request.isMainFrame() && this.isFriendRequestScopeCurrent()) {
              this.friendRequestLoading = false;
              this.friendRequestFailed = true;
            }
          })
        if (this.friendRequestLoading) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(34)
              .height(34)
              .color(SteamArkTheme.accent(this.isDarkMode))
            Text($r('app.string.steam_friend_requests_sheet_loading'))
              .fontSize(14)
              .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          }
          .padding(18)
          .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
            SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
          .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
          .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
          .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
        }
        if (this.friendRequestFailed) {
          Text($r('app.string.steam_friend_requests_sheet_failed'))
            .fontSize(14)
            .lineHeight(20)
            .fontColor(SteamArkTheme.error(this.isDarkMode))
            .textAlign(TextAlign.Center)
            .padding(18)
            .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
              SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
            .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
            .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
        }
      }
      .layoutWeight(1)
      .width('100%')
      .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
      .clip(true)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    .backgroundColor(SteamArkTheme.background(this.isDarkMode))
  }

  @Builder
  private buildHeaderCard(): void {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.bell'))
          .fontSize(22)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        Column({ space: 3 }) {
          Text($r('app.string.steam_messages_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text(this.selectedAccountName.length > 0
            ? this.selectedAccountName
            : $r('app.string.steam_messages_account_empty'))
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(16)
            .fontColor([SteamArkTheme.onAccent(this.isDarkMode)])
          Text($r('app.string.steam_messages_refresh'))
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
        }
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
      .enabled(this.canSync() && !this.isRefreshVisible())
      .onClick((): void => {
        void this.refresh(false);
      })
      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(16)
            .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
          Text($r('app.string.steam_messages_mark_all_read'))
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        }
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .backgroundColor(SteamArkTheme.surface(this.isDarkMode))
      .enabled(this.canSync() && this.hasUnreadNotifications() && this.actionItemId.length <= 0)
      .onClick((): void => {
        void this.markAllRead();
      })
      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.person_2'))
            .fontSize(16)
            .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
          Text($r('app.string.steam_social_title'))
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        }
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .backgroundColor(SteamArkTheme.surface(this.isDarkMode))
      .onClick((): void => {
        SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.SOCIAL, null);
      })
      Text(this.statusMessage)
        .width('100%')
        .fontSize(11)
        .fontColor(this.syncFailed
          ? SteamArkTheme.error(this.isDarkMode)
          : SteamArkTheme.textMuted(this.isDarkMode))
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildCategoryTabs(): void {
    Scroll() {
      Row({ space: 4 }) {
        this.buildTabTitle($r('app.string.steam_messages_tab_all'), SteamMessageTab.ALL)
        this.buildTabTitle($r('app.string.steam_messages_tab_promotions'), SteamMessageTab.PROMOTION)
        this.buildTabTitle($r('app.string.steam_messages_tab_system'), SteamMessageTab.SYSTEM)
        this.buildTabTitle($r('app.string.steam_messages_tab_friends'), SteamMessageTab.FRIEND)
        this.buildTabTitle($r('app.string.steam_messages_tab_trades'), SteamMessageTab.TRADE)
      }
      .height(42)
    }
    .width('100%')
    .height(42)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private buildTabTitle(title: ResourceStr, tab: number): void {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(12)
        .fontWeight(this.selectedTab === tab ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selectedTab === tab
          ? SteamArkTheme.accent(this.isDarkMode)
          : SteamArkTheme.textSecondary(this.isDarkMode))
      Column() {}
        .width(this.selectedTab === tab ? 28 : 8)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.selectedTab === tab
          ? SteamArkTheme.accent(this.isDarkMode)
          : $r('app.color.background_transparent'))
        .animation({ duration: 220, curve: Curve.EaseOut })
    }
    .height(40)
    .padding({ left: 12, right: 12, top: 7, bottom: 3 })
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.selectedTab = tab;
      });
    })
  }

  @Builder
  private buildMessageCard(item: SteamArkMessageItem): void {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        if (item.imageUrl.length > 0) {
          Image(item.imageUrl)
            .width(72)
            .height(48)
            .borderRadius(4)
            .objectFit(ImageFit.Cover)
        } else {
          SymbolGlyph(this.categoryIcon(item.category))
            .fontSize(21)
            .fontColor([this.categoryColor(item.category)])
        }
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(item.title)
              .layoutWeight(1)
              .fontSize(14)
              .fontWeight(item.unread ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
              .maxLines(2)
            Text(this.categoryLabel(item.category))
              .fontSize(10)
              .fontColor(this.categoryColor(item.category))
          }
          .width('100%')
          Text(item.body)
            .width('100%')
            .fontSize(12)
            .lineHeight(17)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.source)
            .fontSize(10)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(17)
          .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
      }
      .width('100%')
      .onClick((): void => {
        void this.openMessage(item);
      })
      if (item.remoteId.length > 0 || item.tradeOfferId.length > 0) {
        Row({ space: 8 }) {
          if (item.remoteId.length > 0) {
            Button($r('app.string.steam_messages_hide'))
              .layoutWeight(1)
              .height(34)
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(this.actionItemId.length <= 0)
              .onClick((): void => {
                void this.hideMessage(item);
              })
          }
          if (item.tradeOfferId.length > 0) {
            Button($r('app.string.steam_trade_open_in_browser'))
              .layoutWeight(1)
              .height(34)
              .enabled(this.actionItemId.length <= 0)
              .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
              .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
              .onClick((): void => {
                this.confirmTradeAction(item);
              })
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: this.isFocusedMessage(item) ? 2 : 0,
      color: this.isFocusedMessage(item)
        ? SteamArkTheme.accent(this.isDarkMode)
        : $r('app.color.background_transparent')
    })
    .animation({ duration: SteamArkExperiencePolicy.CONTENT_ENTER_DURATION, curve: Curve.EaseOut })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildEmptyCard(): void {
    Column({ space: 8 }) {
      if (this.isRefreshVisible()) {
        LoadingProgress()
          .width(30)
          .height(30)
          .color(SteamArkTheme.accent(this.isDarkMode))
      } else {
        SymbolGlyph($r('sys.symbol.message'))
          .fontSize(28)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      }
      Text(this.isRefreshVisible()
        ? $r('app.string.steam_messages_loading')
        : (this.synced ? $r('app.string.steam_messages_empty') : $r('app.string.steam_messages_not_loaded')))
        .fontSize(14)
        .lineHeight(20)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(24)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildBoundaryCard(): void {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(18)
        .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
      Text($r('app.string.steam_messages_boundary'))
        .layoutWeight(1)
        .fontSize(13)
        .lineHeight(19)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
    }
    .width('100%')
    .padding(14)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  private async initialize(): Promise<void> {
    const generation: number = this.lifecycleGeneration;
    try {
      await steamArkStateService.initialize();
      if (this.isPageActive && this.lifecycleGeneration === generation) {
        this.applyStateSnapshot(steamArkStateService.getSnapshot());
      }
    } catch (error) {
      SteamArkLog.warn('MessagesPage', 'state initialization failed; errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private startSilentRefreshTimer(): void {
    this.stopSilentRefreshTimer();
    this.refreshTimer = setInterval((): void => {
      if (this.isPageActive && this.canSync() && !this.isRefreshVisible()) {
        this.requestCoordinatorRefresh('messages_page_timer');
      }
    }, MESSAGE_SILENT_REFRESH_INTERVAL_MS);
  }

  private stopSilentRefreshTimer(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    this.stateReady = snapshot.initialized;
    const previousId: string = this.selectedAccountId;
    const selected = steamArkStateService.getSelectedAccount();
    const nextAccountId: string = selected === null ? '' : selected.profile.accountId;
    const accountChanged: boolean = previousId !== nextAccountId;
    if (accountChanged) {
      this.accountScopeGeneration += 1;
      this.clearAccountScopedState();
    }
    this.selectedAccountId = nextAccountId;
    if (selected === null) {
      this.selectedAccountName = '';
      this.sessionState = SteamSessionState.DISCONNECTED;
    } else {
      this.selectedAccountName = selected.profile.displayName.length > 0
        ? selected.profile.displayName
        : selected.profile.accountId;
      this.sessionState = selected.session.state;
    }
    if (this.canSync() && (accountChanged || this.loadedAccountId !== this.selectedAccountId) &&
      !this.isRefreshVisible()) {
      this.restoreCache(this.selectedAccountId);
      this.loadedAccountId = this.selectedAccountId;
      this.requestCoordinatorRefresh('messages_page_restore');
    }
    this.applyNotificationNavigationRequest();
    this.applySyncSnapshot(steamArkSyncCoordinator.getSnapshot());
  }

  private async refresh(silent: boolean): Promise<void> {
    if (!this.canSync() || this.isRefreshVisible()) {
      this.statusMessage = $r('app.string.steam_messages_status_login_required');
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    const accountId: string = this.selectedAccountId;
    this.syncing = true;
    this.syncFailed = false;
    if (!silent) {
      this.statusMessage = $r('app.string.steam_messages_status_loading');
    }
    try {
      const result: SteamArkMessageSyncResult = await steamArkStateService.syncMessages(accountId);
      if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        return;
      }
      if (!this.hasValidSyncTimestamp(result.syncedAtEpochSeconds)) {
        this.syncFailed = true;
        this.statusMessage = $r('app.string.steam_messages_status_failed');
        SteamArkLog.warn('MessagesPage', 'message refresh ignored because the result has no valid sync timestamp; account=' +
          SteamArkLog.accountId(accountId));
        return;
      }
      this.messages = this.mergeMessages(this.messages, result.items);
      this.applyFocusedMessage();
      this.synced = true;
      this.loadedAccountId = accountId;
      this.lastRemoteSyncAtEpochSeconds = result.syncedAtEpochSeconds;
      this.saveCache(accountId, result);
      this.syncFailed = false;
      this.statusMessage = result.sourceWarning.length > 0
        ? $r('app.string.steam_messages_status_partial')
        : $r('app.string.steam_messages_status_success');
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.syncFailed = true;
        this.statusMessage = error instanceof Error && error.message.length > 0
          ? error.message
          : $r('app.string.steam_messages_status_failed');
      }
      SteamArkLog.warn('MessagesPage', 'message refresh failed; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.syncing = false;
      }
    }
  }

  private async openMessage(item: SteamArkMessageItem): Promise<void> {
    const accountId: string = this.selectedAccountId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
      return;
    }
    if (item.unread && item.remoteId.length > 0 && this.actionItemId.length <= 0) {
      this.actionItemId = item.id;
      try {
        await steamArkStateService.markMessageRead(accountId, item);
        if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
          this.replaceMessageReadState(item.id, false);
          this.saveCurrentCache();
        }
      } catch (error) {
        SteamArkLog.warn('MessagesPage', 'mark read failed; errorType=' + SteamArkLog.errorKind(error));
      } finally {
        if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
          this.actionItemId = '';
        }
      }
    }
    if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
      return;
    }
    if (item.category === SteamArkMessageCategory.FRIEND) {
      this.showFriendRequestDetails(accountId, lifecycleGeneration, accountScopeGeneration);
      return;
    }
    this.openExternalUrl(item.url);
  }

  private showFriendRequestDetails(accountId: string, lifecycleGeneration: number,
    accountScopeGeneration: number): void {
    void this.openFriendRequestSheet(accountId, lifecycleGeneration, accountScopeGeneration);
  }

  private async openFriendRequestSheet(accountId: string, lifecycleGeneration: number,
    accountScopeGeneration: number): Promise<void> {
    if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
      return;
    }
    const selected = steamArkStateService.getSelectedAccount();
    if (selected !== null && selected.profile.accountId === accountId && selected.profile.steamId64.length > 0) {
      try {
        const credentials: SteamCredentialSet = await steamArkStateService.getCredentials(accountId);
        if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
          return;
        }
        if (credentials.accessToken.length > 0) {
          const cookieValue: string = selected.profile.steamId64 + '%7C%7C' + credentials.accessToken;
          webview.WebCookieManager.configCookieSync(
            'https://steamcommunity.com/',
            'steamLoginSecure=' + cookieValue + '; Path=/; Secure; HttpOnly; SameSite=None',
            false,
            true
          );
        }
      } catch (error) {
        SteamArkLog.warn('MessagesPage', 'friend request Web session setup failed; errorType=' +
          SteamArkLog.errorKind(error));
      }
    }
    if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
      return;
    }
    this.friendRequestAccountId = accountId;
    this.friendRequestLifecycleGeneration = lifecycleGeneration;
    this.friendRequestScopeGeneration = accountScopeGeneration;
    this.friendRequestLoading = true;
    this.friendRequestFailed = false;
    this.friendRequestSheetVisible = true;
  }

  private async markAllRead(): Promise<void> {
    if (!this.canSync() || this.actionItemId.length > 0) {
      return;
    }
    const accountId: string = this.selectedAccountId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
      return;
    }
    this.actionItemId = 'mark-all';
    try {
      await steamArkStateService.markAllMessagesRead(accountId);
      if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        return;
      }
      const values: Array<SteamArkMessageItem> = [];
      for (let index: number = 0; index < this.messages.length; index++) {
        values.push(this.copyMessage(this.messages[index], false));
      }
      this.messages = values;
      this.statusMessage = $r('app.string.steam_messages_action_success');
      this.saveCurrentCache();
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.statusMessage = error instanceof Error ? error.message :
          $r('app.string.steam_messages_action_failed');
      }
    } finally {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.actionItemId = '';
      }
    }
  }

  private async hideMessage(item: SteamArkMessageItem): Promise<void> {
    if (this.actionItemId.length > 0) {
      return;
    }
    const accountId: string = this.selectedAccountId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
      return;
    }
    this.actionItemId = item.id;
    try {
      await steamArkStateService.hideMessage(accountId, item);
      if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        return;
      }
      const values: Array<SteamArkMessageItem> = [];
      for (let index: number = 0; index < this.messages.length; index++) {
        if (this.messages[index].id !== item.id) {
          values.push(this.messages[index]);
        }
      }
      this.messages = values;
      this.statusMessage = $r('app.string.steam_messages_action_success');
      this.saveCurrentCache();
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.statusMessage = error instanceof Error ? error.message :
          $r('app.string.steam_messages_action_failed');
      }
    } finally {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.actionItemId = '';
      }
    }
  }

  private confirmTradeAction(item: SteamArkMessageItem): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.steam_trade_browser_handoff_title'),
      message: $r('app.string.steam_trade_browser_handoff_message'),
      primaryButton: {
        value: $r('app.string.steam_trade_open_in_browser'),
        action: (): void => {
          void this.performTradeAction(item);
        }
      },
      secondaryButton: {
        value: $r('app.string.steam_accounts_cancel'),
        action: (): void => {}
      }
    });
  }

  private async performTradeAction(item: SteamArkMessageItem): Promise<void> {
    const accountId: string = this.selectedAccountId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
      return;
    }
    this.openExternalUrl(this.tradeOfferUrl(item));
  }

  private tradeOfferUrl(item: SteamArkMessageItem): string {
    const itemUrl: string = item.url.trim();
    if (itemUrl.length > 0) {
      return itemUrl;
    }
    const offerId: string = item.tradeOfferId.trim();
    return offerId.length > 0
      ? 'https://steamcommunity.com/tradeoffer/' + offerId + '/'
      : 'https://steamcommunity.com/my/tradeoffers/';
  }

  private replaceMessageReadState(itemId: string, unread: boolean): void {
    const values: Array<SteamArkMessageItem> = [];
    for (let index: number = 0; index < this.messages.length; index++) {
      const item: SteamArkMessageItem = this.messages[index];
      values.push(item.id === itemId ? this.copyMessage(item, unread) : item);
    }
    this.messages = values;
  }

  private copyMessage(item: SteamArkMessageItem, unread: boolean): SteamArkMessageItem {
    return new SteamArkMessageItem(item.id, item.category, item.title, item.body, item.url,
      item.source, item.createdAtEpochSeconds, unread, item.imageUrl, item.remoteId,
      item.notificationType, item.tradeOfferId, item.tradeOfferSent);
  }

  private hasUnreadNotifications(): boolean {
    for (let index: number = 0; index < this.messages.length; index++) {
      if (this.messages[index].unread && this.messages[index].remoteId.length > 0) {
        return true;
      }
    }
    return false;
  }

  private saveCurrentCache(): void {
    if (this.selectedAccountId.length <= 0) {
      return;
    }
    const accountId: string = this.selectedAccountId;
    const remoteSyncAtEpochSeconds: number = this.lastRemoteSyncAtEpochSeconds;
    if (!this.hasValidSyncTimestamp(remoteSyncAtEpochSeconds)) {
      return;
    }
    this.saveCache(
      accountId,
      new SteamArkMessageSyncResult(this.messages, remoteSyncAtEpochSeconds)
    );
  }

  private mergeMessages(cached: Array<SteamArkMessageItem>, remote: Array<SteamArkMessageItem>):
    Array<SteamArkMessageItem> {
    const byId: Map<string, SteamArkMessageItem> = new Map<string, SteamArkMessageItem>();
    for (let index: number = 0; index < cached.length; index++) {
      byId.set(cached[index].id, cached[index]);
    }
    for (let index: number = 0; index < remote.length; index++) {
      byId.set(remote[index].id, remote[index]);
    }
    const values: Array<SteamArkMessageItem> = [];
    byId.forEach((item: SteamArkMessageItem): void => {
      values.push(item);
    });
    values.sort((left: SteamArkMessageItem, right: SteamArkMessageItem): number =>
      right.createdAtEpochSeconds - left.createdAtEpochSeconds);
    return values.length > MAX_CACHED_MESSAGE_COUNT
      ? values.slice(0, MAX_CACHED_MESSAGE_COUNT)
      : values;
  }

  private visibleMessages(): Array<SteamArkMessageItem> {
    if (this.selectedTab === SteamMessageTab.ALL) {
      return this.messages;
    }
    const result: Array<SteamArkMessageItem> = [];
    for (let index: number = 0; index < this.messages.length; index++) {
      const item: SteamArkMessageItem = this.messages[index];
      if ((this.selectedTab === SteamMessageTab.PROMOTION && item.category === SteamArkMessageCategory.PROMOTION) ||
        (this.selectedTab === SteamMessageTab.SYSTEM &&
          (item.category === SteamArkMessageCategory.SYSTEM || item.category === SteamArkMessageCategory.INVENTORY)) ||
        (this.selectedTab === SteamMessageTab.FRIEND && item.category === SteamArkMessageCategory.FRIEND) ||
        (this.selectedTab === SteamMessageTab.TRADE && item.category === SteamArkMessageCategory.TRADE)) {
        result.push(item);
      }
    }
    return result;
  }

  private canSync(): boolean {
    return this.selectedAccountId.length > 0 && this.sessionState === SteamSessionState.LOGGED_ON;
  }

  private isCurrent(lifecycleGeneration: number, accountId: string, accountScopeGeneration: number): boolean {
    return this.isPageActive && this.lifecycleGeneration === lifecycleGeneration &&
      this.accountScopeGeneration === accountScopeGeneration && this.selectedAccountId === accountId;
  }

  private isFriendRequestScopeCurrent(): boolean {
    return this.friendRequestSheetVisible && this.friendRequestAccountId.length > 0 &&
      this.isCurrent(this.friendRequestLifecycleGeneration, this.friendRequestAccountId,
        this.friendRequestScopeGeneration);
  }

  private clearAccountScopedState(): void {
    this.messages = [];
    this.syncing = false;
    this.coordinatorSyncing = false;
    this.synced = false;
    this.syncFailed = false;
    this.actionItemId = '';
    this.loadedAccountId = '';
    this.lastRemoteSyncAtEpochSeconds = 0;
    this.coordinatorMessagesUpdatedAtEpochSeconds = 0;
    this.friendRequestSheetVisible = false;
    this.friendRequestLoading = false;
    this.friendRequestFailed = false;
    this.friendRequestAccountId = '';
    this.friendRequestLifecycleGeneration = 0;
    this.friendRequestScopeGeneration = 0;
    this.focusedMessageId = '';
    this.statusMessage = $r('app.string.steam_messages_status_idle');
  }

  private applyNotificationNavigationRequest(): void {
    if (this.embedded || this.notificationRequestApplied) {
      return;
    }
    const request: SteamArkMessageNavigationRequest | null = this.notificationRequest;
    if (request === null || request.accountId.length <= 0 || request.messageId.length <= 0) {
      this.notificationRequestApplied = true;
      return;
    }
    if (this.selectedAccountId !== request.accountId) {
      return;
    }
    this.selectedTab = SteamMessageTab.ALL;
    this.focusedMessageId = request.messageId;
    this.notificationRequestApplied = true;
    this.applyFocusedMessage();
  }

  private applyFocusedMessage(): void {
    if (this.focusedMessageId.length <= 0) {
      return;
    }
    this.selectedTab = SteamMessageTab.ALL;
  }

  private isFocusedMessage(item: SteamArkMessageItem): boolean {
    return this.focusedMessageId.length > 0 && item.id === this.focusedMessageId;
  }

  private requestCoordinatorRefresh(reason: string): void {
    if (!this.canSync() || this.isRefreshVisible()) {
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    const accountId: string = this.selectedAccountId;
    void steamArkSyncCoordinator.requestAccountSync(accountId, reason).catch((error: Error): void => {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.coordinatorSyncing = false;
        this.syncFailed = true;
        this.statusMessage = $r('app.string.steam_messages_status_failed');
      }
      SteamArkLog.warn('MessagesPage', 'background message sync dispatch failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    });
  }

  private applySyncSnapshot(snapshot: SteamArkSyncSnapshot): void {
    if (!this.isPageActive || this.selectedAccountId.length <= 0) {
      return;
    }
    const accountSnapshot: SteamArkAccountSyncSnapshot | null =
      this.findAccountSyncSnapshot(snapshot, this.selectedAccountId);
    if (accountSnapshot === null) {
      this.coordinatorSyncing = false;
      return;
    }
    const messagesFailed: boolean = this.hasMessagesSyncFailure(accountSnapshot);
    this.coordinatorSyncing = accountSnapshot.running;
    if (accountSnapshot.running && !messagesFailed) {
      this.syncFailed = false;
    }
    const messagesUpdatedAtEpochSeconds: number = accountSnapshot.freshness.messagesUpdatedAtEpochSeconds;
    if (messagesUpdatedAtEpochSeconds > this.coordinatorMessagesUpdatedAtEpochSeconds) {
      this.coordinatorMessagesUpdatedAtEpochSeconds = messagesUpdatedAtEpochSeconds;
      this.restoreCache(this.selectedAccountId);
      this.loadedAccountId = this.selectedAccountId;
      this.syncFailed = false;
    }
    if (messagesFailed && !this.synced) {
      this.syncFailed = true;
      this.statusMessage = $r('app.string.steam_messages_status_failed');
      SteamArkLog.warn('MessagesPage', 'background message synchronization failed; account=' +
        SteamArkLog.accountId(this.selectedAccountId));
      return;
    }
    if (!this.synced && accountSnapshot.running) {
      this.statusMessage = $r('app.string.steam_messages_status_loading');
    }
  }

  private findAccountSyncSnapshot(
    snapshot: SteamArkSyncSnapshot,
    accountId: string
  ): SteamArkAccountSyncSnapshot | null {
    for (let index: number = 0; index < snapshot.accounts.length; index++) {
      const accountSnapshot: SteamArkAccountSyncSnapshot = snapshot.accounts[index];
      if (accountSnapshot.accountId === accountId) {
        return accountSnapshot;
      }
    }
    return null;
  }

  private hasMessagesSyncFailure(snapshot: SteamArkAccountSyncSnapshot): boolean {
    if (snapshot.failure.stage === SteamArkSyncStage.MESSAGES) {
      return true;
    }
    for (let index: number = 0; index < snapshot.stageFailures.length; index++) {
      if (snapshot.stageFailures[index].stage === SteamArkSyncStage.MESSAGES) {
        return true;
      }
    }
    return false;
  }

  private isRefreshVisible(): boolean {
    return this.syncing || this.coordinatorSyncing;
  }

  private categoryLabel(category: SteamArkMessageCategory): ResourceStr {
    if (category === SteamArkMessageCategory.PROMOTION) return $r('app.string.steam_messages_category_promotion');
    if (category === SteamArkMessageCategory.FRIEND) return $r('app.string.steam_messages_category_friend');
    if (category === SteamArkMessageCategory.TRADE) return $r('app.string.steam_messages_category_trade');
    if (category === SteamArkMessageCategory.INVENTORY) return $r('app.string.steam_messages_category_inventory');
    return $r('app.string.steam_messages_category_system');
  }

  private categoryIcon(category: SteamArkMessageCategory): Resource {
    if (category === SteamArkMessageCategory.PROMOTION) return $r('sys.symbol.gift');
    if (category === SteamArkMessageCategory.FRIEND) return $r('sys.symbol.person_2');
    if (category === SteamArkMessageCategory.TRADE) return $r('sys.symbol.arrow_left_arrow_right');
    if (category === SteamArkMessageCategory.INVENTORY) return $r('sys.symbol.archivebox');
    return $r('sys.symbol.bell');
  }

  private categoryColor(category: SteamArkMessageCategory): ResourceColor {
    if (category === SteamArkMessageCategory.PROMOTION) return SteamArkTheme.warning(this.isDarkMode);
    if (category === SteamArkMessageCategory.TRADE) return SteamArkTheme.success(this.isDarkMode);
    if (category === SteamArkMessageCategory.FRIEND) return SteamArkTheme.accentCyan(this.isDarkMode);
    return SteamArkTheme.accent(this.isDarkMode);
  }

  private saveCache(accountId: string, result: SteamArkMessageSyncResult): void {
    if (!this.hasValidSyncTimestamp(result.syncedAtEpochSeconds)) {
      SteamArkLog.warn('MessagesPage', 'message cache write skipped because the result has no valid sync timestamp; account=' +
        SteamArkLog.accountId(accountId));
      return;
    }
    const saved: boolean = SteamArkMessageCacheStore.writeSyncResult(
      accountId, result, MESSAGE_CACHE_TTL_MS
    );
    if (!saved) {
      SteamArkLog.debug('MessagesPage', 'stale message cache write ignored; account=' +
        SteamArkLog.accountId(accountId));
    }
  }

  private restoreCache(accountId: string): void {
    this.synced = false;
    const cached: SteamArkMessageCacheReadResult = SteamArkMessageCacheStore.readMessages(accountId);
    if (!cached.valid) {
      return;
    }
    this.messages = cached.items;
    this.applyFocusedMessage();
    this.synced = true;
    this.lastRemoteSyncAtEpochSeconds = cached.syncedAtEpochSeconds;
    this.statusMessage = $r('app.string.steam_messages_status_cached');
  }

  private hasValidSyncTimestamp(syncedAtEpochSeconds: number): boolean {
    return Number.isSafeInteger(syncedAtEpochSeconds) && syncedAtEpochSeconds > 0;
  }

  private openExternalUrl(url: string): void {
    const pushed: boolean = SteamArkNavigationBridge.pushHomeRoute(
      SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(url, 'Steam', 'steamcommunity.com')
    );
    if (!pushed) {
      this.statusMessage = $r('app.string.steam_external_open_failed');
    }
  }
}
