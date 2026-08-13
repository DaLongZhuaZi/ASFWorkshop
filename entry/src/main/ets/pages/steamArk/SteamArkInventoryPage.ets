import { HdsNavDestination } from '@kit.UIDesignKit';
import { webview } from '@kit.ArkWeb';
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
  SteamArkLog,
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
import { SteamArkBrowserRequest, SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
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
  @State private detailSheetVisible: boolean = false;
  @State private detailSheetUrl: string = '';
  @State private detailSheetItemName: string = '';
  @State private detailSheetLoading: boolean = false;
  @State private detailSheetFailed: boolean = false;
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
  @State private inventoryWaterFlowViewportHeight: number = 420;
  @State private statusMessage: ResourceStr = $r('app.string.steam_inventory_status_idle');
  @State private marketPrices: Array<SteamArkMarketPrice> = [];
  @State private marketPriceSyncing: boolean = false;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly scroller: Scroller = steamArkTabScrollers.inventory;
  private readonly detailController: webview.WebviewController = new webview.WebviewController();
  private inventoryRequestVersion: number = 0;
  private marketPriceRequestVersion: number = 0;
  private activeInventoryRequestCount: number = 0;
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private accountScopeGeneration: number = 0;
  private inventoryPageBodyHeight: number = 0;
  private coordinatorInventoryUpdatedAtEpochSeconds: number = 0;
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
    } else {
      const lifecycleGeneration: number = this.lifecycleGeneration;
      SteamArkPageWindowSupport.loadDynamicTopInset(
        this.getUIContext(),
        108,
        SteamArkTheme.CONTENT_TOP_INSET,
        (inset: number): void => {
          if (this.isCurrentLifecycle(lifecycleGeneration)) {
            this.topInsetVp = inset;
            this.updateInventoryWaterFlowViewport(this.inventoryPageBodyHeight);
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
      .backgroundImage(this.profileBackgroundUrl)
      .backgroundImageSize(ImageSize.Cover)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .bindToScrollable([this.scroller])
      .onReady((context: NavDestinationContext): void => {
        this.pathStack = context.pathStack;
      })
      .onBackPressed((): boolean => {
        SteamArkPageWindowSupport.restoreHome();
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
              this.buildItemsCard();
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
          bottom: this.embedded ? 84 : 92
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .backgroundColor($r('app.color.background_transparent'))
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.updateInventoryWaterFlowViewport(newValue.height);
    })
    .backgroundColor(this.embedded
      ? $r('app.color.background_transparent') : SteamArkTheme.background(this.isDarkMode))
    .opacity(this.stateReady && !this.isInventoryRefreshVisible() && !this.marketPriceSyncing ? 1 : 0.9)
    .animation({ duration: SteamArkExperiencePolicy.CONTENT_REFRESH_DURATION, curve: Curve.EaseOut })
    .bindSheet($$this.detailSheetVisible, this.buildInventoryDetailSheet(), {
      height: SheetSize.LARGE,
      showClose: true,
      preferType: SheetType.BOTTOM
    })
  }

  @Builder
  private buildInventoryDetailSheet(): void {
    Column({ space: 10 }) {
      Text(this.detailSheetItemName.length > 0
        ? this.detailSheetItemName : $r('app.string.steam_inventory_detail_sheet_title'))
        .width('100%')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .textAlign(TextAlign.Center)
      Stack({ alignContent: Alignment.Center }) {
        if (this.detailSheetUrl.length > 0) {
          Web({ src: this.detailSheetUrl, controller: this.detailController })
            .width('100%')
            .height('100%')
            .backgroundColor(SteamArkTheme.background(this.isDarkMode))
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .onPageBegin((): void => {
              this.detailSheetLoading = true;
              this.detailSheetFailed = false;
            })
            .onPageEnd((): void => {
              this.detailSheetLoading = false;
              this.detailSheetFailed = false;
            })
            .onErrorReceive((event: OnErrorReceiveEvent): void => {
              if (!event.request.isMainFrame) {
                return;
              }
              this.detailSheetLoading = false;
              this.detailSheetFailed = true;
            })
        }
        if (this.detailSheetLoading) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(34)
              .height(34)
              .color(SteamArkTheme.accent(this.isDarkMode))
            Text($r('app.string.steam_inventory_detail_sheet_loading'))
              .fontSize(14)
              .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
              .textAlign(TextAlign.Center)
          }
          .padding(18)
          .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
            SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
          .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
          .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
          .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
        }
        if (this.detailSheetFailed) {
          Text($r('app.string.steam_inventory_detail_sheet_failed'))
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
          if (filterKey === 1) {
            this.onlyTradeable = value;
          } else {
            this.onlyMarketable = value;
          }
          this.statusMessage = $r('app.string.steam_inventory_status_filters');
        })
    }
    .layoutWeight(1)
    .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
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
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
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

  @Builder
  private buildItemsCard(): void {
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
        .layoutWeight(1)
        .columnsTemplate('repeat(auto-fill, 156vp)')
        .columnsGap(10)
        .rowsGap(10)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .cachedCount(12)
    }
    .width('100%')
    .height(this.inventoryWaterFlowViewportHeight)
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
  private buildInventoryItemRow(item: SteamInventoryItem): void {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (item.iconUrlLarge.length > 0 || item.iconUrl.length > 0) {
          Image(item.iconUrlLarge.length > 0 ? item.iconUrlLarge : item.iconUrl)
            .width('100%')
            .height(108)
            .objectFit(ImageFit.Contain)
            .backgroundColor(Color.Transparent)
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

        if (this.canOpenCommunityDetail(item)) {
          Button() {
            Row({ space: 6 }) {
            Text($r('app.string.steam_inventory_open_community_detail'))
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
          .accessibilityText($r('app.string.steam_inventory_open_community_detail'))
          .onClick((): void => {
            this.openInventoryDetailSheet(item);
          })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
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

  private marketUrl(item: SteamInventoryItem): string {
    const marketName: string = item.marketHashName.length > 0 ? item.marketHashName : item.name;
    return 'https://steamcommunity.com/market/listings/' + item.appId + '/' + encodeURIComponent(marketName);
  }

  private canOpenCommunityDetail(item: SteamInventoryItem): boolean {
    return item.marketable && item.appId.trim().length > 0 &&
      (item.marketHashName.trim().length > 0 || item.name.trim().length > 0);
  }

  private openInventoryDetailSheet(item: SteamInventoryItem): void {
    if (!this.canOpenCommunityDetail(item)) {
      return;
    }
    this.detailSheetItemName = item.name.length > 0 ? item.name : item.marketName;
    this.detailSheetUrl = this.marketUrl(item);
    this.detailSheetLoading = true;
    this.detailSheetFailed = false;
    this.detailSheetVisible = true;
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

  private async syncInventoryPage(append: boolean, silent: boolean = false): Promise<void> {
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
      const query = new SteamInventoryQuery(
        '753',
        '6',
        requestedPage,
        100,
        '',
        false,
        false,
        requestedStartAssetId,
        'english'
      );
      const page = await steamArkStateService.syncInventory(accountId, query);
      if (!this.isCurrentInventoryRequest(lifecycleGeneration, requestVersion, accountId,
        accountScopeGeneration)) {
        SteamArkLog.debug('InventoryPage', 'stale inventory page ignored; page=' + requestedPage.toString());
        return;
      }
      if (append) {
        this.appendInventoryItems(page.items);
      } else {
        const cachedPages: Array<SteamInventoryPage> = steamArkStateService.getCachedDefaultInventoryPages(accountId);
        if (cachedPages.length > 0) {
          const lastCachedPage: SteamInventoryPage = cachedPages[cachedPages.length - 1];
          this.inventoryItems = this.mergeCachedInventoryPages(cachedPages);
          this.inventoryPage = lastCachedPage.query.page;
          this.nextStartAssetId = lastCachedPage.nextStartAssetId;
          this.hasMoreInventory = lastCachedPage.hasMore && lastCachedPage.nextStartAssetId.length > 0;
        } else {
          this.inventoryItems = page.items.slice();
          this.inventoryPage = requestedPage;
          this.nextStartAssetId = page.nextStartAssetId;
          this.hasMoreInventory = page.hasMore && page.nextStartAssetId.length > 0;
        }
      }
      this.inventoryTotalCount = page.totalCount;
      this.hasInventorySynced = true;
      this.inventorySyncFailed = false;
      if (append) {
        this.inventoryPage = requestedPage;
        this.nextStartAssetId = page.nextStartAssetId;
        this.hasMoreInventory = page.hasMore && page.nextStartAssetId.length > 0;
      }
      void this.refreshMarketPrices(accountId, lifecycleGeneration, accountScopeGeneration);
      if (!silent) {
        this.statusMessage = page.hasMore && page.nextStartAssetId.length <= 0
          ? $r('app.string.steam_inventory_status_more_unavailable')
          : $r('app.string.steam_inventory_status_sync_success');
      }
      SteamArkLog.info('InventoryPage', 'read-only inventory sync completed; items=' +
        page.items.length.toString() + ', total=' + page.totalCount.toString() +
        ', hasMore=' + String(this.hasMoreInventory));
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
      }
    } finally {
      if (this.isCurrentInventoryRequest(lifecycleGeneration, requestVersion, accountId,
        accountScopeGeneration)) {
        this.activeInventoryRequestCount = Math.max(0, this.activeInventoryRequestCount - 1);
        this.isSyncing = this.activeInventoryRequestCount > 0;
      }
    }
  }

  private restoreInventoryCache(
    accountId: string,
    lifecycleGeneration: number,
    accountScopeGeneration: number
  ): void {
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
      this.restoreInventoryCache(accountId, lifecycleGeneration, accountScopeGeneration);
      void steamArkSyncCoordinator.requestAccountSync(accountId, 'inventory_page_restore')
        .catch((error: Error): void => {
          if (this.isCurrentInventoryScope(lifecycleGeneration, accountId, accountScopeGeneration)) {
            this.inventorySyncFailed = true;
            this.statusMessage = $r('app.string.steam_inventory_status_sync_failed');
          }
          SteamArkLog.warn('InventoryPage', 'background inventory sync dispatch failed; errorType=' +
            SteamArkLog.errorKind(error));
        });
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
    this.coordinatorSyncRunning = accountSnapshot.running;
    const inventoryFailed: boolean = this.hasInventorySyncFailure(accountSnapshot);
    if (accountSnapshot.running && !inventoryFailed) {
      this.inventorySyncFailed = false;
    }
    const inventoryUpdatedAtEpochSeconds: number = accountSnapshot.freshness.inventoryUpdatedAtEpochSeconds;
    if (inventoryUpdatedAtEpochSeconds > this.coordinatorInventoryUpdatedAtEpochSeconds) {
      this.coordinatorInventoryUpdatedAtEpochSeconds = inventoryUpdatedAtEpochSeconds;
      this.restoreInventoryCache(
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

  private resetInventoryResults(): void {
    this.inventoryRequestVersion += 1;
    this.marketPriceRequestVersion += 1;
    this.activeInventoryRequestCount = 0;
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
      const batch = await service.loadBatch(account.profile, items);
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

  private updateInventoryWaterFlowViewport(height: Length): void {
    if (typeof height !== 'number') {
      return;
    }
    this.inventoryPageBodyHeight = height;
    const availableHeight: number = Math.floor(height - this.topInsetVp - 320);
    const nextHeight: number = Math.max(320, Math.min(720, availableHeight));
    if (Math.abs(nextHeight - this.inventoryWaterFlowViewportHeight) >= 1) {
      this.inventoryWaterFlowViewportHeight = nextHeight;
    }
  }

}
