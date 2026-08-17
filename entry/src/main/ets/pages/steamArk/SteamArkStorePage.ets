import { HdsNavDestination } from '@kit.UIDesignKit';
import { NGFControlStyleTokens, NGFHdsTitleBarOptionsFactory, NGFMaterialSurfaceTokens, ngfVisualEffectsFacade } from 'ngf_framework';
import { SteamWishlistItem } from 'steam_core';
import {
  SteamArkLog,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  SteamArkStoreSearchItem,
  steamArkStateService,
  steamArkStoreService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { SteamArkBrowserRequest, SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';

class SteamArkStoreSectionKind {
  static readonly SEARCH: number = 0;
  static readonly WISHLIST: number = 1;
}

/**
 * Read-only store browse: public search plus the account wishlist. Purchases
 * and add-to-wishlist stay in the logged-in in-app browser handoff.
 */
@Component
export struct SteamArkStorePage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private section: number = SteamArkStoreSectionKind.SEARCH;
  @State private queryDraft: string = '';
  @State private searchItems: Array<SteamArkStoreSearchItem> = [];
  @State private searchTotal: number = 0;
  @State private searching: boolean = false;
  @State private searchFailed: boolean = false;
  @State private wishlistItems: Array<SteamWishlistItem> = [];
  @State private wishlistLoading: boolean = false;
  @State private wishlistFailed: boolean = false;
  @State private stateReady: boolean = false;
  @State private selectedAccountId: string = '';
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private isPageActive: boolean = false;
  private generation: number = 0;
  private fetchGeneration: number = 0;
  private wishlistLoadedOnce: boolean = false;
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
    steamArkStateService.subscribe('SteamArkStorePage', this.stateListener);
    const snapshot: SteamArkStateSnapshot = steamArkStateService.getSnapshot();
    this.stateReady = snapshot.initialized;
    this.selectedAccountId = snapshot.selectedAccountId;
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.generation += 1;
    this.fetchGeneration += 1;
    steamArkStateService.unsubscribe('SteamArkStorePage');
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
          $r('app.string.steam_store_title'),
          $r('app.string.steam_store_subtitle'),
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
            this.buildNoticeCard()
            this.buildSectionTabs()
            if (this.section === SteamArkStoreSectionKind.SEARCH) {
              this.buildSearchCard()
              if (this.searching) {
                LoadingProgress()
                  .width(28)
                  .height(28)
                  .color(SteamArkTheme.accent(this.isDarkMode))
              } else if (this.searchFailed) {
                Text($r('app.string.steam_store_search_failed'))
                  .width('100%')
                  .fontSize(12)
                  .fontColor(SteamArkTheme.error(this.isDarkMode))
              } else if (this.searchItems.length <= 0) {
                Text($r('app.string.steam_store_search_empty'))
                  .width('100%')
                  .fontSize(12)
                  .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
              } else {
                this.buildSearchResults()
              }
            } else {
              if (this.wishlistLoading) {
                LoadingProgress()
                  .width(28)
                  .height(28)
                  .color(SteamArkTheme.accent(this.isDarkMode))
              } else if (this.wishlistFailed) {
                Text($r('app.string.steam_store_wishlist_failed'))
                  .width('100%')
                  .fontSize(12)
                  .fontColor(SteamArkTheme.error(this.isDarkMode))
              } else if (this.wishlistItems.length <= 0) {
                Text($r('app.string.steam_store_wishlist_empty'))
                  .width('100%')
                  .fontSize(12)
                  .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
              } else {
                this.buildWishlist()
              }
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
  private buildNoticeCard(): void {
    Text($r('app.string.steam_store_notice'))
      .width('100%')
      .fontSize(12)
      .lineHeight(18)
      .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      .padding(12)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
      .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
  }

  @Builder
  private buildSectionTabs(): void {
    Row({ space: 8 }) {
      Button($r('app.string.steam_store_tab_search'))
        .layoutWeight(1)
        .height(36)
        .buttonStyle(this.section === SteamArkStoreSectionKind.SEARCH
          ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.TEXTUAL)
        .id('steam-ark-store-tab-search')
        .onClick((): void => {
          this.section = SteamArkStoreSectionKind.SEARCH;
        })
      Button($r('app.string.steam_store_tab_wishlist'))
        .layoutWeight(1)
        .height(36)
        .buttonStyle(this.section === SteamArkStoreSectionKind.WISHLIST
          ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.TEXTUAL)
        .id('steam-ark-store-tab-wishlist')
        .onClick((): void => {
          this.section = SteamArkStoreSectionKind.WISHLIST;
          if (!this.wishlistLoadedOnce) {
            this.loadWishlist();
          }
        })
    }
    .width('100%')
  }

  @Builder
  private buildSearchCard(): void {
    Column({ space: 10 }) {
      TextInput({ text: this.queryDraft,
        placeholder: $r('app.string.steam_store_search_placeholder') })
        .id('steam-ark-store-search-input')
        .width('100%')
        .fontSize(14)
        .enabled(!this.searching)
        .onChange((value: string): void => {
          this.queryDraft = value;
        })
        .onSubmit((): void => {
          this.search();
        })
      Button($r('app.string.steam_store_search_button'))
        .width('100%')
        .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(this.canSearch() ? SteamArkTheme.accent(this.isDarkMode)
          : SteamArkTheme.buttonDisabled(this.isDarkMode))
        .enabled(this.canSearch())
        .id('steam-ark-store-search-submit')
        .onClick((): void => {
          this.search();
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildSearchResults(): void {
    Column({ space: 8 }) {
      ForEach(this.searchItems, (item: SteamArkStoreSearchItem) => {
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text(item.name)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(item.priceText.length > 0 ? item.priceText
              : $r('app.string.steam_store_price_unknown'))
              .fontSize(12)
              .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
            if (item.metascoreText.length > 0) {
              Text($r('app.string.steam_store_metascore_prefix') + item.metascoreText)
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button($r('app.string.steam_store_open'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
            .padding({ left: 12, right: 12 })
            .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
            .id('steam-ark-store-open-' + item.appId)
            .onClick((): void => {
              this.openStorePage(item.appId, item.name);
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
        .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
      }, (item: SteamArkStoreSearchItem) => item.appId + '|' + item.name)
      Text($r('app.string.steam_store_total_suffix', this.searchTotal.toString()))
        .width('100%')
        .fontSize(11)
        .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
    }
    .width('100%')
  }

  @Builder
  private buildWishlist(): void {
    Column({ space: 8 }) {
      ForEach(this.wishlistItems, (item: SteamWishlistItem) => {
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text(item.name.length > 0 ? item.name
              : $r('app.string.steam_store_wishlist_unnamed', item.appId))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (item.releaseDateText.length > 0) {
              Text(item.releaseDateText)
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            }
            if (item.priceText.length > 0) {
              Text(item.priceText)
                .fontSize(12)
                .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button($r('app.string.steam_store_open'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
            .padding({ left: 12, right: 12 })
            .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
            .id('steam-ark-wishlist-open-' + item.appId)
            .onClick((): void => {
              this.openStorePage(item.appId, item.name);
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
        .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
      }, (item: SteamWishlistItem) => item.appId + '|' + item.rank.toString())
    }
    .width('100%')
  }

  private canSearch(): boolean {
    return !this.searching && this.queryDraft.trim().length > 0;
  }

  private search(): void {
    if (!this.canSearch()) {
      return;
    }
    const account = steamArkStateService.getSelectedAccount();
    if (account === null) {
      return;
    }
    this.fetchGeneration += 1;
    const fetchGeneration: number = this.fetchGeneration;
    this.searching = true;
    this.searchFailed = false;
    void steamArkStoreService.search(account.profile, this.queryDraft,
      steamArkStateService.resolveAccountLocale(account.profile.accountId))
      .then((result): void => {
        if (!this.isPageActive || this.fetchGeneration !== fetchGeneration) {
          return;
        }
        this.searching = false;
        this.searchFailed = !result.success;
        this.searchItems = result.items;
        this.searchTotal = result.total;
        SteamArkLog.debug('StorePage', 'store search completed; items=' +
          result.items.length.toString());
      })
      .catch((): void => {
        if (this.isPageActive && this.fetchGeneration === fetchGeneration) {
          this.searching = false;
          this.searchFailed = true;
        }
      });
  }

  private loadWishlist(): void {
    if (this.wishlistLoading || this.selectedAccountId.length <= 0) {
      return;
    }
    this.fetchGeneration += 1;
    const fetchGeneration: number = this.fetchGeneration;
    this.wishlistLoading = true;
    this.wishlistFailed = false;
    this.wishlistLoadedOnce = true;
    void steamArkStoreService.loadWishlist(this.selectedAccountId)
      .then((result): void => {
        if (!this.isPageActive || this.fetchGeneration !== fetchGeneration) {
          return;
        }
        this.wishlistLoading = false;
        this.wishlistFailed = !result.success;
        this.wishlistItems = result.items;
      })
      .catch((): void => {
        if (this.isPageActive && this.fetchGeneration === fetchGeneration) {
          this.wishlistLoading = false;
          this.wishlistFailed = true;
        }
      });
  }

  private openStorePage(appId: string, name: string): void {
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest('https://store.steampowered.com/app/' + appId + '/',
        name.length > 0 ? name : appId, 'store.steampowered.com'));
  }
}
