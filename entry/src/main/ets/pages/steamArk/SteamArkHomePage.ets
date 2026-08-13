import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  hdsMaterial
} from '@kit.UIDesignKit';
import {
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  ngfSettingsStoreFacade,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import {
  SteamBadgeSyncReport,
  SteamFarmSnapshot,
  SteamFarmState,
  SteamInventoryPage,
  SteamSessionState
} from 'steam_core';
import {
  HarmonySteamNetworkProbe,
  HarmonySteamNetworkProbeOptions,
  SteamArkNetworkProbeResult,
  SteamArkNetworkProbeSiteResult,
  SteamArkNetworkProbeStatus
} from '../../steamAdapters';
import {
  SteamArkFarmingEvent,
  SteamArkFarmingEventListener,
  SteamArkFarmingEventType,
  SteamArkLog,
  SteamArkAccountSnapshot,
  SteamArkAccountSyncSnapshot,
  SteamArkInventorySummary,
  SteamArkSocialSnapshot,
  SteamArkSocialSnapshotListener,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  SteamArkSyncSnapshot,
  SteamArkSyncSnapshotListener,
  SteamArkSyncStage,
  steamArkFarmingService,
  steamArkSocialService,
  steamArkSyncCoordinator,
  steamArkStateService
} from '../../steamServices';
import { SteamArkAccountsPage } from './SteamArkAccountsPage';
import { SteamArkBrowserPage } from './SteamArkBrowserPage';
import { SteamArkInventoryPage } from './SteamArkInventoryPage';
import { SteamArkMessagesPage } from './SteamArkMessagesPage';
import { SteamArkNetworkPage } from './SteamArkNetworkPage';
import { SteamArkTokenPage } from './SteamArkTokenPage';
import { SteamArkDiagnosticsPage } from './SteamArkDiagnosticsPage';
import { SteamArkSettingsPage } from './SteamArkSettingsPage';
import { SteamArkSocialPage } from './SteamArkSocialPage';
import { SteamArkTheme } from './SteamArkTheme';
import { steamArkTabScrollers } from './SteamArkTabScrollers';
import { SteamArkWorkspacePage } from './SteamArkWorkspacePage';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkBrowserRequest, SteamArkMessageNavigationRequest, SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { steamArkFloatingWindowCoordinator } from './SteamArkFloatingWindowCoordinator';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';

class SteamArkHomeTab {
  static readonly OVERVIEW: number = 0;
  static readonly ACCOUNTS: number = 1;
  static readonly FARMING: number = 2;
  static readonly INVENTORY: number = 3;
  static readonly MESSAGES: number = 4;
  static readonly TOKENS: number = 5;
  static readonly SETTINGS: number = 6;
}

class SteamArkHomeCardId {
  static readonly ACTIONS: string = 'actions';
  static readonly ACCOUNTS: string = 'accounts';
  static readonly ASSETS: string = 'assets';
  static readonly FARMING: string = 'farming';
  static readonly SOCIAL: string = 'social';
  static readonly SECURITY: string = 'security';
}

class SteamArkHomeCardDefinition {
  readonly id: string;
  readonly title: ResourceStr;
  readonly icon: Resource;

  constructor(id: string, title: ResourceStr, icon: Resource) {
    this.id = id;
    this.title = title;
    this.icon = icon;
  }
}

class SteamArkHomeAccountSyncStatus {
  readonly accountId: string;
  readonly running: boolean;
  readonly inventoryFailed: boolean;
  readonly farmingFailed: boolean;
  readonly socialFailed: boolean;

  constructor(
    accountId: string,
    running: boolean,
    inventoryFailed: boolean,
    farmingFailed: boolean,
    socialFailed: boolean
  ) {
    this.accountId = accountId;
    this.running = running;
    this.inventoryFailed = inventoryFailed;
    this.farmingFailed = farmingFailed;
    this.socialFailed = socialFailed;
  }
}

const STEAM_ARK_STARTUP_TAB_KEY: string = 'steam_ark_startup_tab_v1';
const STEAM_ARK_HOME_CARDS_KEY: string = 'steam_ark_home_cards_v1';
const STEAM_ARK_OVERVIEW_CACHE_FRESHNESS_SECONDS: number = 300;

@Component
struct SteamArkHomeMetricValue {
  @Prop value: ResourceStr = '';
  @Prop label: ResourceStr = '';
  @Prop isDarkMode: boolean = false;

  build(): void {
    Column({ space: 3 }) {
      Text(this.value)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.label)
        .fontSize(10)
        .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        .maxLines(2)
        .textAlign(TextAlign.Center)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
}

@Component
export struct SteamArkHomePage {
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private selectedTabIndex: number = SteamArkHomeTab.OVERVIEW;
  @State private pressedTabIndex: number = -1;
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private bottomInsetVp: number = 0;
  @State private accountCount: number = 0;
  @State private selectedAccountId: string = '';
  @State private selectedAccountName: string = '';
  @State private sessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  @State private farmingState: SteamFarmState = SteamFarmState.IDLE;
  @State private farmingNow: boolean = false;
  @State private startupTabIndex: number = SteamArkHomeTab.OVERVIEW;
  @State private currentInventoryCount: number = 0;
  @State private currentCardCount: number = 0;
  @State private currentBadgeCount: number = 0;
  @State private currentFarmableGameCount: number = 0;
  @State private currentInventoryKnown: boolean = false;
  @State private currentCardKnown: boolean = false;
  @State private currentBadgeKnown: boolean = false;
  @State private currentFarmableGameKnown: boolean = false;
  @State private currentInventoryFresh: boolean = false;
  @State private currentCardFresh: boolean = false;
  @State private currentBadgeFresh: boolean = false;
  @State private currentFarmableGameFresh: boolean = false;
  @State private allInventoryCount: number = 0;
  @State private allCardCount: number = 0;
  @State private allBadgeCount: number = 0;
  @State private allInventoryKnown: boolean = false;
  @State private allCardKnown: boolean = false;
  @State private allBadgeKnown: boolean = false;
  @State private allInventoryFresh: boolean = false;
  @State private allCardFresh: boolean = false;
  @State private allBadgeFresh: boolean = false;
  @State private unreadMessageCount: number = 0;
  @State private unreadMessageKnown: boolean = false;
  @State private accountSyncStatuses: Array<SteamArkHomeAccountSyncStatus> = [];
  @State private visibleHomeCardIds: Array<string> = [];
  @State private cardManagerVisible: boolean = false;
  @State private stateReady: boolean = false;
  @State private onboardingNetworkRunning: boolean = false;
  @State private onboardingNetworkAttempted: boolean = false;
  @State private onboardingNetworkStatus: SteamArkNetworkProbeStatus = SteamArkNetworkProbeStatus.UNSUPPORTED;
  @State private onboardingNetworkSites: Array<SteamArkNetworkProbeSiteResult> = [];
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly tabsController: HdsTabsController = new HdsTabsController();
  private readonly overviewScroller: Scroller = new Scroller();
  private readonly accountsScroller: Scroller = steamArkTabScrollers.accounts;
  private readonly workspaceScroller: Scroller = steamArkTabScrollers.workspace;
  private readonly inventoryScroller: Scroller = steamArkTabScrollers.inventory;
  private readonly messagesScroller: Scroller = steamArkTabScrollers.messages;
  private readonly tokenScroller: Scroller = steamArkTabScrollers.tokens;
  private readonly settingsScroller: Scroller = steamArkTabScrollers.settings;
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private overviewInventoryRequestAccountId: string = '';
  private overviewBadgeRequestAccountId: string = '';
  private onboardingNetworkProbeVersion: number = 0;
  private readonly homeCards: Array<SteamArkHomeCardDefinition> = [
    new SteamArkHomeCardDefinition(SteamArkHomeCardId.ACTIONS,
      $r('app.string.steam_home_card_actions_title'), $r('sys.symbol.wand_and_stars')),
    new SteamArkHomeCardDefinition(SteamArkHomeCardId.ACCOUNTS,
      $r('app.string.steam_home_card_accounts_title'), $r('sys.symbol.person_2')), 
    new SteamArkHomeCardDefinition(SteamArkHomeCardId.ASSETS,
      $r('app.string.steam_home_card_assets_title'), $r('sys.symbol.archivebox')), 
    new SteamArkHomeCardDefinition(SteamArkHomeCardId.FARMING,
      $r('app.string.steam_home_card_farming_title'), $r('sys.symbol.play_round_triangle_fill')), 
    new SteamArkHomeCardDefinition(SteamArkHomeCardId.SOCIAL,
      $r('app.string.steam_home_card_social_title'), $r('sys.symbol.message_fill')), 
    new SteamArkHomeCardDefinition(SteamArkHomeCardId.SECURITY,
      $r('app.string.steam_home_card_security_title'), $r('sys.symbol.lock_shield'))
  ];
  private readonly socialListener: SteamArkSocialSnapshotListener = (snapshot: SteamArkSocialSnapshot): void => {
    if (this.isPageActive) {
      this.applySocialSnapshot(snapshot);
    }
  };

  private loadStartupTabPreference(): void {
    const storedIndex: number = ngfSettingsStoreFacade.getNumber(
      STEAM_ARK_STARTUP_TAB_KEY,
      SteamArkHomeTab.OVERVIEW
    );
    const normalizedIndex: number = Number.isSafeInteger(storedIndex) &&
      storedIndex >= SteamArkHomeTab.OVERVIEW && storedIndex <= SteamArkHomeTab.SETTINGS
      ? storedIndex
      : SteamArkHomeTab.OVERVIEW;
    this.startupTabIndex = normalizedIndex;
    this.selectedTabIndex = normalizedIndex;
    this.tabsController.changeIndex(normalizedIndex);
  }

  private loadHomeCardPreference(): void {
    const defaultValue: string = SteamArkHomeCardId.ACTIONS + ',' +
      SteamArkHomeCardId.ACCOUNTS + ',' + SteamArkHomeCardId.ASSETS + ',' +
      SteamArkHomeCardId.FARMING + ',' + SteamArkHomeCardId.SOCIAL + ',' +
      SteamArkHomeCardId.SECURITY;
    const stored: string = ngfSettingsStoreFacade.getString(STEAM_ARK_HOME_CARDS_KEY, defaultValue);
    const values: Array<string> = stored.split(',');
    const normalized: Array<string> = [];
    for (let index: number = 0; index < values.length; index++) {
      const value: string = values[index].trim();
      if (this.findHomeCard(value) !== null && !normalized.includes(value)) {
        normalized.push(value);
      }
    }
    if (normalized.length <= 0) {
      for (let index: number = 0; index < this.homeCards.length; index++) {
        normalized.push(this.homeCards[index].id);
      }
    }
    this.visibleHomeCardIds = normalized;
  }

  private persistHomeCardPreference(): void {
    ngfSettingsStoreFacade.setString(STEAM_ARK_HOME_CARDS_KEY, this.visibleHomeCardIds.join(','));
  }
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('HomePage', 'state snapshot received; accounts=' + snapshot.accounts.length.toString());
    this.applyStateSnapshot(snapshot);
  };
  private readonly syncListener: SteamArkSyncSnapshotListener = (snapshot: SteamArkSyncSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    this.applySyncSnapshot(snapshot);
  };
  private readonly farmingListener: SteamArkFarmingEventListener = (event: SteamArkFarmingEvent): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('HomePage', 'farming event received; type=' + String(event.type));
    if (event.accountId === this.selectedAccountId && event.snapshot !== null) {
      this.applyFarmingSnapshot(event.snapshot);
    }
    if (event.type === SteamArkFarmingEventType.BADGE_SYNCED) {
      this.applyCollectionMetrics(steamArkStateService.getSnapshot());
    }
  };

  aboutToAppear(): void {
    SteamArkLog.lifecycle('HomePage', 'aboutToAppear');
    this.lifecycleGeneration += 1;
    this.isPageActive = true;
    const lifecycleGeneration: number = this.lifecycleGeneration;
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
    SteamArkPageWindowSupport.loadDynamicBottomInset(
      this.getUIContext(),
      0,
      (inset: number): void => {
        if (this.isPageActive && this.lifecycleGeneration === lifecycleGeneration) {
          this.bottomInsetVp = inset;
        }
      }
    );
    SteamArkPageWindowSupport.apply(SteamArkPageWindowName.HOME);
    SteamArkNavigationBridge.bindHomeStack(this.pathStack);
    steamArkStateService.subscribe('SteamArkHomePage', this.stateListener);
    steamArkSyncCoordinator.subscribe('SteamArkHomePage', this.syncListener);
    steamArkFarmingService.subscribe('SteamArkHomePage', this.farmingListener);
    steamArkSocialService.subscribe('SteamArkHomePage', this.socialListener);
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    this.loadStartupTabPreference();
    this.loadHomeCardPreference();
    this.applySocialSnapshot(steamArkSocialService.restore(this.selectedAccountId));
    this.applyFarmingSnapshot(steamArkFarmingService.getSnapshot(this.selectedAccountId));
    void this.initializeStateService();
    void steamArkFloatingWindowCoordinator.showStatusBall();
    this.ensureOverviewInventory();
    this.ensureOverviewBadges();
    this.startOnboardingNetworkProbeIfNeeded();
    SteamArkLog.info('HomePage', 'subscriptions registered; selectedAccount=' +
      SteamArkLog.accountId(this.selectedAccountId));
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle('HomePage', 'aboutToDisappear');
    this.isPageActive = false;
    this.lifecycleGeneration += 1;
    this.onboardingNetworkProbeVersion += 1;
    this.onboardingNetworkRunning = false;
    SteamArkNavigationBridge.unbindHomeStack(this.pathStack);
    steamArkStateService.unsubscribe('SteamArkHomePage');
    steamArkSyncCoordinator.unsubscribe('SteamArkHomePage');
    steamArkFarmingService.unsubscribe('SteamArkHomePage');
    steamArkSocialService.unsubscribe('SteamArkHomePage');
  }

  build() {
    HdsNavigation(this.pathStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        SteamArkProfileBackground()

        HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
          TabContent() {
            Scroll(this.overviewScroller) {
              this.buildOverviewTab()
            }
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .backgroundColor($r('app.color.background_transparent'))
          }
          .tabBar(this.buildTabItem($r('app.string.steam_home_tab_overview'), $r('sys.symbol.house'), SteamArkHomeTab.OVERVIEW))
          .opacity(this.selectedTabIndex === SteamArkHomeTab.OVERVIEW ? 1 : 0.72)
          .animation({ duration: SteamArkExperiencePolicy.CONTENT_ENTER_DURATION, curve: Curve.EaseOut })

          TabContent() {
            SteamArkAccountsPage({
              embedded: true,
              contentTopInsetVp: this.topInsetVp
            })
          }
          .width('100%')
          .height('100%')
          .tabBar(this.buildTabItem($r('app.string.steam_home_tab_accounts'), $r('sys.symbol.person_2'), SteamArkHomeTab.ACCOUNTS))
          .opacity(this.selectedTabIndex === SteamArkHomeTab.ACCOUNTS ? 1 : 0.72)
          .animation({ duration: SteamArkExperiencePolicy.CONTENT_ENTER_DURATION, curve: Curve.EaseOut })

          TabContent() {
            SteamArkWorkspacePage({
              embedded: true,
              contentTopInsetVp: this.topInsetVp
            })
          }
          .width('100%')
          .height('100%')
          .tabBar(this.buildTabItem($r('app.string.steam_home_tab_farming'), $r('sys.symbol.play_round_triangle_fill'), SteamArkHomeTab.FARMING))
          .opacity(this.selectedTabIndex === SteamArkHomeTab.FARMING ? 1 : 0.72)
          .animation({ duration: SteamArkExperiencePolicy.CONTENT_ENTER_DURATION, curve: Curve.EaseOut })

          TabContent() {
            SteamArkInventoryPage({
              embedded: true,
              contentTopInsetVp: this.topInsetVp
            })
          }
          .width('100%')
          .height('100%')
          .tabBar(this.buildTabItem($r('app.string.steam_home_tab_inventory'), $r('sys.symbol.archivebox'), SteamArkHomeTab.INVENTORY))
          .opacity(this.selectedTabIndex === SteamArkHomeTab.INVENTORY ? 1 : 0.72)
          .animation({ duration: SteamArkExperiencePolicy.CONTENT_ENTER_DURATION, curve: Curve.EaseOut })

          TabContent() {
            SteamArkMessagesPage({
              embedded: true,
              contentTopInsetVp: this.topInsetVp
            })
          }
          .width('100%')
          .height('100%')
          .tabBar(this.buildTabItem($r('app.string.steam_home_tab_messages'), $r('sys.symbol.bell'), SteamArkHomeTab.MESSAGES))
          .opacity(this.selectedTabIndex === SteamArkHomeTab.MESSAGES ? 1 : 0.72)
          .animation({ duration: SteamArkExperiencePolicy.CONTENT_ENTER_DURATION, curve: Curve.EaseOut })

          TabContent() {
            SteamArkTokenPage({
              embedded: true,
              contentTopInsetVp: this.topInsetVp
            })
          }
          .width('100%')
          .height('100%')
          .tabBar(this.buildTabItem($r('app.string.steam_home_tab_tokens'), $r('sys.symbol.key_fill'), SteamArkHomeTab.TOKENS))
          .opacity(this.selectedTabIndex === SteamArkHomeTab.TOKENS ? 1 : 0.72)
          .animation({ duration: SteamArkExperiencePolicy.CONTENT_ENTER_DURATION, curve: Curve.EaseOut })

          TabContent() {
            SteamArkSettingsPage({
              embedded: true,
              contentTopInsetVp: this.topInsetVp
            })
          }
          .width('100%')
          .height('100%')
          .tabBar(this.buildTabItem($r('app.string.steam_home_tab_settings'), $r('sys.symbol.gearshape'), SteamArkHomeTab.SETTINGS))
          .opacity(this.selectedTabIndex === SteamArkHomeTab.SETTINGS ? 1 : 0.72)
          .animation({ duration: SteamArkExperiencePolicy.CONTENT_ENTER_DURATION, curve: Curve.EaseOut })
        }
        .width('100%')
        .height('100%')
        .barMode(BarMode.Fixed)
        .barOverlap(true)
        .barFloatingStyle({
          adaptToHandedness: true,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
          },
          thermoCtrl: true,
          barOpacity: 0.96,
          barBottomMargin: this.bottomInsetVp
        })
        .scrollable(true)
        .onChange((index: number): void => {
          this.selectedTabIndex = index;
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(SteamArkTheme.background(this.isDarkMode))
    }
    .titleBar(NGFHdsTitleBarOptionsFactory.buildOverContentWithTitleColors(
      $r('app.string.steam_home_title'),
      $r('app.string.steam_home_subtitle'),
      $r('app.color.background_transparent'),
      SteamArkTheme.textPrimary(this.isDarkMode),
      SteamArkTheme.textSecondary(this.isDarkMode),
      true,
      false
    ))
    .backgroundImage(this.profileBackgroundUrl)
    .backgroundImageSize(ImageSize.Cover)
    .titleMode(HdsNavigationTitleMode.FREE)
    .hideBackButton(true)
    .navDestination(this.buildNavDestination)
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .width('100%')
    .height('100%')
    .backgroundColor(SteamArkTheme.background(this.isDarkMode))
    .bindToScrollable([
      this.overviewScroller,
      this.accountsScroller,
      this.workspaceScroller,
      this.inventoryScroller,
      this.messagesScroller,
      this.tokenScroller,
      this.settingsScroller
    ])
  }

  @Builder
  private buildTabItem(title: ResourceStr, icon: Resource, tabIndex: number): void {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(this.selectedTabIndex === tabIndex ? 23 : 21)
        .fontWeight(this.selectedTabIndex === tabIndex ? FontWeight.Bold : FontWeight.Normal)
        .fontColor([this.selectedTabIndex === tabIndex
          ? SteamArkTheme.accent(this.isDarkMode)
          : SteamArkTheme.textSecondary(this.isDarkMode)])
      Text(title)
        .fontSize(11)
        .fontColor(this.selectedTabIndex === tabIndex
          ? SteamArkTheme.textPrimary(this.isDarkMode)
          : SteamArkTheme.textSecondary(this.isDarkMode))
        .fontWeight(this.selectedTabIndex === tabIndex ? FontWeight.Medium : FontWeight.Normal)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .scale(this.pressedTabIndex === tabIndex ? { x: 0.92, y: 0.92 } : { x: 1, y: 1 })
    .opacity(this.pressedTabIndex === tabIndex ? 0.82 : 1)
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressedTabIndex = tabIndex;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedTabIndex = -1;
        if (event.type === TouchType.Up) {
          this.selectTab(tabIndex);
        }
      }
    })
  }

  private selectTab(tabIndex: number): void {
    this.tabsController.changeIndex(tabIndex);
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
      this.selectedTabIndex = tabIndex;
    });
    SteamArkLog.info('HomePage', 'tab selected; index=' + tabIndex.toString());
  }

  @Builder
  private buildOverviewTab(): void {
    Column({ space: 12 }) {
      if (!this.stateReady) {
        SteamArkStateUnavailableCard({
          isDarkMode: this.isDarkMode,
          useSysMat: this.useSysMat
        })
      } else {
        if (this.accountCount <= 0) {
          this.buildNoAccountHome()
        } else {
          this.buildOverviewHeader()
          this.buildCardManagerBar()
          ForEach(this.visibleCardDefinitions(), (card: SteamArkHomeCardDefinition) => {
            this.buildHomeCard(card)
          }, (card: SteamArkHomeCardDefinition): string => card.id)
          if (this.cardManagerVisible) {
            this.buildCardManager()
          }
        }
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: this.topInsetVp, bottom: 84 })
  }

  @Builder
  private buildNoAccountHome(): void {
    Column({ space: 6 }) {
      Text($r('app.string.steam_home_onboarding_title'))
        .width('100%')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_home_onboarding_subtitle'))
        .width('100%')
        .fontSize(14)
        .lineHeight(21)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 6 })

    this.buildOnboardingNetworkPanel()
    this.buildOnboardingLoginPanel()
    this.buildOnboardingStepsPanel()
    this.buildOnboardingSafetyPanel()
  }

  @Builder
  private buildOnboardingNetworkPanel(): void {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        SymbolGlyph(this.onboardingNetworkIcon())
          .fontSize(22)
          .fontColor([this.onboardingNetworkColor()])
        Column({ space: 3 }) {
          Text($r('app.string.steam_home_onboarding_network_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text(this.onboardingNetworkStatusText())
            .fontSize(12)
            .fontColor(this.onboardingNetworkColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.onboardingNetworkRunning) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(SteamArkTheme.accentCyan(this.isDarkMode))
        }
      }
      .width('100%')

      Text($r('app.string.steam_home_onboarding_network_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))

      Row({ space: 8 }) {
        SteamArkHomeMetricValue({
          value: this.onboardingNetworkAvailabilityMetric(),
          label: $r('app.string.steam_home_onboarding_network_available'),
          isDarkMode: this.isDarkMode
        })
        SteamArkHomeMetricValue({
          value: this.onboardingNetworkAverageLatency(),
          label: $r('app.string.steam_home_onboarding_network_latency'),
          isDarkMode: this.isDarkMode
        })
      }
      .width('100%')

      if (this.onboardingNetworkSites.length > 0) {
        Column({ space: 0 }) {
          ForEach(this.onboardingNetworkSites, (site: SteamArkNetworkProbeSiteResult): void => {
            this.buildOnboardingNetworkSite(site)
          }, (site: SteamArkNetworkProbeSiteResult): string => site.targetId)
        }
        .width('100%')
      }

      if (this.onboardingNetworkAttempted &&
        this.onboardingNetworkStatus !== SteamArkNetworkProbeStatus.SUCCESS) {
        Text($r('app.string.steam_home_onboarding_network_failed_hint'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.warning(this.isDarkMode))
      }

      Row({ space: 8 }) {
        this.buildOnboardingActionButton($r('sys.symbol.arrow_clockwise'),
          $r('app.string.steam_home_onboarding_network_refresh'), 1)
        this.buildOnboardingActionButton($r('sys.symbol.gearshape'),
          $r('app.string.steam_home_onboarding_network_settings'), 2)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PROMINENT_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
  }

  @Builder
  private buildOnboardingNetworkSite(site: SteamArkNetworkProbeSiteResult): void {
    Row({ space: 10 }) {
      SymbolGlyph(this.onboardingSiteIcon(site))
        .fontSize(17)
        .fontColor([this.onboardingSiteColor(site)])
      Column({ space: 2 }) {
        Text(this.onboardingNetworkSiteName(site.targetId))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text(this.onboardingSiteStatusText(site))
          .fontSize(11)
          .fontColor(this.onboardingSiteColor(site))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(site.durationMs > 0 ? site.durationMs.toString() + ' ms' : '--')
        .fontSize(12)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .width('100%')
    .constraintSize({ minHeight: 48 })
    .padding({ left: 4, right: 4 })
    .border({ width: { bottom: 1 }, color: SteamArkTheme.divider(this.isDarkMode) })
  }

  @Builder
  private buildOnboardingLoginPanel(): void {
    Column({ space: 12 }) {
      Text($r('app.string.steam_home_onboarding_login_title'))
        .width('100%')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_home_onboarding_login_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      this.buildOnboardingInfoRow($r('sys.symbol.qrcode'),
        $r('app.string.steam_home_onboarding_qr_title'),
        $r('app.string.steam_home_onboarding_qr_desc'))
      this.buildOnboardingInfoRow($r('sys.symbol.lock_shield'),
        $r('app.string.steam_home_onboarding_password_title'),
        $r('app.string.steam_home_onboarding_password_desc'))
      this.buildOnboardingInfoRow($r('sys.symbol.doc_text'),
        $r('app.string.steam_home_onboarding_mafile_title'),
        $r('app.string.steam_home_onboarding_mafile_desc'))
      Button() {
        Row({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.person_2'))
            .fontSize(17)
            .fontColor([SteamArkTheme.onAccent(this.isDarkMode)])
          Text($r('app.string.steam_home_onboarding_add_account'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
        }
      }
      .width('100%')
      .height(44)
      .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
      .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
      .onClick((): void => {
        this.selectTab(SteamArkHomeTab.ACCOUNTS)
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildOnboardingStepsPanel(): void {
    Column({ space: 12 }) {
      Text($r('app.string.steam_home_onboarding_steps_title'))
        .width('100%')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      this.buildOnboardingStep(1, $r('app.string.steam_home_onboarding_step_sync_title'),
        $r('app.string.steam_home_onboarding_step_sync_desc'))
      this.buildOnboardingStep(2, $r('app.string.steam_home_onboarding_step_inventory_title'),
        $r('app.string.steam_home_onboarding_step_inventory_desc'))
      this.buildOnboardingStep(3, $r('app.string.steam_home_onboarding_step_social_title'),
        $r('app.string.steam_home_onboarding_step_social_desc'))
      this.buildOnboardingStep(4, $r('app.string.steam_home_onboarding_step_token_title'),
        $r('app.string.steam_home_onboarding_step_token_desc'))
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildOnboardingSafetyPanel(): void {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(22)
        .fontColor([SteamArkTheme.warning(this.isDarkMode)])
      Column({ space: 4 }) {
        Text($r('app.string.steam_home_onboarding_safety_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_home_onboarding_safety_desc'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildOnboardingInfoRow(icon: Resource, title: ResourceStr, detail: ResourceStr): void {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
      Column({ space: 4 }) {
        Text(title)
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text(detail)
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 8, bottom: 10 })
    .border({ width: { bottom: 1 }, color: SteamArkTheme.divider(this.isDarkMode) })
  }

  @Builder
  private buildOnboardingStep(step: number, title: ResourceStr, detail: ResourceStr): void {
    Row({ space: 12 }) {
      Text(step.toString())
        .width(28)
        .height(28)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
        .textAlign(TextAlign.Center)
        .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
        .borderRadius(14)
      Column({ space: 4 }) {
        Text(title)
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text(detail)
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  @Builder
  private buildOnboardingActionButton(icon: Resource, title: ResourceStr, action: number): void {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph(icon)
          .fontSize(15)
          .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
        Text(title)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
    }
    .layoutWeight(1)
    .height(40)
    .backgroundColor(SteamArkTheme.surfaceControl(this.isDarkMode))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .enabled(action !== 1 || !this.onboardingNetworkRunning)
    .opacity(action === 1 && this.onboardingNetworkRunning ? 0.55 : 1)
    .onClick((): void => {
      if (action === 1) {
        void this.runOnboardingNetworkProbe()
      } else {
        this.selectTab(SteamArkHomeTab.SETTINGS)
      }
    })
  }

  @Builder
  private buildCardManagerBar(): void {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text($r('app.string.steam_home_cards_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_home_cards_desc'))
          .fontSize(11)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph(this.cardManagerVisible
          ? $r('sys.symbol.checkmark') : $r('sys.symbol.slider_horizontal_2'))
          .fontSize(19)
          .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
      }
      .width(40)
      .height(40)
      .padding(0)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .accessibilityText($r('app.string.steam_home_cards_manage'))
      .onClick((): void => {
        this.cardManagerVisible = !this.cardManagerVisible;
      })
    }
    .width('100%')
    .padding({ left: 14, right: 8, top: 10, bottom: 10 })
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildHomeCard(card: SteamArkHomeCardDefinition): void {
    if (card.id === SteamArkHomeCardId.ACTIONS) {
      this.buildActionsCard(card)
    } else if (card.id === SteamArkHomeCardId.ACCOUNTS) {
      this.buildAccountsCard(card)
    } else if (card.id === SteamArkHomeCardId.ASSETS) {
      this.buildAssetsCard(card)
    } else if (card.id === SteamArkHomeCardId.FARMING) {
      this.buildFarmingCard(card)
    } else if (card.id === SteamArkHomeCardId.SOCIAL) {
      this.buildSocialCard(card)
    } else if (card.id === SteamArkHomeCardId.SECURITY) {
      this.buildSecurityCard(card)
    }
  }

  @Builder
  private buildCardHeader(card: SteamArkHomeCardDefinition): void {
    Row({ space: 9 }) {
      SymbolGlyph(card.icon)
        .fontSize(20)
        .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
      Text(card.title)
        .layoutWeight(1)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(15)
        .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
    }
    .width('100%')
  }

  @Builder
  private buildActionsCard(card: SteamArkHomeCardDefinition): void {
    Column({ space: 12 }) {
      this.buildCardHeader(card)
      Text(this.actionSummary())
        .width('100%')
        .fontSize(13)
        .lineHeight(19)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Row({ space: 8 }) {
        this.buildCardActionButton($r('sys.symbol.person_2'), $r('app.string.steam_home_card_action_accounts'), SteamArkHomeTab.ACCOUNTS)
        this.buildCardActionButton($r('sys.symbol.archivebox'), $r('app.string.steam_home_card_action_inventory'), SteamArkHomeTab.INVENTORY)
        this.buildCardActionButton($r('sys.symbol.bell'), $r('app.string.steam_home_card_action_messages'), SteamArkHomeTab.MESSAGES)
      }
      .width('100%')
    }
    .onClick((): void => {
      this.selectTab(SteamArkHomeTab.ACCOUNTS)
    })
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PROMINENT_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
  }

  @Builder
  private buildAccountsCard(card: SteamArkHomeCardDefinition): void {
    Column({ space: 10 }) {
      this.buildCardHeader(card)
      Row({ space: 8 }) {
        SteamArkHomeMetricValue({
          value: this.accountCount.toString(),
          label: $r('app.string.steam_home_card_accounts_metric'),
          isDarkMode: this.isDarkMode
        })
        SteamArkHomeMetricValue({
          value: this.selectedAccountName.length > 0 ? this.selectedAccountName : '--',
          label: $r('app.string.steam_home_card_current_account_metric'),
          isDarkMode: this.isDarkMode
        })
        SteamArkHomeMetricValue({
          value: this.sessionMetric(),
          label: $r('app.string.steam_home_card_session_metric'),
          isDarkMode: this.isDarkMode
        })
      }
      .width('100%')
    }
    .onClick((): void => {
      this.selectTab(SteamArkHomeTab.ACCOUNTS)
    })
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PROMINENT_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
  }

  @Builder
  private buildAssetsCard(card: SteamArkHomeCardDefinition): void {
    Column({ space: 10 }) {
      this.buildCardHeader(card)
      Row({ space: 8 }) {
        SteamArkHomeMetricValue({
          value: this.metricValue(this.currentInventoryCount, this.currentInventoryKnown,
            SteamArkSyncStage.INVENTORY, true),
          label: $r('app.string.steam_home_card_current_inventory_metric'),
          isDarkMode: this.isDarkMode
        })
        SteamArkHomeMetricValue({
          value: this.metricValue(this.currentCardCount, this.currentCardKnown,
            SteamArkSyncStage.INVENTORY, true),
          label: $r('app.string.steam_home_card_current_cards_metric'),
          isDarkMode: this.isDarkMode
        })
        SteamArkHomeMetricValue({
          value: this.metricValue(this.currentBadgeCount, this.currentBadgeKnown,
            SteamArkSyncStage.FARMING, true),
          label: $r('app.string.steam_home_card_current_badges_metric'),
          isDarkMode: this.isDarkMode
        })
      }
      .width('100%')
      Row({ space: 8 }) {
        SteamArkHomeMetricValue({
          value: this.metricValue(this.allInventoryCount, this.allInventoryKnown,
            SteamArkSyncStage.INVENTORY, false),
          label: $r('app.string.steam_home_card_all_inventory_metric'),
          isDarkMode: this.isDarkMode
        })
        SteamArkHomeMetricValue({
          value: this.metricValue(this.allCardCount, this.allCardKnown,
            SteamArkSyncStage.INVENTORY, false),
          label: $r('app.string.steam_home_card_all_cards_metric'),
          isDarkMode: this.isDarkMode
        })
        SteamArkHomeMetricValue({
          value: this.metricValue(this.allBadgeCount, this.allBadgeKnown,
            SteamArkSyncStage.FARMING, false),
          label: $r('app.string.steam_home_card_all_badges_metric'),
          isDarkMode: this.isDarkMode
        })
      }
      .width('100%')
      Text(this.allAssetsSummary())
        .fontSize(11)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .width('100%')
    }
    .onClick((): void => {
      this.selectTab(SteamArkHomeTab.INVENTORY)
    })
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PROMINENT_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
  }

  @Builder
  private buildFarmingCard(card: SteamArkHomeCardDefinition): void {
    Column({ space: 10 }) {
      this.buildCardHeader(card)
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.play_round_triangle_fill'))
          .fontSize(30)
          .fontColor([this.farmingColor()])
        Column({ space: 3 }) {
          Text(this.farmingMetric())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text(this.farmingSummary())
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Column({ space: 2 }) {
          Text(this.metricValue(this.currentFarmableGameCount, this.currentFarmableGameKnown,
            SteamArkSyncStage.FARMING, true))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text($r('app.string.steam_home_card_farming_candidate_metric'))
            .fontSize(10)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
            .maxLines(2)
            .textAlign(TextAlign.Center)
        }
        .width(72)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
    }
    .onClick((): void => {
      this.selectTab(SteamArkHomeTab.FARMING)
    })
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PROMINENT_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
  }

  @Builder
  private buildSocialCard(card: SteamArkHomeCardDefinition): void {
    Column({ space: 10 }) {
      this.buildCardHeader(card)
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.message_fill'))
          .fontSize(28)
          .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
        Column({ space: 3 }) {
          Text(this.metricValue(this.unreadMessageCount, this.unreadMessageKnown,
            SteamArkSyncStage.SOCIAL, true))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text($r('app.string.steam_home_card_unread_messages'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text($r('app.string.steam_home_card_social_action'))
          .fontSize(12)
          .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
      }
      .width('100%')
    }
    .onClick((): void => {
      this.selectTab(SteamArkHomeTab.MESSAGES)
    })
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PROMINENT_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
  }

  @Builder
  private buildSecurityCard(card: SteamArkHomeCardDefinition): void {
    Column({ space: 10 }) {
      this.buildCardHeader(card)
      Row({ space: 10 }) {
        SymbolGlyph(this.statusIcon())
          .fontSize(28)
          .fontColor([this.statusColor()])
        Column({ space: 3 }) {
          Text(this.statusText())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.statusColor())
          Text($r('app.string.steam_home_card_security_desc'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
    }
    .onClick((): void => {
      SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.SETTINGS, null)
    })
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PROMINENT_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
  }

  @Builder
  private buildCardActionButton(icon: Resource, title: ResourceStr, tabIndex: number): void {
    Button() {
      Row({ space: 5 }) {
        SymbolGlyph(icon)
          .fontSize(14)
          .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
        Text(title)
          .fontSize(11)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
    }
    .layoutWeight(1)
    .height(34)
    .padding({ left: 4, right: 4 })
    .backgroundColor(SteamArkTheme.surfaceControl(this.isDarkMode))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .onClick((): void => {
      this.selectTab(tabIndex)
    })
  }

  @Builder
  private buildCardManager(): void {
    Column({ space: 8 }) {
      Text($r('app.string.steam_home_cards_manage_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_home_cards_manage_desc'))
        .fontSize(11)
        .lineHeight(16)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      ForEach(this.homeCards, (card: SteamArkHomeCardDefinition) => {
        this.buildCardManagerRow(card)
      }, (card: SteamArkHomeCardDefinition): string => card.id)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildCardManagerRow(card: SteamArkHomeCardDefinition): void {
    Row({ space: 8 }) {
      SymbolGlyph(card.icon)
        .fontSize(17)
        .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
      Text(card.title)
        .layoutWeight(1)
        .fontSize(13)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph(this.isCardVisible(card.id)
          ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(20)
          .fontColor([this.isCardVisible(card.id)
            ? SteamArkTheme.accentCyan(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode)])
      }
      .width(34)
      .height(34)
      .padding(0)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .accessibilityText($r('app.string.steam_home_cards_toggle'))
      .onClick((): void => {
        this.toggleHomeCard(card.id)
      })
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.chevron_up'))
          .fontSize(15)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      }
      .width(30)
      .height(30)
      .padding(0)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .enabled(this.visibleHomeCardIds.indexOf(card.id) > 0)
      .accessibilityText($r('app.string.steam_home_cards_move_up'))
      .onClick((): void => {
        this.moveHomeCard(card.id, -1)
      })
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(15)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      }
      .width(30)
      .height(30)
      .padding(0)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .enabled(this.visibleHomeCardIds.indexOf(card.id) >= 0 &&
        this.visibleHomeCardIds.indexOf(card.id) < this.visibleHomeCardIds.length - 1)
      .accessibilityText($r('app.string.steam_home_cards_move_down'))
      .onClick((): void => {
        this.moveHomeCard(card.id, 1)
      })
    }
    .width('100%')
    .height(42)
  }

  private visibleCardDefinitions(): Array<SteamArkHomeCardDefinition> {
    const result: Array<SteamArkHomeCardDefinition> = [];
    for (let index: number = 0; index < this.visibleHomeCardIds.length; index++) {
      const card: SteamArkHomeCardDefinition | null = this.findHomeCard(this.visibleHomeCardIds[index]);
      if (card !== null) {
        result.push(card);
      }
    }
    return result;
  }

  private findHomeCard(id: string): SteamArkHomeCardDefinition | null {
    for (let index: number = 0; index < this.homeCards.length; index++) {
      if (this.homeCards[index].id === id) {
        return this.homeCards[index];
      }
    }
    return null;
  }

  private isCardVisible(id: string): boolean {
    return this.visibleHomeCardIds.includes(id);
  }

  private toggleHomeCard(id: string): void {
    const currentIndex: number = this.visibleHomeCardIds.indexOf(id);
    if (currentIndex >= 0) {
      if (this.visibleHomeCardIds.length <= 1) {
        return;
      }
      this.visibleHomeCardIds.splice(currentIndex, 1);
    } else {
      this.visibleHomeCardIds.push(id);
    }
    this.visibleHomeCardIds = this.visibleHomeCardIds.slice();
    this.persistHomeCardPreference();
  }

  private moveHomeCard(id: string, offset: number): void {
    const currentIndex: number = this.visibleHomeCardIds.indexOf(id);
    const targetIndex: number = currentIndex + offset;
    if (currentIndex < 0 || targetIndex < 0 || targetIndex >= this.visibleHomeCardIds.length) {
      return;
    }
    const movingId: string = this.visibleHomeCardIds[currentIndex];
    this.visibleHomeCardIds[currentIndex] = this.visibleHomeCardIds[targetIndex];
    this.visibleHomeCardIds[targetIndex] = movingId;
    this.visibleHomeCardIds = this.visibleHomeCardIds.slice();
    this.persistHomeCardPreference();
  }

  private actionSummary(): ResourceStr {
    if (this.selectedAccountId.length <= 0) {
      return $r('app.string.steam_home_card_actions_no_account');
    }
    if (this.sessionState !== SteamSessionState.LOGGED_ON) {
      return $r('app.string.steam_home_card_actions_session');
    }
    if (!this.unreadMessageKnown) {
      return $r('app.string.steam_home_card_actions_social_syncing');
    }
    if (this.unreadMessageCount > 0) {
      return $r('app.string.steam_home_card_actions_messages');
    }
    if (this.farmingNow) {
      return $r('app.string.steam_home_card_actions_farming');
    }
    return $r('app.string.steam_home_card_actions_ready');
  }

  private farmingSummary(): ResourceStr {
    if (this.farmingNow) {
      return $r('app.string.steam_home_card_farming_running');
    }
    if (!this.currentFarmableGameKnown) {
      return $r('app.string.steam_home_card_farming_syncing');
    }
    if (!this.currentFarmableGameFresh) {
      return this.hasMetricSyncFailure(SteamArkSyncStage.FARMING, true)
        ? $r('app.string.steam_home_card_farming_refresh_failed')
        : $r('app.string.steam_home_card_farming_cached');
    }
    return this.currentFarmableGameCount > 0
      ? $r('app.string.steam_home_card_farming_available')
      : $r('app.string.steam_home_card_farming_empty');
  }

  private allAssetsSummary(): ResourceStr {
    if (!this.currentInventoryKnown || !this.currentCardKnown || !this.currentBadgeKnown) {
      return $r('app.string.steam_home_card_assets_syncing');
    }
    if (!this.allInventoryKnown || !this.allCardKnown || !this.allBadgeKnown) {
      return $r('app.string.steam_home_card_assets_partial');
    }
    if (!this.currentInventoryFresh || !this.currentCardFresh || !this.currentBadgeFresh ||
      !this.allInventoryFresh || !this.allCardFresh || !this.allBadgeFresh) {
      return this.hasMetricSyncFailure(SteamArkSyncStage.INVENTORY, false) ||
        this.hasMetricSyncFailure(SteamArkSyncStage.FARMING, false)
        ? $r('app.string.steam_home_card_assets_refresh_failed')
        : $r('app.string.steam_home_card_assets_cached');
    }
    return $r('app.string.steam_home_card_assets_summary');
  }

  private metricValue(
    value: number,
    isKnown: boolean,
    stage: SteamArkSyncStage,
    currentAccountOnly: boolean
  ): ResourceStr {
    if (isKnown) {
      return value.toString();
    }
    if (this.isMetricSynchronizing(currentAccountOnly)) {
      return $r('app.string.steam_home_metric_syncing');
    }
    if (this.hasMetricSyncFailure(stage, currentAccountOnly)) {
      return $r('app.string.steam_home_metric_sync_failed');
    }
    return $r('app.string.steam_home_metric_not_synced');
  }

  private applySocialSnapshot(snapshot: SteamArkSocialSnapshot): void {
    if (snapshot.accountId !== this.selectedAccountId) {
      return;
    }
    let count: number = 0;
    for (let index: number = 0; index < snapshot.sessions.length; index++) {
      count += snapshot.sessions[index].unreadCount;
    }
    this.unreadMessageCount = count;
    this.unreadMessageKnown = this.hasFreshOverviewData(snapshot.updatedAtEpochSeconds);
  }

  @Builder
  private buildOverviewHeader(): void {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column() {}
            .width(52)
            .height(52)
            .borderRadius(26)
            .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
            .opacity(0.18)
          SymbolGlyph($r('sys.symbol.gamecontroller'))
            .fontSize(28)
            .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
        }
        Column({ space: 4 }) {
          Text($r('app.string.steam_home_overview_title'))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text($r('app.string.steam_home_overview_desc'))
            .fontSize(12)
            .lineHeight(18)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row({ space: 8 }) {
        SymbolGlyph(this.statusIcon())
          .fontSize(15)
          .fontColor([this.statusColor()])
        Text(this.statusText())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.statusColor())
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor(SteamArkTheme.surfaceControl(this.isDarkMode))
      .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    }
    .width('100%')
    .padding(18)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode),
      this.useSysMat
    ))
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
  private buildStartupSelection(): void {
    Column({ space: 10 }) {
      Text($r('app.string.steam_home_startup_title'))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_home_startup_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Row({ space: 8 }) {
        this.buildStartupButton(SteamArkHomeTab.OVERVIEW, $r('app.string.steam_home_tab_overview'))
        this.buildStartupButton(SteamArkHomeTab.ACCOUNTS, $r('app.string.steam_home_tab_accounts'))
        this.buildStartupButton(SteamArkHomeTab.FARMING, $r('app.string.steam_home_tab_farming'))
        this.buildStartupButton(SteamArkHomeTab.INVENTORY, $r('app.string.steam_home_tab_inventory'))
      }
      .width('100%')
      Row({ space: 8 }) {
        this.buildStartupButton(SteamArkHomeTab.MESSAGES, $r('app.string.steam_home_tab_messages'))
        this.buildStartupButton(SteamArkHomeTab.TOKENS, $r('app.string.steam_home_tab_tokens'))
        this.buildStartupButton(SteamArkHomeTab.SETTINGS, $r('app.string.steam_home_tab_settings'))
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildStartupButton(tabIndex: number, title: ResourceStr): void {
    Button(title)
      .layoutWeight(1)
      .height(40)
      .fontSize(12)
      .fontColor(this.startupTabIndex === tabIndex
        ? SteamArkTheme.onAccent(this.isDarkMode)
        : SteamArkTheme.textSecondary(this.isDarkMode))
      .backgroundColor(this.startupTabIndex === tabIndex
        ? SteamArkTheme.accent(this.isDarkMode)
        : SteamArkTheme.surfaceControl(this.isDarkMode))
      .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
      .onClick((): void => {
        this.startupTabIndex = tabIndex;
        ngfSettingsStoreFacade.setNumber(STEAM_ARK_STARTUP_TAB_KEY, tabIndex);
        this.selectTab(tabIndex);
      })
  }

  @Builder
  private buildSafetyPanel(): void {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(22)
        .fontColor([SteamArkTheme.success(this.isDarkMode)])
      Column({ space: 4 }) {
        Text($r('app.string.steam_home_safety_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_home_safety_desc'))
          .fontSize(11)
          .lineHeight(16)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .maxLines(3)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildNavDestination(name: string, param: Object): void {
    if (name === SteamArkRouteName.WORKSPACE) {
      SteamArkWorkspacePage()
    } else if (name === SteamArkRouteName.ACCOUNTS) {
      SteamArkAccountsPage()
    } else if (name === SteamArkRouteName.INVENTORY) {
      SteamArkInventoryPage()
    } else if (name === SteamArkRouteName.NETWORK) {
      SteamArkNetworkPage()
    } else if (name === SteamArkRouteName.TOKENS) {
      SteamArkTokenPage()
    } else if (name === SteamArkRouteName.SETTINGS) {
      SteamArkSettingsPage()
    } else if (name === SteamArkRouteName.DIAGNOSTICS) {
      SteamArkDiagnosticsPage()
    } else if (name === SteamArkRouteName.MESSAGES) {
      SteamArkMessagesPage({ notificationRequest: SteamArkMessageNavigationRequest.fromRouteParameter(param) })
    } else if (name === SteamArkRouteName.SOCIAL) {
      SteamArkSocialPage()
    } else if (name === SteamArkRouteName.BROWSER) {
      SteamArkBrowserPage({ request: param as SteamArkBrowserRequest })
    }
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    if (!this.isPageActive) {
      return;
    }
    const previousAccountCount: number = this.accountCount;
    this.stateReady = snapshot.initialized;
    this.accountCount = snapshot.accounts.length;
    this.selectedAccountId = snapshot.selectedAccountId;
    const selected = steamArkStateService.getSelectedAccount();
    if (selected === null) {
      this.selectedAccountName = '';
      this.sessionState = SteamSessionState.DISCONNECTED;
    } else {
      this.selectedAccountName = selected.profile.displayName.length > 0
        ? selected.profile.displayName
        : selected.profile.accountId;
      this.sessionState = selected.session.state;
    }
    this.applySyncSnapshot(steamArkSyncCoordinator.getSnapshot());
    this.applySocialSnapshot(steamArkSocialService.restore(this.selectedAccountId));
    this.applyFarmingSnapshot(steamArkFarmingService.getSnapshot(this.selectedAccountId));
    if (this.accountCount > 0 && previousAccountCount <= 0) {
      this.onboardingNetworkProbeVersion += 1;
      this.onboardingNetworkRunning = false;
    } else {
      this.startOnboardingNetworkProbeIfNeeded();
    }
    SteamArkLog.debug('HomePage', 'state applied; selectedAccount=' +
      SteamArkLog.accountId(this.selectedAccountId) + ', session=' + String(this.sessionState));
  }

  private startOnboardingNetworkProbeIfNeeded(): void {
    if (!this.isPageActive || !this.stateReady || this.accountCount > 0 ||
      this.onboardingNetworkRunning || this.onboardingNetworkAttempted) {
      return;
    }
    void this.runOnboardingNetworkProbe();
  }

  private async runOnboardingNetworkProbe(): Promise<void> {
    if (!this.isPageActive || !this.stateReady || this.accountCount > 0 || this.onboardingNetworkRunning) {
      return;
    }
    const probeVersion: number = this.onboardingNetworkProbeVersion + 1;
    this.onboardingNetworkProbeVersion = probeVersion;
    this.onboardingNetworkRunning = true;
    this.onboardingNetworkAttempted = true;
    const startedAt: number = Date.now();
    SteamArkLog.info('HomePage', 'onboarding network probe started');
    try {
      const probe: HarmonySteamNetworkProbe = new HarmonySteamNetworkProbe(
        new HarmonySteamNetworkProbeOptions()
      );
      const result: SteamArkNetworkProbeResult = await probe.probe();
      if (this.isCurrentOnboardingNetworkProbe(probeVersion)) {
        this.onboardingNetworkStatus = result.status;
        this.onboardingNetworkSites = result.sites.slice();
      }
      SteamArkLog.info('HomePage', 'onboarding network probe completed; status=' + String(result.status) +
        ', sites=' + result.sites.length.toString());
      SteamArkLog.performance('HomePage', 'onboarding network probe', startedAt);
    } catch (error) {
      if (this.isCurrentOnboardingNetworkProbe(probeVersion)) {
        this.onboardingNetworkStatus = SteamArkNetworkProbeStatus.FAILED;
        this.onboardingNetworkSites = [];
      }
      SteamArkLog.warn('HomePage', 'onboarding network probe failed; errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentOnboardingNetworkProbe(probeVersion)) {
        this.onboardingNetworkRunning = false;
      }
    }
  }

  private isCurrentOnboardingNetworkProbe(probeVersion: number): boolean {
    return this.isPageActive && this.stateReady && this.accountCount <= 0 &&
      probeVersion === this.onboardingNetworkProbeVersion;
  }

  private onboardingNetworkStatusText(): ResourceStr {
    if (this.onboardingNetworkRunning) {
      return $r('app.string.steam_network_status_probe_testing');
    }
    if (!this.onboardingNetworkAttempted) {
      return $r('app.string.steam_home_onboarding_network_not_tested');
    }
    switch (this.onboardingNetworkStatus) {
      case SteamArkNetworkProbeStatus.SUCCESS:
        return $r('app.string.steam_network_status_probe_success');
      case SteamArkNetworkProbeStatus.PARTIAL:
        return $r('app.string.steam_network_status_probe_partial');
      case SteamArkNetworkProbeStatus.UNSUPPORTED:
        return $r('app.string.steam_network_status_probe_unsupported');
      case SteamArkNetworkProbeStatus.FAILED:
      default:
        return $r('app.string.steam_network_status_probe_failed');
    }
  }

  private onboardingNetworkIcon(): Resource {
    if (this.onboardingNetworkRunning) {
      return $r('sys.symbol.arrow_clockwise');
    }
    if (!this.onboardingNetworkAttempted) {
      return $r('sys.symbol.info_circle');
    }
    if (this.onboardingNetworkStatus === SteamArkNetworkProbeStatus.SUCCESS) {
      return $r('sys.symbol.wifi');
    }
    if (this.onboardingNetworkStatus === SteamArkNetworkProbeStatus.PARTIAL ||
      this.onboardingNetworkStatus === SteamArkNetworkProbeStatus.UNSUPPORTED) {
      return $r('sys.symbol.exclamationmark_triangle');
    }
    return $r('sys.symbol.xmark_circle');
  }

  private onboardingNetworkColor(): ResourceColor {
    if (this.onboardingNetworkRunning || !this.onboardingNetworkAttempted) {
      return SteamArkTheme.accentCyan(this.isDarkMode);
    }
    if (this.onboardingNetworkStatus === SteamArkNetworkProbeStatus.SUCCESS) {
      return SteamArkTheme.success(this.isDarkMode);
    }
    if (this.onboardingNetworkStatus === SteamArkNetworkProbeStatus.PARTIAL ||
      this.onboardingNetworkStatus === SteamArkNetworkProbeStatus.UNSUPPORTED) {
      return SteamArkTheme.warning(this.isDarkMode);
    }
    return SteamArkTheme.error(this.isDarkMode);
  }

  private onboardingNetworkSupportedCount(): number {
    let count: number = 0;
    for (let index: number = 0; index < this.onboardingNetworkSites.length; index++) {
      if (this.onboardingNetworkSites[index].supported) {
        count += 1;
      }
    }
    return count;
  }

  private onboardingNetworkPassedCount(): number {
    let count: number = 0;
    for (let index: number = 0; index < this.onboardingNetworkSites.length; index++) {
      if (this.onboardingNetworkSites[index].supported && this.onboardingNetworkSites[index].succeeded) {
        count += 1;
      }
    }
    return count;
  }

  private onboardingNetworkAvailabilityMetric(): string {
    if (!this.onboardingNetworkAttempted || this.onboardingNetworkRunning ||
      this.onboardingNetworkSites.length <= 0) {
      return '--';
    }
    const supportedCount: number = this.onboardingNetworkSupportedCount();
    if (supportedCount <= 0) {
      return '--';
    }
    return this.onboardingNetworkPassedCount().toString() + ' / ' +
      supportedCount.toString();
  }

  private onboardingNetworkAverageLatency(): ResourceStr {
    let total: number = 0;
    let count: number = 0;
    for (let index: number = 0; index < this.onboardingNetworkSites.length; index++) {
      const site: SteamArkNetworkProbeSiteResult = this.onboardingNetworkSites[index];
      if (site.supported && site.succeeded && site.durationMs > 0) {
        total += site.durationMs;
        count += 1;
      }
    }
    if (count <= 0) {
      return this.onboardingNetworkAttempted ? '--' : $r('app.string.steam_home_onboarding_network_not_tested');
    }
    return Math.round(total / count).toString() + ' ms';
  }

  private onboardingSiteIcon(site: SteamArkNetworkProbeSiteResult): Resource {
    if (!site.supported) {
      return $r('sys.symbol.info_circle');
    }
    return site.succeeded ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.xmark_circle');
  }

  private onboardingSiteColor(site: SteamArkNetworkProbeSiteResult): ResourceColor {
    if (!site.supported) {
      return SteamArkTheme.warning(this.isDarkMode);
    }
    return site.succeeded
      ? SteamArkTheme.success(this.isDarkMode)
      : SteamArkTheme.error(this.isDarkMode);
  }

  private onboardingSiteStatusText(site: SteamArkNetworkProbeSiteResult): ResourceStr {
    if (!site.supported) {
      return $r('app.string.steam_network_probe_unsupported');
    }
    return site.succeeded
      ? $r('app.string.steam_network_probe_passed')
      : $r('app.string.steam_network_probe_failed');
  }

  private onboardingNetworkSiteName(targetId: string): ResourceStr {
    switch (targetId) {
      case 'store':
        return $r('app.string.steam_network_site_store');
      case 'community':
        return $r('app.string.steam_network_site_community');
      case 'api':
        return $r('app.string.steam_network_site_api');
      case 'help':
        return $r('app.string.steam_network_site_help');
      case 'checkout':
        return $r('app.string.steam_network_site_checkout');
      case 'cm':
        return $r('app.string.steam_network_site_cm');
      default:
        return targetId;
    }
  }

  private applyFarmingSnapshot(snapshot: SteamFarmSnapshot | null): void {
    if (snapshot === null) {
      this.farmingState = SteamFarmState.IDLE;
      this.farmingNow = false;
      SteamArkLog.debug('HomePage', 'farming snapshot cleared');
      return;
    }
    this.farmingState = snapshot.state;
    this.farmingNow = snapshot.nowFarming;
    SteamArkLog.debug('HomePage', 'farming state applied; state=' + String(snapshot.state) +
      ', nowFarming=' + String(snapshot.nowFarming));
  }

  private applySyncSnapshot(snapshot: SteamArkSyncSnapshot): void {
    const statuses: Array<SteamArkHomeAccountSyncStatus> = [];
    for (let index: number = 0; index < snapshot.accounts.length; index++) {
      const accountSnapshot: SteamArkAccountSyncSnapshot = snapshot.accounts[index];
      statuses.push(new SteamArkHomeAccountSyncStatus(
        accountSnapshot.accountId,
        accountSnapshot.running,
        this.hasSyncStageFailure(accountSnapshot, SteamArkSyncStage.INVENTORY),
        this.hasSyncStageFailure(accountSnapshot, SteamArkSyncStage.FARMING),
        this.hasSyncStageFailure(accountSnapshot, SteamArkSyncStage.SOCIAL)
      ));
    }
    this.accountSyncStatuses = statuses;
    this.applyCollectionMetrics(steamArkStateService.getSnapshot());
  }

  private hasSyncStageFailure(snapshot: SteamArkAccountSyncSnapshot, stage: SteamArkSyncStage): boolean {
    if (snapshot.failure.stage === stage) {
      return true;
    }
    for (let index: number = 0; index < snapshot.stageFailures.length; index++) {
      if (snapshot.stageFailures[index].stage === stage) {
        return true;
      }
    }
    return false;
  }

  private isMetricSynchronizing(currentAccountOnly: boolean): boolean {
    for (let index: number = 0; index < this.accountSyncStatuses.length; index++) {
      const status: SteamArkHomeAccountSyncStatus = this.accountSyncStatuses[index];
      if (currentAccountOnly && status.accountId !== this.selectedAccountId) {
        continue;
      }
      if (status.running) {
        return true;
      }
    }
    return false;
  }

  private hasMetricSyncFailure(stage: SteamArkSyncStage, currentAccountOnly: boolean): boolean {
    for (let index: number = 0; index < this.accountSyncStatuses.length; index++) {
      const status: SteamArkHomeAccountSyncStatus = this.accountSyncStatuses[index];
      if (currentAccountOnly && status.accountId !== this.selectedAccountId) {
        continue;
      }
      if (stage === SteamArkSyncStage.INVENTORY && status.inventoryFailed) {
        return true;
      }
      if (stage === SteamArkSyncStage.FARMING && status.farmingFailed) {
        return true;
      }
      if (stage === SteamArkSyncStage.SOCIAL && status.socialFailed) {
        return true;
      }
    }
    return false;
  }

  private applyCollectionMetrics(snapshot: SteamArkStateSnapshot): void {
    this.currentInventoryCount = 0;
    this.currentCardCount = 0;
    this.currentBadgeCount = 0;
    this.currentFarmableGameCount = 0;
    this.currentInventoryKnown = false;
    this.currentCardKnown = false;
    this.currentBadgeKnown = false;
    this.currentFarmableGameKnown = false;
    this.currentInventoryFresh = false;
    this.currentCardFresh = false;
    this.currentBadgeFresh = false;
    this.currentFarmableGameFresh = false;
    this.allInventoryCount = 0;
    this.allCardCount = 0;
    this.allBadgeCount = 0;
    this.allInventoryKnown = snapshot.accounts.length > 0;
    this.allCardKnown = snapshot.accounts.length > 0;
    this.allBadgeKnown = snapshot.accounts.length > 0;
    this.allInventoryFresh = snapshot.accounts.length > 0;
    this.allCardFresh = snapshot.accounts.length > 0;
    this.allBadgeFresh = snapshot.accounts.length > 0;
    for (let index: number = 0; index < snapshot.accounts.length; index++) {
      const accountId: string = snapshot.accounts[index].profile.accountId;
      const summary: SteamArkInventorySummary = steamArkStateService.getInventorySummary(accountId);
      const report: SteamBadgeSyncReport | null = steamArkFarmingService.getBadgeSyncReport(accountId);
      const inventoryKnown: boolean = this.hasCachedInventorySummary(summary);
      const inventoryFresh: boolean = this.hasFreshInventorySummary(summary);
      const cardKnown: boolean = this.hasCachedInventoryCardCount(accountId, summary);
      const cardFresh: boolean = this.hasFreshInventoryCardCount(accountId, summary);
      const badgeKnown: boolean = this.hasCachedBadgeReport(report);
      const badgeFresh: boolean = this.hasFreshBadgeReport(
        report,
        steamArkFarmingService.getBadgeSyncReportUpdatedAtEpochSeconds(accountId)
      );
      if (inventoryKnown) {
        this.allInventoryCount += summary.totalCount;
      }
      if (cardKnown) {
        this.allCardCount += summary.cardCount;
      }
      if (!inventoryKnown) {
        this.allInventoryKnown = false;
      }
      if (!inventoryFresh) {
        this.allInventoryFresh = false;
      }
      if (!cardKnown) {
        this.allCardKnown = false;
      }
      if (!cardFresh) {
        this.allCardFresh = false;
      }
      if (badgeKnown && report !== null) {
        this.allBadgeCount += this.badgeCount(report);
      }
      if (!badgeKnown) {
        this.allBadgeKnown = false;
      }
      if (!badgeFresh) {
        this.allBadgeFresh = false;
      }
      if (accountId === this.selectedAccountId) {
        this.currentInventoryKnown = inventoryKnown;
        this.currentCardKnown = cardKnown;
        this.currentBadgeKnown = badgeKnown;
        this.currentFarmableGameKnown = badgeKnown;
        this.currentInventoryFresh = inventoryFresh;
        this.currentCardFresh = cardFresh;
        this.currentBadgeFresh = badgeFresh;
        this.currentFarmableGameFresh = badgeFresh;
        if (inventoryKnown) {
          this.currentInventoryCount = summary.totalCount;
        }
        if (cardKnown) {
          this.currentCardCount = summary.cardCount;
        }
        if (badgeKnown && report !== null) {
          this.currentBadgeCount = this.badgeCount(report);
          this.currentFarmableGameCount = this.farmableGameCount(report);
        }
      }
    }
    SteamArkLog.debug('HomePage', 'collection metrics applied; currentInventory=' +
      this.currentInventoryCount.toString() + ', currentCards=' + this.currentCardCount.toString() +
      ', currentBadges=' + this.currentBadgeCount.toString() +
      ', currentFarmableGames=' + this.currentFarmableGameCount.toString() +
      ', allInventory=' + this.allInventoryCount.toString() +
      ', allCards=' + this.allCardCount.toString() + ', allBadges=' + this.allBadgeCount.toString() +
      ', currentInventoryKnown=' + String(this.currentInventoryKnown) +
      ', currentCardKnown=' + String(this.currentCardKnown) +
      ', currentBadgeKnown=' + String(this.currentBadgeKnown) +
      ', currentFarmableGameKnown=' + String(this.currentFarmableGameKnown) +
      ', allInventoryKnown=' + String(this.allInventoryKnown) +
      ', allCardKnown=' + String(this.allCardKnown) +
      ', allBadgeKnown=' + String(this.allBadgeKnown) +
      ', currentInventoryFresh=' + String(this.currentInventoryFresh) +
      ', currentCardFresh=' + String(this.currentCardFresh) +
      ', currentBadgeFresh=' + String(this.currentBadgeFresh) +
      ', allInventoryFresh=' + String(this.allInventoryFresh) +
      ', allCardFresh=' + String(this.allCardFresh) +
      ', allBadgeFresh=' + String(this.allBadgeFresh));
  }

  private hasCachedInventorySummary(summary: SteamArkInventorySummary): boolean {
    return summary.hasSnapshot && summary.totalCount >= summary.loadedItemCount;
  }

  private hasFreshInventorySummary(summary: SteamArkInventorySummary): boolean {
    return this.hasCachedInventorySummary(summary) &&
      this.hasFreshOverviewData(summary.syncedAtEpochSeconds);
  }

  private hasCachedInventoryCardCount(accountId: string, summary: SteamArkInventorySummary): boolean {
    return accountId.trim().length > 0 && this.hasCachedInventorySummary(summary) && summary.isComplete;
  }

  private hasFreshInventoryCardCount(accountId: string, summary: SteamArkInventorySummary): boolean {
    return this.hasCachedInventoryCardCount(accountId, summary) && this.hasFreshOverviewData(summary.syncedAtEpochSeconds);
  }

  private hasCachedBadgeReport(report: SteamBadgeSyncReport | null): boolean {
    return report !== null && report.requestedPageCount > 0 &&
      report.fetchedPageCount >= report.requestedPageCount;
  }

  private hasFreshBadgeReport(report: SteamBadgeSyncReport | null, updatedAtEpochSeconds: number): boolean {
    return this.hasCachedBadgeReport(report) && this.hasFreshOverviewData(updatedAtEpochSeconds);
  }

  private badgeCount(report: SteamBadgeSyncReport): number {
    let count: number = report.communityBadges.length;
    for (let index: number = 0; index < report.games.length; index++) {
      if (report.games[index].appId !== '753' && report.games[index].badgeLevel > 0) {
        count += 1;
      }
    }
    return count;
  }

  private hasFreshOverviewData(updatedAtEpochSeconds: number): boolean {
    if (updatedAtEpochSeconds <= 0) {
      return false;
    }
    const nowEpochSeconds: number = Math.floor(Date.now() / 1000);
    return nowEpochSeconds - updatedAtEpochSeconds < STEAM_ARK_OVERVIEW_CACHE_FRESHNESS_SECONDS;
  }

  private farmableGameCount(report: SteamBadgeSyncReport): number {
    let count: number = 0;
    for (let index: number = 0; index < report.games.length; index++) {
      if (report.games[index].cardsRemaining > 0) {
        count += 1;
      }
    }
    return count;
  }

  private ensureOverviewInventory(): void {
    if (!this.isPageActive || this.overviewInventoryRequestAccountId.length > 0 ||
      !steamArkStateService.isInventoryAdapterReady()) {
      return;
    }
    const snapshot: SteamArkStateSnapshot = steamArkStateService.getSnapshot();
    const nowEpochSeconds: number = Math.floor(Date.now() / 1000);
    let requiresSynchronization: boolean = false;
    for (let index = 0; index < snapshot.accounts.length; index++) {
      const account: SteamArkAccountSnapshot = snapshot.accounts[index];
      const candidateAccountId: string = account.profile.accountId;
      const summary: SteamArkInventorySummary = steamArkStateService.getInventorySummary(candidateAccountId);
      const cacheComplete: boolean = summary.hasSnapshot && summary.isComplete;
      const cacheFresh: boolean = this.hasFreshDefaultInventoryPages(candidateAccountId, nowEpochSeconds);
      if (account.session.state === SteamSessionState.LOGGED_ON && (!cacheFresh || !cacheComplete)) {
        requiresSynchronization = true;
        break;
      }
    }
    if (!requiresSynchronization) {
      return;
    }
    const requestScope: string = 'all_logged_on_accounts';
    this.overviewInventoryRequestAccountId = requestScope;
    SteamArkLog.info('HomePage', 'overview inventory synchronization started; scope=' + requestScope);
    void steamArkSyncCoordinator.requestSilentSync('home_overview_inventory').then((): void => {
      if (this.isPageActive) {
        this.applyCollectionMetrics(steamArkStateService.getSnapshot());
      }
      SteamArkLog.info('HomePage', 'overview inventory synchronization completed; scope=' + requestScope);
    }).catch((error: Error): void => {
      SteamArkLog.warn('HomePage', 'overview inventory synchronization failed; scope=' + requestScope +
        ', errorType=' + SteamArkLog.errorKind(error));
    }).finally((): void => {
      if (this.overviewInventoryRequestAccountId === requestScope) {
        this.overviewInventoryRequestAccountId = '';
      }
    });
  }

  private hasFreshDefaultInventoryPages(accountId: string, nowEpochSeconds: number): boolean {
    const pages: Array<SteamInventoryPage> = steamArkStateService.getCachedDefaultInventoryPages(accountId);
    if (pages.length <= 0) {
      return false;
    }
    for (let index: number = 0; index < pages.length; index++) {
      const syncedAtEpochSeconds: number = pages[index].syncedAtEpochSeconds;
      if (syncedAtEpochSeconds <= 0 || nowEpochSeconds - syncedAtEpochSeconds >=
        STEAM_ARK_OVERVIEW_CACHE_FRESHNESS_SECONDS) {
        return false;
      }
    }
    return true;
  }

  private ensureOverviewBadges(): void {
    if (!this.isPageActive || this.overviewBadgeRequestAccountId.length > 0 ||
      !steamArkFarmingService.isFarmingReady()) {
      return;
    }
    const snapshot: SteamArkStateSnapshot = steamArkStateService.getSnapshot();
    const nowEpochSeconds: number = Math.floor(Date.now() / 1000);
    let accountId: string = '';
    for (let index = 0; index < snapshot.accounts.length; index++) {
      const account: SteamArkAccountSnapshot = snapshot.accounts[index];
      const reportUpdatedAtEpochSeconds = steamArkFarmingService
        .getBadgeSyncReportUpdatedAtEpochSeconds(account.profile.accountId);
      const cacheFresh: boolean = reportUpdatedAtEpochSeconds > 0 &&
        nowEpochSeconds - reportUpdatedAtEpochSeconds < STEAM_ARK_OVERVIEW_CACHE_FRESHNESS_SECONDS;
      if (account.session.state === SteamSessionState.LOGGED_ON && !cacheFresh) {
        accountId = account.profile.accountId;
        break;
      }
    }
    if (accountId.length <= 0) {
      return;
    }
    const requestScope: string = 'all_logged_on_accounts';
    this.overviewBadgeRequestAccountId = requestScope;
    SteamArkLog.info('HomePage', 'overview badge synchronization started; scope=' + requestScope);
    void steamArkSyncCoordinator.requestSilentSync('home_overview_badges').then((): void => {
      if (this.isPageActive) {
        this.applyCollectionMetrics(steamArkStateService.getSnapshot());
      }
      SteamArkLog.info('HomePage', 'overview badge synchronization completed; scope=' + requestScope);
    }).catch((error: Error): void => {
      SteamArkLog.warn('HomePage', 'overview badge synchronization failed; scope=' + requestScope +
        ', errorType=' + SteamArkLog.errorKind(error));
    }).finally((): void => {
      if (this.overviewBadgeRequestAccountId === requestScope) {
        this.overviewBadgeRequestAccountId = '';
      }
    });
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
      this.ensureOverviewInventory();
      this.ensureOverviewBadges();
      SteamArkLog.info('HomePage', 'state service ready; initialized=' + String(initialized));
      SteamArkLog.performance('HomePage', 'state initialization', startedAt);
    } catch (_error) {
      SteamArkLog.error('HomePage', 'state service initialization failed');
    }
  }

  private statusText(): ResourceStr {
    if (!this.stateReady) {
      return $r('app.string.steam_state_unavailable_status');
    }
    if (this.selectedAccountId.length <= 0) {
      return $r('app.string.steam_home_status_no_account');
    }
    switch (this.sessionState) {
      case SteamSessionState.CONNECTING:
        return $r('app.string.steam_accounts_session_connecting');
      case SteamSessionState.CONNECTED:
        return $r('app.string.steam_accounts_session_connected');
      case SteamSessionState.LOGGED_ON:
        return this.farmingNow
          ? $r('app.string.steam_home_status_farming')
          : $r('app.string.steam_home_status_signed_in');
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

  private statusIcon(): Resource {
    if (!this.stateReady) {
      return $r('sys.symbol.exclamationmark_triangle');
    }
    if (this.selectedAccountId.length <= 0) {
      return $r('sys.symbol.info_circle');
    }
    switch (this.sessionState) {
      case SteamSessionState.CONNECTING:
      case SteamSessionState.RECONNECTING:
        return $r('sys.symbol.arrow_clockwise');
      case SteamSessionState.LOGGED_ON:
        return this.farmingNow
          ? $r('sys.symbol.play_round_triangle_fill')
          : $r('sys.symbol.checkmark_circle');
      case SteamSessionState.NEEDS_QR_SCAN:
      case SteamSessionState.NEEDS_EMAIL_CODE:
      case SteamSessionState.NEEDS_TWO_FACTOR:
      case SteamSessionState.NEEDS_MOBILE_CONFIRMATION:
      case SteamSessionState.EXPIRED:
      case SteamSessionState.ERROR:
        return $r('sys.symbol.exclamationmark_triangle');
      case SteamSessionState.CONNECTED:
      case SteamSessionState.DISCONNECTED:
      default:
        return $r('sys.symbol.info_circle');
    }
  }

  private statusColor(): ResourceColor {
    if (!this.stateReady) {
      return SteamArkTheme.warning(this.isDarkMode);
    }
    if (this.selectedAccountId.length <= 0) {
      return SteamArkTheme.warning(this.isDarkMode);
    }
    switch (this.sessionState) {
      case SteamSessionState.LOGGED_ON:
        return this.farmingNow
          ? SteamArkTheme.success(this.isDarkMode)
          : SteamArkTheme.accentCyan(this.isDarkMode);
      case SteamSessionState.ERROR:
      case SteamSessionState.EXPIRED:
        return SteamArkTheme.error(this.isDarkMode);
      case SteamSessionState.NEEDS_QR_SCAN:
      case SteamSessionState.NEEDS_EMAIL_CODE:
      case SteamSessionState.NEEDS_TWO_FACTOR:
      case SteamSessionState.NEEDS_MOBILE_CONFIRMATION:
        return SteamArkTheme.warning(this.isDarkMode);
      case SteamSessionState.CONNECTING:
      case SteamSessionState.CONNECTED:
      case SteamSessionState.RECONNECTING:
        return SteamArkTheme.accentCyan(this.isDarkMode);
      case SteamSessionState.DISCONNECTED:
      default:
        return SteamArkTheme.warning(this.isDarkMode);
    }
  }

  private sessionMetric(): ResourceStr {
    if (this.selectedAccountId.length <= 0) {
      return $r('app.string.steam_home_session_disconnected');
    }
    switch (this.sessionState) {
      case SteamSessionState.LOGGED_ON:
        return $r('app.string.steam_accounts_session_logged_on');
      case SteamSessionState.CONNECTING:
        return $r('app.string.steam_accounts_session_connecting');
      case SteamSessionState.CONNECTED:
        return $r('app.string.steam_accounts_session_connected');
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

  private farmingMetric(): ResourceStr {
    switch (this.farmingState) {
      case SteamFarmState.FARMING:
        return $r('app.string.steam_home_farming_running');
      case SteamFarmState.PAUSED:
        return $r('app.string.steam_home_farming_paused');
      case SteamFarmState.ERROR:
        return $r('app.string.steam_home_farming_error');
      case SteamFarmState.STARTING:
      case SteamFarmState.RECONNECTING:
        return $r('app.string.steam_workspace_farming_starting');
      case SteamFarmState.COMPLETED:
        return $r('app.string.steam_workspace_farming_completed');
      case SteamFarmState.IDLE:
      default:
        return $r('app.string.steam_home_farming_idle');
    }
  }

  private farmingColor(): ResourceColor {
    if (this.farmingState === SteamFarmState.ERROR) {
      return SteamArkTheme.error(this.isDarkMode);
    }
    if (this.farmingNow || this.farmingState === SteamFarmState.FARMING) {
      return SteamArkTheme.success(this.isDarkMode);
    }
    return SteamArkTheme.accentCyan(this.isDarkMode);
  }
}

@Entry
@Component
struct SteamArkHomeEntryPage {
  build(): void {
    Column() {
      SteamArkHomePage()
    }
    .width('100%')
    .height('100%')
  }
}
