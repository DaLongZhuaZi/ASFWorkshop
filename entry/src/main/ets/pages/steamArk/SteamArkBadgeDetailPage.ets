import {
  NGFControlStyleTokens,
  NGFMaterialSurfaceTokens,
  ngfVisualEffectsFacade,
  resolveResourceString
} from 'ngf_framework';
import {
  SteamGameAchievementsResult,
  SteamGameDetailBundle,
  SteamGameDetailInfo
} from 'steam_core';
import {
  SteamArkLog,
  steamArkGameLibraryService,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import {
  SteamArkBadgeDetailRequest,
  SteamArkBadgeKind,
  SteamArkBrowserRequest,
  SteamArkGameDetailRequest,
  SteamArkRouteName
} from './SteamArkRoutes';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';

const TAG: string = 'BadgeDetailPage';

/**
 * Full-screen badge detail panel rendered as an in-page overlay inside the
 * workspace page (官方一镜到底方式三：同页 if/else + geometryTransition +
 * animateTo). Its header image shares a geometryTransition id with the clicked
 * tile image, so the badge image morphs between the tile and the header while
 * the panel fades in. The workspace page owns the animateTo timing and the
 * back button (drawn above this panel); community/store links push the
 * BROWSER route on the home stack.
 */
@Component
export struct SteamArkBadgeDetailPage {
  @Prop request: SteamArkBadgeDetailRequest = new SteamArkBadgeDetailRequest();
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  @State private heroCollapseRatio: number = 0;
  @State private heroZoneWidthVp: number = 0;
  @State private gameLoading: boolean = false;
  @State private gameInfo: SteamGameDetailInfo | null = null;
  @State private gameAchievements: SteamGameAchievementsResult | null = null;
  private static readonly HERO_EXPANDED_HEIGHT: number = 170;
  private static readonly HERO_DOCK_SIZE: number = 56;
  private readonly heroScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.heroCollapseRatio = 0;
    SteamArkLog.lifecycle(TAG, 'aboutToAppear', 'kind=' + String(this.request.kind) +
      ', id=' + this.identity());
    if (this.request.kind === SteamArkBadgeKind.GAME && this.request.appId.length > 0) {
      void this.loadGame();
    }
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle(TAG, 'aboutToDisappear', 'id=' + this.identity());
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      SteamArkProfileBackground()
      Scroll(this.heroScroller) {
        Column({ space: 12 }) {
          this.buildHeaderCard()
          this.buildDetailsCard()
          this.buildGameCard()
          this.buildActionsCard()
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: SteamArkTheme.CONTENT_TOP_INSET + SteamArkBadgeDetailPage.HERO_EXPANDED_HEIGHT + 12,
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
   * Collapsing hero: the badge image stays pinned at the top, shrinks 1:1
   * with the scroll offset down to a small top-left dock with the name beside
   * it, and grows back when scrolling up. The geometryTransition id never
   * leaves this node, so the seamless open/close flight keeps working from
   * any size.
   */
  @Builder
  private buildHeroDock(): void {
    Column() {
      Row({ space: 12 }) {
        Image(this.request.imageUrl)
          .width(this.heroWidthVp())
          .height(this.heroHeightVp())
          .objectFit(ImageFit.Contain)
          .borderRadius(12)
          .backgroundColor(Color.Transparent)
          .clip(true)
          .geometryTransition(SteamArkBadgeDetailRequest.geometryId(
            this.request.kind, this.request.appId, this.request.badgeId))
          .transition(TransitionEffect.OPACITY)
        Column({ space: 2 }) {
          Text(this.request.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.kindLabel())
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
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
      (SteamArkBadgeDetailPage.HERO_DOCK_SIZE - this.heroZoneWidthVp) * this.heroCollapseRatio;
  }

  private heroHeightVp(): number {
    const expanded: number = SteamArkBadgeDetailPage.HERO_EXPANDED_HEIGHT;
    return expanded + (SteamArkBadgeDetailPage.HERO_DOCK_SIZE - expanded) * this.heroCollapseRatio;
  }

  private updateHeroCollapse(): void {
    const travel: number = SteamArkBadgeDetailPage.HERO_EXPANDED_HEIGHT -
      SteamArkBadgeDetailPage.HERO_DOCK_SIZE + 24;
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
        Text(this.request.name)
          .width('100%')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          this.buildHeaderChip(this.kindLabel())
          if (this.request.kind === SteamArkBadgeKind.GAME) {
            this.buildHeaderChip(this.statusLabel())
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
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(SteamArkTheme.accent(this.isDarkMode))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor(SteamArkTheme.surfaceControl(this.isDarkMode))
      .borderRadius(7)
  }

  @Builder
  private buildDetailsCard(): void {
    Column({ space: 12 }) {
      if (this.request.kind === SteamArkBadgeKind.GAME) {
        if (this.request.badgeLevel > 0) {
          this.buildDetailRow(
            $r('app.string.steam_badge_detail_level_label'),
            this.request.badgeLevel.toString()
          )
        }
        if (this.request.hoursPlayed > 0) {
          this.buildPlaytimeRow()
        }
        this.buildCardsRow()
      } else {
        if (this.request.experience > 0) {
          this.buildDetailRow(
            $r('app.string.steam_badge_detail_experience_label'),
            this.request.experience.toString()
          )
        }
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
  private buildDetailRow(label: ResourceStr, value: ResourceStr): void {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Blank()
      Text(value)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
    }
    .width('100%')
  }

  /** Related game section for game badges, mirroring the inventory detail page. */
  @Builder
  private buildGameCard(): void {
    if (this.request.kind === SteamArkBadgeKind.GAME && this.request.appId.length > 0) {
      Column({ space: 10 }) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.gamecontroller'))
            .fontSize(15)
            .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
          Text($r('app.string.steam_inventory_detail_game_title'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        }
        .width('100%')
        if (this.gameLoading) {
          Row({ space: 10 }) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(SteamArkTheme.accent(this.isDarkMode))
            Text($r('app.string.steam_inventory_detail_game_loading'))
              .fontSize(12)
              .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
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
          if (this.gameAchievements !== null && this.gameAchievements.totalCount > 0) {
            this.buildDetailRow($r('app.string.steam_inventory_detail_game_achievements'),
              this.gameAchievements.unlockedCount.toString() + ' / ' +
              this.gameAchievements.totalCount.toString())
          }
        }
        if (this.request.hoursPlayed > 0) {
          this.buildDetailRow($r('app.string.steam_badge_detail_playtime_label'),
          this.request.hoursPlayed.toFixed(1) + ' ' +
            resolveResourceString(this.getUIContext().getHostContext(),
              $r('app.string.steam_library_hours_unit')))
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

  private async loadGame(): Promise<void> {
    const accountId: string = steamArkStateService.getSnapshot().selectedAccountId;
    if (accountId.length <= 0) {
      return;
    }
    this.gameLoading = true;
    try {
      const bundle: SteamGameDetailBundle | null = await steamArkGameLibraryService.loadGameDetail(
        accountId, this.request.appId,
        (refreshed: SteamGameDetailBundle): void => {
          this.gameInfo = refreshed.info;
          this.gameAchievements = refreshed.achievements;
        });
      if (bundle !== null) {
        this.gameInfo = bundle.info;
        this.gameAchievements = bundle.achievements;
      }
    } catch (error) {
      SteamArkLog.warn(TAG, 'badge game detail load failed; appId=' + this.request.appId +
        ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      this.gameLoading = false;
    }
  }

  private openGameDetailPage(): void {
    const request: SteamArkGameDetailRequest = new SteamArkGameDetailRequest(
      this.request.appId,
      this.gameInfo !== null && this.gameInfo.name.length > 0 ? this.gameInfo.name : this.request.name,
      this.gameInfo !== null && this.gameInfo.capsuleImageUrl.length > 0
        ? this.gameInfo.capsuleImageUrl : '',
      '',
      Math.round(this.request.hoursPlayed * 3600),
      0,
      0,
      false
    );
    SteamArkLog.info(TAG, 'game detail route pushed from badge; appId=' + this.request.appId);
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.GAME_DETAIL, request);
  }

  @Builder
  private buildPlaytimeRow(): void {
    Row() {
      Text($r('app.string.steam_badge_detail_playtime_label'))
        .fontSize(13)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Blank()
      Row({ space: 3 }) {
        Text(this.request.hoursPlayed.toFixed(1))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_library_hours_unit'))
          .fontSize(12)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
    }
    .width('100%')
  }

  @Builder
  private buildCardsRow(): void {
    if (this.request.cardsRemaining > 0) {
      this.buildDetailRow(
        $r('app.string.steam_badge_detail_cards_remaining_label'),
        $r('app.string.steam_workspace_badges_uncrafted_remaining', this.request.cardsRemaining)
      )
    } else if (!this.request.badgeCrafted) {
      this.buildDetailRow(
        $r('app.string.steam_badge_detail_cards_remaining_label'),
        $r('app.string.steam_workspace_badges_uncrafted_ready')
      )
    }
  }

  @Builder
  private buildActionsCard(): void {
    Column({ space: 10 }) {
      if (this.request.kind === SteamArkBadgeKind.GAME && this.request.appId.length > 0) {
        Button($r('app.string.steam_badge_detail_open_game_detail'))
          .width('100%')
          .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
          .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
          .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
          .onClick((): void => {
            this.openGameDetailPage();
          })
      }
      Button($r('app.string.steam_badge_detail_open_badge_page'))
        .width('100%')
        .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
        .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .onClick((): void => {
          this.openBadgePage();
        })
      if (this.request.kind === SteamArkBadgeKind.GAME && this.request.storeUrl.length > 0) {
        Button($r('app.string.steam_badge_detail_open_store'))
          .width('100%')
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
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  private kindLabel(): ResourceStr {
    if (this.request.kind === SteamArkBadgeKind.COMMUNITY) {
      return $r('app.string.steam_badge_detail_kind_community');
    }
    return $r('app.string.steam_badge_detail_kind_game');
  }

  private statusLabel(): ResourceStr {
    if (this.request.badgeCrafted) {
      return $r('app.string.steam_badge_detail_status_crafted');
    }
    return $r('app.string.steam_badge_detail_status_uncrafted');
  }

  private identity(): string {
    if (this.request.kind === SteamArkBadgeKind.COMMUNITY) {
      return this.request.badgeId;
    }
    return this.request.appId;
  }

  private openBadgePage(): void {
    SteamArkLog.info(TAG, 'badge page opened; id=' + this.identity());
    let fallbackUrl: string = 'https://steamcommunity.com/my/badges/';
    if (this.request.kind === SteamArkBadgeKind.GAME) {
      fallbackUrl = 'https://steamcommunity.com/my/gamecards/' + this.request.appId + '/';
    }
    let title: string = this.request.name;
    if (title.length <= 0) {
      title = resolveResourceString(this.getUIContext().getHostContext(), $r('app.string.steam_badge_detail_subtitle'));
    }
    const request: SteamArkBrowserRequest = new SteamArkBrowserRequest(
      this.request.badgeUrl.length > 0 ? this.request.badgeUrl : fallbackUrl,
      title,
      this.identity()
    );
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER, request);
  }

  private openStorePage(): void {
    SteamArkLog.info(TAG, 'store page opened; appId=' + this.request.appId);
    const request: SteamArkBrowserRequest = new SteamArkBrowserRequest(
      this.request.storeUrl,
      this.request.name,
      this.request.appId
    );
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER, request);
  }
}
