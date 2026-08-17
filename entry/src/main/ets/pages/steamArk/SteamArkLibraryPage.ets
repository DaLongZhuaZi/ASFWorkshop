import { HdsNavDestination } from '@kit.UIDesignKit';
import {
  NGFControlStyleTokens,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  ngfI18nManagerFacade,
  ngfRelativeTimeFormatterFacade,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import { SteamLibraryGame, SteamSessionState } from 'steam_core';
import {
  SteamArkGameLibrarySnapshot,
  SteamArkGameLibrarySnapshotListener,
  SteamArkLog,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkGameLibraryService,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import {
  SteamArkBrowserRequest,
  SteamArkGameDetailRequest,
  SteamArkRouteName
} from './SteamArkRoutes';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import { SteamArkGameCover, SteamArkGameCoverUrl } from './SteamArkGameCover';
import { SteamArkGameDetailPage } from './SteamArkGameDetailPage';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkPanelBackBridge } from './SteamArkPanelBackBridge';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';
import { steamArkTabScrollers } from './SteamArkTabScrollers';

const LIBRARY_PANEL_TOP_BAR_HEIGHT: number = 44;
const LIBRARY_PANEL_TOP_BAR_TOP: number = SteamArkTheme.CONTENT_TOP_INSET - LIBRARY_PANEL_TOP_BAR_HEIGHT;

class SteamLibrarySortKind {
  static readonly NAME: number = 0;
  static readonly RECENT: number = 1;
  static readonly PLAYTIME: number = 2;
  static readonly FAVORITE: number = 3;
}

// Section-height simulation constants: every tile renders its cover at the
// clamped aspect ratio plus a fixed text footer (title 2 lines + playtime).
class SteamArkLibraryTileMetrics {
  static readonly FOOTER_HEIGHT: number = 72;
  static readonly ASPECT_MIN: number = 0.45;
  static readonly ASPECT_MAX: number = 2.8;
}

@Component
export struct SteamArkLibraryPage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private selectedAccountId: string = '';
  @State private selectedAccountName: string = '';
  @State private hasAccount: boolean = false;
  @State private syncFailed: boolean = false;
  @State private sessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  @State private games: Array<SteamLibraryGame> = [];
  @State private totalCount: number = 0;
  @State private sortKind: number = SteamLibrarySortKind.NAME;
  @State private stateReady: boolean = false;
  @State private syncing: boolean = false;
  @State private libraryKnown: boolean = false;
  @State private gameWaterFlowViewportHeight: number = 420;
  @State private pageBodyHeight: number = 0;
  @State private headerCardHeight: number = 0;
  @State private sortBarHeight: number = 0;
  @State private gameDetailVisible: boolean = false;
  @State private searchText: string = '';
  @State private collapsedGroupKeys: Array<string> = [];
  @State private searchBarHeight: number = 52;
  @State private gridWidthVp: number = 0;
  /** Compositor-only section transition: 1 fully visible, 0 faded out. */
  @State private gridFade: number = 1;
  private gridSwitching: boolean = false;
  private searchDebounceTimer: number = -1;
  @State private statusMessage: ResourceStr = $r('app.string.steam_library_status_idle');
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private readonly scroller: Scroller = steamArkTabScrollers.library;
  private gameDetailRequest: SteamArkGameDetailRequest = new SteamArkGameDetailRequest();
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (this.isPageActive) {
      this.applyStateSnapshot(snapshot);
    }
  };
  private readonly libraryListener: SteamArkGameLibrarySnapshotListener = (snapshot: SteamArkGameLibrarySnapshot): void => {
    if (this.isPageActive && snapshot.accountId === this.selectedAccountId) {
      this.applyLibrarySnapshot(snapshot);
    }
  };

  aboutToAppear(): void {
    SteamArkLog.lifecycle('LibraryPage', 'aboutToAppear', 'embedded=' + String(this.embedded));
    this.isPageActive = true;
    this.lifecycleGeneration += 1;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    if (this.embedded) {
      SteamArkPanelBackBridge.registerCloseHandler(
        SteamArkPanelBackBridge.GAME_DETAIL_PANEL,
        SteamArkPanelBackBridge.TAB_LIBRARY,
        (): void => {
          this.closeGameDetail();
        });
    } else {
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.HOME);
    }
    steamArkStateService.subscribe('SteamArkLibraryPage', this.stateListener);
    steamArkGameLibraryService.subscribe('SteamArkLibraryPage', this.libraryListener);
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    void this.initializeStateService(lifecycleGeneration);
    SteamArkLog.info('LibraryPage', 'state and library subscriptions registered');
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle('LibraryPage', 'aboutToDisappear', 'embedded=' + String(this.embedded));
    this.isPageActive = false;
    this.lifecycleGeneration += 1;
    if (this.embedded) {
      SteamArkPanelBackBridge.unregisterCloseHandler(SteamArkPanelBackBridge.GAME_DETAIL_PANEL);
    }
    steamArkStateService.unsubscribe('SteamArkLibraryPage');
    steamArkGameLibraryService.unsubscribe('SteamArkLibraryPage');
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
        $r('app.string.steam_library_title'),
        $r('app.string.steam_library_subtitle'),
        $r('app.color.background_transparent'),
        SteamArkTheme.textPrimary(this.isDarkMode),
        SteamArkTheme.textSecondary(this.isDarkMode),
        true,
        false
      ))
      .backgroundImage(this.profileBackgroundUrl)
      .backgroundImageSize(ImageSize.Cover)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .hideTitleBar(this.gameDetailVisible)
      .bindToScrollable([this.scroller])
      .onReady((context: NavDestinationContext): void => {
        this.pathStack = context.pathStack;
      })
      .onBackPressed((): boolean => {
        SteamArkPageWindowSupport.restoreHome();
        if (this.gameDetailVisible) {
          this.closeGameDetail();
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

      // The list stays mounted while the game detail covers it, so WaterFlow
      // scroll and tile geometry never reset and the close-direction
      // geometryTransition always flies back to the real tile position.
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          this.buildHeaderCard()
          if (!this.canUseLibrary()) {
            this.buildUnavailableCard()
          } else {
            this.buildSearchBar()
            this.buildSortBar()
            if (this.filteredGames().length > 0) {
              this.buildLibrarySections()
            } else if (this.searchText.trim().length > 0) {
              this.buildSearchEmptyCard()
            } else if (!this.syncing) {
              this.buildEmptyCard()
            }
          }
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: this.embedded ? this.contentTopInsetVp : SteamArkTheme.CONTENT_TOP_INSET,
          bottom: 0
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

      if (this.gameDetailVisible) {
        Stack({ alignContent: Alignment.TopStart }) {
          SteamArkGameDetailPage({ request: this.gameDetailRequest })
          this.buildGamePanelTopBar()
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
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.updateGameWaterFlowViewport(newValue.height);
    })
  }

  @Builder
  private buildGamePanelTopBar(): void {
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
      .id('steam-ark-game-panel-back')
      .onClick((): void => {
        this.closeGameDetail();
      })

      Text(this.gameDetailRequest.name.length > 0
        ? this.gameDetailRequest.name
        : $r('app.string.steam_library_title'))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: LIBRARY_PANEL_TOP_BAR_TOP, bottom: 6 })
  }

  @Builder
  private buildHeaderCard(): void {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.gamecontroller'))
          .fontSize(24)
          .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
        Column({ space: 3 }) {
          Text(this.selectedAccountName.length > 0
            ? this.selectedAccountName : $r('app.string.steam_library_account_empty'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text(this.statusMessage)
            .fontSize(11)
            .fontColor(this.syncFailed
              ? SteamArkTheme.error(this.isDarkMode) : SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.syncing) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(SteamArkTheme.accent(this.isDarkMode))
        } else {
          Button() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(18)
              .fontColor([SteamArkTheme.accent(this.isDarkMode)])
          }
          .width(40)
          .height(40)
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(this.canUseLibrary())
          .onClick((): void => {
            void this.refreshLibrary();
          })
        }
      }
      .width('100%')
      Row({ space: 14 }) {
        this.buildMetric($r('app.string.steam_library_metric_games'), this.totalCount,
          this.libraryKnown)
        this.buildMetric($r('app.string.steam_library_metric_favorites'), this.favoriteCount(),
          this.libraryKnown)
        this.buildMetric($r('app.string.steam_library_metric_playtime'), this.totalPlaytimeHours(),
          this.libraryKnown)
      }
      .width('100%')
      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.gift'))
            .fontSize(16)
            .fontColor([SteamArkTheme.onAccent(this.isDarkMode)])
          Text($r('app.string.steam_wishlist_entry'))
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
      .enabled(this.selectedAccountId.length > 0)
      .id('steam-ark-library-open-store')
      .onClick((): void => {
        this.openWishlistPage();
      })
    }
    .width('100%')
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.updateHeaderCardHeight(newValue.height);
    })
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildMetric(label: ResourceStr, value: number, isKnown: boolean): void {
    Column({ space: 2 }) {
      Text(isKnown ? value.toString() : '--')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text(label)
        .fontSize(11)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  /** Search box above the sort bar; input changes animate the grid reflow. */
  @Builder
  private buildSearchBar(): void {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(17)
        .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
      TextInput({ text: this.searchText,
        placeholder: $r('app.string.steam_library_search_placeholder') })
        .layoutWeight(1)
        .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
        .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
        .backgroundColor(Color.Transparent)
        .padding(0)
        .onChange((value: string): void => {
          this.scheduleSearchChange(value);
        })
        .onSubmit((): void => {
        })
      if (this.searchText.length > 0) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(13)
            .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
        }
        .width(30)
        .height(30)
        .padding(0)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .accessibilityText($r('app.string.steam_library_search_clear'))
        .onClick((): void => {
          this.clearSearch();
        })
      }
    }
    .width('100%')
    .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
    .padding({ left: 12, right: 8 })
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.updateSearchBarHeight(newValue.height);
    })
  }

  @Builder
  private buildSearchEmptyCard(): void {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.doc_text_magnifyingglass_fill'))
        .fontSize(34)
        .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
      Text($r('app.string.steam_library_search_empty'))
        .fontSize(13)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Button($r('app.string.steam_library_search_clear'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize(12)
        .fontColor(SteamArkTheme.accent(this.isDarkMode))
        .onClick((): void => {
          this.clearSearch();
        })
    }
    .width('100%')
    .height(this.gameWaterFlowViewportHeight)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private buildSortBar(): void {
    Row({ space: 8 }) {
      this.buildSortChip($r('app.string.steam_library_sort_name'), SteamLibrarySortKind.NAME)
      this.buildSortChip($r('app.string.steam_library_sort_recent'), SteamLibrarySortKind.RECENT)
      this.buildSortChip($r('app.string.steam_library_sort_playtime'), SteamLibrarySortKind.PLAYTIME)
      this.buildSortChip($r('app.string.steam_library_sort_favorite'), SteamLibrarySortKind.FAVORITE)
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.updateSortBarHeight(newValue.height);
    })
  }

  @Builder
  private buildSortChip(title: ResourceStr, kind: number): void {
    Text(title)
      .fontSize(12)
      .fontColor(this.sortKind === kind
        ? SteamArkTheme.accent(this.isDarkMode) : SteamArkTheme.textSecondary(this.isDarkMode))
      .fontWeight(this.sortKind === kind ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(this.sortKind === kind
        ? SteamArkTheme.surfaceOverlay(this.isDarkMode)
        : NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
      .onClick((): void => {
        this.applyGridChange((): void => {
          this.sortKind = kind;
        });
        SteamArkLog.debug('LibraryPage', 'library sort changed; kind=' + kind.toString());
      })
  }

  /**
   * The waterfall fills the whole remaining viewport and extends behind the
   * floating bottom bar (barOverlap), like the overview tab's cards: the
   * content keeps flowing into the bar region, so no dead background strip
   * is left between the grid and the bar. The only clearance is the
   * waterfall's small bottom padding, which stops the last row just above
   * the system navigation strip.
   */
  /**
   * Per-group waterfalls: every smart group renders its own header row (a
   * standalone full line) followed by its own WaterFlow whose height is
   * simulated from the tile aspects. The page-level Scroll owns scrolling, so
   * collapsing animates the section height to zero instead of removing items.
   */
  @Builder
  private buildLibrarySections(): void {
    Column() {
      ForEach(this.sectionBucketKeys(), (bucketKey: string) => {
        this.buildGroupSection(bucketKey)
      }, (bucketKey: string): string => bucketKey)
    }
    .width('100%')
    // Compositor-only transition for sort/search changes: animating just
    // opacity/scale keeps every child untouched — no per-item re-layout, so
    // large libraries stay smooth. The data swap happens while faded out.
    .opacity(this.gridFade)
    .scale({
      x: 1 - 0.03 * (1 - this.gridFade),
      y: 1 - 0.03 * (1 - this.gridFade)
    })
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      if (typeof newValue.width === 'number' && newValue.width > 0 &&
        Math.abs(newValue.width - this.gridWidthVp) >= 1) {
        this.gridWidthVp = newValue.width;
      }
    })
  }

  /**
   * Two-phase grid transition: fade the section container out (compositor),
   * swap the driving state underneath, fade back in. Item-level moves are
   * deliberately avoided — re-laying out hundreds of tiles janks the frame.
   */
  private applyGridChange(mutate: () => void): void {
    if (this.gridSwitching) {
      return;
    }
    this.gridSwitching = true;
    this.getUIContext().animateTo({
      duration: 120,
      curve: Curve.FastOutSlowIn,
      onFinish: (): void => {
        this.getUIContext().animateTo({
          duration: 220,
          curve: Curve.FastOutSlowIn,
          onFinish: (): void => {
            this.gridSwitching = false;
          }
        }, (): void => {
          mutate();
          this.gridFade = 1;
        });
      }
    }, (): void => {
      this.gridFade = 0;
    });
  }

  /** Debounced search input so fast typing coalesces into one transition. */
  private scheduleSearchChange(value: string): void {
    if (this.searchDebounceTimer >= 0) {
      clearTimeout(this.searchDebounceTimer);
    }
    this.searchDebounceTimer = setTimeout((): void => {
      this.searchDebounceTimer = -1;
      this.applyGridChange((): void => {
        this.searchText = value;
      });
    }, 240);
  }

  private clearSearch(): void {
    if (this.searchDebounceTimer >= 0) {
      clearTimeout(this.searchDebounceTimer);
      this.searchDebounceTimer = -1;
    }
    this.applyGridChange((): void => {
      this.searchText = '';
    });
  }

  @Builder
  private buildGroupSection(bucketKey: string): void {
    Column({ space: 8 }) {
      if (bucketKey.length > 0) {
        this.buildSectionHeaderRow(bucketKey)
      }
      // Waterfall packing per section. Reorders never animate item moves
      // (WaterFlow cannot, and full re-layout janks large libraries); the
      // sort/search transition is a compositor-only container fade instead.
      WaterFlow({ layoutMode: WaterFlowLayoutMode.SLIDING_WINDOW }) {
        ForEach(this.sectionGames(bucketKey), (game: SteamLibraryGame) => {
          FlowItem() {
            this.buildGameTile(game)
          }
          .width('100%')
        }, (game: SteamLibraryGame): string => bucketKey + '-' + game.appId)
      }
      .width('100%')
      .columnsTemplate(this.gridColumnsTemplate())
      .columnsGap(10)
      .rowsGap(12)
      .edgeEffect(EdgeEffect.None)
      .scrollBar(BarState.Off)
      .cachedCount(12)
      .clip(true)
      .height(this.sectionHeight(bucketKey))
    }
    .width('100%')
  }

  /** Standalone full-line group header; count derives live from the filter. */
  @Builder
  private buildSectionHeaderRow(bucketKey: string): void {
    Button() {
      Row({ space: 8 }) {
        SymbolGlyph(this.collapsedGroupKeys.includes(bucketKey)
          ? $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
        Text(this.bucketLabel(bucketKey))
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text(this.sectionGames(bucketKey).length.toString())
          .fontSize(11)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        Blank()
      }
      .width('100%')
      .height(40)
      .padding({ left: 10, right: 10 })
    }
    .width('100%')
    .height(40)
    .padding(0)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
    .border({ width: { bottom: 1 }, color: SteamArkTheme.divider(this.isDarkMode) })
    .onClick((): void => {
      this.toggleGroup(bucketKey);
    })
  }

  @Builder
  private buildGameTile(game: SteamLibraryGame): void {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        if (this.gameDetailVisible && this.gameDetailRequest.appId === game.appId) {
          // The opened tile cover unmounts (real disappear) so the detail
          // cover can pair with it in both flight directions; the equal-size
          // placeholder keeps the persistent list layout stable.
          Column()
            .width('100%')
            .aspectRatio(SteamArkGameCoverUrl.aspectFor(game.appId, game.logoUrl, game.iconUrl))
        } else {
          SteamArkGameCover({
            appId: game.appId,
            primaryUrl: SteamArkGameCoverUrl.largeFor(game.appId, game.logoUrl, game.iconUrl),
            fallbackUrl: game.logoUrl,
            iconUrl: game.iconUrl,
            isDarkMode: this.isDarkMode,
            coverAspectRatio: SteamArkGameCoverUrl.aspectFor(game.appId, game.logoUrl, game.iconUrl)
          })
          .clip(true)
          .geometryTransition(SteamArkGameDetailRequest.coverGeometryId(game.appId))
          .transition(TransitionEffect.OPACITY)
        }
        if (game.favorite) {
          Text('★')
            .fontSize(13)
            .fontColor(SteamArkTheme.accent(this.isDarkMode))
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor(SteamArkTheme.surfaceControl(this.isDarkMode))
            .borderRadius(7)
            .margin(6)
        }
      }
      .width('100%')
      Text(game.name)
        .width('100%')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (game.playtimeForeverSeconds > 0) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(11)
            .fontColor([SteamArkTheme.accent(this.isDarkMode)])
          Text(this.playtimeText(game))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text($r('app.string.steam_library_hours_unit'))
            .fontSize(10)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .width('100%')
      }
      if (game.lastPlayedEpochSeconds > 0) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.calendar'))
            .fontSize(10)
            .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
          Text($r('app.string.steam_library_last_played_label'))
            .fontSize(10)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          Text(this.lastPlayedText(game))
            .fontSize(10)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
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
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
    .onClick((): void => {
      this.openGamePage(game);
    })
  }

  @Builder
  private buildUnavailableCard(): void {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.gamecontroller'))
        .fontSize(30)
        .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
      Text($r('app.string.steam_library_unavailable_title'))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_library_unavailable_desc'))
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildEmptyCard(): void {
    Column({ space: 8 }) {
      Text($r('app.string.steam_library_empty_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_library_empty_desc'))
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  private async initializeStateService(lifecycleGeneration: number): Promise<void> {
    try {
      const initialized: boolean = await steamArkStateService.initialize();
      if (!this.isCurrentLifecycle(lifecycleGeneration)) {
        return;
      }
      this.applyStateSnapshot(steamArkStateService.getSnapshot());
      SteamArkLog.info('LibraryPage', 'state service ready; initialized=' + String(initialized));
      if (initialized) {
        this.restoreLibrary();
        void this.refreshLibrary();
      }
    } catch (error) {
      SteamArkLog.warn('LibraryPage', 'state service initialization failed; errorType=' +
        SteamArkLog.errorKind(error));
    }
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    if (!this.isPageActive) {
      return;
    }
    this.stateReady = snapshot.initialized;
    const previousId: string = this.selectedAccountId;
    this.selectedAccountId = snapshot.selectedAccountId;
    this.hasAccount = snapshot.selectedAccountId.length > 0;
    const selected = steamArkStateService.getSelectedAccount();
    const nextSessionState = selected === null
      ? SteamSessionState.DISCONNECTED
      : selected.session.state;
    if (selected === null) {
      this.selectedAccountName = '';
      this.sessionState = SteamSessionState.DISCONNECTED;
    } else {
      this.selectedAccountName = selected.profile.displayName.length > 0
        ? selected.profile.displayName
        : selected.profile.accountId;
      this.sessionState = nextSessionState;
    }
    if (previousId !== this.selectedAccountId) {
      this.games = [];
      this.totalCount = 0;
      this.libraryKnown = false;
      this.restoreLibrary();
      if (this.canUseLibrary()) {
        void this.refreshLibrary();
      }
    }
  }

  private applyLibrarySnapshot(snapshot: SteamArkGameLibrarySnapshot): void {
    if (!this.isPageActive || snapshot.accountId !== this.selectedAccountId) {
      return;
    }
    this.games = snapshot.games;
    this.totalCount = snapshot.totalCount;
    this.libraryKnown = snapshot.totalCount > 0 || snapshot.games.length > 0 ||
      snapshot.updatedAtEpochSeconds > 0;
    this.syncing = false;
    const hasGames: boolean = snapshot.games.length > 0;
    // A refresh failure only turns the header red when there is nothing to
    // show; cached games stay visible with a stale-data status instead.
    const hardFailed: boolean = snapshot.errorMessage.length > 0 && !hasGames;
    this.syncFailed = hardFailed;
    if (hardFailed) {
      this.statusMessage = $r('app.string.steam_library_status_failed');
    } else if (snapshot.errorMessage.length > 0) {
      this.statusMessage = $r('app.string.steam_library_status_stale');
    } else if (hasGames) {
      this.statusMessage = $r('app.string.steam_library_status_synced');
    } else {
      this.statusMessage = $r('app.string.steam_library_status_idle');
    }
  }

  private restoreLibrary(): void {
    if (this.selectedAccountId.length <= 0) {
      return;
    }
    const restored = steamArkGameLibraryService.restore(this.selectedAccountId);
    if (restored !== null) {
      this.applyLibrarySnapshot(restored);
    }
  }

  private async refreshLibrary(): Promise<void> {
    if (this.syncing || this.selectedAccountId.length <= 0) {
      return;
    }
    if (!this.canUseLibrary()) {
      this.statusMessage = $r('app.string.steam_library_status_not_logged_on');
      return;
    }
    this.syncing = true;
    this.statusMessage = $r('app.string.steam_library_status_loading');
    try {
      await steamArkGameLibraryService.sync(this.selectedAccountId);
    } catch (_error) {
      if (this.isPageActive) {
        this.syncing = false;
        this.syncFailed = true;
        this.statusMessage = $r('app.string.steam_library_status_failed');
      }
    }
  }

  private canUseLibrary(): boolean {
    return this.stateReady && this.hasAccount && this.sessionState === SteamSessionState.LOGGED_ON;
  }

  /**
   * The waterfall fills the whole remaining viewport and extends into the
   * bottom bar region (barOverlap): once the header card and the sort bar
   * are measured, the grid gets exactly the remaining page height (top inset
   * and the two 12vp gaps included), so its bottom edge reaches the window
   * bottom behind the floating tab bar. Before the first measurement a fixed
   * estimate keeps the first frame stable.
   */
  private updateGameWaterFlowViewport(height: Length): void {
    if (typeof height !== 'number') {
      return;
    }
    this.pageBodyHeight = height;
    const topInset: number = this.embedded ? this.contentTopInsetVp : SteamArkTheme.CONTENT_TOP_INSET;
    const gapSpace: number = 24;
    // Embedded-in-tabs mode also reserves the docked friends mini bar above
    // the floating tab bar; routed pages have neither.
    const bottomReserve: number = this.embedded ? SteamArkExperiencePolicy.FRIENDS_BAR_RESERVE : 0;
    let availableHeight: number;
    if (this.headerCardHeight > 0 && this.sortBarHeight > 0) {
      availableHeight = Math.floor(height - topInset - bottomReserve -
        this.headerCardHeight - this.searchBarHeight - this.sortBarHeight - gapSpace);
    } else {
      availableHeight = Math.floor(height - topInset - bottomReserve - 260 - this.searchBarHeight);
    }
    const nextHeight: number = Math.max(320, availableHeight);
    if (Math.abs(nextHeight - this.gameWaterFlowViewportHeight) >= 1) {
      this.gameWaterFlowViewportHeight = nextHeight;
    }
  }

  private updateHeaderCardHeight(height: Length): void {
    if (typeof height !== 'number' || Math.abs(height - this.headerCardHeight) < 1) {
      return;
    }
    this.headerCardHeight = height;
    if (this.pageBodyHeight > 0) {
      this.updateGameWaterFlowViewport(this.pageBodyHeight);
    }
  }

  private updateSortBarHeight(height: Length): void {
    if (typeof height !== 'number' || Math.abs(height - this.sortBarHeight) < 1) {
      return;
    }
    this.sortBarHeight = height;
    if (this.pageBodyHeight > 0) {
      this.updateGameWaterFlowViewport(this.pageBodyHeight);
    }
  }

  private sortedGames(): Array<SteamLibraryGame> {
    const result: Array<SteamLibraryGame> = this.games.slice();
    if (this.sortKind === SteamLibrarySortKind.RECENT) {
      result.sort((left: SteamLibraryGame, right: SteamLibraryGame): number => {
        return right.lastPlayedEpochSeconds - left.lastPlayedEpochSeconds;
      });
    } else if (this.sortKind === SteamLibrarySortKind.PLAYTIME) {
      result.sort((left: SteamLibraryGame, right: SteamLibraryGame): number => {
        return right.playtimeForeverSeconds - left.playtimeForeverSeconds;
      });
    } else if (this.sortKind === SteamLibrarySortKind.FAVORITE) {
      result.sort((left: SteamLibraryGame, right: SteamLibraryGame): number => {
        if (left.favorite !== right.favorite) {
          return left.favorite ? -1 : 1;
        }
        return left.name.localeCompare(right.name);
      });
    } else {
      result.sort((left: SteamLibraryGame, right: SteamLibraryGame): number => {
        return left.name.localeCompare(right.name);
      });
    }
    return result;
  }

  /**
   * Sorted games narrowed by the search query. Steam localizes game names per
   * account language, so a plain case-insensitive substring match covers
   * multi-language fuzzy search; the AppID is matched too.
   */
  private filteredGames(): Array<SteamLibraryGame> {
    const query: string = this.searchText.trim().toLowerCase();
    const sorted: Array<SteamLibraryGame> = this.sortedGames();
    if (query.length <= 0) {
      return sorted;
    }
    return sorted.filter((game: SteamLibraryGame): boolean =>
      game.name.toLowerCase().includes(query) || game.appId.includes(query));
  }

  /**
   * Section keys to render: grouped sorts list their non-empty buckets in
   * order; a single-bucket result and all other sorts render one headerless
   * flat section.
   */
  private sectionBucketKeys(): Array<string> {
    const grouped: boolean = this.sortKind === SteamLibrarySortKind.RECENT ||
      this.sortKind === SteamLibrarySortKind.PLAYTIME;
    if (!grouped) {
      return [''];
    }
    const games: Array<SteamLibraryGame> = this.filteredGames();
    const present: Map<string, boolean> = new Map<string, boolean>();
    for (let index = 0; index < games.length; index++) {
      const bucketKey: string = this.sortKind === SteamLibrarySortKind.RECENT
        ? this.recentBucketOf(games[index]) : this.playtimeBucketOf(games[index]);
      present.set(bucketKey, true);
    }
    if (present.size <= 1) {
      return [''];
    }
    const keys: Array<string> = [];
    const order: Array<string> = this.bucketOrder();
    for (let index = 0; index < order.length; index++) {
      if (present.has(order[index])) {
        keys.push(order[index]);
      }
    }
    return keys;
  }

  /** Games of one section; the empty key means the flat full list. */
  private sectionGames(bucketKey: string): Array<SteamLibraryGame> {
    const games: Array<SteamLibraryGame> = this.filteredGames();
    if (bucketKey.length <= 0) {
      return games;
    }
    return games.filter((game: SteamLibraryGame): boolean =>
      (this.sortKind === SteamLibrarySortKind.RECENT
        ? this.recentBucketOf(game) : this.playtimeBucketOf(game)) === bucketKey);
  }

  /** Live section height: 0 when collapsed, else simulated waterfall height. */
  private sectionHeight(bucketKey: string): number {
    if (bucketKey.length > 0 && this.collapsedGroupKeys.includes(bucketKey)) {
      return 0;
    }
    const games: Array<SteamLibraryGame> = this.sectionGames(bucketKey);
    if (games.length <= 0 || this.gridWidthVp <= 0) {
      return 0;
    }
    const columns: number = this.gridColumns();
    if (columns <= 0) {
      return 0;
    }
    const tileWidth: number = (this.gridWidthVp - (columns - 1) * 10) / columns;
    return this.simulatedWaterfallHeight(games, columns, tileWidth) +
      (bucketKey.length > 0 ? 8 : 20);
  }

  /** Shortest-column packing simulation: each tile lands on the shortest column. */
  private simulatedWaterfallHeight(games: Array<SteamLibraryGame>,
    columns: number, tileWidth: number): number {
    const columnHeights: Array<number> = [];
    for (let index = 0; index < columns; index++) {
      columnHeights.push(0);
    }
    for (let index = 0; index < games.length; index++) {
      const game: SteamLibraryGame = games[index];
      const rawAspect: number = SteamArkGameCoverUrl.aspectFor(
        game.appId, game.logoUrl, game.iconUrl);
      const aspect: number = Math.min(SteamArkLibraryTileMetrics.ASPECT_MAX,
        Math.max(SteamArkLibraryTileMetrics.ASPECT_MIN, rawAspect));
      const tileHeight: number = tileWidth / aspect + SteamArkLibraryTileMetrics.FOOTER_HEIGHT;
      let shortest: number = 0;
      for (let column = 1; column < columnHeights.length; column++) {
        if (columnHeights[column] < columnHeights[shortest]) {
          shortest = column;
        }
      }
      columnHeights[shortest] += tileHeight + 12;
    }
    let tallest: number = 0;
    for (let index = 0; index < columnHeights.length; index++) {
      if (columnHeights[index] > tallest) {
        tallest = columnHeights[index];
      }
    }
    return tallest;
  }

  /** Column count mirrors the SM2/MD3/LG5 breakpoints the grid used before. */
  private gridColumns(): number {
    if (this.gridWidthVp >= 840) {
      return 5;
    }
    if (this.gridWidthVp >= 600) {
      return 3;
    }
    return 2;
  }

  private gridColumnsTemplate(): string {
    const columns: number = this.gridColumns();
    let template: string = '';
    for (let index = 0; index < columns; index++) {
      template += (index > 0 ? ' ' : '') + '1fr';
    }
    return template.length > 0 ? template : '1fr 1fr';
  }

  private bucketOrder(): Array<string> {
    if (this.sortKind === SteamLibrarySortKind.RECENT) {
      return ['recent_2d', 'recent_7d', 'recent_30d', 'recent_older', 'never'];
    }
    return ['pt_1000', 'pt_500', 'pt_100', 'pt_50', 'pt_10', 'pt_lt10', 'never'];
  }

  private recentBucketOf(game: SteamLibraryGame): string {
    if (game.lastPlayedEpochSeconds <= 0) {
      return 'never';
    }
    const ageDays: number = (Math.floor(Date.now() / 1000) - game.lastPlayedEpochSeconds) / 86400;
    if (ageDays < 2) {
      return 'recent_2d';
    }
    if (ageDays < 7) {
      return 'recent_7d';
    }
    if (ageDays < 30) {
      return 'recent_30d';
    }
    return 'recent_older';
  }

  private playtimeBucketOf(game: SteamLibraryGame): string {
    if (game.playtimeForeverSeconds <= 0) {
      return 'never';
    }
    const hours: number = game.playtimeForeverSeconds / 3600;
    if (hours >= 1000) {
      return 'pt_1000';
    }
    if (hours >= 500) {
      return 'pt_500';
    }
    if (hours >= 100) {
      return 'pt_100';
    }
    if (hours >= 50) {
      return 'pt_50';
    }
    if (hours >= 10) {
      return 'pt_10';
    }
    return 'pt_lt10';
  }

  private bucketLabel(bucketKey: string): ResourceStr {
    switch (bucketKey) {
      case 'recent_2d':
        return $r('app.string.steam_library_group_recent_2d');
      case 'recent_7d':
        return $r('app.string.steam_library_group_recent_7d');
      case 'recent_30d':
        return $r('app.string.steam_library_group_recent_30d');
      case 'recent_older':
        return $r('app.string.steam_library_group_recent_older');
      case 'pt_1000':
        return $r('app.string.steam_library_group_pt_1000');
      case 'pt_500':
        return $r('app.string.steam_library_group_pt_500');
      case 'pt_100':
        return $r('app.string.steam_library_group_pt_100');
      case 'pt_50':
        return $r('app.string.steam_library_group_pt_50');
      case 'pt_10':
        return $r('app.string.steam_library_group_pt_10');
      case 'pt_lt10':
        return $r('app.string.steam_library_group_pt_lt10');
      case 'never':
        return $r('app.string.steam_library_group_never');
      default:
        return '';
    }
  }

  private toggleGroup(bucketKey: string): void {
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.SECTION_EXPAND_DURATION,
      curve: Curve.EaseOut
    }, (): void => {
      const next: Array<string> = this.collapsedGroupKeys.slice();
      const index: number = next.indexOf(bucketKey);
      if (index >= 0) {
        next.splice(index, 1);
      } else {
        next.push(bucketKey);
      }
      this.collapsedGroupKeys = next;
    });
  }

  private updateSearchBarHeight(height: Length): void {
    if (typeof height !== 'number' || height <= 0) {
      return;
    }
    if (Math.abs(height - this.searchBarHeight) >= 1) {
      this.searchBarHeight = height;
      this.updateGameWaterFlowViewport(this.pageBodyHeight);
    }
  }

  private favoriteCount(): number {
    let count = 0;
    for (let index = 0; index < this.games.length; index++) {
      if (this.games[index].favorite) {
        count++;
      }
    }
    return count;
  }

  private totalPlaytimeHours(): number {
    let seconds = 0;
    for (let index = 0; index < this.games.length; index++) {
      seconds += this.games[index].playtimeForeverSeconds;
    }
    return Math.round(seconds / 3600);
  }

  private playtimeText(game: SteamLibraryGame): string {
    if (game.playtimeForeverSeconds <= 0) {
      return '';
    }
    const hours = game.playtimeForeverSeconds / 3600;
    return hours >= 100 ? Math.round(hours).toString() : hours.toFixed(1);
  }

  private lastPlayedText(game: SteamLibraryGame): string {
    if (game.lastPlayedEpochSeconds <= 0) {
      return '';
    }
    const result = ngfRelativeTimeFormatterFacade.format(
      game.lastPlayedEpochSeconds * 1000,
      this.timeLocale()
    );
    return result.text;
  }

  private timeLocale(): string {
    const locale = steamArkStateService.resolveAccountLocale(this.selectedAccountId);
    const steamLanguage = locale !== null ? locale.steamLanguage : '';
    if (steamLanguage === 'schinese' || steamLanguage === 'tchinese') {
      return 'zh-CN';
    }
    if (steamLanguage === 'japanese') {
      return 'ja-JP';
    }
    if (steamLanguage === 'koreana') {
      return 'ko-KR';
    }
    if (steamLanguage === 'russian') {
      return 'ru-RU';
    }
    if (steamLanguage === 'brazilian') {
      return 'pt-BR';
    }
    return 'en-US';
  }

  /** Opens the selected account's wishlist in the logged-in in-app browser. */
  private openWishlistPage(): void {
    const account = steamArkStateService.getSelectedAccount();
    const steamId64: string = account === null ? '' : account.profile.steamId64.trim();
    if (steamId64.length <= 0) {
      SteamArkLog.warn('LibraryPage', 'wishlist open skipped; selected account has no steamId64');
      return;
    }
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest('https://steamcommunity.com/profiles/' + steamId64 + '/wishlist/',
        ngfI18nManagerFacade.resolveString($r('app.string.steam_wishlist_entry')),
        'steamcommunity.com'));
  }

  private openGamePage(game: SteamLibraryGame): void {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.info('LibraryPage', 'library game opened; appId=' + game.appId);
    const request: SteamArkGameDetailRequest = new SteamArkGameDetailRequest(
      game.appId,
      game.name,
      game.logoUrl,
      game.iconUrl,
      game.playtimeForeverSeconds,
      game.playtimeTwoWeeksSeconds,
      game.lastPlayedEpochSeconds,
      game.favorite
    );
    this.gameDetailRequest = request;
    if (this.embedded) {
      SteamArkPanelBackBridge.setVisible(SteamArkPanelBackBridge.GAME_DETAIL_PANEL, true);
    }
    // Official 一镜到底 (persistent-source variant): the list stays mounted;
    // the opened tile cover unmounts while the detail is open so the pair has
    // a genuine appear/disappear in both flight directions, and the flight
    // always ends at the tile's real, never-reset position.
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.EXPAND_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.gameDetailVisible = true;
    });
  }

  private closeGameDetail(): void {
    if (!this.gameDetailVisible) {
      return;
    }
    SteamArkLog.info('LibraryPage', 'game detail closed');
    if (this.embedded) {
      SteamArkPanelBackBridge.setVisible(SteamArkPanelBackBridge.GAME_DETAIL_PANEL, false);
    }
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.EXPAND_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.gameDetailVisible = false;
    });
  }

  private isCurrentLifecycle(lifecycleGeneration: number): boolean {
    return this.isPageActive && this.lifecycleGeneration === lifecycleGeneration;
  }
}
