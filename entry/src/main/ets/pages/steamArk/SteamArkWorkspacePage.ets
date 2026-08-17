import { HdsNavDestination } from '@kit.UIDesignKit';
import {
  NGFControlStyleTokens,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import {
  SteamCommandErrorCode,
  SteamCommandResult,
  SteamFarmSnapshot,
  SteamFarmState,
  SteamBadgeSyncReport,
  SteamGameDrop,
  SteamCommunityBadge,
  SteamInventoryItem,
  SteamInventoryPage,
  SteamAuthError,
  SteamSessionState
} from 'steam_core';
import {
  SteamArkFarmingEvent,
  SteamArkFarmingEventListener,
  SteamArkFarmingEventType,
  SteamArkLog,
  SteamArkAccountSyncSnapshot,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  SteamArkSyncSnapshot,
  SteamArkSyncSnapshotListener,
  SteamArkSyncStage,
  steamArkFarmingService,
  steamArkSyncCoordinator,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { steamArkTabScrollers } from './SteamArkTabScrollers';
import { SteamArkBadgeDetailPage } from './SteamArkBadgeDetailPage';
import { SteamArkPanelBackBridge } from './SteamArkPanelBackBridge';
import {
  SteamArkBadgeDetailRequest,
  SteamArkBadgeKind,
  SteamArkBrowserRequest,
  SteamArkRouteName
} from './SteamArkRoutes';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';

class SteamWorkspaceActionKey {
  static readonly ACCOUNT: number = 1;
  static readonly FARMING: number = 2;
  static readonly INVENTORY: number = 3;
  static readonly NETWORK: number = 4;
}

class SteamWorkspaceTab {
  static readonly CARDS_AND_BADGES: number = 0;
  static readonly FARMING: number = 1;
}

class SteamCardInventoryGroup {
  readonly appId: string;
  readonly gameName: string;
  readonly items: Array<SteamInventoryItem>;

  constructor(appId: string, gameName: string, items: Array<SteamInventoryItem>) {
    this.appId = appId;
    this.gameName = gameName;
    this.items = items.slice();
  }
}

const FARMING_GAMES_AUTO_REFRESH_INTERVAL_MS: number = 5 * 60 * 1000;
const BADGE_PANEL_TOP_BAR_HEIGHT: number = 44;
const BADGE_PANEL_TOP_BAR_TOP: number = SteamArkTheme.CONTENT_TOP_INSET - BADGE_PANEL_TOP_BAR_HEIGHT;

@Component
export struct SteamArkWorkspacePage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private actionMessage: ResourceStr = $r('app.string.steam_workspace_status_idle');
  @State private commandText: string = '';
  @State private commandBusy: boolean = false;
  @State private commandMessage: ResourceStr = $r('app.string.steam_workspace_command_idle');
  @State private commandDetail: string = '';
  @State private accountCount: number = 0;
  @State private selectedAccountId: string = '';
  @State private selectedAccountName: string = '';
  @State private sessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  @State private farmingState: SteamFarmState = SteamFarmState.IDLE;
  @State private farmingBusy: boolean = false;
  @State private farmingNow: boolean = false;
  @State private farmingGames: Array<SteamGameDrop> = [];
  @State private gameBadgeGames: Array<SteamGameDrop> = [];
  @State private communityBadges: Array<SteamCommunityBadge> = [];
  @State private farmingGamesRefreshing: boolean = false;
  @State private farmingGamesLoaded: boolean = false;
  @State private farmingGamesRefreshFailed: boolean = false;
  @State private workspaceTab: number = SteamWorkspaceTab.CARDS_AND_BADGES;
  @State private cardItems: Array<SteamInventoryItem> = [];
  @State private cardItemsRefreshing: boolean = false;
  @State private cardItemsLoaded: boolean = false;
  @State private cardItemsRefreshFailed: boolean = false;
  @State private badgeDetailVisible: boolean = false;
  @State private gridColumns: number = 2;
  @State private stateReady: boolean = false;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('steam_ark_profile_background_enabled') private backgroundEnabled: boolean = true;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly scroller: Scroller = steamArkTabScrollers.workspace;
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private accountScopeGeneration: number = 0;
  private farmingGamesRequestVersion: number = 0;
  private refreshingFarmingGamesForAccountId: string = '';
  private lastFarmingGamesRefreshAccountId: string = '';
  private lastFarmingGamesRefreshAtMs: number = 0;
  private coordinatorFarmingUpdatedAtEpochSeconds: number = 0;
  private badgeDetailRequest: SteamArkBadgeDetailRequest = new SteamArkBadgeDetailRequest();
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('WorkspacePage', 'state snapshot received; accounts=' + snapshot.accounts.length.toString());
    this.applyStateSnapshot(snapshot);
  };
  private readonly farmingListener: SteamArkFarmingEventListener = (event: SteamArkFarmingEvent): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('WorkspacePage', 'farming event received; type=' + String(event.type));
    this.applyFarmingEvent(event);
  };
  private readonly syncListener: SteamArkSyncSnapshotListener = (snapshot: SteamArkSyncSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    this.applySyncSnapshot(snapshot);
  };

  aboutToAppear(): void {
    SteamArkLog.lifecycle('WorkspacePage', 'aboutToAppear', 'embedded=' + String(this.embedded));
    this.lifecycleGeneration += 1;
    this.isPageActive = true;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.farmingBusy = false;
    this.commandBusy = false;
    this.gridColumns = this.resolveGridColumns();
    if (this.embedded) {
      this.topInsetVp = this.contentTopInsetVp;
      SteamArkPanelBackBridge.registerCloseHandler(
        SteamArkPanelBackBridge.BADGE_PANEL,
        SteamArkPanelBackBridge.TAB_FARMING,
        (): void => {
          this.closeBadgeDetail();
        });
    } else {
      SteamArkPageWindowSupport.loadDynamicTopInset(
        this.getUIContext(),
        108,
        SteamArkTheme.CONTENT_TOP_INSET,
        (inset: number): void => {
          if (this.isPageActive && this.lifecycleGeneration === lifecycleGeneration) {
            this.topInsetVp = inset;
          }
        }
      );
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.WORKSPACE);
    }
    steamArkStateService.subscribe('SteamArkWorkspacePage', this.stateListener);
    steamArkFarmingService.subscribe('SteamArkWorkspacePage', this.farmingListener);
    steamArkSyncCoordinator.subscribe('SteamArkWorkspacePage', this.syncListener);
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    this.applyFarmingSnapshot(steamArkFarmingService.getSnapshot(this.selectedAccountId));
    this.applySyncSnapshot(steamArkSyncCoordinator.getSnapshot());
    void this.initializeStateService();
    SteamArkLog.info('WorkspacePage', 'state, farming and sync subscriptions registered');
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle('WorkspacePage', 'aboutToDisappear', 'embedded=' + String(this.embedded));
    this.isPageActive = false;
    this.lifecycleGeneration += 1;
    this.farmingGamesRequestVersion += 1;
    this.refreshingFarmingGamesForAccountId = '';
    this.farmingGamesRefreshing = false;
    if (this.embedded) {
      SteamArkPanelBackBridge.unregisterCloseHandler(SteamArkPanelBackBridge.BADGE_PANEL);
      SteamArkPanelBackBridge.setVisible(SteamArkPanelBackBridge.BADGE_PANEL, false);
    }
    steamArkStateService.unsubscribe('SteamArkWorkspacePage');
    steamArkFarmingService.unsubscribe('SteamArkWorkspacePage');
    steamArkSyncCoordinator.unsubscribe('SteamArkWorkspacePage');
    if (!this.embedded) {
      SteamArkPageWindowSupport.restoreHome();
    }
  }

  build() {
    if (this.embedded) {
      this.buildPageBody();
    } else {
      HdsNavDestination() {
        this.buildPageBody();
      }
      .titleBar(NGFHdsTitleBarOptionsFactory.buildOverContentWithTitleColors(
        $r('app.string.steam_workspace_title'),
        $r('app.string.steam_workspace_subtitle'),
        $r('app.color.background_transparent'),
        SteamArkTheme.textPrimary(this.isDarkMode),
        SteamArkTheme.textSecondary(this.isDarkMode),
        true,
        false
      ))
      .backgroundImage(this.backgroundEnabled ? this.profileBackgroundUrl : '')
      .backgroundImageSize(ImageSize.Cover)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .hideTitleBar(this.badgeDetailVisible)
      .bindToScrollable([this.scroller])
      .onReady((context: NavDestinationContext): void => {
        this.pathStack = context.pathStack;
      })
      .onBackPressed((): boolean => {
        SteamArkPageWindowSupport.restoreHome();
        if (this.badgeDetailVisible) {
          this.closeBadgeDetail();
          return true;
        }
        this.pathStack.pop();
        return true;
      });
    }
  }

  @Builder
  private buildPageBody(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.embedded) {
        SteamArkProfileBackground()
      }

      // The list stays mounted while the badge detail covers it, so tile
      // geometry never resets and the close-direction geometryTransition
      // always flies back to the real tile position.
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (!this.stateReady) {
            SteamArkStateUnavailableCard({
              isDarkMode: this.isDarkMode,
              useSysMat: this.useSysMat
            });
          } else {
            this.buildHeroCard();
            this.buildWorkspaceTabs();
            if (!this.embedded) {
              this.buildAccountCard();
            }
            if (this.workspaceTab === SteamWorkspaceTab.CARDS_AND_BADGES) {
              this.buildCardsAndBadgesCard();
            } else {
              this.buildCommandCard();
              this.buildFarmingCard();
            }
            if (!this.embedded) {
              this.buildInventoryCard();
              this.buildNetworkCard();
            }
            this.buildSafetyCard();
            this.buildActionMessage();
          }
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: this.embedded ? this.contentTopInsetVp : this.topInsetVp,
          bottom: this.embedded
            ? 84 + SteamArkExperiencePolicy.FRIENDS_BAR_RESERVE
            : 92
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .backgroundColor($r('app.color.background_transparent'))
      .onDidScroll((_xOffset: number, yOffset: number): void => {
        if (this.embedded) {
          steamArkTabScrollers.notifyScrollDelta(yOffset);
        }
      })

      if (this.badgeDetailVisible) {
        Stack({ alignContent: Alignment.TopStart }) {
          SteamArkBadgeDetailPage({ request: this.badgeDetailRequest })
          this.buildBadgePanelTopBar()
        }
        .width('100%')
        .height('100%')
        .transition(SteamArkExperiencePolicy.seamlessBranchTransition())
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.embedded
      ? $r('app.color.background_transparent') : SteamArkTheme.background(this.isDarkMode))
    .opacity(this.stateReady && !this.farmingGamesRefreshing && !this.cardItemsRefreshing ? 1 : 0.9)
    .animation({ duration: SteamArkExperiencePolicy.CONTENT_REFRESH_DURATION, curve: Curve.EaseOut })
  }

  @Builder
  private buildBadgePanelTopBar(): void {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
      .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
      .id('steam-ark-badge-panel-back')
      .onClick((): void => {
        this.closeBadgeDetail();
      })

      Text(this.badgeDetailRequest.name.length > 0
        ? this.badgeDetailRequest.name
        : $r('app.string.steam_badge_detail_subtitle'))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: BADGE_PANEL_TOP_BAR_TOP, bottom: 6 })
  }

  @Builder
  private buildWorkspaceTabs(): void {
    Row() {
      this.buildWorkspaceTabTitle(
        $r('app.string.steam_workspace_tab_cards_badges'),
        SteamWorkspaceTab.CARDS_AND_BADGES
      )
      this.buildWorkspaceTabTitle(
        $r('app.string.steam_workspace_tab_farming'),
        SteamWorkspaceTab.FARMING
      )
    }
    .width('100%')
    .height(44)
  }

  @Builder
  private buildWorkspaceTabTitle(title: ResourceStr, tab: number): void {
    Column({ space: 5 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(this.workspaceTab === tab ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.workspaceTab === tab
          ? SteamArkTheme.accent(this.isDarkMode)
          : SteamArkTheme.textSecondary(this.isDarkMode))
      Column() {}
        .width(56)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.workspaceTab === tab
          ? SteamArkTheme.accent(this.isDarkMode)
          : $r('app.color.background_transparent'))
    }
    .width('100%')
    .height(42)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .animation({ duration: 220, curve: Curve.EaseOut })
    .onClick((): void => {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.workspaceTab = tab;
      });
    })
  }

  @Builder
  private buildCardsAndBadgesCard(): void {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.archivebox'))
          .fontSize(19)
          .fontColor([SteamArkTheme.warning(this.isDarkMode)])
        Text($r('app.string.steam_workspace_cards_owned_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')

      if (this.cardItems.length > 0) {
        Grid() {
          ForEach(this.cardItems, (item: SteamInventoryItem) => {
            GridItem() {
              this.buildCardTile(item)
            }
          }, (item: SteamInventoryItem): string => item.assetId)
        }
        .width('100%')
        .columnsTemplate(this.gridTemplate())
        .columnsGap(10)
        .rowsGap(10)
      } else {
        Text(this.cardItemsEmptyState())
          .width('100%')
          .fontSize(12)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
      }

      Divider().color(SteamArkTheme.divider(this.isDarkMode))
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.medal'))
          .fontSize(19)
          .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
        Text($r('app.string.steam_workspace_badges_owned_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')
      if (this.visibleGameBadges().length > 0) {
        Grid() {
          ForEach(this.visibleGameBadges(), (game: SteamGameDrop) => {
            GridItem() {
              this.buildGameBadgeTile(game)
            }
          }, (game: SteamGameDrop): string => game.appId)
        }
        .width('100%')
        .columnsTemplate(this.gridTemplate())
        .columnsGap(10)
        .rowsGap(10)
      } else {
        Text(this.gameBadgesEmptyState())
          .width('100%')
          .fontSize(12)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
      }

      if (this.uncraftedBadges().length > 0) {
        Divider().color(SteamArkTheme.divider(this.isDarkMode))
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.wand_and_stars'))
            .fontSize(19)
            .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
          Text($r('app.string.steam_workspace_badges_uncrafted_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        }
        .width('100%')
        Grid() {
          ForEach(this.uncraftedBadges(), (game: SteamGameDrop) => {
            GridItem() {
              this.buildUncraftedBadgeTile(game)
            }
          }, (game: SteamGameDrop): string => game.appId)
        }
        .width('100%')
        .columnsTemplate(this.gridTemplate())
        .columnsGap(10)
        .rowsGap(10)
      } else {
        Text($r('app.string.steam_workspace_badges_uncrafted_empty'))
          .width('100%')
          .fontSize(12)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
      }

      Divider().color(SteamArkTheme.divider(this.isDarkMode))
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.person_2'))
          .fontSize(19)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        Text($r('app.string.steam_workspace_community_badges_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')
      if (this.communityBadges.length > 0) {
        Grid() {
          ForEach(this.communityBadges, (badge: SteamCommunityBadge) => {
            GridItem() {
              this.buildCommunityBadgeTile(badge)
            }
          }, (badge: SteamCommunityBadge): string => badge.badgeId)
        }
        .width('100%')
        .columnsTemplate(this.gridTemplate())
        .columnsGap(10)
        .rowsGap(10)
      } else {
        Text(this.communityBadgesEmptyState())
          .width('100%')
          .fontSize(12)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode),
        this.useSysMat
      )
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildCardTile(item: SteamInventoryItem): void {
    Column({ space: 6 }) {
      Image(item.iconUrlLarge.length > 0 ? item.iconUrlLarge : item.iconUrl)
        .width('100%')
        .height(86)
        .objectFit(ImageFit.Contain)
        .borderRadius(8)
        .backgroundColor(Color.Transparent)
      Text(item.name.length > 0 ? item.name : item.marketName)
        .width('100%')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(item.amount.toString())
        .fontSize(11)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .width('100%')
    .padding(8)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwareControlShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildGameBadgeTile(game: SteamGameDrop): void {
    Column({ space: 6 }) {
      if (this.isOpenGameBadgeTile(game.appId)) {
        this.buildBadgeTilePlaceholder()
      } else {
        Image(game.badgeImageUrl.length > 0 ? game.badgeImageUrl : game.imageUrl)
          .width('100%')
          .height(86)
          .objectFit(ImageFit.Contain)
          .borderRadius(8)
          .backgroundColor(Color.Transparent)
          .clip(true)
          .geometryTransition(SteamArkBadgeDetailRequest.geometryId(SteamArkBadgeKind.GAME, game.appId, ''))
          .transition(TransitionEffect.OPACITY)
      }
      Text(game.name.length > 0 ? game.name : game.appId)
        .width('100%')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (game.badgeLevel > 0) {
        Row({ space: 3 }) {
          Text($r('app.string.steam_workspace_badge_level_prefix'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          Text(game.badgeLevel.toString())
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
      }
    }
    .width('100%')
    .padding(8)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwareControlShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForClickablePanel())
    .onClick((): void => {
      this.openGameBadgeDetail(game);
    })
  }

  @Builder
  private buildUncraftedBadgeTile(game: SteamGameDrop): void {
    Column({ space: 6 }) {
      if (this.isOpenGameBadgeTile(game.appId)) {
        this.buildBadgeTilePlaceholder()
      } else {
        Image(game.imageUrl)
          .width('100%')
          .height(86)
          .objectFit(ImageFit.Contain)
          .borderRadius(8)
          .backgroundColor(Color.Transparent)
          .clip(true)
          .geometryTransition(SteamArkBadgeDetailRequest.geometryId(SteamArkBadgeKind.GAME, game.appId, ''))
          .transition(TransitionEffect.OPACITY)
          .opacity(0.55)
      }
      Text(game.name.length > 0 ? game.name : game.appId)
        .width('100%')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.uncraftedBadgeStatus(game))
        .width('100%')
        .fontSize(10)
        .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(8)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: 1,
      color: SteamArkTheme.textMuted(this.isDarkMode),
      style: BorderStyle.Dashed
    })
    .opacity(0.85)
    .onClick((): void => {
      this.openGameBadgeDetail(game);
    })
  }

  @Builder
  private buildCommunityBadgeTile(badge: SteamCommunityBadge): void {
    Column({ space: 6 }) {
      if (this.isOpenCommunityBadgeTile(badge.badgeId)) {
        this.buildBadgeTilePlaceholder()
      } else {
        Image(badge.imageUrl)
          .width('100%')
          .height(86)
          .objectFit(ImageFit.Contain)
          .borderRadius(8)
          .backgroundColor(Color.Transparent)
          .clip(true)
          .geometryTransition(SteamArkBadgeDetailRequest.geometryId(SteamArkBadgeKind.COMMUNITY, '', badge.badgeId))
          .transition(TransitionEffect.OPACITY)
      }
      Text(badge.name)
        .width('100%')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 3 }) {
        Text($r('app.string.steam_workspace_community_badge_experience_prefix'))
          .fontSize(11)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        Text(badge.experience.toString())
          .fontSize(11)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
    }
    .width('100%')
    .padding(8)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwareControlShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForClickablePanel())
    .onClick((): void => {
      this.openCommunityBadgeDetail(badge);
    })
  }

  @Builder
  private buildHeroCard(): void {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column() {}
            .width(56)
            .height(56)
            .borderRadius(28)
            .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
            .opacity(0.18)
          SymbolGlyph($r('sys.symbol.gamecontroller'))
            .fontSize(30)
            .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        }

        Column({ space: 4 }) {
          Text($r('app.string.steam_workspace_title'))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text($r('app.string.steam_workspace_subtitle'))
            .fontSize(13)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.steam_workspace_account_count_label'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          Text(String(this.accountCount))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Column({ space: 2 }) {
          Text($r('app.string.steam_workspace_current_account_label'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          Text(this.selectedAccountName.length > 0
            ? this.selectedAccountName
            : $r('app.string.steam_workspace_account_empty'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(2)
        .alignItems(HorizontalAlign.Start)
        Column({ space: 2 }) {
          Text($r('app.string.steam_workspace_session_label'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          Text(this.sessionLabel(this.sessionState))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.sessionState === SteamSessionState.LOGGED_ON
              ? SteamArkTheme.success(this.isDarkMode)
              : SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(2)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.steam_workspace_readonly_tag'))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(SteamArkTheme.surfaceOverlay(this.isDarkMode))
          .borderRadius(12)
        Text(this.selectedAccountId.length > 0
          ? this.sessionLabel(this.sessionState)
          : $r('app.string.steam_accounts_session_disconnected'))
          .fontSize(11)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(18)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PROMINENT_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwareProminentShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
  }

  @Builder
  private buildCommandCard(): void {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.keyboard'))
          .fontSize(22)
          .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
        Column({ space: 3 }) {
          Text($r('app.string.steam_workspace_command_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      TextInput({
        placeholder: $r('app.string.steam_workspace_command_placeholder'),
        text: this.commandText
      })
        .id('steam-ark-workspace-command-input')
        .width('100%')
        .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
        .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
        .padding({ left: 12, right: 12 })
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceControl(this.isDarkMode),
          this.useSysMat
        ))
        .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
        .enabled(!this.commandBusy)
        .onChange((value: string): void => {
          this.commandText = value;
        })

      Button() {
        Row({ space: 6 }) {
          SymbolGlyph(this.commandBusy
            ? $r('sys.symbol.arrow_clockwise')
            : $r('sys.symbol.play_round_triangle_fill'))
            .fontSize(16)
            .fontColor([this.commandBusy
              ? SteamArkTheme.buttonDisabledText(this.isDarkMode)
              : SteamArkTheme.onAccent(this.isDarkMode)])
          Text(this.commandBusy
            ? $r('app.string.steam_workspace_command_busy')
            : $r('app.string.steam_workspace_command_execute'))
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.commandBusy
              ? SteamArkTheme.buttonDisabledText(this.isDarkMode)
              : SteamArkTheme.onAccent(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
        .width('100%')
        .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
        .id('steam-ark-workspace-command-execute')
        .padding(0)
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(this.commandBusy
          ? SteamArkTheme.buttonDisabled(this.isDarkMode)
          : SteamArkTheme.accent(this.isDarkMode))
        .fontColor(this.commandBusy
          ? SteamArkTheme.buttonDisabledText(this.isDarkMode)
          : SteamArkTheme.onAccent(this.isDarkMode))
        .enabled(!this.commandBusy)
        .onClick((): void => {
          void this.handleCommandSubmit();
        })

      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.info_circle'))
          .fontSize(15)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
        Column({ space: 2 }) {
          Text(this.commandMessage)
            .fontSize(12)
            .lineHeight(18)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          if (this.commandDetail.length > 0) {
            Text(this.commandDetail)
              .width('100%')
              .fontSize(11)
              .lineHeight(16)
              .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
              .maxLines(6)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwarePanelShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildAccountCard(): void {
    this.buildWorkspaceCard(
      $r('sys.symbol.person_2'),
      $r('app.string.steam_workspace_account_title'),
      this.accountValue(),
      $r('app.string.steam_workspace_manage_account'),
      SteamWorkspaceActionKey.ACCOUNT,
      SteamArkTheme.accent(this.isDarkMode),
      true
    )
  }

  @Builder
  private buildFarmingCard(): void {
    Column({ space: 8 }) {
      this.buildWorkspaceCard(
        $r('sys.symbol.play_round_triangle_fill'),
        $r('app.string.steam_workspace_farming_title'),
        this.farmingValue(),
        this.farmingActionTitle(),
        SteamWorkspaceActionKey.FARMING,
        SteamArkTheme.success(this.isDarkMode),
        this.isFarmingActionEnabled()
      )
      if (!steamArkFarmingService.isFarmingReady()) {
        Text($r('app.string.steam_workspace_farming_disabled_reason'))
          .width('100%')
          .fontSize(11)
          .lineHeight(16)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.farmingGames.length > 0) {
        this.buildFarmingGames();
      } else if (this.selectedAccountId.length > 0 && this.sessionState === SteamSessionState.LOGGED_ON) {
        Text(this.farmingGamesRefreshing
          ? $r('app.string.steam_workspace_farming_games_loading')
          : (this.farmingGamesRefreshFailed
            ? $r('app.string.steam_workspace_farming_games_failed')
            : (this.farmingGamesLoaded
              ? $r('app.string.steam_workspace_farming_games_empty')
              : $r('app.string.steam_workspace_farming_games_loading'))))
          .width('100%')
          .fontSize(12)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode));
      }
      if (this.shouldShowStopAction()) {
        Button() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.stop_circle'))
              .fontSize(15)
              .fontColor([SteamArkTheme.error(this.isDarkMode)])
            Text($r('app.string.steam_workspace_stop_farming'))
              .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
              .fontWeight(FontWeight.Medium)
              .fontColor(SteamArkTheme.error(this.isDarkMode))
          }
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
        .id('steam-ark-workspace-farming-stop')
        .padding(0)
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(SteamArkTheme.surfaceControl(this.isDarkMode))
        .enabled(!this.farmingBusy)
        .onClick((): void => {
          void this.handleStopFarming();
        })
      }
    }
    .width('100%')
  }

  @Builder
  private buildFarmingGames(): void {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.gamecontroller'))
          .fontSize(16)
          .fontColor([SteamArkTheme.success(this.isDarkMode)])
        Text($r('app.string.steam_workspace_farming_games_title'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')
      ForEach(this.farmingGames, (game: SteamGameDrop) => {
        Row({ space: 10 }) {
          Image(game.imageUrl)
            .width(96)
            .height(45)
            .objectFit(ImageFit.Cover)
            .borderRadius(4)
          Column({ space: 3 }) {
            Text(game.name.length > 0 ? game.name : game.appId)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: 4 }) {
              Text($r('app.string.steam_workspace_farming_game_cards'))
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
              Text(String(game.cardsRemaining))
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            }
            Row({ space: 12 }) {
              Text($r('app.string.steam_workspace_farming_game_hours'))
                .fontSize(11)
                .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
              Text(game.hoursPlayed.toFixed(1))
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(17)
              .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
          }
          .width(40)
          .height(40)
          .padding(0)
          .borderRadius(20)
          .backgroundColor(SteamArkTheme.surfaceControl(this.isDarkMode))
          .onClick((): void => {
            this.openExternalUrl(game.storeUrl);
          })
        }
        .width('100%')
        .padding(10)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
        .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
        .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
        .border({
          width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
          color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
            SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
        })
        .shadow(NGFMaterialSurfaceTokens.buildMaterialAwareControlShadow(this.useSysMat))
        .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForClickablePanel())
      }, (game: SteamGameDrop): string => game.appId)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  private buildInventoryCard(): void {
    this.buildWorkspaceCard(
      $r('sys.symbol.archivebox'),
      $r('app.string.steam_workspace_inventory_title'),
      $r('app.string.steam_workspace_inventory_empty'),
      $r('app.string.steam_workspace_open_inventory'),
      SteamWorkspaceActionKey.INVENTORY,
      SteamArkTheme.warning(this.isDarkMode),
      true
    )
  }

  @Builder
  private buildNetworkCard(): void {
    this.buildWorkspaceCard(
      $r('sys.symbol.wifi'),
      $r('app.string.steam_workspace_network_title'),
      this.networkValue(),
      $r('app.string.steam_workspace_network_diagnostics'),
      SteamWorkspaceActionKey.NETWORK,
      SteamArkTheme.accentCyan(this.isDarkMode),
      true
    )
  }

  @Builder
  private buildWorkspaceCard(
    icon: Resource,
    title: ResourceStr,
    value: ResourceStr,
    actionTitle: ResourceStr,
    actionKey: number,
    accent: ResourceColor,
    actionEnabled: boolean
  ): void {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        SymbolGlyph(icon)
          .fontSize(25)
          .fontColor([accent])

        Column({ space: 3 }) {
          Text(title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          Text(value)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(15)
            .fontColor([actionEnabled ? SteamArkTheme.buttonForeground(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode)])
          Text(actionTitle)
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(actionEnabled ? SteamArkTheme.buttonForeground(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
      .padding(0)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(actionEnabled
        ? NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat)
        : SteamArkTheme.surfaceControl(this.isDarkMode))
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
      .enabled(actionEnabled)
      .id(this.workspaceActionId(actionKey))
      .onClick((): void => {
        this.handleAction(actionKey);
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwarePanelShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildSafetyCard(): void {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(24)
        .fontColor([SteamArkTheme.success(this.isDarkMode)])
      Column({ space: 5 }) {
        Text($r('app.string.steam_workspace_safety_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_workspace_safety_desc'))
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildActionMessage(): void {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(16)
        .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      Text(this.actionMessage)
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4, bottom: 8 })
  }

  private handleAction(actionKey: number): void {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.info('WorkspacePage', 'workspace action requested; action=' + actionKey.toString());
    switch (actionKey) {
      case SteamWorkspaceActionKey.ACCOUNT:
        this.pushRoute(SteamArkRouteName.ACCOUNTS);
        break;
      case SteamWorkspaceActionKey.FARMING:
        void this.handleFarmingAction();
        break;
      case SteamWorkspaceActionKey.INVENTORY:
        this.pushRoute(SteamArkRouteName.INVENTORY);
        break;
      case SteamWorkspaceActionKey.NETWORK:
        this.pushRoute(SteamArkRouteName.NETWORK);
        break;
      default:
        this.actionMessage = $r('app.string.steam_workspace_status_idle');
        break;
    }
  }

  private pushRoute(routeName: string): void {
    if (this.embedded) {
      const pushed: boolean = SteamArkNavigationBridge.pushHomeRoute(routeName);
      if (!pushed && this.isPageActive) {
        this.actionMessage = $r('app.string.steam_navigation_route_failed');
      }
      return;
    }
    this.pathStack.pushPathByName(routeName, null);
  }

  private openGameBadgeDetail(game: SteamGameDrop): void {
    const request: SteamArkBadgeDetailRequest = new SteamArkBadgeDetailRequest(
      SteamArkBadgeKind.GAME,
      game.appId,
      '',
      game.name.length > 0 ? game.name : game.appId,
      game.badgeImageUrl.length > 0 ? game.badgeImageUrl : game.imageUrl,
      game.badgeLevel,
      0,
      game.hoursPlayed,
      game.cardsRemaining,
      game.badgeCrafted,
      game.badgeUrl,
      game.storeUrl
    );
    this.openBadgeDetail(request);
  }

  private openCommunityBadgeDetail(badge: SteamCommunityBadge): void {
    const request: SteamArkBadgeDetailRequest = new SteamArkBadgeDetailRequest(
      SteamArkBadgeKind.COMMUNITY,
      '',
      badge.badgeId,
      badge.name,
      badge.imageUrl,
      0,
      badge.experience,
      0,
      0,
      true,
      badge.badgeUrl,
      ''
    );
    this.openBadgeDetail(request);
  }

  /** True when this game-badge tile is the one whose detail is currently open. */
  private isOpenGameBadgeTile(appId: string): boolean {
    return this.badgeDetailVisible &&
      this.badgeDetailRequest.kind === SteamArkBadgeKind.GAME &&
      this.badgeDetailRequest.appId === appId;
  }

  /** True when this community-badge tile is the one whose detail is open. */
  private isOpenCommunityBadgeTile(badgeId: string): boolean {
    return this.badgeDetailVisible &&
      this.badgeDetailRequest.kind === SteamArkBadgeKind.COMMUNITY &&
      this.badgeDetailRequest.badgeId === badgeId;
  }

  /**
   * Same-size stand-in for the opened tile image. Unmounting the real image
   * gives the geometryTransition pair a genuine disappear on open and a
   * genuine appear on close, while the persistent list keeps its layout.
   */
  @Builder
  private buildBadgeTilePlaceholder(): void {
    Column()
      .width('100%')
      .height(86)
  }

  private openBadgeDetail(request: SteamArkBadgeDetailRequest): void {
    if (!this.isPageActive) {
      return;
    }
    const identity: string = request.kind === SteamArkBadgeKind.COMMUNITY ? request.badgeId : request.appId;
    SteamArkLog.info('WorkspacePage', 'badge detail opened; kind=' + String(request.kind) +
      ', id=' + identity);
    this.badgeDetailRequest = request;
    if (this.embedded) {
      SteamArkPanelBackBridge.setVisible(SteamArkPanelBackBridge.BADGE_PANEL, true);
    }
    // Official 一镜到底 (persistent-source variant): the list stays mounted;
    // the opened tile image unmounts while the detail is open so the pair has
    // a genuine appear/disappear in both flight directions, and the flight
    // always ends at the tile's real, never-reset position.
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.EXPAND_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.badgeDetailVisible = true;
    });
  }

  private closeBadgeDetail(): void {
    if (!this.badgeDetailVisible) {
      return;
    }
    SteamArkLog.info('WorkspacePage', 'badge detail closed');
    if (this.embedded) {
      SteamArkPanelBackBridge.setVisible(SteamArkPanelBackBridge.BADGE_PANEL, false);
    }
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.EXPAND_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.badgeDetailVisible = false;
    });
  }

  private workspaceActionId(actionKey: number): string {
    switch (actionKey) {
      case SteamWorkspaceActionKey.ACCOUNT:
        return 'steam-ark-workspace-account-open';
      case SteamWorkspaceActionKey.FARMING:
        return 'steam-ark-workspace-farming-action';
      case SteamWorkspaceActionKey.INVENTORY:
        return 'steam-ark-workspace-inventory-open';
      case SteamWorkspaceActionKey.NETWORK:
        return 'steam-ark-workspace-network-open';
      default:
        return 'steam-ark-workspace-action';
    }
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    if (!this.isPageActive) {
      return;
    }
    this.stateReady = snapshot.initialized;
    if (!this.stateReady) {
      this.actionMessage = $r('app.string.steam_state_unavailable_status');
    }
    this.accountCount = snapshot.accounts.length;
    const previousAccountId: string = this.selectedAccountId;
    const previousSessionState: SteamSessionState = this.sessionState;
    const selected = steamArkStateService.getSelectedAccount();
    const nextSessionState: SteamSessionState = selected === null
      ? SteamSessionState.DISCONNECTED
      : selected.session.state;
    const accountChanged: boolean = previousAccountId !== snapshot.selectedAccountId;
    const accountScopeInvalidated: boolean = accountChanged ||
      (previousSessionState === SteamSessionState.LOGGED_ON && nextSessionState !== SteamSessionState.LOGGED_ON);
    if (accountScopeInvalidated) {
      this.accountScopeGeneration += 1;
      this.resetAccountScopedFarmingResults();
    }
    this.selectedAccountId = snapshot.selectedAccountId;
    if (accountChanged) {
      this.cardItems = [];
      this.cardItemsLoaded = false;
      this.cardItemsRefreshFailed = false;
    }
    if (selected === null) {
      this.selectedAccountName = '';
      this.sessionState = SteamSessionState.DISCONNECTED;
    } else {
      this.selectedAccountName = selected.profile.displayName.length > 0
        ? selected.profile.displayName
        : selected.profile.accountId;
      this.sessionState = selected.session.state;
    }
    this.applyFarmingSnapshot(steamArkFarmingService.getSnapshot(this.selectedAccountId));
    this.applyCachedBadgeReport(this.selectedAccountId);
    const shouldRefreshFarmingGames: boolean = this.selectedAccountId !== this.lastFarmingGamesRefreshAccountId ||
      Date.now() - this.lastFarmingGamesRefreshAtMs >= FARMING_GAMES_AUTO_REFRESH_INTERVAL_MS;
    if (this.selectedAccountId.length > 0 && this.sessionState === SteamSessionState.LOGGED_ON &&
      this.refreshingFarmingGamesForAccountId.length <= 0 && shouldRefreshFarmingGames) {
      const lifecycleGeneration: number = this.lifecycleGeneration;
      const accountScopeGeneration: number = this.accountScopeGeneration;
      void this.refreshFarmingGamesSilently(this.selectedAccountId, lifecycleGeneration, accountScopeGeneration);
    }
    this.loadCardItemsFromInventoryCache(this.selectedAccountId);
    SteamArkLog.debug('WorkspacePage', 'state applied; selectedAccount=' +
      SteamArkLog.accountId(this.selectedAccountId) + ', session=' + String(this.sessionState));
  }

  private loadCardItemsFromInventoryCache(accountId: string): void {
    if (!this.isPageActive || accountId.length <= 0) {
      return;
    }
    const pages: Array<SteamInventoryPage> = steamArkStateService.getCachedDefaultInventoryPages(accountId);
    if (pages.length <= 0) {
      this.cardItemsRefreshing = false;
      return;
    }
    const cards: Array<SteamInventoryItem> = [];
    for (let pageIndex: number = 0; pageIndex < pages.length; pageIndex++) {
      const page: SteamInventoryPage = pages[pageIndex];
      for (let itemIndex: number = 0; itemIndex < page.items.length; itemIndex++) {
        const item: SteamInventoryItem = page.items[itemIndex];
        if (!item.isTradingCard || this.hasCardItem(cards, item)) {
          continue;
        }
        cards.push(item);
      }
    }
    this.cardItems = cards;
    this.cardItemsLoaded = true;
    this.cardItemsRefreshFailed = false;
    this.cardItemsRefreshing = false;
    SteamArkLog.debug('WorkspacePage', 'card inventory cache applied; account=' +
      SteamArkLog.accountId(accountId) + ', cards=' + cards.length.toString());
  }

  private applySyncSnapshot(snapshot: SteamArkSyncSnapshot): void {
    if (!this.isPageActive || this.selectedAccountId.length <= 0) {
      return;
    }
    const accountSnapshot: SteamArkAccountSyncSnapshot | null =
      this.findAccountSyncSnapshot(snapshot, this.selectedAccountId);
    if (accountSnapshot === null) {
      return;
    }
    if (this.hasInventorySyncFailure(accountSnapshot) && !this.cardItemsLoaded) {
      this.cardItemsRefreshing = false;
      this.cardItemsRefreshFailed = true;
      SteamArkLog.warn('WorkspacePage', 'card inventory synchronization failed; account=' +
        SteamArkLog.accountId(this.selectedAccountId));
    } else if (!this.cardItemsLoaded && accountSnapshot.running) {
      this.cardItemsRefreshing = true;
      this.cardItemsRefreshFailed = false;
    } else if (!accountSnapshot.running) {
      this.cardItemsRefreshing = false;
    }

    const farmingUpdatedAtEpochSeconds: number = accountSnapshot.freshness.farmingUpdatedAtEpochSeconds;
    if (farmingUpdatedAtEpochSeconds > this.coordinatorFarmingUpdatedAtEpochSeconds) {
      this.coordinatorFarmingUpdatedAtEpochSeconds = farmingUpdatedAtEpochSeconds;
      this.applyCachedBadgeReport(this.selectedAccountId);
      if (this.farmingGamesLoaded) {
        this.lastFarmingGamesRefreshAccountId = this.selectedAccountId;
        this.lastFarmingGamesRefreshAtMs = Date.now();
      }
    }
    if (this.hasFarmingSyncFailure(accountSnapshot) && !this.farmingGamesLoaded) {
      this.farmingGamesRefreshing = false;
      this.farmingGamesRefreshFailed = true;
      SteamArkLog.warn('WorkspacePage', 'badge synchronization failed; account=' +
        SteamArkLog.accountId(this.selectedAccountId));
    } else if (!this.farmingGamesLoaded && accountSnapshot.running) {
      this.farmingGamesRefreshing = true;
      this.farmingGamesRefreshFailed = false;
    } else if (!accountSnapshot.running) {
      this.farmingGamesRefreshing = false;
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

  private hasInventorySyncFailure(snapshot: SteamArkAccountSyncSnapshot): boolean {
    if (snapshot.failure.stage === SteamArkSyncStage.INVENTORY) {
      return true;
    }
    for (let index: number = 0; index < snapshot.stageFailures.length; index++) {
      if (snapshot.stageFailures[index].stage === SteamArkSyncStage.INVENTORY) {
        return true;
      }
    }
    return false;
  }

  private hasFarmingSyncFailure(snapshot: SteamArkAccountSyncSnapshot): boolean {
    if (snapshot.failure.stage === SteamArkSyncStage.FARMING) {
      return true;
    }
    for (let index: number = 0; index < snapshot.stageFailures.length; index++) {
      if (snapshot.stageFailures[index].stage === SteamArkSyncStage.FARMING) {
        return true;
      }
    }
    return false;
  }

  private hasCardItem(items: Array<SteamInventoryItem>, candidate: SteamInventoryItem): boolean {
    for (let index: number = 0; index < items.length; index++) {
      const item: SteamInventoryItem = items[index];
      if (item.assetId === candidate.assetId && item.classId === candidate.classId &&
        item.instanceId === candidate.instanceId) {
        return true;
      }
    }
    return false;
  }

  private cardGroups(): Array<SteamCardInventoryGroup> {
    const groups: Array<SteamCardInventoryGroup> = [];
    for (let index = 0; index < this.cardItems.length; index++) {
      const item: SteamInventoryItem = this.cardItems[index];
      const appId: string = item.ownerAppId.length > 0 ? item.ownerAppId : item.appId;
      let group: SteamCardInventoryGroup | null = null;
      for (let groupIndex = 0; groupIndex < groups.length; groupIndex++) {
        if (groups[groupIndex].appId === appId) {
          group = groups[groupIndex];
          break;
        }
      }
      if (group === null) {
        group = new SteamCardInventoryGroup(appId, item.ownerAppName, []);
        groups.push(group);
      }
      group.items.push(item);
    }
    return groups;
  }

  private visibleGameBadges(): Array<SteamGameDrop> {
    const badges: Array<SteamGameDrop> = [];
    for (let index = 0; index < this.gameBadgeGames.length; index++) {
      const game: SteamGameDrop = this.gameBadgeGames[index];
      if (game.appId !== '753' && game.badgeCrafted) {
        badges.push(game);
      }
    }
    return badges;
  }

  private uncraftedBadges(): Array<SteamGameDrop> {
    const badges: Array<SteamGameDrop> = [];
    for (let index = 0; index < this.gameBadgeGames.length; index++) {
      const game: SteamGameDrop = this.gameBadgeGames[index];
      if (game.appId !== '753' && !game.badgeCrafted) {
        badges.push(game);
      }
    }
    return badges;
  }

  private uncraftedBadgeStatus(game: SteamGameDrop): ResourceStr {
    if (game.cardsRemaining > 0) {
      return $r('app.string.steam_workspace_badges_uncrafted_remaining', game.cardsRemaining);
    }
    return $r('app.string.steam_workspace_badges_uncrafted_ready');
  }

  private cardItemsEmptyState(): ResourceStr {
    if (this.cardItemsRefreshing) {
      return $r('app.string.steam_workspace_cards_loading');
    }
    if (this.cardItemsRefreshFailed) {
      return $r('app.string.steam_workspace_cards_failed');
    }
    if (!this.cardItemsLoaded && this.shouldAwaitAccountAssetData()) {
      return $r('app.string.steam_workspace_cards_loading');
    }
    return $r('app.string.steam_workspace_cards_empty');
  }

  private gameBadgesEmptyState(): ResourceStr {
    if (this.farmingGamesRefreshing) {
      return $r('app.string.steam_workspace_farming_games_loading');
    }
    if (this.farmingGamesRefreshFailed) {
      return $r('app.string.steam_workspace_farming_games_failed');
    }
    if (!this.farmingGamesLoaded && this.shouldAwaitAccountAssetData()) {
      return $r('app.string.steam_workspace_farming_games_loading');
    }
    return $r('app.string.steam_workspace_badges_empty');
  }

  private communityBadgesEmptyState(): ResourceStr {
    if (this.farmingGamesRefreshing) {
      return $r('app.string.steam_workspace_farming_games_loading');
    }
    if (this.farmingGamesRefreshFailed) {
      return $r('app.string.steam_workspace_farming_games_failed');
    }
    if (!this.farmingGamesLoaded && this.shouldAwaitAccountAssetData()) {
      return $r('app.string.steam_workspace_farming_games_loading');
    }
    return $r('app.string.steam_workspace_community_badges_empty');
  }

  private shouldAwaitAccountAssetData(): boolean {
    return this.selectedAccountId.length > 0 && this.sessionState === SteamSessionState.LOGGED_ON;
  }

  private async refreshFarmingGamesSilently(
    accountId: string,
    lifecycleGeneration: number,
    accountScopeGeneration: number
  ): Promise<void> {
    if (!this.isCurrentFarmingScope(lifecycleGeneration, accountId, accountScopeGeneration) ||
      accountId.length <= 0 || this.refreshingFarmingGamesForAccountId.length > 0) {
      return;
    }
    const requestVersion: number = this.farmingGamesRequestVersion + 1;
    this.farmingGamesRequestVersion = requestVersion;
    this.refreshingFarmingGamesForAccountId = accountId;
    this.farmingGamesRefreshing = true;
    this.farmingGamesRefreshFailed = false;
    try {
      await steamArkSyncCoordinator.requestAccountSync(accountId, 'workspace_farming_games');
      if (this.isCurrentFarmingGamesRequest(lifecycleGeneration, accountId, accountScopeGeneration,
        requestVersion)) {
        const accountSnapshot: SteamArkAccountSyncSnapshot | null =
          steamArkSyncCoordinator.getAccountSnapshot(accountId);
        if (accountSnapshot === null || this.hasFarmingSyncFailure(accountSnapshot)) {
          this.farmingGamesRefreshFailed = true;
          this.actionMessage = $r('app.string.steam_workspace_farming_games_failed');
          return;
        }
        const report = steamArkFarmingService.getBadgeSyncReport(accountId);
        this.gameBadgeGames = report === null ? [] : report.games.slice();
        this.communityBadges = report === null ? [] : report.communityBadges.slice();
        this.lastFarmingGamesRefreshAccountId = accountId;
        this.lastFarmingGamesRefreshAtMs = Date.now();
        this.farmingGamesLoaded = true;
        this.actionMessage = $r('app.string.steam_workspace_farming_games_refreshed');
      }
    } catch (error) {
      if (this.isCurrentFarmingGamesRequest(lifecycleGeneration, accountId, accountScopeGeneration,
        requestVersion)) {
        this.farmingGamesRefreshFailed = true;
        const detail: string = this.displayError(error instanceof Error ? error : new Error(''));
        this.actionMessage = detail.length > 0 ? detail : $r('app.string.steam_workspace_farming_games_failed');
      }
      SteamArkLog.warn('WorkspacePage', 'silent farming game refresh failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentFarmingGamesRequest(lifecycleGeneration, accountId, accountScopeGeneration,
        requestVersion)) {
        this.refreshingFarmingGamesForAccountId = '';
        this.farmingGamesRefreshing = false;
      }
    }
  }

  private async initializeStateService(): Promise<void> {
    if (!this.isPageActive) {
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const startedAt: number = Date.now();
    try {
      const initialized: boolean = await steamArkStateService.initialize();
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      this.applyStateSnapshot(steamArkStateService.getSnapshot());
      if (initialized) {
        this.actionMessage = $r('app.string.steam_workspace_status_accounts_loaded');
      }
      SteamArkLog.info('WorkspacePage', 'state service ready; initialized=' + String(initialized));
      SteamArkLog.performance('WorkspacePage', 'state initialization', startedAt);
    } catch (_error) {
      SteamArkLog.error('WorkspacePage', 'state service initialization failed');
    }
  }

  private accountValue(): ResourceStr {
    return this.selectedAccountName.length > 0
      ? this.selectedAccountName
      : $r('app.string.steam_workspace_account_empty');
  }

  private farmingValue(): ResourceStr {
    if (!steamArkFarmingService.isFarmingReady()) {
      return $r('app.string.steam_workspace_farming_pending');
    }
    switch (this.farmingState) {
      case SteamFarmState.STARTING:
        return $r('app.string.steam_workspace_farming_starting');
      case SteamFarmState.FARMING:
        return $r('app.string.steam_workspace_farming_running');
      case SteamFarmState.PAUSED:
        return $r('app.string.steam_workspace_farming_paused');
      case SteamFarmState.RECONNECTING:
        return $r('app.string.steam_workspace_farming_reconnecting');
      case SteamFarmState.COMPLETED:
        return $r('app.string.steam_workspace_farming_completed');
      case SteamFarmState.ERROR:
        return $r('app.string.steam_workspace_farming_error');
      case SteamFarmState.IDLE:
      default:
        return $r('app.string.steam_workspace_farming_idle');
    }
  }

  private farmingActionTitle(): ResourceStr {
    if (!steamArkFarmingService.isFarmingReady()) {
      return $r('app.string.steam_workspace_farming_pending');
    }
    if (this.farmingState === SteamFarmState.FARMING) {
      return $r('app.string.steam_workspace_pause_farming');
    }
    if (this.farmingState === SteamFarmState.PAUSED) {
      return $r('app.string.steam_workspace_resume_farming');
    }
    return $r('app.string.steam_workspace_start_farming');
  }

  private isFarmingActionEnabled(): boolean {
    return this.stateReady && steamArkFarmingService.isFarmingReady() &&
      this.selectedAccountId.length > 0 &&
      this.sessionState === SteamSessionState.LOGGED_ON &&
      !this.farmingBusy &&
      this.farmingState !== SteamFarmState.STARTING;
  }

  private async handleFarmingAction(): Promise<void> {
    if (!this.isPageActive || this.farmingBusy) {
      SteamArkLog.debug('WorkspacePage', 'farming action skipped; already busy');
      return;
    }
    if (!this.stateReady) {
      this.actionMessage = $r('app.string.steam_state_unavailable_status');
      SteamArkLog.warn('WorkspacePage', 'farming action blocked; state service unavailable');
      return;
    }
    if (!steamArkFarmingService.isFarmingReady()) {
      this.actionMessage = $r('app.string.steam_workspace_status_farming_pending');
      SteamArkLog.warn('WorkspacePage', 'farming action blocked; runtime unavailable');
      return;
    }
    if (this.selectedAccountId.length <= 0 || this.sessionState !== SteamSessionState.LOGGED_ON) {
      this.actionMessage = $r('app.string.steam_workspace_status_farming_account_required');
      SteamArkLog.warn('WorkspacePage', 'farming action blocked; account not logged on');
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.farmingBusy = true;
    SteamArkLog.info('WorkspacePage', 'farming action started; account=' +
      SteamArkLog.accountId(this.selectedAccountId) + ', state=' + String(this.farmingState));
    try {
      if (this.farmingState === SteamFarmState.FARMING) {
        await steamArkFarmingService.pause(this.selectedAccountId);
        if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
          return;
        }
        this.actionMessage = $r('app.string.steam_workspace_status_farming_paused');
      } else if (this.farmingState === SteamFarmState.PAUSED) {
        await steamArkFarmingService.resume(this.selectedAccountId);
        if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
          return;
        }
        this.actionMessage = $r('app.string.steam_workspace_status_farming_resumed');
      } else {
        await steamArkFarmingService.start(this.selectedAccountId);
        if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
          return;
        }
        this.actionMessage = $r('app.string.steam_workspace_status_farming_started');
      }
      SteamArkLog.info('WorkspacePage', 'farming action completed; account=' +
        SteamArkLog.accountId(this.selectedAccountId));
    } catch (_error) {
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      const detail = this.displayError(_error);
      this.actionMessage = detail.length > 0
        ? detail
        : $r('app.string.steam_workspace_status_farming_failed');
      SteamArkLog.error('WorkspacePage', 'farming action failed; account=' +
        SteamArkLog.accountId(this.selectedAccountId));
    } finally {
      if (this.isPageActive && this.lifecycleGeneration === lifecycleGeneration) {
        this.farmingBusy = false;
      }
    }
  }

  private async handleStopFarming(): Promise<void> {
    if (!this.isPageActive || this.farmingBusy || this.selectedAccountId.length <= 0) {
      SteamArkLog.debug('WorkspacePage', 'stop farming skipped; busy or no account');
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.farmingBusy = true;
    SteamArkLog.info('WorkspacePage', 'stop farming started; account=' + SteamArkLog.accountId(this.selectedAccountId));
    try {
      await steamArkFarmingService.stop(this.selectedAccountId);
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      this.actionMessage = $r('app.string.steam_workspace_status_farming_stopped');
      SteamArkLog.info('WorkspacePage', 'stop farming completed; account=' + SteamArkLog.accountId(this.selectedAccountId));
    } catch (_error) {
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      const detail = this.displayError(_error);
      this.actionMessage = detail.length > 0
        ? detail
        : $r('app.string.steam_workspace_status_farming_failed');
      SteamArkLog.error('WorkspacePage', 'stop farming failed; account=' + SteamArkLog.accountId(this.selectedAccountId));
    } finally {
      if (this.isPageActive && this.lifecycleGeneration === lifecycleGeneration) {
        this.farmingBusy = false;
      }
    }
  }

  private async handleCommandSubmit(): Promise<void> {
    if (!this.isPageActive || this.commandBusy) {
      return;
    }
    if (!this.stateReady) {
      this.commandMessage = $r('app.string.steam_state_unavailable_status');
      this.commandDetail = '';
      SteamArkLog.warn('WorkspacePage', 'command rejected; state service unavailable');
      return;
    }
    const message = this.commandText.trim();
    if (message.length <= 0) {
      this.commandMessage = $r('app.string.steam_workspace_command_empty');
      this.commandDetail = '';
      SteamArkLog.warn('WorkspacePage', 'command rejected; empty input');
      return;
    }

    const stateSnapshot = steamArkStateService.getSnapshot();
    const knownAccountIds: Array<string> = this.collectAccountIds(stateSnapshot);
    const globalConfig = stateSnapshot.globalConfig;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.commandBusy = true;
    SteamArkLog.info('WorkspacePage', 'command execution started; length=' + message.length.toString() +
      ', selectedAccount=' + SteamArkLog.accountId(this.selectedAccountId));
    try {
      const result = await steamArkFarmingService.executeCommand(
        message,
        this.selectedAccountId,
        knownAccountIds,
        globalConfig.commandPrefix,
        false
      );
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      this.applyCommandResult(result);
      SteamArkLog.info('WorkspacePage', 'command execution completed; success=' + String(result.success));
    } catch (_error) {
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      const detail = this.displayError(_error);
      this.commandMessage = detail.length > 0
        ? detail
        : $r('app.string.steam_workspace_command_execution_failed');
      this.commandDetail = '';
      SteamArkLog.error('WorkspacePage', 'command execution failed');
    } finally {
      if (this.isPageActive && this.lifecycleGeneration === lifecycleGeneration) {
        this.commandBusy = false;
      }
    }
  }

  private collectAccountIds(snapshot: SteamArkStateSnapshot): Array<string> {
    const accountIds: Array<string> = [];
    for (let index = 0; index < snapshot.accounts.length; index++) {
      accountIds.push(snapshot.accounts[index].profile.accountId);
    }
    return accountIds;
  }

  private applyCommandResult(result: SteamCommandResult): void {
    if (result.success) {
      if (result.snapshot !== null && result.snapshot.accountId === this.selectedAccountId) {
        this.applyFarmingSnapshot(result.snapshot);
      }
      this.commandMessage = $r('app.string.steam_workspace_command_completed');
      this.commandDetail = this.safeDisplayMessage(result.message);
      SteamArkLog.debug('WorkspacePage', 'command result applied; success=true');
      return;
    }
    this.commandMessage = this.commandErrorMessage(result.errorCode);
    this.commandDetail = this.commandFailureDetail(result.message, result.errorCode);
    SteamArkLog.warn('WorkspacePage', 'command result applied; success=false, errorCode=' + String(result.errorCode));
  }

  private commandFailureDetail(message: string, errorCode: SteamCommandErrorCode): string {
    const detail = this.safeDisplayMessage(message);
    const code = 'code=' + String(errorCode);
    if (detail.length <= 0) {
      return code;
    }
    return detail + ' [' + code + ']';
  }

  private commandErrorMessage(errorCode: SteamCommandErrorCode): ResourceStr {
    switch (errorCode) {
      case SteamCommandErrorCode.EMPTY:
        return $r('app.string.steam_workspace_command_empty');
      case SteamCommandErrorCode.PREFIX_REQUIRED:
        return $r('app.string.steam_workspace_command_prefix_required');
      case SteamCommandErrorCode.UNKNOWN_COMMAND:
        return $r('app.string.steam_workspace_command_unknown');
      case SteamCommandErrorCode.ACCOUNT_REQUIRED:
        return $r('app.string.steam_workspace_command_account_required');
      case SteamCommandErrorCode.ARGUMENTS_INVALID:
        return $r('app.string.steam_workspace_command_arguments_invalid');
      case SteamCommandErrorCode.APP_IDS_REQUIRED:
        return $r('app.string.steam_workspace_command_app_ids_required');
      case SteamCommandErrorCode.APP_ID_INVALID:
        return $r('app.string.steam_workspace_command_app_id_invalid');
      case SteamCommandErrorCode.TOO_MANY_GAMES:
        return $r('app.string.steam_workspace_command_too_many_games');
      case SteamCommandErrorCode.READ_ONLY_COMMAND_REQUIRED:
        return $r('app.string.steam_workspace_command_read_only_required');
      case SteamCommandErrorCode.HIGH_RISK_DISABLED:
        return $r('app.string.steam_workspace_command_high_risk_disabled');
      case SteamCommandErrorCode.EXECUTION_FAILED:
        return $r('app.string.steam_workspace_command_execution_failed');
      case SteamCommandErrorCode.NONE:
      default:
        return $r('app.string.steam_workspace_command_execution_failed');
    }
  }

  private applyFarmingEvent(event: SteamArkFarmingEvent): void {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('WorkspacePage', 'farming event applied; type=' + String(event.type) +
      ', account=' + SteamArkLog.accountId(event.accountId));
    if (event.snapshot !== null && event.accountId === this.selectedAccountId) {
      this.applyFarmingSnapshot(event.snapshot);
    }
    if (event.type === SteamArkFarmingEventType.BADGE_SYNCED &&
      event.accountId === this.selectedAccountId) {
      this.applyCachedBadgeReport(event.accountId);
      this.farmingGamesRefreshing = false;
      if (!this.isCompleteBadgeReport(event.badgeReport)) {
        SteamArkLog.warn('WorkspacePage', 'incomplete badge synchronization report received; account=' +
          SteamArkLog.accountId(event.accountId));
      }
    }
    if (event.type === SteamArkFarmingEventType.ERROR && event.accountId.length === 0) {
      const detail: string = this.safeDisplayMessage(event.message);
      this.actionMessage = detail.length > 0
        ? detail
        : $r('app.string.steam_workspace_status_farming_failed');
    }
  }

  private applyFarmingSnapshot(snapshot: SteamFarmSnapshot | null): void {
    if (snapshot === null) {
      this.farmingState = SteamFarmState.IDLE;
      this.farmingNow = false;
      this.farmingGames = [];
      SteamArkLog.debug('WorkspacePage', 'farming snapshot cleared');
      return;
    }
    this.farmingState = snapshot.state;
    this.farmingNow = snapshot.nowFarming;
    this.farmingGames = snapshot.games.slice();
    this.applyCachedBadgeReport(snapshot.accountId);
    SteamArkLog.debug('WorkspacePage', 'farming state applied; state=' + String(snapshot.state) +
      ', nowFarming=' + String(snapshot.nowFarming));
  }

  private applyCachedBadgeReport(accountId: string): void {
    if (accountId.length <= 0) {
      this.gameBadgeGames = [];
      this.communityBadges = [];
      return;
    }
    const report = steamArkFarmingService.getBadgeSyncReport(accountId);
    this.gameBadgeGames = report === null ? [] : report.games.slice();
    this.communityBadges = report === null ? [] : report.communityBadges.slice();
    if (report === null) {
      this.farmingGamesLoaded = false;
    } else {
      const completeReport: boolean = this.isCompleteBadgeReport(report);
      this.farmingGamesLoaded = completeReport;
      this.farmingGamesRefreshFailed = !completeReport;
    }
    SteamArkLog.debug('WorkspacePage', 'badge cache applied; account=' + SteamArkLog.accountId(accountId) +
      ', games=' + this.gameBadgeGames.length.toString() + ', communityBadges=' +
      this.communityBadges.length.toString());
  }

  private isCompleteBadgeReport(report: SteamBadgeSyncReport | null): boolean {
    return report !== null && report.requestedPageCount > 0 &&
      report.fetchedPageCount >= report.requestedPageCount;
  }

  private resetAccountScopedFarmingResults(): void {
    this.farmingGamesRequestVersion += 1;
    this.refreshingFarmingGamesForAccountId = '';
    this.coordinatorFarmingUpdatedAtEpochSeconds = 0;
    this.farmingGamesRefreshing = false;
    this.farmingGamesLoaded = false;
    this.farmingGamesRefreshFailed = false;
    this.farmingGames = [];
    this.gameBadgeGames = [];
    this.communityBadges = [];
  }

  private isCurrentFarmingScope(
    lifecycleGeneration: number,
    accountId: string,
    accountScopeGeneration: number
  ): boolean {
    return this.isPageActive && this.lifecycleGeneration === lifecycleGeneration &&
      this.accountScopeGeneration === accountScopeGeneration && this.selectedAccountId === accountId;
  }

  private isCurrentFarmingGamesRequest(
    lifecycleGeneration: number,
    accountId: string,
    accountScopeGeneration: number,
    requestVersion: number
  ): boolean {
    return this.isCurrentFarmingScope(lifecycleGeneration, accountId, accountScopeGeneration) &&
      this.farmingGamesRequestVersion === requestVersion;
  }

  private shouldShowStopAction(): boolean {
    return this.selectedAccountId.length > 0 &&
      steamArkFarmingService.hasRuntime(this.selectedAccountId) &&
      this.farmingState !== SteamFarmState.IDLE;
  }

  private networkValue(): ResourceStr {
    return this.selectedAccountId.length > 0
      ? this.sessionLabel(this.sessionState)
      : $r('app.string.steam_workspace_network_unconfigured');
  }

  private sessionLabel(state: SteamSessionState): ResourceStr {
    switch (state) {
      case SteamSessionState.CONNECTING:
        return $r('app.string.steam_accounts_session_connecting');
      case SteamSessionState.CONNECTED:
        return $r('app.string.steam_accounts_session_connected');
      case SteamSessionState.LOGGED_ON:
        return $r('app.string.steam_accounts_session_logged_on');
      case SteamSessionState.NEEDS_QR_SCAN:
        return $r('app.string.steam_accounts_session_qr_scan');
      case SteamSessionState.NEEDS_EMAIL_CODE:
        return $r('app.string.steam_accounts_session_email_code');
      case SteamSessionState.NEEDS_TWO_FACTOR:
        return $r('app.string.steam_accounts_session_two_factor');
      case SteamSessionState.NEEDS_MOBILE_CONFIRMATION:
        return $r('app.string.steam_accounts_session_mobile_confirmation');
      case SteamSessionState.EXPIRED:
        return $r('app.string.steam_accounts_session_expired');
      case SteamSessionState.RECONNECTING:
        return $r('app.string.steam_accounts_session_reconnecting');
      case SteamSessionState.ERROR:
        return $r('app.string.steam_accounts_session_error');
      case SteamSessionState.DISCONNECTED:
      default:
        return $r('app.string.steam_accounts_session_disconnected');
    }
  }

  private displayError(error: Error | Object): string {
    if (!(error instanceof Error)) {
      return '';
    }
    let message = this.safeDisplayMessage(error.message);
    if (error instanceof SteamAuthError) {
      const context = error.kind.toString() +
        (error.stage.length > 0 ? ' / ' + error.stage : '');
      message = message.length > 0 ? message + ' [' + context + ']' : context;
      if (error.code !== 0) {
        message += ' [code=' + error.code.toString() + ']';
      }
    }
    if (message.length > 512) {
      return message.substring(0, 512);
    }
    return message;
  }

  private safeDisplayMessage(message: string): string {
    const normalized = message.replace(/\r/g, ' ').replace(/\n/g, ' ').trim();
    if (normalized.length > 512) {
      return normalized.substring(0, 512);
    }
    return normalized;
  }

  private resolveGridColumns(): number {
    const breakpoint: WidthBreakpoint = this.getUIContext().getWindowWidthBreakpoint();
    switch (breakpoint) {
      case WidthBreakpoint.WIDTH_XL:
      case WidthBreakpoint.WIDTH_LG:
        return 4;
      case WidthBreakpoint.WIDTH_MD:
        return 3;
      case WidthBreakpoint.WIDTH_SM:
      case WidthBreakpoint.WIDTH_XS:
      default:
        return 2;
    }
  }

  private gridTemplate(): string {
    switch (this.gridColumns) {
      case 4:
        return '1fr 1fr 1fr 1fr';
      case 3:
        return '1fr 1fr 1fr';
      case 2:
      default:
        return '1fr 1fr';
    }
  }

  private normalizeSteamUrl(url: string, fallback: string): string {
    const normalized: string = url.trim();
    if (normalized.startsWith('https://') || normalized.startsWith('http://')) {
      return normalized;
    }
    if (normalized.startsWith('//')) {
      return 'https:' + normalized;
    }
    if (normalized.startsWith('/')) {
      return 'https://steamcommunity.com' + normalized;
    }
    return fallback;
  }

  private openExternalUrl(url: string): void {
    const pushed: boolean = SteamArkNavigationBridge.pushHomeRoute(
      SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(url, 'Steam', 'store.steampowered.com')
    );
    if (!pushed) {
      this.actionMessage = $r('app.string.steam_external_open_failed');
      SteamArkLog.warn('WorkspacePage', 'internal store route failed');
    }
  }
}
