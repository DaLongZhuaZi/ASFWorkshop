import {
  NGFControlStyleTokens,
  NGFMaterialSurfaceTokens,
  ngfRelativeTimeFormatterFacade,
  ngfVisualEffectsFacade,
  resolveResourceString
} from 'ngf_framework';
import {
  SteamGameAchievementsResult,
  SteamGameDetailBundle,
  SteamGameDetailInfo,
  SteamGameDrop,
  SteamCredentialSet,
  SteamInventoryCardDropState,
  SteamInventoryItem,
  SteamLibraryGame
} from 'steam_core';
import {
  SteamArkLog,
  SteamArkRegionPolicy,
  steamArkFarmingService,
  steamArkGameLibraryService,
  steamArkStateService
} from '../../steamServices';
import {
  SteamArkMarketPrice,
  SteamArkMarketPriceHistory,
  SteamArkMarketPriceHistoryPoint,
  SteamArkMarketPriceService
} from '../../steamServices/SteamArkMarketPriceService';
import { SteamArkTheme } from './SteamArkTheme';
import {
  SteamArkBrowserRequest,
  SteamArkGameDetailRequest,
  SteamArkInventoryDetailRequest,
  SteamArkRouteName
} from './SteamArkRoutes';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';

const TAG: string = 'InventoryDetailPage';
const MAX_CHART_POINTS: number = 160;
const CHART_HEIGHT_VP: number = 200;
const STEAM_COMMUNITY_APP_ID: string = '753';

/**
 * In-app inventory item detail panel rendered as an in-page overlay inside
 * the inventory page (官方一镜到底方式三：同页 if/else + geometryTransition +
 * animateTo). Its header icon shares a geometryTransition id with the clicked
 * tile icon, so the icon morphs between the tile and the header while the
 * panel fades in. The inventory page owns the animateTo timing and the back
 * button; market price, badge progress and related game info are fetched
 * independently so one failing source never hides the others.
 */
@Component
export struct SteamArkInventoryDetailPage {
  @Prop request: SteamArkInventoryDetailRequest = new SteamArkInventoryDetailRequest();
  @State private loading: boolean = true;
  @State private hasAccount: boolean = false;
  @State private marketLoading: boolean = false;
  @State private marketFailed: boolean = false;
  @State private marketPrice: SteamArkMarketPrice | null = null;
  @State private priceHistoryLoading: boolean = false;
  @State private priceHistoryFailed: boolean = false;
  @State private priceHistory: SteamArkMarketPriceHistory | null = null;
  @State private gameLoading: boolean = false;
  @State private gameFailed: boolean = false;
  @State private gameInfo: SteamGameDetailInfo | null = null;
  @State private gameAchievements: SteamGameAchievementsResult | null = null;
  @State private badgeDrop: SteamGameDrop | null = null;
  @State private playtimeSeconds: number = 0;
  @State private heroCollapseRatio: number = 0;
  @State private heroZoneWidthVp: number = 0;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly chartContext: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private static readonly HERO_EXPANDED_HEIGHT: number = 160;
  private static readonly HERO_DOCK_SIZE: number = 56;
  private readonly heroScroller: Scroller = new Scroller();
  private isPageActive: boolean = false;
  private loadGeneration: number = 0;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.heroCollapseRatio = 0;
    SteamArkLog.lifecycle(TAG, 'aboutToAppear', 'assetId=' + this.request.assetId +
      ', appId=' + this.request.appId + ', ownerAppId=' + this.request.ownerAppId);
    void this.loadDetail();
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle(TAG, 'aboutToDisappear', 'assetId=' + this.request.assetId);
    this.isPageActive = false;
    this.loadGeneration += 1;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      SteamArkProfileBackground()
      Scroll(this.heroScroller) {
        Column({ space: 12 }) {
          this.buildHeaderCard()
          if (this.loading && !this.hasAccount) {
            this.buildLoadingCard()
          } else if (!this.hasAccount) {
            this.buildFailedCard()
          } else {
            this.buildMarketCard()
            this.buildBadgeCard()
            this.buildGameCard()
            this.buildAttributesCard()
            this.buildDescriptionCard()
            this.buildActionsCard()
          }
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: SteamArkTheme.CONTENT_TOP_INSET + SteamArkInventoryDetailPage.HERO_EXPANDED_HEIGHT + 12,
          bottom: 48
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onDidScroll((_xOffset: number, _yOffset: number): void => {
        this.updateHeroCollapse();
      })
      this.buildHeroDock()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(SteamArkTheme.background(this.isDarkMode))
  }

  /**
   * Collapsing hero: the item icon stays pinned at the top, shrinks 1:1 with
   * the scroll offset down to a small top-left dock with the name beside it,
   * and grows back when scrolling up. The geometryTransition id never leaves
   * this node, so the seamless open/close flight keeps working from any size.
   */
  @Builder
  private buildHeroDock(): void {
    Column() {
      Row({ space: 12 }) {
        if (this.itemIconUrl().length > 0) {
          Image(this.itemIconUrl())
            .width(this.heroWidthVp())
            .height(this.heroHeightVp())
            .objectFit(ImageFit.Contain)
            .backgroundColor(Color.Transparent)
            .clip(true)
            .geometryTransition(SteamArkInventoryDetailRequest.iconGeometryId(this.request.assetId))
            .transition(TransitionEffect.OPACITY)
            .onError((): void => {
            })
        } else {
          SymbolGlyph($r('sys.symbol.archivebox'))
            .fontSize(this.heroCollapseRatio > 0.5 ? 22 : 44)
            .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
        }
        Column({ space: 2 }) {
          Text(this.displayName())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.request.type.length > 0) {
            Text(this.request.type)
              .fontSize(11)
              .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .opacity(this.heroCollapseRatio)
      }
      .width('100%')
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        if (typeof newValue.width === 'number' && newValue.width > 0) {
          this.heroZoneWidthVp = newValue.width;
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: SteamArkTheme.CONTENT_TOP_INSET })
    .hitTestBehavior(HitTestMode.None)
  }

  private heroWidthVp(): Length {
    if (this.heroZoneWidthVp <= 0) {
      return '100%';
    }
    return this.heroZoneWidthVp +
      (SteamArkInventoryDetailPage.HERO_DOCK_SIZE - this.heroZoneWidthVp) * this.heroCollapseRatio;
  }

  private heroHeightVp(): number {
    const expanded: number = SteamArkInventoryDetailPage.HERO_EXPANDED_HEIGHT;
    return expanded + (SteamArkInventoryDetailPage.HERO_DOCK_SIZE - expanded) * this.heroCollapseRatio;
  }

  private updateHeroCollapse(): void {
    const travel: number = SteamArkInventoryDetailPage.HERO_EXPANDED_HEIGHT -
      SteamArkInventoryDetailPage.HERO_DOCK_SIZE + 24;
    const offset: number = this.heroScroller.currentOffset().yOffset;
    const ratio: number = Math.min(1, Math.max(0, offset / travel));
    if (Math.abs(ratio - this.heroCollapseRatio) >= 0.004 ||
      (ratio === 0) !== (this.heroCollapseRatio === 0)) {
      this.heroCollapseRatio = ratio;
    }
  }

  @Builder
  private buildHeaderCard(): void {
    Column({ space: 10 }) {
      Column({ space: 6 }) {
        Text(this.displayName())
          .width('100%')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.marketNameLine().length > 0) {
          Text(this.marketNameLine())
            .width('100%')
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.request.type.length > 0) {
          Text(this.request.type)
            .width('100%')
            .fontSize(11)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
          this.buildHeaderChip(this.inventoryCategory())
          if (this.request.marketable) {
            this.buildHeaderChip($r('app.string.steam_inventory_badge_marketable'))
          }
          if (this.request.tradable) {
            this.buildHeaderChip($r('app.string.steam_inventory_badge_tradable'))
          }
          if (Number.isSafeInteger(this.request.amount) && this.request.amount >= 0) {
            this.buildHeaderChip($r('app.string.steam_inventory_detail_amount_chip',
              this.request.amount))
          }
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
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
  private buildHeaderChip(label: ResourceStr): void {
    Text(label)
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontColor(SteamArkTheme.accent(this.isDarkMode))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor(SteamArkTheme.surfaceControl(this.isDarkMode))
      .borderRadius(7)
      .margin({ right: 6, bottom: 6 })
  }

  @Builder
  private buildLoadingCard(): void {
    Column({ space: 8 }) {
      LoadingProgress()
        .width(30)
        .height(30)
        .color(SteamArkTheme.accent(this.isDarkMode))
      Text($r('app.string.steam_inventory_detail_loading'))
        .fontSize(12)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .width('100%')
    .padding(24)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildFailedCard(): void {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
        .fontSize(28)
        .fontColor([SteamArkTheme.warning(this.isDarkMode)])
      Text($r('app.string.steam_inventory_detail_load_failed'))
        .fontSize(13)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Button($r('app.string.steam_inventory_detail_retry'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontColor(SteamArkTheme.accent(this.isDarkMode))
        .onClick((): void => {
          void this.loadDetail();
        })
    }
    .width('100%')
    .padding(24)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildMarketCard(): void {
    Column({ space: 12 }) {
      this.buildSectionTitle($r('sys.symbol.waveform'),
        $r('app.string.steam_inventory_detail_market_title'))
      if (!this.request.marketable || this.request.marketHashName.trim().length <= 0) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(14)
            .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
          Text($r('app.string.steam_inventory_detail_market_not_listed'))
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .width('100%')
      } else if (this.marketLoading) {
        Row({ space: 10 }) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(SteamArkTheme.accent(this.isDarkMode))
          Text($r('app.string.steam_inventory_detail_market_loading'))
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .width('100%')
      } else if (this.marketFailed && this.marketPrice === null) {
        Row({ space: 10 }) {
          Text($r('app.string.steam_inventory_detail_market_unavailable'))
            .layoutWeight(1)
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          Button($r('app.string.steam_inventory_detail_retry'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize(12)
            .fontColor(SteamArkTheme.accent(this.isDarkMode))
            .onClick((): void => {
              void this.loadMarket();
            })
        }
        .width('100%')
      } else {
        this.buildMarketPriceRows()
        this.buildPriceHistorySection()
      }
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
  private buildMarketPriceRows(): void {
    Row({ space: 10 }) {
      this.buildMarketMetric($r('app.string.steam_inventory_detail_market_lowest'),
        this.lowestPriceText())
      this.buildMarketMetric($r('app.string.steam_inventory_detail_market_median'),
        this.medianPriceText())
      this.buildMarketMetric($r('app.string.steam_inventory_detail_market_volume'),
        this.volumeText())
    }
    .width('100%')
    if (this.marketPrice !== null && this.marketPrice.fetchedAtEpochSeconds > 0) {
      Row({ space: 6 }) {
        Text($r('app.string.steam_inventory_detail_price_updated'))
          .fontSize(10)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        Text(this.relativeDateText(this.marketPrice.fetchedAtEpochSeconds))
          .fontSize(10)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
      }
      .width('100%')
    }
  }

  @Builder
  private buildMarketMetric(label: ResourceStr, value: string): void {
    Column({ space: 2 }) {
      Text(value.length > 0 ? value : '--')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(1)
      Text(label)
        .fontSize(10)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildPriceHistorySection(): void {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.waveform_circle'))
          .fontSize(14)
          .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
        Text($r('app.string.steam_inventory_detail_price_history_title'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')
      if (this.priceHistoryLoading) {
        Row({ space: 10 }) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(SteamArkTheme.accent(this.isDarkMode))
          Text($r('app.string.steam_inventory_detail_price_history_loading'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .width('100%')
      } else if (this.priceHistoryFailed || this.priceHistory === null ||
        this.priceHistory.points.length < 2) {
        Row({ space: 10 }) {
          Text(this.priceHistoryFailed
            ? $r('app.string.steam_inventory_detail_price_history_failed')
            : $r('app.string.steam_inventory_detail_price_history_empty'))
            .layoutWeight(1)
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          Button($r('app.string.steam_inventory_detail_retry'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize(11)
            .fontColor(SteamArkTheme.accent(this.isDarkMode))
            .onClick((): void => {
              void this.loadPriceHistory();
            })
        }
        .width('100%')
      } else {
        Canvas(this.chartContext)
          .width('100%')
          .height(CHART_HEIGHT_VP)
          .backgroundColor(Color.Transparent)
          .onReady((): void => {
            this.drawPriceChart();
          })
        Text($r('app.string.steam_inventory_detail_price_history_hint'))
          .width('100%')
          .fontSize(10)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildBadgeCard(): void {
    if (this.request.isTradingCard || this.badgeDrop !== null) {
      Column({ space: 10 }) {
        this.buildSectionTitle($r('sys.symbol.medal'), $r('app.string.steam_inventory_detail_badge_title'))
        if (this.badgeDrop !== null) {
          Row({ space: 8 }) {
            this.buildHeaderChip(this.badgeCraftedLabel())
            if (this.badgeDrop.badgeLevel > 0) {
              this.buildHeaderChip($r('app.string.steam_inventory_detail_badge_level',
                this.badgeDrop.badgeLevel))
            }
          }
          .width('100%')
          if (this.badgeDrop.hoursPlayed > 0) {
            this.buildDetailRow($r('app.string.steam_inventory_detail_badge_hours_played'),
              this.hoursText(this.badgeDrop.hoursPlayed * 3600) + ' ' +
              this.resolveString($r('app.string.steam_library_hours_unit')))
          }
          if (this.badgeDrop.cardsRemaining > 0) {
            this.buildDetailRow($r('app.string.steam_inventory_detail_badge_cards_remaining'),
              this.badgeDrop.cardsRemaining.toString())
          } else if (!this.badgeDrop.badgeCrafted) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.checkmark_circle'))
                .fontSize(14)
                .fontColor([SteamArkTheme.success(this.isDarkMode)])
              Text($r('app.string.steam_inventory_detail_badge_ready'))
                .layoutWeight(1)
                .fontSize(12)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            }
            .width('100%')
          }
          Button($r('app.string.steam_badge_detail_open_badge_page'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize(12)
            .fontColor(SteamArkTheme.accent(this.isDarkMode))
            .onClick((): void => {
              this.openBadgePage();
            })
        } else {
          Text($r('app.string.steam_inventory_detail_badge_no_data'))
            .width('100%')
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
      .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
      .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
    }
  }

  @Builder
  private buildGameCard(): void {
    if (this.isGameOwnerApp()) {
      Column({ space: 10 }) {
        this.buildSectionTitle($r('sys.symbol.gamecontroller'),
          $r('app.string.steam_inventory_detail_game_title'))
        Row({ space: 8 }) {
          Text($r('app.string.steam_inventory_detail_owner_game'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
          Text(this.gameDisplayName())
            .layoutWeight(1)
            .fontSize(11)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        if (this.gameLoading) {
          Row({ space: 10 }) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(SteamArkTheme.accent(this.isDarkMode))
            Text($r('app.string.steam_inventory_detail_game_loading'))
              .fontSize(12)
              .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          }
          .width('100%')
        } else if (this.gameFailed) {
          Row({ space: 10 }) {
            Text($r('app.string.steam_inventory_detail_game_load_failed'))
              .layoutWeight(1)
              .fontSize(12)
              .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            Button($r('app.string.steam_inventory_detail_retry'))
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .fontSize(12)
              .fontColor(SteamArkTheme.accent(this.isDarkMode))
              .onClick((): void => {
                void this.loadGame();
              })
          }
          .width('100%')
        } else if (this.gameInfo !== null) {
          if (this.gameInfo.headerImageUrl.length > 0 || this.gameInfo.capsuleImageUrl.length > 0) {
            Image(this.gameInfo.headerImageUrl.length > 0
              ? this.gameInfo.headerImageUrl : this.gameInfo.capsuleImageUrl)
              .width('100%')
              .height(120)
              .objectFit(ImageFit.Contain)
              .borderRadius(10)
              .onError((): void => {
              })
          }
          this.buildGameInfoRows()
          this.buildAchievementsRow()
        } else {
          Text($r('app.string.steam_inventory_detail_game_no_data'))
            .width('100%')
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        this.buildGameButtons()
      }
      .width('100%')
      .padding(16)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
      .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
      .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
    }
  }

  @Builder
  private buildGameInfoRows(): void {
    if (this.gameInfo !== null) {
      if (this.gameInfo.releaseDateText.length > 0) {
        this.buildDetailRow($r('app.string.steam_inventory_detail_game_release_date'),
          this.gameInfo.releaseDateText)
      }
      if (this.gameInfo.developers.length > 0) {
        this.buildDetailRow($r('app.string.steam_inventory_detail_game_developers'),
          this.gameInfo.developers.join('、'))
      }
      if (this.gameInfo.genres.length > 0) {
        this.buildDetailRow($r('app.string.steam_inventory_detail_game_genres'),
          this.gameInfo.genres.join('、'))
      }
      if (this.playtimeSeconds > 0) {
        this.buildDetailRow($r('app.string.steam_inventory_detail_game_playtime'),
          this.hoursText(this.playtimeSeconds) + ' ' +
          this.resolveString($r('app.string.steam_library_hours_unit')))
      }
    }
  }

  @Builder
  private buildAchievementsRow(): void {
    if (this.gameAchievements !== null && this.gameAchievements.totalCount > 0) {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text($r('app.string.steam_inventory_detail_game_achievements'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          Text(this.gameAchievements.unlockedCount.toString() + ' / ' +
            this.gameAchievements.totalCount.toString())
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.accent(this.isDarkMode))
          Progress({
            value: Math.round(this.gameAchievements.unlockedCount * 100 /
              this.gameAchievements.totalCount),
            total: 100,
            type: ProgressType.Linear
          })
            .width(72)
            .height(4)
            .color(SteamArkTheme.accent(this.isDarkMode))
            .backgroundColor(SteamArkTheme.surfaceOverlay(this.isDarkMode))
        }
        .width('100%')
      }
      .width('100%')
    }
  }

  @Builder
  private buildGameButtons(): void {
    Row({ space: 8 }) {
      Button($r('app.string.steam_inventory_detail_open_game_detail'))
        .layoutWeight(1)
        .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
        .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .onClick((): void => {
          this.openGameDetailPage();
        })
      Button($r('app.string.steam_inventory_detail_open_store'))
        .layoutWeight(1)
        .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontWeight(FontWeight.Medium)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontColor(SteamArkTheme.accent(this.isDarkMode))
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .onClick((): void => {
          this.openStorePage();
        })
    }
    .width('100%')
  }

  @Builder
  private buildAttributesCard(): void {
    Column({ space: 10 }) {
      this.buildSectionTitle($r('sys.symbol.list_bullet'),
        $r('app.string.steam_inventory_detail_attributes_title'))
      this.buildDetailRow($r('app.string.steam_inventory_detail_attribute_asset_id'),
        this.request.assetId.length > 0 ? this.request.assetId : '--')
      this.buildDetailRow($r('app.string.steam_inventory_detail_attribute_class_id'),
        this.request.classId.length > 0 ? this.request.classId : '--')
      this.buildDetailRow($r('app.string.steam_inventory_detail_attribute_instance_id'),
        this.request.instanceId.length > 0 ? this.request.instanceId : '--')
      this.buildDetailRow($r('app.string.steam_inventory_detail_attribute_app_id'),
        this.request.appId.length > 0 ? this.request.appId : '--')
      this.buildDetailRow($r('app.string.steam_inventory_detail_attribute_context_id'),
        this.request.contextId.length > 0 ? this.request.contextId : '--')
      if (Number.isSafeInteger(this.request.amount) && this.request.amount >= 0) {
        this.buildDetailRow($r('app.string.steam_inventory_detail_attribute_amount'),
          this.request.amount.toString())
      }
      if (Number.isSafeInteger(this.request.originalAmount) && this.request.originalAmount >= 0) {
        this.buildDetailRow($r('app.string.steam_inventory_detail_attribute_original_amount'),
          this.request.originalAmount.toString())
      }
      this.buildDetailRow($r('app.string.steam_inventory_detail_attribute_card_drop'),
        this.resolveString(this.cardDropLabel()))
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
  private buildDescriptionCard(): void {
    Column({ space: 10 }) {
      this.buildSectionTitle($r('sys.symbol.doc_text'),
        $r('app.string.steam_inventory_detail_description_title'))
      ForEach(this.descriptionImageUrls(), (url: string): void => {
        Image(url)
          .width('100%')
          .height(80)
          .objectFit(ImageFit.Contain)
          .backgroundColor(Color.Transparent)
          .onError((): void => {
          })
      }, (url: string): string => url)
      if (this.cleanDescription().length > 0) {
        Text(this.cleanDescription())
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      } else {
        Text($r('app.string.steam_inventory_detail_description_empty'))
          .width('100%')
          .fontSize(12)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
      }
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
  private buildActionsCard(): void {
    Column({ space: 10 }) {
      this.buildSectionTitle($r('sys.symbol.link'),
        $r('app.string.steam_inventory_detail_actions_title'))
      if (this.request.marketable) {
        this.buildActionButton($r('app.string.steam_inventory_detail_open_market'),
          (): void => {
            this.openMarketPage();
          })
      }
      this.buildActionButton($r('app.string.steam_inventory_detail_open_community_item'),
        (): void => {
          this.openCommunityItemPage();
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
  private buildActionButton(label: ResourceStr, action: () => void): void {
    Button() {
      Row({ space: 6 }) {
        Text(label)
          .layoutWeight(1)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.accent(this.isDarkMode))
          .maxLines(2)
          .textAlign(TextAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
      }
      .width('100%')
    }
    .width('100%')
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .onClick(action)
  }

  @Builder
  private buildDetailRow(label: ResourceStr, value: string): void {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(11)
        .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
      Text(value)
        .layoutWeight(1)
        .fontSize(11)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
    }
    .width('100%')
  }

  @Builder
  private buildSectionTitle(symbol: Resource, title: ResourceStr): void {
    Row({ space: 8 }) {
      SymbolGlyph(symbol)
        .fontSize(16)
        .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
    }
    .width('100%')
  }

  private async loadDetail(): Promise<void> {
    const generation: number = this.loadGeneration + 1;
    this.loadGeneration = generation;
    this.loading = true;
    const accountId: string = steamArkStateService.getSnapshot().selectedAccountId;
    this.hasAccount = accountId.length > 0;
    if (!this.hasAccount) {
      this.loading = false;
      return;
    }
    this.loadCachedBadgeAndPlaytime(accountId);
    await this.loadMarket();
    await this.loadGame();
    if (this.isCurrentLoad(generation)) {
      this.loading = false;
    }
  }

  private async loadMarket(): Promise<void> {
    if (!this.request.marketable || this.request.marketHashName.trim().length <= 0) {
      this.marketLoading = false;
      this.marketFailed = false;
      return;
    }
    const account = steamArkStateService.getSelectedAccount();
    if (account === null) {
      this.marketLoading = false;
      this.marketFailed = true;
      return;
    }
    this.marketLoading = true;
    this.marketFailed = false;
    try {
      const service = new SteamArkMarketPriceService();
      const credentials: SteamCredentialSet =
        await steamArkStateService.getCredentials(account.profile.accountId);
      const proxyPassword: string =
        await steamArkStateService.getProxyPassword(account.profile.accountId);
      const batch = await service.loadBatch(account.profile, [this.toSteamInventoryItem()],
        SteamArkRegionPolicy.resolve(account.region, account.profile.countryCode,
          account.profile.walletCurrency), credentials, proxyPassword);
      if (batch.prices.length > 0) {
        this.marketPrice = batch.prices[0];
      }
      await this.loadPriceHistory();
    } catch (error) {
      SteamArkLog.warn(TAG, 'market data load failed; assetId=' + this.request.assetId +
        ', errorType=' + SteamArkLog.errorKind(error));
      this.marketFailed = true;
    } finally {
      this.marketLoading = false;
    }
  }

  private async loadPriceHistory(): Promise<void> {
    if (!this.request.marketable || this.request.marketHashName.trim().length <= 0) {
      this.priceHistoryLoading = false;
      return;
    }
    const account = steamArkStateService.getSelectedAccount();
    if (account === null) {
      this.priceHistoryLoading = false;
      this.priceHistoryFailed = true;
      return;
    }
    this.priceHistoryLoading = true;
    this.priceHistoryFailed = false;
    try {
      const service = new SteamArkMarketPriceService();
      const credentials: SteamCredentialSet =
        await steamArkStateService.getCredentials(account.profile.accountId);
      const proxyPassword: string =
        await steamArkStateService.getProxyPassword(account.profile.accountId);
      const history: SteamArkMarketPriceHistory | null = await service.fetchPriceHistory(
        account.profile, this.request.appId, this.request.marketHashName, credentials, proxyPassword);
      this.priceHistory = history;
      this.priceHistoryFailed = history === null || history.points.length < 2;
      this.drawPriceChart();
    } catch (error) {
      SteamArkLog.warn(TAG, 'price history load failed; assetId=' + this.request.assetId +
        ', errorType=' + SteamArkLog.errorKind(error));
      this.priceHistoryFailed = true;
    } finally {
      this.priceHistoryLoading = false;
    }
  }

  private async loadGame(): Promise<void> {
    if (!this.isGameOwnerApp()) {
      this.gameLoading = false;
      return;
    }
    const accountId: string = steamArkStateService.getSnapshot().selectedAccountId;
    if (accountId.length <= 0) {
      this.gameLoading = false;
      this.gameFailed = true;
      return;
    }
    this.gameLoading = true;
    this.gameFailed = false;
    try {
      // Default load + silent refresh: a cached bundle renders immediately and
      // a stale one is refreshed in the background through the callback.
      const bundle = await steamArkGameLibraryService.loadGameDetail(
        accountId, this.request.ownerAppId,
        (refreshed: SteamGameDetailBundle): void => {
          if (!this.isPageActive) {
            return;
          }
          this.gameInfo = refreshed.info;
          this.gameAchievements = refreshed.achievements;
        });
      if (bundle === null) {
        throw new Error('Steam game detail is not available');
      }
      this.gameInfo = bundle.info;
      this.gameAchievements = bundle.achievements;
    } catch (error) {
      SteamArkLog.warn(TAG, 'game detail load failed; ownerAppId=' + this.request.ownerAppId +
        ', errorType=' + SteamArkLog.errorKind(error));
      this.gameFailed = true;
    } finally {
      this.gameLoading = false;
    }
  }

  /** Reads the badge drop and library playtime synchronously from cached reports. */
  private loadCachedBadgeAndPlaytime(accountId: string): void {
    const report = steamArkFarmingService.getBadgeSyncReport(accountId);
    if (report !== null) {
      for (let index = 0; index < report.games.length; index++) {
        const game: SteamGameDrop = report.games[index];
        if (game.appId === this.request.ownerAppId) {
          this.badgeDrop = game;
          break;
        }
      }
    }
    let librarySnapshot = steamArkGameLibraryService.getSnapshot(accountId);
    if (librarySnapshot === null) {
      librarySnapshot = steamArkGameLibraryService.restore(accountId);
    }
    if (librarySnapshot !== null) {
      for (let index = 0; index < librarySnapshot.games.length; index++) {
        const game: SteamLibraryGame = librarySnapshot.games[index];
        if (game.appId === this.request.ownerAppId) {
          this.playtimeSeconds = game.playtimeForeverSeconds;
          break;
        }
      }
    }
  }

  private drawPriceChart(): void {
    const history: SteamArkMarketPriceHistory | null = this.priceHistory;
    if (history === null || history.points.length < 2) {
      return;
    }
    const context: CanvasRenderingContext2D = this.chartContext;
    const width: number = context.width;
    const height: number = context.height;
    if (width <= 0 || height <= 0) {
      return;
    }
    const points: Array<SteamArkMarketPriceHistoryPoint> = this.downsampledPoints(history.points);
    if (points.length < 2) {
      return;
    }
    context.clearRect(0, 0, width, height);
    const lineColor: string = this.chartColor(
      this.isDarkMode ? $r('app.color.steam_ark_theme_dark_accent')
        : $r('app.color.steam_ark_theme_light_accent'),
      this.isDarkMode ? '#1A9FFF' : '#1479D1');
    const gridColor: string = this.chartColor(
      this.isDarkMode ? $r('app.color.steam_ark_theme_dark_divider')
        : $r('app.color.steam_ark_theme_light_divider'),
      this.isDarkMode ? '#27435A' : '#C8D7E4');
    const labelColor: string = this.chartColor(
      this.isDarkMode ? $r('app.color.steam_ark_theme_dark_text_muted')
        : $r('app.color.steam_ark_theme_light_text_muted'),
      this.isDarkMode ? '#7890A4' : '#718494');
    const volumeColor: string = this.chartColor(
      this.isDarkMode ? $r('app.color.steam_ark_theme_dark_accent_cyan')
        : $r('app.color.steam_ark_theme_light_accent_cyan'),
      this.isDarkMode ? '#66C0F4' : '#0B78B3');
    const padLeft: number = 6;
    const padRight: number = 46;
    const padTop: number = 12;
    const padBottom: number = 16;
    const plotWidth: number = width - padLeft - padRight;
    const plotHeight: number = height - padTop - padBottom;
    const volumeZoneHeight: number = plotHeight * 0.24;
    const pricePlotHeight: number = plotHeight - volumeZoneHeight;
    let minUnits: number = points[0].minorUnits;
    let maxUnits: number = points[0].minorUnits;
    let maxVolume: number = 0;
    for (let index = 0; index < points.length; index++) {
      const point: SteamArkMarketPriceHistoryPoint = points[index];
      if (point.minorUnits < minUnits) {
        minUnits = point.minorUnits;
      }
      if (point.minorUnits > maxUnits) {
        maxUnits = point.minorUnits;
      }
      if (point.volumeCount > maxVolume) {
        maxVolume = point.volumeCount;
      }
    }
    let range: number = maxUnits - minUnits;
    if (range <= 0) {
      range = Math.max(1, maxUnits * 0.04);
      minUnits -= range;
    }
    const priceBottom: number = height - padBottom - volumeZoneHeight;
    const priceTop: number = padTop;
    const priceY = (minorUnits: number): number =>
      priceBottom - (minorUnits - minUnits) / range * (priceBottom - priceTop);
    // Volume bars behind the price line.
    context.fillStyle = volumeColor;
    context.globalAlpha = 0.32;
    const barWidth: number = Math.max(1, plotWidth / points.length * 0.6);
    for (let index = 0; index < points.length; index++) {
      const point: SteamArkMarketPriceHistoryPoint = points[index];
      const barHeight: number = maxVolume > 0
        ? point.volumeCount / maxVolume * volumeZoneHeight : 0;
      const x: number = padLeft + index / (points.length - 1) * plotWidth;
      context.fillRect(x - barWidth / 2, height - padBottom - barHeight, barWidth, barHeight);
    }
    context.globalAlpha = 1;
    // Horizontal grid lines at min / mid / max.
    context.strokeStyle = gridColor;
    context.lineWidth = 0.5;
    for (let lineIndex = 0; lineIndex < 3; lineIndex++) {
      const ratio: number = lineIndex / 2;
      const y: number = priceTop + (priceBottom - priceTop) * ratio;
      context.beginPath();
      context.moveTo(padLeft, y);
      context.lineTo(width - padRight, y);
      context.stroke();
    }
    // Price line and area fill.
    context.beginPath();
    for (let index = 0; index < points.length; index++) {
      const x: number = padLeft + index / (points.length - 1) * plotWidth;
      const y: number = priceY(points[index].minorUnits);
      if (index === 0) {
        context.moveTo(x, y);
      } else {
        context.lineTo(x, y);
      }
    }
    context.strokeStyle = lineColor;
    context.lineWidth = 1.5;
    context.stroke();
    context.lineTo(width - padRight, priceBottom);
    context.lineTo(padLeft, priceBottom);
    context.closePath();
    context.fillStyle = lineColor;
    context.globalAlpha = 0.10;
    context.fill();
    context.globalAlpha = 1;
    // Axis labels.
    context.font = '9vp sans-serif';
    context.fillStyle = labelColor;
    context.textAlign = 'right';
    context.fillText(this.chartPriceLabel(maxUnits, history.pricePrefix), width - 2, priceTop + 7);
    context.fillText(this.chartPriceLabel(minUnits, history.pricePrefix), width - 2, priceBottom - 2);
    context.textAlign = 'left';
    context.fillText(this.chartDateLabel(points[0].epochSeconds), padLeft, height - 3);
    context.textAlign = 'right';
    context.fillText(this.chartDateLabel(points[points.length - 1].epochSeconds),
      width - padRight, height - 3);
    context.textAlign = 'left';
  }

  private downsampledPoints(points: Array<SteamArkMarketPriceHistoryPoint>):
    Array<SteamArkMarketPriceHistoryPoint> {
    if (points.length <= MAX_CHART_POINTS) {
      return points.slice();
    }
    const step: number = Math.ceil(points.length / MAX_CHART_POINTS);
    const sampled: Array<SteamArkMarketPriceHistoryPoint> = [];
    for (let index = 0; index < points.length; index += step) {
      sampled.push(points[index]);
    }
    const last: SteamArkMarketPriceHistoryPoint = points[points.length - 1];
    if (sampled[sampled.length - 1] !== last) {
      sampled.push(last);
    }
    return sampled;
  }

  private chartColor(resource: Resource, fallback: string): string {
    try {
      const resolved: string = resolveResourceString(this.getUIContext().getHostContext(), resource);
      if (resolved.length > 0) {
        return resolved;
      }
    } catch (error) {
      SteamArkLog.debug(TAG, 'chart color resolution failed; fallback used');
    }
    return fallback;
  }

  private chartPriceLabel(minorUnits: number, pricePrefix: string): string {
    if (minorUnits % 100 === 0) {
      return pricePrefix + (minorUnits / 100).toFixed(0);
    }
    return pricePrefix + (minorUnits / 100).toFixed(2);
  }

  private chartDateLabel(epochSeconds: number): string {
    const date: Date = new Date(epochSeconds * 1000);
    const month: number = date.getUTCMonth() + 1;
    const day: number = date.getUTCDate();
    return date.getUTCFullYear().toString() + '-' + this.pad2(month) + '-' + this.pad2(day);
  }

  private pad2(value: number): string {
    return value < 10 ? '0' + value.toString() : value.toString();
  }

  private toSteamInventoryItem(): SteamInventoryItem {
    return new SteamInventoryItem(
      this.request.assetId,
      this.request.classId,
      this.request.instanceId,
      this.request.appId,
      this.request.contextId,
      this.request.amount,
      this.request.name,
      this.request.type,
      this.request.marketable,
      this.request.tradable,
      this.request.cardDropState,
      this.request.originalAmount,
      this.request.description,
      this.request.iconUrl,
      this.request.iconUrlLarge,
      this.request.marketHashName,
      this.request.marketName,
      this.request.isTradingCard,
      0,
      this.request.ownerAppId,
      this.request.ownerAppName
    );
  }

  private isCurrentLoad(generation: number): boolean {
    return this.isPageActive && this.loadGeneration === generation;
  }

  private displayName(): string {
    if (this.request.name.length > 0) {
      return this.request.name;
    }
    if (this.request.marketHashName.length > 0) {
      return this.request.marketHashName;
    }
    return this.resolveString($r('app.string.steam_inventory_detail_sheet_title'));
  }

  private marketNameLine(): string {
    const hashName: string = this.request.marketHashName.trim();
    if (hashName.length <= 0 || hashName === this.request.name.trim()) {
      return '';
    }
    return hashName;
  }

  private itemIconUrl(): string {
    if (this.request.iconUrlLarge.length > 0) {
      return this.request.iconUrlLarge;
    }
    return this.request.iconUrl;
  }

  private inventoryCategory(): ResourceStr {
    if (this.request.isTradingCard) {
      return $r('app.string.steam_inventory_category_cards');
    }
    if (this.request.marketable) {
      return $r('app.string.steam_inventory_category_market');
    }
    if (this.request.tradable) {
      return $r('app.string.steam_inventory_category_trade');
    }
    return $r('app.string.steam_inventory_category_other');
  }

  private lowestPriceText(): string {
    if (this.marketPrice === null || !this.marketPrice.available) {
      return '';
    }
    return this.marketPrice.lowestPriceText.length > 0
      ? this.marketPrice.lowestPriceText : '--';
  }

  private medianPriceText(): string {
    if (this.marketPrice === null || !this.marketPrice.available ||
      this.marketPrice.medianPriceText.length <= 0) {
      return '';
    }
    return this.marketPrice.medianPriceText;
  }

  private volumeText(): string {
    if (this.marketPrice === null || !this.marketPrice.available) {
      return '';
    }
    return this.marketPrice.volumeCount > 0 ? this.marketPrice.volumeCount.toString() : '';
  }

  private badgeCraftedLabel(): ResourceStr {
    if (this.badgeDrop !== null && this.badgeDrop.badgeCrafted) {
      return $r('app.string.steam_inventory_detail_badge_crafted');
    }
    return $r('app.string.steam_inventory_detail_badge_not_crafted');
  }

  private cardDropLabel(): ResourceStr {
    if (this.request.cardDropState === SteamInventoryCardDropState.AVAILABLE) {
      return $r('app.string.steam_inventory_detail_card_drop_available');
    }
    if (this.request.cardDropState === SteamInventoryCardDropState.DROPPED) {
      return $r('app.string.steam_inventory_detail_card_drop_dropped');
    }
    if (this.request.cardDropState === SteamInventoryCardDropState.NOT_APPLICABLE) {
      return $r('app.string.steam_inventory_detail_card_drop_not_applicable');
    }
    return $r('app.string.steam_inventory_detail_card_drop_unknown');
  }

  private isGameOwnerApp(): boolean {
    const owner: string = this.request.ownerAppId.trim();
    if (owner.length <= 0 || owner === STEAM_COMMUNITY_APP_ID) {
      return false;
    }
    return /^\d+$/.test(owner);
  }

  private gameDisplayName(): string {
    if (this.gameInfo !== null && this.gameInfo.name.length > 0) {
      return this.gameInfo.name;
    }
    if (this.request.ownerAppName.length > 0) {
      return this.request.ownerAppName;
    }
    return this.request.ownerAppId;
  }

  private hoursText(seconds: number): string {
    if (seconds <= 0) {
      return '--';
    }
    const hours: number = seconds / 3600;
    return hours >= 100 ? Math.round(hours).toString() : hours.toFixed(1);
  }

  private relativeDateText(epochSeconds: number): string {
    const result = ngfRelativeTimeFormatterFacade.format(
      epochSeconds * 1000,
      this.timeLocale()
    );
    return result.text;
  }

  private timeLocale(): string {
    const locale = steamArkStateService.resolveAccountLocale(
      steamArkStateService.getSnapshot().selectedAccountId);
    const steamLanguage: string = locale !== null ? locale.steamLanguage : '';
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

  private descriptionImageUrls(): Array<string> {
    const urls: Array<string> = [];
    const imagePattern = /<img\b[^>]*>/gi;
    let match: RegExpExecArray | null = imagePattern.exec(this.request.description);
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
      match = imagePattern.exec(this.request.description);
    }
    return urls;
  }

  private cleanDescription(): string {
    return this.request.description
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

  private marketUrl(): string {
    const marketName: string = this.request.marketHashName.length > 0
      ? this.request.marketHashName : this.request.name;
    return 'https://steamcommunity.com/market/listings/' + this.request.appId + '/' +
      encodeURIComponent(marketName);
  }

  private communityItemUrl(): string {
    return 'https://steamcommunity.com/my/inventory/#' + this.request.appId + '_' +
      this.request.contextId + '_' + this.request.assetId;
  }

  private openMarketPage(): void {
    SteamArkLog.info(TAG, 'market page opened; assetId=' + this.request.assetId);
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(this.marketUrl(), this.displayName(), this.request.appId));
  }

  private openCommunityItemPage(): void {
    SteamArkLog.info(TAG, 'community item page opened; assetId=' + this.request.assetId);
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(this.communityItemUrl(), this.displayName(), 'steamcommunity.com'));
  }

  private openBadgePage(): void {
    SteamArkLog.info(TAG, 'badge page opened; ownerAppId=' + this.request.ownerAppId);
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(
        'https://steamcommunity.com/my/gamecards/' + this.request.ownerAppId + '/',
        this.gameDisplayName(), this.request.ownerAppId));
  }

  private openGameDetailPage(): void {
    // Route through our own game detail host page instead of the browser.
    const request: SteamArkGameDetailRequest = new SteamArkGameDetailRequest(
      this.request.ownerAppId,
      this.gameDisplayName(),
      this.gameInfo !== null && this.gameInfo.capsuleImageUrl.length > 0
        ? this.gameInfo.capsuleImageUrl : '',
      '',
      this.playtimeSeconds,
      0,
      0,
      false
    );
    SteamArkLog.info(TAG, 'game detail route pushed; ownerAppId=' + this.request.ownerAppId);
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.GAME_DETAIL, request);
  }

  private openStorePage(): void {
    SteamArkLog.info(TAG, 'store page opened; ownerAppId=' + this.request.ownerAppId);
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(
        'https://store.steampowered.com/app/' + this.request.ownerAppId + '/',
        this.gameDisplayName(), this.request.ownerAppId));
  }

  private resolveString(resource: ResourceStr): string {
    try {
      return resolveResourceString(this.getUIContext().getHostContext(), resource);
    } catch (error) {
      SteamArkLog.debug(TAG, 'resource resolution failed');
      return '';
    }
  }
}
