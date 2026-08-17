import { HdsNavDestination } from '@kit.UIDesignKit';
import {
  NGFControlStyleTokens,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  ngfI18nManagerFacade,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import {
  SteamAuthError,
  SteamInventoryItem,
  SteamInventoryPage,
  SteamInventoryQuery,
  SteamSessionState
} from 'steam_core';
import {
  SteamArkAccountSyncSnapshot,
  SteamArkContentLocale,
  SteamArkLog,
  SteamArkRegionPolicy,
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
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import { SteamArkBrowserRequest, SteamArkInventoryDetailRequest, SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { SteamArkInventoryDetailPage } from './SteamArkInventoryDetailPage';
import { SteamArkPanelBackBridge } from './SteamArkPanelBackBridge';
import { SteamArkMarketPrice, SteamArkMarketPriceService } from '../../steamServices/SteamArkMarketPriceService';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';

class SteamInventoryAppTab {
  readonly appId: string;
  readonly title: ResourceStr;

  constructor(appId: string, title: ResourceStr) {
    this.appId = appId;
    this.title = title;
  }
}

const INVENTORY_APP_CACHE_TTL_MS: number = 5 * 60 * 1000;
const INVENTORY_PANEL_TOP_BAR_HEIGHT: number = 44;
const INVENTORY_PANEL_TOP_BAR_TOP: number = SteamArkTheme.CONTENT_TOP_INSET - INVENTORY_PANEL_TOP_BAR_HEIGHT;

@Component
export struct SteamArkInventoryPage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private searchText: string = '';
  @State private onlyTradeable: boolean = false;
  @State private onlyMarketable: boolean = false;
  @State private selectedOwnerAppId: string = '';
  @State private isSyncing: boolean = false;
  @State private coordinatorSyncRunning: boolean = false;
  @State private hasAccount: boolean = false;
  @State private stateReady: boolean = false;
  @State private selectedAccountId: string = '';
  @State private selectedAccountName: string = '';
  @State private sessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  @State private inventoryAdapterReady: boolean = false;
  @State private inventoryItems: Array<SteamInventoryItem> = [];
  @State private inventoryTotalCount: number = 0;
  @State private hasMoreInventory: boolean = false;
  @State private nextStartAssetId: string = '';
  @State private inventoryPage: number = 0;
  @State private hasInventorySynced: boolean = false;
  @State private inventorySyncFailed: boolean = false;
  @State private inventoryDetailVisible: boolean = false;
  @State private statusMessage: ResourceStr = $r('app.string.steam_inventory_status_idle');
  @State private marketPrices: Array<SteamArkMarketPrice> = [];
  @State private marketPriceSyncing: boolean = false;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('steam_ark_profile_background_enabled') private backgroundEnabled: boolean = true;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly scroller: Scroller = steamArkTabScrollers.inventory;
  private inventoryRequestVersion: number = 0;
  private marketPriceRequestVersion: number = 0;
  private activeInventoryRequestCount: number = 0;
  private autoInventorySyncRequested: boolean = false;
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private accountScopeGeneration: number = 0;
  private coordinatorInventoryUpdatedAtEpochSeconds: number = 0;
  private inventoryDetailRequest: SteamArkInventoryDetailRequest = new SteamArkInventoryDetailRequest();
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('InventoryPage', 'state snapshot received; accounts=' + snapshot.accounts.length.toString());
    this.applyStateSnapshot(snapshot);
  };
  private readonly syncListener: SteamArkSyncSnapshotListener = (snapshot: SteamArkSyncSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    this.applySyncSnapshot(snapshot);
  };

  aboutToAppear(): void {
    SteamArkLog.lifecycle('InventoryPage', 'aboutToAppear', 'embedded=' + String(this.embedded));
    this.lifecycleGeneration += 1;
    this.isPageActive = true;
    this.activeInventoryRequestCount = 0;
    this.isSyncing = false;
    this.coordinatorSyncRunning = false;
    if (this.embedded) {
      this.topInsetVp = this.contentTopInsetVp;
      SteamArkPanelBackBridge.registerCloseHandler(
        SteamArkPanelBackBridge.INVENTORY_DETAIL_PANEL,
        SteamArkPanelBackBridge.TAB_INVENTORY,
        (): void => {
          this.closeInventoryDetail();
        });
    } else {
      const lifecycleGeneration: number = this.lifecycleGeneration;
      SteamArkPageWindowSupport.loadDynamicTopInset(
        this.getUIContext(),
        108,
        SteamArkTheme.CONTENT_TOP_INSET,
        (inset: number): void => {
          if (this.isCurrentLifecycle(lifecycleGeneration)) {
            this.topInsetVp = inset;
          }
        }
      );
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.INVENTORY);
    }
    steamArkStateService.subscribe('SteamArkInventoryPage', this.stateListener);
    steamArkSyncCoordinator.subscribe('SteamArkInventoryPage', this.syncListener);
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    this.applySyncSnapshot(steamArkSyncCoordinator.getSnapshot());
    void this.initializeStateService();
    SteamArkLog.info('InventoryPage', 'state and sync subscriptions registered');
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle('InventoryPage', 'aboutToDisappear', 'embedded=' + String(this.embedded));
    this.isPageActive = false;
    this.lifecycleGeneration += 1;
    this.inventoryRequestVersion += 1;
    this.activeInventoryRequestCount = 0;
    this.isSyncing = false;
    this.coordinatorSyncRunning = false;
    if (this.embedded) {
      SteamArkPanelBackBridge.unregisterCloseHandler(SteamArkPanelBackBridge.INVENTORY_DETAIL_PANEL);
    }
    steamArkStateService.unsubscribe('SteamArkInventoryPage');
    steamArkSyncCoordinator.unsubscribe('SteamArkInventoryPage');
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
        $r('app.string.steam_inventory_title'),
        $r('app.string.steam_inventory_subtitle'),
        $r('app.color.background_transparent'),
        SteamArkTheme.textPrimary(this.isDarkMode),
        SteamArkTheme.textSecondary(this.isDarkMode),
        true,
        false
      ))
      .backgroundImage(this.backgroundEnabled ? this.profileBackgroundUrl : '')
      .backgroundImageSize(ImageSize.Cover)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .hideTitleBar(this.inventoryDetailVisible)
      .bindToScrollable([this.scroller])
      .onReady((context: NavDestinationContext): void => {
        this.pathStack = context.pathStack;
      })
      .onBackPressed((): boolean => {
        SteamArkPageWindowSupport.restoreHome();
        if (this.inventoryDetailVisible) {
          this.closeInventoryDetail();
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

      // The page-level Scroll owns all scrolling: the item grid is
      // content-sized, so tiles flow with the page instead of scrolling inside
      // a fixed-height box. The list stays mounted while the item detail covers
      // it, so tile geometry never resets and the close-direction
      // geometryTransition always flies back to the real tile position.
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (!this.stateReady) {
            SteamArkStateUnavailableCard({
              isDarkMode: this.isDarkMode,
              useSysMat: this.useSysMat
            });
          } else {
            this.buildToolbarCard();
            if (this.inventoryItems.length > 0) {
              this.buildItemsSection();
            } else {
              this.buildEmptyStateCard();
            }
            if (this.hasMoreInventory) {
              this.buildLoadMoreCard();
            }
            this.buildReadonlyCard();
          }
          this.buildStatusMessage();
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

      if (this.inventoryDetailVisible) {
        Stack({ alignContent: Alignment.TopStart }) {
          SteamArkInventoryDetailPage({ request: this.inventoryDetailRequest })
          this.buildInventoryPanelTopBar()
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
    .opacity(this.stateReady && !this.isInventoryRefreshVisible() && !this.marketPriceSyncing ? 1 : 0.9)
    .animation({ duration: SteamArkExperiencePolicy.CONTENT_REFRESH_DURATION, curve: Curve.EaseOut })
  }

  @Builder
  private buildInventoryPanelTopBar(): void {
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
      .id('steam-ark-inventory-panel-back')
      .onClick((): void => {
        this.closeInventoryDetail();
      })

      Text(this.inventoryDetailRequest.name.length > 0
        ? this.inventoryDetailRequest.name
        : $r('app.string.steam_inventory_title'))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: INVENTORY_PANEL_TOP_BAR_TOP, bottom: 6 })
  }

  @Builder
  private buildToolbarCard(): void {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.person_2'))
          .fontSize(18)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        Column({ space: 2 }) {
          Text($r('app.string.steam_inventory_account_label'))
            .fontSize(12)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          Text(this.hasAccount ? this.selectedAccountName : $r('app.string.steam_inventory_account_empty'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      this.buildCategoryTabs()

      if (this.marketPrices.length > 0 || this.marketPriceSyncing) {
        Row({ space: 8 }) {
          Text(this.marketSummaryText())
            .fontSize(12)
            .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
      }

      Row({ space: 8 }) {
        Text($r('app.string.steam_inventory_session_label'))
          .fontSize(12)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        Text(this.sessionLabel(this.sessionState))
          .fontSize(12)
          .fontColor(this.sessionState === SteamSessionState.LOGGED_ON
            ? SteamArkTheme.success(this.isDarkMode)
            : SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .width('100%')

      TextInput({
        placeholder: $r('app.string.steam_inventory_search_placeholder'),
        text: this.searchText
      })
        .id('steam-ark-inventory-search-input')
        .width('100%')
        .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
        .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
        .padding({ left: 12, right: 12 })
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
        .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
        .enabled(!this.isInventoryRefreshVisible())
        .onChange((value: string): void => {
          this.searchText = value;
          this.statusMessage = $r('app.string.steam_inventory_status_filters');
        })

      Row({ space: 12 }) {
        Text($r('app.string.steam_inventory_filter_title'))
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          .width(38)
        this.buildFilterToggle(
          $r('app.string.steam_inventory_filter_tradeable'),
          this.onlyTradeable,
          1
        )
        this.buildFilterToggle(
          $r('app.string.steam_inventory_filter_marketable'),
          this.onlyMarketable,
          2
        )
      }
      .width('100%')

      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(16)
            .fontColor([this.isInventorySyncAllowed() && !this.isInventoryRefreshVisible()
              ? SteamArkTheme.onAccent(this.isDarkMode)
              : SteamArkTheme.buttonDisabledText(this.isDarkMode)])
          Text($r('app.string.steam_inventory_sync'))
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isInventorySyncAllowed() && !this.isInventoryRefreshVisible()
              ? SteamArkTheme.onAccent(this.isDarkMode)
              : SteamArkTheme.buttonDisabledText(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .id('steam-ark-inventory-sync')
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(this.isInventorySyncAllowed() && !this.isInventoryRefreshVisible()
        ? SteamArkTheme.accent(this.isDarkMode)
        : SteamArkTheme.buttonDisabled(this.isDarkMode))
      .fontColor(this.isInventorySyncAllowed() && !this.isInventoryRefreshVisible()
        ? SteamArkTheme.onAccent(this.isDarkMode)
        : SteamArkTheme.buttonDisabledText(this.isDarkMode))
      .enabled(this.isInventorySyncAllowed() && !this.isInventoryRefreshVisible())
      .onClick((): void => {
        void this.handleSync();
      })

      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(16)
            .fontColor([SteamArkTheme.onAccent(this.isDarkMode)])
          Text($r('app.string.steam_market_browse_entry'))
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .id('steam-ark-inventory-open-market-browse')
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
      .enabled(this.hasAccount)
      .onClick((): void => {
        SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
          new SteamArkBrowserRequest('https://steamcommunity.com/market/',
            ngfI18nManagerFacade.resolveString($r('app.string.steam_market_browse_title')),
            'steamcommunity.com'));
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
  private buildFilterToggle(title: ResourceStr, isOn: boolean, filterKey: number): void {
    Row({ space: 8 }) {
      Text(title)
        .layoutWeight(1)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .maxLines(2)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .id(this.filterToggleId(filterKey))
        .enabled(!this.isInventoryRefreshVisible())
        .onChange((value: boolean): void => {
          // Filter switches fly with the exact same transition as game
          // switches, so both selections share one animation entry point.
          this.animateInventorySelection((): void => {
            if (filterKey === 1) {
              this.onlyTradeable = value;
            } else {
              this.onlyMarketable = value;
            }
            this.statusMessage = $r('app.string.steam_inventory_status_filters');
          });
        })
    }
    .layoutWeight(1)
    .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
  }

  /**
   * Shared selection animation for the inventory grid: switching games (the
   * category tabs) and switching filters (tradable / marketable toggles) must
   * fly with the exact same transition, so every grid-driving selection
   * mutates its state through this single entry point.
   */
  private animateInventorySelection(mutate: () => void): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, mutate);
  }

  @Builder
  private buildCategoryTabs(): void {
    Scroll() {
      Row({ space: 4 }) {
        ForEach(this.inventoryAppTabs(), (tab: SteamInventoryAppTab): void => {
          this.buildCategoryTab(tab)
        }, (tab: SteamInventoryAppTab): string => tab.appId)
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
  private buildCategoryTab(tab: SteamInventoryAppTab): void {
    Column({ space: 4 }) {
      Text(tab.title)
        .fontSize(12)
        .fontWeight(this.selectedOwnerAppId === tab.appId ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selectedOwnerAppId === tab.appId
          ? SteamArkTheme.accent(this.isDarkMode)
          : SteamArkTheme.textSecondary(this.isDarkMode))
        .maxLines(1)
      Column() {}
        .width(this.selectedOwnerAppId === tab.appId ? 28 : 8)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.selectedOwnerAppId === tab.appId
          ? SteamArkTheme.accent(this.isDarkMode)
          : $r('app.color.background_transparent'))
        .animation({ duration: 220, curve: Curve.EaseOut })
    }
    .height(40)
    .padding({ left: 12, right: 12, top: 7, bottom: 3 })
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.animateInventorySelection((): void => {
        this.selectedOwnerAppId = tab.appId;
      });
    })
  }

  @Builder
  private buildEmptyStateCard(): void {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.archivebox'))
        .fontSize(30)
        .fontColor([SteamArkTheme.warning(this.isDarkMode)])
      Text(this.emptyStateTitle())
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text(this.emptyStateDescription())
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .textAlign(TextAlign.Center)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .width('100%')
    .padding(22)
    .alignItems(HorizontalAlign.Center)
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
  private buildLoadMoreCard(): void {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.arrow_down_circle'))
          .fontSize(16)
          .fontColor([this.isInventoryRefreshVisible()
            ? SteamArkTheme.buttonDisabledText(this.isDarkMode)
            : SteamArkTheme.buttonForeground(this.isDarkMode)])
        Text(this.isInventoryRefreshVisible()
          ? $r('app.string.steam_inventory_status_loading')
          : $r('app.string.steam_inventory_load_more'))
          .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isInventoryRefreshVisible()
            ? SteamArkTheme.buttonDisabledText(this.isDarkMode)
            : SteamArkTheme.buttonForeground(this.isDarkMode))
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .id('steam-ark-inventory-load-more')
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .backgroundColor(this.isInventoryRefreshVisible()
      ? SteamArkTheme.buttonDisabled(this.isDarkMode)
      : NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .fontColor(this.isInventoryRefreshVisible()
      ? SteamArkTheme.buttonDisabledText(this.isDarkMode)
      : SteamArkTheme.buttonForeground(this.isDarkMode))
    .enabled(this.isInventorySyncAllowed() && !this.isInventoryRefreshVisible())
    .onClick((): void => {
      void this.handleLoadMore();
    })
  }

  /**
   * Inventory tiles flow inside the page-level Scroll: the waterfall is
   * content-sized (no fixed-height box, no inner scrolling), exactly like the
   * library page's per-section waterfalls, so one gesture scrolls the whole
   * page and the load-more and readonly cards follow the last row naturally.
   */
  @Builder
  private buildItemsSection(): void {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.archivebox'))
          .fontSize(18)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        Text($r('app.string.steam_inventory_items_count'))
          .fontSize(14)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        Text(this.inventoryTotalMetric())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')

      if (this.visibleInventoryItems().length > 0) {
        WaterFlow({ layoutMode: WaterFlowLayoutMode.SLIDING_WINDOW }) {
          ForEach(
            this.visibleInventoryItems(),
            (item: SteamInventoryItem): void => {
              FlowItem() {
                this.buildInventoryItemRow(item);
              }
              .width('100%')
            },
            (item: SteamInventoryItem): string => item.assetId + '|' + item.classId + '|' + item.instanceId
          )
        }
        .width('100%')
        // API 26 fills each responsive breakpoint column, so the final column
        // never leaves the fixed-width gap created by auto-fill tracks.
        .columnsTemplate({ fillType: PresetFillType.BREAKPOINT_SM2MD3LG5 })
        .columnsGap(10)
        .rowsGap(10)
        .edgeEffect(EdgeEffect.None)
        .scrollBar(BarState.Off)
        .cachedCount(12)
        .clip(true)
      } else {
        // Filters can exclude every synced item; keep that state visible
        // instead of rendering a bare count header above nothing.
        Text($r('app.string.steam_inventory_empty_result_desc'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .textAlign(TextAlign.Center)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .padding({ top: 12, bottom: 12 })
      }
    }
    .width('100%')
  }

  @Builder
  private buildInventoryItemRow(item: SteamInventoryItem): void {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.inventoryDetailVisible && this.inventoryDetailRequest.assetId === item.assetId) {
          // The opened tile icon unmounts (real disappear) so the detail icon
          // can pair with it in both flight directions; the equal-size
          // placeholder keeps the persistent list layout stable.
          Column()
            .width('100%')
            .height(108)
        } else if (item.iconUrlLarge.length > 0 || item.iconUrl.length > 0) {
          Image(item.iconUrlLarge.length > 0 ? item.iconUrlLarge : item.iconUrl)
            .width('100%')
            .height(108)
            .objectFit(ImageFit.Contain)
            .backgroundColor(Color.Transparent)
            .clip(true)
            .geometryTransition(SteamArkInventoryDetailRequest.iconGeometryId(item.assetId))
            .transition(TransitionEffect.OPACITY)
        } else {
          SymbolGlyph($r('sys.symbol.archivebox'))
            .fontSize(34)
            .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
        }
      }
      .width('100%')
      .height(108)

      Column({ space: 6 }) {
        Text(item.name.length > 0 ? item.name : $r('app.string.steam_inventory_no_name'))
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .lineHeight(18)
          .textAlign(TextAlign.Center)
        Text(this.inventoryItemAmountText(item))
          .width('100%')
          .fontSize(12)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .textAlign(TextAlign.Center)

        Text(this.inventoryCategory(item))
          .width('100%')
          .fontSize(11)
          .fontColor(SteamArkTheme.accent(this.isDarkMode))
          .textAlign(TextAlign.Center)

        Text(item.marketHashName.length > 0 ? item.marketHashName : item.type)
          .width('100%')
          .fontSize(11)
          .lineHeight(15)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .textAlign(TextAlign.Center)

        this.buildInventoryDescription(item.description)

        Text($r('app.string.steam_inventory_asset_id'))
          .width('100%')
          .fontSize(10)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          .textAlign(TextAlign.Center)
        Text(item.assetId)
          .width('100%')
          .fontSize(10)
          .lineHeight(14)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .textAlign(TextAlign.Center)

        if (this.priceText(item).length > 0) {
          Text(this.priceText(item))
            .width('100%')
            .fontSize(11)
            .lineHeight(15)
            .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
            .textAlign(TextAlign.Center)
        }

        Row({ space: 6 }) {
          if (item.tradable) {
            Text($r('app.string.steam_inventory_badge_tradable'))
              .fontSize(10)
              .fontColor(SteamArkTheme.success(this.isDarkMode))
          }
          if (item.marketable) {
            Text($r('app.string.steam_inventory_badge_marketable'))
              .fontSize(10)
              .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)

        Button() {
          Row({ space: 6 }) {
            Text($r('app.string.steam_inventory_view_detail'))
              .layoutWeight(1)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .lineHeight(15)
              .fontColor(SteamArkTheme.accent(this.isDarkMode))
              .maxLines(2)
              .textAlign(TextAlign.Center)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(13)
              .fontColor([SteamArkTheme.accent(this.isDarkMode)])
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height(48)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .accessibilityText($r('app.string.steam_inventory_view_detail'))
        .onClick((): void => {
          this.openInventoryDetailPage(item);
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .onClick((): void => {
      this.openInventoryDetailPage(item);
    })
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
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

  private inventoryAppList(accountId: string): Array<string> {
    const apps: Array<string> = ['753', '730', '570', '440'];
    const report = steamArkFarmingService.getBadgeSyncReport(accountId);
    if (report !== null) {
      for (let index = 0; index < report.games.length && apps.length < 12; index++) {
        const appId: string = report.games[index].appId;
        if (appId !== '753' && !apps.includes(appId)) {
          apps.push(appId);
        }
      }
    }
    return apps;
  }

  private inventoryContextId(appId: string): string {
    return appId === '753' ? '6' : '2';
  }

  private mergeInventoryItems(target: Array<SteamInventoryItem>, items: Array<SteamInventoryItem>): void {
    for (let index = 0; index < items.length; index++) {
      const item: SteamInventoryItem = items[index];
      const identity: string = item.appId + '|' + item.assetId;
      let duplicate: boolean = false;
      for (let existingIndex = 0; existingIndex < target.length; existingIndex++) {
        if (target[existingIndex].appId + '|' + target[existingIndex].assetId === identity) {
          duplicate = true;
          break;
        }
      }
      if (!duplicate) {
        target.push(item);
      }
    }
  }

  private visibleInventoryItems(): Array<SteamInventoryItem> {
    const result: Array<SteamInventoryItem> = [];
    const needle: string = this.searchText.trim().toLowerCase();
    for (let index = 0; index < this.inventoryItems.length; index++) {
      const item: SteamInventoryItem = this.inventoryItems[index];
      if (this.selectedOwnerAppId.length > 0 && item.ownerAppId !== this.selectedOwnerAppId) {
        continue;
      }
      if (this.onlyTradeable && !item.tradable) {
        continue;
      }
      if (this.onlyMarketable && !item.marketable) {
        continue;
      }
      if (needle.length > 0 && item.name.toLowerCase().indexOf(needle) < 0 &&
        item.marketName.toLowerCase().indexOf(needle) < 0 && item.type.toLowerCase().indexOf(needle) < 0) {
        continue;
      }
      result.push(item);
    }
    return result;
  }

  private inventoryTotalMetric(): string {
    return this.hasInventorySynced ? this.inventoryTotalCount.toString() : '--';
  }

  @Builder
  private buildInventoryDescription(description: string): void {
    ForEach(this.inventoryDescriptionImageUrls(description), (url: string): void => {
      Image(url)
        .width('100%')
        .height(72)
        .objectFit(ImageFit.Contain)
        .backgroundColor(Color.Transparent)
    }, (url: string): string => url)
    if (this.cleanInventoryDescription(description).length > 0) {
      Text(this.cleanInventoryDescription(description))
        .width('100%')
        .fontSize(11)
        .lineHeight(17)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .textAlign(TextAlign.Center)
    }
  }

  private inventoryDescriptionImageUrls(description: string): Array<string> {
    const urls: Array<string> = [];
    const imagePattern = /<img\b[^>]*>/gi;
    let match: RegExpExecArray | null = imagePattern.exec(description);
    while (match !== null) {
      const sourceMatch: RegExpExecArray | null = /\bsrc\s*=\s*["']([^"']+)["']/i.exec(match[0]);
      if (sourceMatch !== null) {
        let url: string = sourceMatch[1].trim();
        if (url.indexOf('http://') === 0) {
          url = 'https://' + url.substring(7);
        }
        if (url.indexOf('https://') === 0 && !urls.includes(url)) {
          urls.push(url);
        }
      }
      match = imagePattern.exec(description);
    }
    return urls;
  }

  private cleanInventoryDescription(description: string): string {
    return description
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<[^>]*>/g, '')
      .replace(/&nbsp;/gi, ' ')
      .replace(/&amp;/gi, '&')
      .replace(/&quot;/gi, '"')
      .replace(/&#39;/gi, "'")
      .replace(/&lt;/gi, '<')
      .replace(/&gt;/gi, '>')
      .replace(/[ \t]+\n/g, '\n')
      .trim();
  }

  private inventoryAppTabs(): Array<SteamInventoryAppTab> {
    const tabs: Array<SteamInventoryAppTab> = [];
    tabs.push(new SteamInventoryAppTab('', $r('app.string.steam_inventory_tab_steam')));
    const knownAppIds: Array<string> = [];
    for (let index: number = 0; index < this.inventoryItems.length; index++) {
      const item: SteamInventoryItem = this.inventoryItems[index];
      if (item.ownerAppId.length <= 0 || item.ownerAppId === '753' || knownAppIds.includes(item.ownerAppId)) {
        continue;
      }
      knownAppIds.push(item.ownerAppId);
      const title: string = item.ownerAppName.length > 0
        ? item.ownerAppName
        : item.ownerAppId;
      tabs.push(new SteamInventoryAppTab(item.ownerAppId, title));
    }
    return tabs;
  }

  private openInventoryDetailPage(item: SteamInventoryItem): void {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.info('InventoryPage', 'inventory item opened; assetId=' + item.assetId +
      ', appId=' + item.appId);
    this.inventoryDetailRequest = SteamArkInventoryDetailRequest.fromItem(item);
    if (this.embedded) {
      SteamArkPanelBackBridge.setVisible(SteamArkPanelBackBridge.INVENTORY_DETAIL_PANEL, true);
    }
    // Official 一镜到底 (persistent-source variant): the list stays mounted;
    // the opened tile icon unmounts while the detail is open so the pair has
    // a genuine appear/disappear in both flight directions, and the flight
    // always ends at the tile's real, never-reset position.
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.EXPAND_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.inventoryDetailVisible = true;
    });
  }

  private closeInventoryDetail(): void {
    if (!this.inventoryDetailVisible) {
      return;
    }
    SteamArkLog.info('InventoryPage', 'inventory detail closed');
    if (this.embedded) {
      SteamArkPanelBackBridge.setVisible(SteamArkPanelBackBridge.INVENTORY_DETAIL_PANEL, false);
    }
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.EXPAND_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.inventoryDetailVisible = false;
    });
  }

  private openExternalUrl(url: string): void {
    const pushed: boolean = SteamArkNavigationBridge.pushHomeRoute(
      SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(url, 'Steam', 'steamcommunity.com')
    );
    if (!pushed) {
      this.statusMessage = $r('app.string.steam_external_open_failed');
      SteamArkLog.warn('InventoryPage', 'internal market route failed');
    }
  }

  private inventoryCategory(item: SteamInventoryItem): ResourceStr {
    if (item.isTradingCard) {
      return $r('app.string.steam_inventory_category_cards');
    }
    if (item.marketable) {
      return $r('app.string.steam_inventory_category_market');
    }
    if (item.tradable) {
      return $r('app.string.steam_inventory_category_trade');
    }
    return $r('app.string.steam_inventory_category_other');
  }

  @Builder
  private buildReadonlyCard(): void {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(23)
        .fontColor([SteamArkTheme.success(this.isDarkMode)])
      Column({ space: 5 }) {
        Text($r('app.string.steam_inventory_readonly_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
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
  private buildStatusMessage(): void {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(16)
        .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      Text(this.statusMessage)
        .layoutWeight(1)
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4, bottom: 8 })
  }

  private async handleSync(): Promise<void> {
    if (this.isInventoryRefreshVisible()) {
      SteamArkLog.debug('InventoryPage', 'inventory sync blocked; request already active');
      return;
    }
    if (!this.stateReady) {
      this.statusMessage = $r('app.string.steam_state_unavailable_status');
      SteamArkLog.warn('InventoryPage', 'inventory sync blocked; state service unavailable');
      return;
    }
    if (!this.hasAccount) {
      this.statusMessage = $r('app.string.steam_inventory_status_idle');
      SteamArkLog.warn('InventoryPage', 'inventory sync blocked; no selected account');
      return;
    }
    if (this.sessionState !== SteamSessionState.LOGGED_ON) {
      this.statusMessage = $r('app.string.steam_inventory_status_not_logged_on');
      SteamArkLog.warn('InventoryPage', 'inventory sync blocked; session not logged on');
      return;
    }
    if (!this.inventoryAdapterReady) {
      this.statusMessage = $r('app.string.steam_inventory_status_adapter_pending');
      SteamArkLog.warn('InventoryPage', 'inventory sync blocked; adapter not ready');
      return;
    }
    this.resetInventoryResults();
    await this.syncInventoryPage(false);
  }

  private async handleLoadMore(): Promise<void> {
    if (this.isInventoryRefreshVisible() || !this.hasMoreInventory || this.nextStartAssetId.length <= 0) {
      return;
    }
    if (!this.isInventorySyncAllowed()) {
      this.statusMessage = $r('app.string.steam_inventory_status_not_logged_on');
      SteamArkLog.warn('InventoryPage', 'inventory pagination blocked; session not logged on');
      return;
    }
    await this.syncInventoryPage(true);
  }

  private async syncInventoryPage(append: boolean, silent: boolean = false,
    fromAuto: boolean = false): Promise<void> {
    if (!this.isPageActive || this.selectedAccountId.length <= 0 || this.activeInventoryRequestCount > 0) {
      return;
    }
    const requestVersion = this.inventoryRequestVersion;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    const accountId = this.selectedAccountId;
    const requestedPage = append ? this.inventoryPage + 1 : 1;
    const requestedStartAssetId = append ? this.nextStartAssetId : '';
    this.activeInventoryRequestCount += 1;
    this.isSyncing = true;
    const startedAt: number = Date.now();
    SteamArkLog.info('InventoryPage', 'read-only inventory sync started; account=' +
      SteamArkLog.accountId(accountId) + ', page=' + requestedPage.toString() +
      ', append=' + String(append) + ', searchLength=' + this.searchText.trim().length.toString());
    if (!silent) {
      this.statusMessage = $r('app.string.steam_inventory_status_loading');
    }
    try {
      const locale: SteamArkContentLocale | null = steamArkStateService.resolveAccountLocale(accountId);
      const language: string = locale !== null ? locale.steamLanguage : 'english';
      let totalCount: number = 0;
      if (append) {
        const query = new SteamInventoryQuery(
          '753', '6', requestedPage, 100, '', false, false, requestedStartAssetId, language
        );
        const page = await steamArkStateService.syncInventory(accountId, query);
        if (!this.isCurrentInventoryRequest(lifecycleGeneration, requestVersion, accountId,
          accountScopeGeneration)) {
          SteamArkLog.debug('InventoryPage', 'stale inventory page ignored; page=' + requestedPage.toString());
          return;
        }
        this.appendInventoryItems(page.items);
        this.inventoryPage = requestedPage;
        this.nextStartAssetId = page.nextStartAssetId;
        this.hasMoreInventory = page.hasMore && page.nextStartAssetId.length > 0;
        totalCount = page.totalCount;
      } else {
        // Steam serves inventory per app; fetch the common game apps plus the
        // account's badged games and merge them into one list.
        const appIds: Array<string> = this.inventoryAppList(accountId);
        const merged: Array<SteamInventoryItem> = [];
        let syncedAppCount: number = 0;
        for (let index = 0; index < appIds.length; index++) {
          const appId: string = appIds[index];
          const query = new SteamInventoryQuery(
            appId, this.inventoryContextId(appId), 1, 100, '', false, false, '', language
          );
          let page: SteamInventoryPage | null = null;
          try {
            const cached: SteamInventoryPage | null = await steamArkStateService.getCachedInventory(accountId, query);
            if (cached !== null && Date.now() - cached.syncedAtEpochSeconds * 1000 < INVENTORY_APP_CACHE_TTL_MS) {
              page = cached;
            } else {
              page = await steamArkStateService.syncInventory(accountId, query);
              syncedAppCount++;
            }
          } catch (error) {
            SteamArkLog.warn('InventoryPage', 'inventory app sync failed; account=' +
              SteamArkLog.accountId(accountId) + ', appId=' + appId +
              ', errorType=' + SteamArkLog.errorKind(error));
            page = await steamArkStateService.getCachedInventory(accountId, query);
          }
          if (!this.isCurrentInventoryRequest(lifecycleGeneration, requestVersion, accountId,
            accountScopeGeneration)) {
            SteamArkLog.debug('InventoryPage', 'stale inventory app ignored; appId=' + appId);
            return;
          }
          if (page === null) {
            continue;
          }
          if (appId === '753') {
            this.inventoryPage = page.query.page;
            this.nextStartAssetId = page.nextStartAssetId;
            this.hasMoreInventory = page.hasMore && page.nextStartAssetId.length > 0;
          }
          this.mergeInventoryItems(merged, page.items);
          this.inventoryItems = merged.slice();
        }
        totalCount = merged.length;
        SteamArkLog.info('InventoryPage', 'multi-app inventory sync completed; account=' +
          SteamArkLog.accountId(accountId) + ', apps=' + appIds.length.toString() +
          ', synced=' + syncedAppCount.toString() + ', items=' + merged.length.toString());
      }
      this.inventoryTotalCount = totalCount;
      this.hasInventorySynced = true;
      this.inventorySyncFailed = false;
      void this.refreshMarketPrices(accountId, lifecycleGeneration, accountScopeGeneration);
      if (!silent) {
        this.statusMessage = $r('app.string.steam_inventory_status_sync_success');
      }
      SteamArkLog.performance('InventoryPage', 'inventory sync', startedAt);
    } catch (_error) {
      if (this.isCurrentInventoryRequest(lifecycleGeneration, requestVersion, accountId,
        accountScopeGeneration)) {
        const detail = this.displayError(_error);
        this.inventorySyncFailed = true;
        this.statusMessage = detail.length > 0
          ? detail
          : $r('app.string.steam_inventory_status_sync_failed');
        SteamArkLog.error('InventoryPage', 'read-only inventory sync failed; account=' +
          SteamArkLog.accountId(accountId) + ', detailLength=' + detail.length.toString());
        if (fromAuto) {
          // Allow a later coordinator completion to retry the automatic sync.
          this.autoInventorySyncRequested = false;
        }
      }
    } finally {
      if (this.isCurrentInventoryRequest(lifecycleGeneration, requestVersion, accountId,
        accountScopeGeneration)) {
        this.activeInventoryRequestCount = Math.max(0, this.activeInventoryRequestCount - 1);
        this.isSyncing = this.activeInventoryRequestCount > 0;
      }
    }
  }

  private async restoreInventoryCache(
    accountId: string,
    lifecycleGeneration: number,
    accountScopeGeneration: number
  ): Promise<void> {
    const normalizedId: string = accountId.trim();
    if (normalizedId.length <= 0 || !this.isCurrentInventoryScope(lifecycleGeneration,
      normalizedId, accountScopeGeneration)) {
      return;
    }
    const cachedPages: Array<SteamInventoryPage> = steamArkStateService.getCachedDefaultInventoryPages(normalizedId);
    if (cachedPages.length > 0 && this.isCurrentInventoryScope(lifecycleGeneration,
      normalizedId, accountScopeGeneration)) {
      const firstCachedPage: SteamInventoryPage = cachedPages[0];
      const lastCachedPage: SteamInventoryPage = cachedPages[cachedPages.length - 1];
      this.inventoryItems = this.mergeCachedInventoryPages(cachedPages);
      this.inventoryTotalCount = firstCachedPage.totalCount;
      this.nextStartAssetId = lastCachedPage.nextStartAssetId;
      this.hasMoreInventory = lastCachedPage.hasMore && lastCachedPage.nextStartAssetId.length > 0;
      this.inventoryPage = lastCachedPage.query.page;
      this.hasInventorySynced = true;
      this.inventorySyncFailed = false;
      this.statusMessage = $r('app.string.steam_inventory_status_cached');
      void this.refreshMarketPrices(normalizedId, lifecycleGeneration, accountScopeGeneration);
    }
    // Merge any freshly synced non-Steam apps (in-memory cache) so CS2, DOTA2
    // and other game inventories are visible even before the next full sync.
    const accountLocale: SteamArkContentLocale | null = steamArkStateService.resolveAccountLocale(normalizedId);
    const language: string = accountLocale !== null ? accountLocale.steamLanguage : 'english';
    const appIds: Array<string> = this.inventoryAppList(normalizedId);
    for (let index = 0; index < appIds.length; index++) {
      const appId: string = appIds[index];
      if (appId === '753') {
        continue;
      }
      if (!this.isCurrentInventoryScope(lifecycleGeneration, normalizedId, accountScopeGeneration)) {
        return;
      }
      const query = new SteamInventoryQuery(
        appId, this.inventoryContextId(appId), 1, 100, '', false, false, '', language
      );
      const cached = await steamArkStateService.getCachedInventory(normalizedId, query);
      if (cached !== null) {
        this.mergeInventoryItems(this.inventoryItems, cached.items);
        this.inventoryTotalCount = this.inventoryItems.length;
      }
    }
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    if (!this.isPageActive) {
      return;
    }
    this.stateReady = snapshot.initialized;
    if (!this.stateReady) {
      this.statusMessage = $r('app.string.steam_state_unavailable_status');
    }
    const previousSelectedId = this.selectedAccountId;
    const previousSessionState = this.sessionState;
    const accountChanged: boolean = previousSelectedId !== snapshot.selectedAccountId;
    if (accountChanged) {
      this.accountScopeGeneration += 1;
    }
    this.selectedAccountId = snapshot.selectedAccountId;
    this.hasAccount = snapshot.selectedAccountId.length > 0;
    this.inventoryAdapterReady = steamArkStateService.isInventoryAdapterReady();
    const selected = steamArkStateService.getSelectedAccount();
    const nextSessionState = selected === null
      ? SteamSessionState.DISCONNECTED
      : selected.session.state;
    if (accountChanged ||
      (previousSessionState === SteamSessionState.LOGGED_ON && nextSessionState !== SteamSessionState.LOGGED_ON)) {
      this.resetInventoryResults();
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
    if (previousSelectedId.length > 0 && previousSelectedId !== this.selectedAccountId) {
      this.statusMessage = $r('app.string.steam_inventory_status_account_changed');
    }
    if (nextSessionState === SteamSessionState.LOGGED_ON &&
      (previousSessionState !== SteamSessionState.LOGGED_ON || accountChanged)) {
      const lifecycleGeneration: number = this.lifecycleGeneration;
      const accountScopeGeneration: number = this.accountScopeGeneration;
      const accountId: string = this.selectedAccountId;
      void this.restoreInventoryCache(accountId, lifecycleGeneration, accountScopeGeneration);
      void steamArkSyncCoordinator.requestAccountSync(accountId, 'inventory_page_restore')
        .catch((error: Error): void => {
          if (this.isCurrentInventoryScope(lifecycleGeneration, accountId, accountScopeGeneration)) {
            this.inventorySyncFailed = true;
            this.statusMessage = $r('app.string.steam_inventory_status_sync_failed');
          }
          SteamArkLog.warn('InventoryPage', 'background inventory sync dispatch failed; errorType=' +
            SteamArkLog.errorKind(error));
        });
      this.maybeAutoSyncInventory();
    }
    SteamArkLog.debug('InventoryPage', 'state applied; selectedAccount=' +
      SteamArkLog.accountId(this.selectedAccountId) + ', session=' + String(this.sessionState) +
      ', adapterReady=' + String(this.inventoryAdapterReady));
    this.applySyncSnapshot(steamArkSyncCoordinator.getSnapshot());
  }

  private applySyncSnapshot(snapshot: SteamArkSyncSnapshot): void {
    if (!this.isPageActive || this.selectedAccountId.length <= 0) {
      return;
    }
    const accountSnapshot: SteamArkAccountSyncSnapshot | null =
      this.findAccountSyncSnapshot(snapshot, this.selectedAccountId);
    if (accountSnapshot === null) {
      this.coordinatorSyncRunning = false;
      return;
    }
    const wasCoordinatorSyncRunning: boolean = this.coordinatorSyncRunning;
    this.coordinatorSyncRunning = accountSnapshot.running;
    if (wasCoordinatorSyncRunning && !accountSnapshot.running) {
      this.maybeAutoSyncInventory();
    }
    const inventoryFailed: boolean = this.hasInventorySyncFailure(accountSnapshot);
    if (accountSnapshot.running && !inventoryFailed) {
      this.inventorySyncFailed = false;
    }
    const inventoryUpdatedAtEpochSeconds: number = accountSnapshot.freshness.inventoryUpdatedAtEpochSeconds;
    if (inventoryUpdatedAtEpochSeconds > this.coordinatorInventoryUpdatedAtEpochSeconds) {
      this.coordinatorInventoryUpdatedAtEpochSeconds = inventoryUpdatedAtEpochSeconds;
      void this.restoreInventoryCache(
        this.selectedAccountId,
        this.lifecycleGeneration,
        this.accountScopeGeneration
      );
    }
    if (inventoryFailed && !this.hasInventorySynced) {
      this.inventorySyncFailed = true;
      this.statusMessage = $r('app.string.steam_inventory_status_sync_failed');
      SteamArkLog.warn('InventoryPage', 'background inventory synchronization failed; account=' +
        SteamArkLog.accountId(this.selectedAccountId));
      return;
    }
    if (!this.hasInventorySynced && accountSnapshot.running) {
      this.statusMessage = $r('app.string.steam_inventory_status_loading');
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

  private async initializeStateService(): Promise<void> {
    const startedAt: number = Date.now();
    const lifecycleGeneration: number = this.lifecycleGeneration;
    try {
      const initialized: boolean = await steamArkStateService.initialize();
      if (!this.isCurrentLifecycle(lifecycleGeneration)) {
        return;
      }
      this.applyStateSnapshot(steamArkStateService.getSnapshot());
      SteamArkLog.info('InventoryPage', 'state service ready; initialized=' + String(initialized));
      SteamArkLog.performance('InventoryPage', 'state initialization', startedAt);
    } catch (_error) {
      SteamArkLog.error('InventoryPage', 'state service initialization failed');
    }
  }

  private isInventorySyncAllowed(): boolean {
    return this.stateReady && this.hasAccount && this.sessionState === SteamSessionState.LOGGED_ON &&
      this.inventoryAdapterReady;
  }

  private isInventoryRefreshVisible(): boolean {
    return this.isSyncing || this.coordinatorSyncRunning;
  }

  /**
   * Steam serves inventory per app (753 = Steam items, game apps use their own
   * context), so the first time the page becomes usable it runs one combined
   * multi-app sync. Without this, opening the page only shows the restored
   * Steam-community inventory and game items such as CS2 skins or DOTA 2
   * cosmetics stay invisible until the user taps the refresh button.
   */
  private maybeAutoSyncInventory(): void {
    if (this.autoInventorySyncRequested) {
      return;
    }
    if (!this.isPageActive || !this.isInventorySyncAllowed()) {
      return;
    }
    if (this.isSyncing) {
      return;
    }
    this.autoInventorySyncRequested = true;
    SteamArkLog.info('InventoryPage', 'multi-app inventory auto sync requested; account=' +
      SteamArkLog.accountId(this.selectedAccountId));
    void this.syncInventoryPage(false, false, true);
  }

  private resetInventoryResults(): void {
    this.inventoryRequestVersion += 1;
    this.marketPriceRequestVersion += 1;
    this.activeInventoryRequestCount = 0;
    this.autoInventorySyncRequested = false;
    this.isSyncing = false;
    this.coordinatorSyncRunning = false;
    this.coordinatorInventoryUpdatedAtEpochSeconds = 0;
    this.inventoryItems = [];
    this.inventoryTotalCount = 0;
    this.hasMoreInventory = false;
    this.nextStartAssetId = '';
    this.inventoryPage = 0;
    this.hasInventorySynced = false;
    this.inventorySyncFailed = false;
    this.marketPrices = [];
    this.marketPriceSyncing = false;
  }

  private emptyStateTitle(): ResourceStr {
    if (!this.hasAccount) {
      return $r('app.string.steam_inventory_account_empty');
    }
    if (this.sessionState !== SteamSessionState.LOGGED_ON) {
      return $r('app.string.steam_inventory_not_logged_on_title');
    }
    if (this.inventorySyncFailed) {
      return $r('app.string.steam_inventory_status_sync_failed');
    }
    if (!this.hasInventorySynced && this.isInventoryRefreshVisible()) {
      return $r('app.string.steam_inventory_status_loading');
    }
    if (this.hasInventorySynced) {
      return $r('app.string.steam_inventory_empty_result_title');
    }
    return $r('app.string.steam_inventory_empty_title');
  }

  private emptyStateDescription(): ResourceStr {
    if (!this.hasAccount) {
      return $r('app.string.steam_inventory_empty_desc');
    }
    if (this.sessionState !== SteamSessionState.LOGGED_ON) {
      return $r('app.string.steam_inventory_not_logged_on_desc');
    }
    if (this.inventorySyncFailed) {
      return this.statusMessage;
    }
    if (!this.hasInventorySynced && this.isInventoryRefreshVisible()) {
      return this.statusMessage;
    }
    if (this.hasInventorySynced) {
      return $r('app.string.steam_inventory_empty_result_desc');
    }
    return $r('app.string.steam_inventory_empty_desc');
  }

  private appendInventoryItems(items: Array<SteamInventoryItem>): void {
    const merged = this.inventoryItems.slice();
    for (let index = 0; index < items.length; index++) {
      const candidate = items[index];
      let exists = false;
      for (let itemIndex = 0; itemIndex < merged.length; itemIndex++) {
        const existing = merged[itemIndex];
        if (existing.assetId === candidate.assetId && existing.classId === candidate.classId &&
          existing.instanceId === candidate.instanceId) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        merged.push(candidate);
      }
    }
    this.inventoryItems = merged;
  }

  private mergeCachedInventoryPages(pages: Array<SteamInventoryPage>): Array<SteamInventoryItem> {
    const merged: Array<SteamInventoryItem> = [];
    for (let pageIndex: number = 0; pageIndex < pages.length; pageIndex++) {
      const page: SteamInventoryPage = pages[pageIndex];
      for (let itemIndex: number = 0; itemIndex < page.items.length; itemIndex++) {
        const candidate: SteamInventoryItem = page.items[itemIndex];
        let exists: boolean = false;
        for (let mergedIndex: number = 0; mergedIndex < merged.length; mergedIndex++) {
          if (merged[mergedIndex].assetId === candidate.assetId) {
            exists = true;
            break;
          }
        }
        if (!exists) {
          merged.push(candidate);
        }
      }
    }
    return merged;
  }

  private async refreshMarketPrices(
    accountId: string,
    lifecycleGeneration: number,
    accountScopeGeneration: number
  ): Promise<void> {
    if (!this.isCurrentInventoryScope(lifecycleGeneration, accountId, accountScopeGeneration)) {
      return;
    }
    const account = steamArkStateService.getSelectedAccount();
    if (account === null || account.profile.accountId !== accountId || this.inventoryItems.length <= 0) {
      return;
    }
    const priceRequestVersion: number = this.marketPriceRequestVersion + 1;
    this.marketPriceRequestVersion = priceRequestVersion;
    const items: Array<SteamInventoryItem> = this.inventoryItems.slice();
    this.marketPriceSyncing = true;
    try {
      const service = new SteamArkMarketPriceService();
      const batch = await service.loadBatch(account.profile, items,
        SteamArkRegionPolicy.resolve(account.region, account.profile.countryCode, account.profile.walletCurrency));
      if (this.isCurrentMarketPriceRequest(lifecycleGeneration, accountId, accountScopeGeneration,
        priceRequestVersion)) {
        this.marketPrices = batch.prices;
      }
    } catch (error) {
      SteamArkLog.warn('InventoryPage', 'market price refresh failed; errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentMarketPriceRequest(lifecycleGeneration, accountId, accountScopeGeneration,
        priceRequestVersion)) {
        this.marketPriceSyncing = false;
      }
    }
  }

  private priceFor(item: SteamInventoryItem): SteamArkMarketPrice | null {
    const name: string = item.marketHashName.trim();
    if (name.length <= 0) {
      return null;
    }
    for (let index = 0; index < this.marketPrices.length; index++) {
      const price: SteamArkMarketPrice = this.marketPrices[index];
      if (price.appId === item.appId && price.marketHashName === name) {
        return price;
      }
    }
    return null;
  }

  private priceText(item: SteamInventoryItem): string {
    const price: SteamArkMarketPrice | null = this.priceFor(item);
    if (price === null || !this.isDisplayableMarketPrice(price)) {
      return '';
    }
    const formattedPrice: string = this.formatMarketPrice(price.lowestMinorUnits, price.currencyCode);
    if (formattedPrice.length <= 0) {
      return '';
    }
    const amountText: string = this.inventoryItemAmountText(item);
    return amountText === '--' ? formattedPrice : formattedPrice + ' x ' + amountText;
  }

  private marketSummaryText(): string {
    let totalMinorUnits: number = 0;
    let currencyCode: string = '';
    let pricedItems: number = 0;
    for (let index = 0; index < this.inventoryItems.length; index++) {
      const item: SteamInventoryItem = this.inventoryItems[index];
      const price: SteamArkMarketPrice | null = this.priceFor(item);
      if (price !== null && this.isDisplayableMarketPrice(price) &&
        Number.isSafeInteger(item.amount) && item.amount >= 0) {
        totalMinorUnits += price.lowestMinorUnits * item.amount;
        currencyCode = this.normalizedCurrencyCode(price.currencyCode);
        pricedItems += 1;
      }
    }
    if (pricedItems <= 0) {
      return this.marketPriceSyncing
        ? ngfI18nManagerFacade.resolveString($r('app.string.steam_inventory_price_loading'))
        : ngfI18nManagerFacade.resolveString($r('app.string.steam_inventory_price_unavailable'));
    }
    return ngfI18nManagerFacade.resolveString($r('app.string.steam_inventory_price_value')) + ' ' +
      this.formatMarketPrice(totalMinorUnits, currencyCode) + ' / ' + pricedItems.toString() + ' ' +
      ngfI18nManagerFacade.resolveString($r('app.string.steam_inventory_price_count'));
  }

  private formatMarketPrice(minorUnits: number, currencyCode: string): string {
    if (!Number.isSafeInteger(minorUnits) || minorUnits < 0) {
      return '';
    }
    const normalizedCurrencyCode: string = this.normalizedCurrencyCode(currencyCode);
    const fractionalDigits: number = normalizedCurrencyCode === 'JPY' ? 0 : 2;
    return normalizedCurrencyCode + ' ' + (minorUnits / 100).toFixed(fractionalDigits);
  }

  private inventoryItemAmountText(item: SteamInventoryItem): string {
    return Number.isSafeInteger(item.amount) && item.amount >= 0 ? item.amount.toString() : '--';
  }

  private isDisplayableMarketPrice(price: SteamArkMarketPrice): boolean {
    return price.available && Number.isSafeInteger(price.lowestMinorUnits) &&
      price.lowestMinorUnits >= 0 && this.normalizedCurrencyCode(price.currencyCode) === price.currencyCode;
  }

  private normalizedCurrencyCode(currencyCode: string): string {
    if (currencyCode === 'CNY' || currencyCode === 'EUR' || currencyCode === 'GBP' ||
      currencyCode === 'JPY' || currencyCode === 'USD') {
      return currencyCode;
    }
    return 'USD';
  }

  private isCurrentLifecycle(generation: number): boolean {
    return this.isPageActive && generation === this.lifecycleGeneration;
  }

  private isCurrentInventoryScope(
    lifecycleGeneration: number,
    accountId: string,
    accountScopeGeneration: number
  ): boolean {
    return this.isCurrentLifecycle(lifecycleGeneration) &&
      this.accountScopeGeneration === accountScopeGeneration && this.selectedAccountId === accountId;
  }

  private isCurrentInventoryRequest(
    lifecycleGeneration: number,
    requestVersion: number,
    accountId: string,
    accountScopeGeneration: number
  ): boolean {
    return this.isCurrentInventoryScope(lifecycleGeneration, accountId, accountScopeGeneration) &&
      requestVersion === this.inventoryRequestVersion &&
      accountId === this.selectedAccountId;
  }

  private isCurrentMarketPriceRequest(
    lifecycleGeneration: number,
    accountId: string,
    accountScopeGeneration: number,
    priceRequestVersion: number
  ): boolean {
    return this.isCurrentInventoryScope(lifecycleGeneration, accountId, accountScopeGeneration) &&
      this.marketPriceRequestVersion === priceRequestVersion;
  }

  private filterToggleId(filterKey: number): string {
    if (filterKey === 1) {
      return 'steam-ark-inventory-filter-tradeable';
    }
    return 'steam-ark-inventory-filter-marketable';
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
    let message = error.message.replace(/\r/g, ' ').replace(/\n/g, ' ').trim();
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

}
