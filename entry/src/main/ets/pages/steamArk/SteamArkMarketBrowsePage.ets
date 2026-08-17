import { HdsNavDestination } from '@kit.UIDesignKit';
import { NGFControlStyleTokens, NGFHdsTitleBarOptionsFactory, NGFMaterialSurfaceTokens, ngfVisualEffectsFacade } from 'ngf_framework';
import { SteamSessionState } from 'steam_core';
import {
  SteamArkAccountSnapshot,
  SteamArkLog,
  SteamArkMarketBrowseResult,
  SteamArkMarketListing,
  SteamArkMarketPriceService,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { SteamArkBrowserRequest, SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';

const PAGE_SIZE: number = 20;

/**
 * Read-only community market browse page. Search results come from the
 * market search render endpoint; buying and selling stay in the logged-in
 * in-app browser handoff.
 */
@Component
export struct SteamArkMarketBrowsePage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private queryDraft: string = '';
  @State private appFilterDraft: string = '';
  @State private activeQuery: string = '';
  @State private activeAppFilter: string = '';
  @State private result: SteamArkMarketBrowseResult | null = null;
  @State private start: number = 0;
  @State private loading: boolean = false;
  @State private stateReady: boolean = false;
  @State private selectedAccountId: string = '';
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly service: SteamArkMarketPriceService = new SteamArkMarketPriceService();
  private isPageActive: boolean = false;
  private generation: number = 0;
  private searchGeneration: number = 0;
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    this.stateReady = snapshot.initialized;
    this.selectedAccountId = snapshot.selectedAccountId;
  };

  aboutToAppear(): void {
    this.isPageActive = true;
    this.generation += 1;
    const currentGeneration: number = this.generation;
    if (this.embedded) {
      this.topInsetVp = this.contentTopInsetVp;
    } else {
      SteamArkPageWindowSupport.loadDynamicTopInset(
        this.getUIContext(),
        108,
        SteamArkTheme.CONTENT_TOP_INSET,
        (inset: number): void => {
          if (this.isPageActive && this.generation === currentGeneration) {
            this.topInsetVp = inset;
          }
        }
      );
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.SETTINGS);
    }
    steamArkStateService.subscribe('SteamArkMarketBrowsePage', this.stateListener);
    const snapshot: SteamArkStateSnapshot = steamArkStateService.getSnapshot();
    this.stateReady = snapshot.initialized;
    this.selectedAccountId = snapshot.selectedAccountId;
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.generation += 1;
    this.searchGeneration += 1;
    steamArkStateService.unsubscribe('SteamArkMarketBrowsePage');
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
          $r('app.string.steam_market_browse_title'),
          $r('app.string.steam_market_browse_subtitle'),
          $r('app.color.background_transparent'),
          SteamArkTheme.textPrimary(this.isDarkMode),
          SteamArkTheme.textSecondary(this.isDarkMode),
          true,
          false
        ))
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
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
    Column() {
      if (!this.stateReady || this.selectedAccountId.length <= 0) {
        SteamArkStateUnavailableCard({
          isDarkMode: this.isDarkMode,
          useSysMat: this.useSysMat
        })
      } else {
        Scroll() {
          Column({ space: 12 }) {
            this.buildSearchCard()
            if (this.loading) {
              LoadingProgress()
                .width(28)
                .height(28)
                .color(SteamArkTheme.accent(this.isDarkMode))
            } else if (this.result !== null && !this.result.success) {
              Text(this.browseErrorText())
                .width('100%')
                .fontSize(12)
                .fontColor(SteamArkTheme.error(this.isDarkMode))
            } else if (this.result !== null && this.result.listings.length <= 0) {
              Text($r('app.string.steam_market_browse_empty'))
                .width('100%')
                .fontSize(12)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            } else if (this.result !== null) {
              this.buildListings()
              this.buildPagination()
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: this.topInsetVp, bottom: 24 })
        }
        .scrollBar(BarState.Auto)
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private buildSearchCard(): void {
    Column({ space: 10 }) {
      Text($r('app.string.steam_market_browse_hint'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      TextInput({ text: this.queryDraft,
        placeholder: $r('app.string.steam_market_browse_query_placeholder') })
        .id('steam-ark-market-browse-query')
        .width('100%')
        .fontSize(14)
        .enabled(!this.loading)
        .onChange((value: string): void => {
          this.queryDraft = value;
        })
        .onSubmit((): void => {
          this.searchFrom(0);
        })
      TextInput({ text: this.appFilterDraft,
        placeholder: $r('app.string.steam_market_browse_app_placeholder') })
        .id('steam-ark-market-browse-app-filter')
        .width('100%')
        .fontSize(14)
        .enabled(!this.loading)
        .onChange((value: string): void => {
          this.appFilterDraft = value;
        })
        .onSubmit((): void => {
          this.searchFrom(0);
        })
      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(16)
            .fontColor([SteamArkTheme.buttonForeground(this.isDarkMode)])
          Text($r('app.string.steam_market_browse_search'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .padding(0)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(this.canSearch() ? SteamArkTheme.accent(this.isDarkMode)
        : SteamArkTheme.buttonDisabled(this.isDarkMode))
      .enabled(this.canSearch())
      .id('steam-ark-market-browse-submit')
      .onClick((): void => {
        this.searchFrom(0);
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildListings(): void {
    Column({ space: 8 }) {
      ForEach(this.result === null ? [] : this.result.listings, (listing: SteamArkMarketListing) => {
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text(listing.displayName)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(listing.sellPriceText.length > 0
              ? listing.sellPriceText
              : $r('app.string.steam_market_browse_price_unknown'))
              .fontSize(12)
              .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
            Text($r('app.string.steam_market_browse_listings_suffix', listing.sellListings.toString()))
              .fontSize(11)
              .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button($r('app.string.steam_market_browse_open'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
            .padding({ left: 12, right: 12 })
            .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
            .id('steam-ark-market-browse-open-' + listing.marketHashName)
            .onClick((): void => {
              this.openListing(listing);
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
        .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
      }, (listing: SteamArkMarketListing) => listing.appId + '|' + listing.marketHashName)
    }
    .width('100%')
  }

  @Builder
  private buildPagination(): void {
    if (this.result !== null && this.result.success) {
      Row({ space: 12 }) {
        Button($r('app.string.steam_market_browse_prev'))
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
          .enabled(!this.loading && this.start > 0)
          .backgroundColor(this.start > 0 ? SteamArkTheme.accent(this.isDarkMode)
            : SteamArkTheme.buttonDisabled(this.isDarkMode))
          .id('steam-ark-market-browse-prev')
          .onClick((): void => {
            this.searchFrom(Math.max(0, this.start - PAGE_SIZE));
          })
        Column({ space: 2 }) {
          Text((this.start + 1).toString() + '-' +
            (this.start + (this.result === null ? 0 : this.result.listings.length)).toString())
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          if (this.result !== null && this.result.totalCount > 0) {
            Text($r('app.string.steam_market_browse_total_suffix', this.result.totalCount.toString()))
              .fontSize(11)
              .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        Button($r('app.string.steam_market_browse_next'))
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
          .enabled(!this.loading && this.hasMorePages())
          .backgroundColor(this.hasMorePages() ? SteamArkTheme.accent(this.isDarkMode)
            : SteamArkTheme.buttonDisabled(this.isDarkMode))
          .id('steam-ark-market-browse-next')
          .onClick((): void => {
            this.searchFrom(this.start + PAGE_SIZE);
          })
      }
      .width('100%')
    }
  }

  private canSearch(): boolean {
    return !this.loading && this.selectedAccountId.length > 0;
  }

  private hasMorePages(): boolean {
    if (this.result === null || !this.result.success) {
      return false;
    }
    return this.start + this.result.listings.length < this.result.totalCount;
  }

  private browseErrorText(): ResourceStr {
    if (this.result !== null && this.result.errorMessage === 'rate_limited') {
      return $r('app.string.steam_market_browse_rate_limited');
    }
    return $r('app.string.steam_market_browse_failed');
  }

  private searchFrom(start: number): void {
    if (!this.canSearch()) {
      return;
    }
    const account: SteamArkAccountSnapshot | null = steamArkStateService.getSelectedAccount();
    if (account === null || account.session.state !== SteamSessionState.LOGGED_ON) {
      return;
    }
    this.searchGeneration += 1;
    const searchGeneration: number = this.searchGeneration;
    this.activeQuery = this.queryDraft;
    this.activeAppFilter = this.appFilterDraft.trim();
    this.start = start;
    this.loading = true;
    void this.service.browse(account.profile, this.activeQuery, this.activeAppFilter,
      start, PAGE_SIZE, steamArkStateService.resolveAccountLocale(account.profile.accountId))
      .then((result: SteamArkMarketBrowseResult): void => {
        if (!this.isPageActive || this.searchGeneration !== searchGeneration) {
          return;
        }
        this.result = result;
        this.loading = false;
        SteamArkLog.debug('MarketBrowsePage', 'market browse completed; listings=' +
          result.listings.length.toString() + ', total=' + result.totalCount.toString());
      })
      .catch((): void => {
        if (this.isPageActive && this.searchGeneration === searchGeneration) {
          this.loading = false;
          this.result = new SteamArkMarketBrowseResult(
            false, 0, PAGE_SIZE, start, '', [], 'network');
        }
      });
  }

  private openListing(listing: SteamArkMarketListing): void {
    const url: string = 'https://steamcommunity.com/market/listings/' +
      listing.appId + '/' + encodeURIComponent(listing.marketHashName) + '/';
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(url, listing.displayName, 'steamcommunity.com'));
  }
}
