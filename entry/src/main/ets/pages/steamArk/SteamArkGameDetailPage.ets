import {
  NGFMaterialSurfaceTokens,
  ngfRelativeTimeFormatterFacade,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import {
  SteamGameAchievementInfo,
  SteamGameAchievementsResult,
  SteamGameDetailBundle,
  SteamGameDetailCategory,
  SteamGameDetailInfo,
  SteamGameNewsItem
} from 'steam_core';
import { SteamArkLog, steamArkGameLibraryService, steamArkStateService } from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import {
  SteamArkAchievementDetailRequest,
  SteamArkBrowserRequest,
  SteamArkGameDetailRequest,
  SteamArkRouteName
} from './SteamArkRoutes';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';
import { SteamArkGameCoverUrl } from './SteamArkGameCover';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';

const TAG: string = 'GameDetailPage';
const MAX_NEWS_ITEMS: number = 8;

/**
 * In-app game detail panel rendered as an in-page overlay inside the library
 * page (官方一镜到底方式三：同页 if/else + geometryTransition + animateTo).
 * Its header cover shares a geometryTransition id with the clicked tile cover,
 * so the cover morphs between the tile and the header while the panel fades
 * in. The library page owns the animateTo timing and the back button; store
 * info, achievements and news are fetched independently so one failing source
 * never hides the others.
 */
@Component
export struct SteamArkGameDetailPage {
  @Prop request: SteamArkGameDetailRequest = new SteamArkGameDetailRequest();
  @State private info: SteamGameDetailInfo | null = null;
  @State private news: Array<SteamGameNewsItem> = [];
  @State private achievements: SteamGameAchievementsResult | null = null;
  @State private achievementDetailVisible: boolean = false;
  private achievementDetailRequest: SteamArkAchievementDetailRequest =
    new SteamArkAchievementDetailRequest();
  @State private loading: boolean = true;
  @State private failed: boolean = false;
  @State private heroCollapseRatio: number = 0;
  @State private heroZoneWidthVp: number = 0;
  @State private coverStage: number = 0;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private static readonly HERO_DOCK_SIZE: number = 56;
  private readonly heroScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    SteamArkLog.lifecycle(TAG, 'aboutToAppear', 'appId=' + this.request.appId);
    this.coverStage = 0;
    this.heroCollapseRatio = 0;
    void this.loadDetail();
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle(TAG, 'aboutToDisappear', 'appId=' + this.request.appId);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      SteamArkProfileBackground()
      Scroll(this.heroScroller) {
        Column({ space: 12 }) {
          this.buildHeaderCard()
          if (this.loading) {
            this.buildLoadingCard()
          } else if (this.failed) {
            this.buildFailedCard()
          } else {
            this.buildPlaytimeCard()
            this.buildAchievementsCard()
            this.buildFeaturesCard()
            this.buildAboutCard()
            this.buildNewsCard()
          }
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: SteamArkTheme.CONTENT_TOP_INSET + this.heroExpandedHeightVp() + 12,
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
      this.buildAchievementDetailOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(SteamArkTheme.background(this.isDarkMode))
  }

  /**
   * Collapsing hero: the cover stays pinned at the top, shrinks 1:1 with the
   * scroll offset down to a small top-left dock with the title beside it, and
   * grows back when scrolling up. The geometryTransition id never leaves this
   * node, so the seamless open/close flight keeps working from any size.
   */
  @Builder
  private buildHeroDock(): void {
    Column() {
      Row({ space: 12 }) {
        Image(this.dockCoverUrl())
          .width(this.heroWidthVp())
          .height(this.heroHeightVp())
          .objectFit(ImageFit.Contain)
          .clip(true)
          .borderRadius(14)
          .geometryTransition(SteamArkGameDetailRequest.coverGeometryId(this.request.appId))
          .transition(TransitionEffect.OPACITY)
          .onError((): void => {
            this.coverStage += 1;
          })
        Column({ space: 2 }) {
          Row({ space: 4 }) {
            if (this.request.favorite) {
              Text('★')
                .fontSize(12)
                .fontColor(SteamArkTheme.accent(this.isDarkMode))
            }
            Text(this.displayName())
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.hoursText(this.request.playtimeForeverSeconds).length > 0) {
            Row({ space: 4 }) {
              Text($r('app.string.steam_library_metric_playtime'))
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
              Text(this.hoursText(this.request.playtimeForeverSeconds) + ' h')
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            }
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

  private dockCoverUrl(): string {
    const urls: Array<string> = [];
    const primary: string = SteamArkGameCoverUrl.largeFor(
      this.request.appId, this.request.logoUrl, this.request.iconUrl);
    if (primary.length > 0) {
      urls.push(primary);
    }
    if (this.request.logoUrl.length > 0) {
      urls.push(this.request.logoUrl);
    }
    if (this.request.iconUrl.length > 0) {
      urls.push(this.request.iconUrl);
    }
    if (this.coverStage >= urls.length) {
      return '';
    }
    return urls[this.coverStage];
  }

  private heroExpandedHeightVp(): number {
    if (this.heroZoneWidthVp <= 0) {
      return 180;
    }
    const aspect: number = SteamArkGameCoverUrl.aspectFor(
      this.request.appId, this.request.logoUrl, this.request.iconUrl);
    const expanded: number = this.heroZoneWidthVp / aspect;
    return Math.max(96, Math.min(220, expanded));
  }

  private heroWidthVp(): Length {
    if (this.heroZoneWidthVp <= 0) {
      return '100%';
    }
    return this.heroZoneWidthVp +
      (SteamArkGameDetailPage.HERO_DOCK_SIZE - this.heroZoneWidthVp) * this.heroCollapseRatio;
  }

  private heroHeightVp(): number {
    const expanded: number = this.heroExpandedHeightVp();
    return expanded + (SteamArkGameDetailPage.HERO_DOCK_SIZE - expanded) * this.heroCollapseRatio;
  }

  private updateHeroCollapse(): void {
    const travel: number = this.heroExpandedHeightVp() - SteamArkGameDetailPage.HERO_DOCK_SIZE + 24;
    if (travel <= 0) {
      return;
    }
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
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(this.displayName())
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.info !== null && this.info.releaseDateText.length > 0) {
            Text(this.info.releaseDateText)
              .fontSize(11)
              .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button($r('app.string.steam_game_detail_open_community'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize(12)
          .fontColor(SteamArkTheme.accent(this.isDarkMode))
          .onClick((): void => {
            this.openCommunityPage();
          })
      }
      .width('100%')
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
  private buildLoadingCard(): void {
    Column({ space: 8 }) {
      LoadingProgress()
        .width(30)
        .height(30)
        .color(SteamArkTheme.accent(this.isDarkMode))
      Text($r('app.string.steam_library_status_loading'))
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
      Text($r('app.string.steam_game_detail_load_failed'))
        .fontSize(13)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Button($r('app.string.steam_game_detail_retry'))
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
  private buildPlaytimeCard(): void {
    Column({ space: 12 }) {
      this.buildSectionTitle($r('sys.symbol.clock'), $r('app.string.steam_game_detail_playtime_title'))
      Row({ space: 10 }) {
        this.buildPlaytimeMetric($r('app.string.steam_game_detail_playtime_total'),
          this.hoursText(this.request.playtimeForeverSeconds))
        this.buildPlaytimeMetric($r('app.string.steam_game_detail_playtime_two_weeks'),
          this.hoursText(this.request.playtimeTwoWeeksSeconds))
        this.buildPlaytimeMetric($r('app.string.steam_game_detail_playtime_last_played'),
          this.lastPlayedText())
      }
      .width('100%')
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
  private buildPlaytimeMetric(label: ResourceStr, value: string): void {
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
  private buildAchievementsCard(): void {
    Column({ space: 10 }) {
      this.buildSectionTitle($r('sys.symbol.medal'), $r('app.string.steam_game_detail_achievements_title'))
      if (this.achievements === null) {
        Text($r('app.string.steam_game_detail_achievements_empty'))
          .fontSize(12)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      } else {
        Row({ space: 8 }) {
          Text($r('app.string.steam_game_detail_achievements_unlocked'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          Text(this.achievements.unlockedCount.toString() + ' / ' + this.achievements.totalCount.toString())
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.accent(this.isDarkMode))
          Progress({
            value: this.achievements.totalCount > 0
              ? Math.round(this.achievements.unlockedCount * 100 / this.achievements.totalCount) : 0,
            total: 100,
            type: ProgressType.Linear
          })
            .width(72)
            .height(4)
            .color(SteamArkTheme.accent(this.isDarkMode))
            .backgroundColor(SteamArkTheme.surfaceOverlay(this.isDarkMode))
        }
        .width('100%')
        if (this.achievements.achievements.length <= 0 && this.achievements.totalCount > 0) {
          Text($r('app.string.steam_game_detail_achievements_summary_only'))
            .fontSize(11)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
            .width('100%')
        }
        // Badge-style achievement tiles: unlocked first, locked after; tapping
        // opens the achievement detail overlay with a seamless flight.
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
          ForEach(this.achievementRows(this.achievements), (achievement: SteamGameAchievementInfo) => {
            this.buildAchievementTile(achievement)
          }, (achievement: SteamGameAchievementInfo): string =>
            (achievement.apiName.length > 0 ? achievement.apiName : achievement.name) + ':' +
            String(achievement.achieved))
        }
        .width('100%')
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
  private buildAchievementTile(achievement: SteamGameAchievementInfo): void {
    Column({ space: 6 }) {
      if (this.isOpenAchievementTile(achievement)) {
        // The opened tile icon unmounts (real disappear) so the detail hero
        // icon can pair with it in both flight directions; the equal-size
        // placeholder keeps the persistent list layout stable.
        Column()
          .width(44)
          .height(44)
      } else if (achievement.iconUrl.length > 0) {
        Image(achievement.iconUrl)
          .width(44)
          .height(44)
          .objectFit(ImageFit.Contain)
          .opacity(achievement.achieved ? 1 : 0.4)
          .geometryTransition(SteamArkAchievementDetailRequest.iconGeometryId(
            achievement.apiName, achievement.name))
          .transition(TransitionEffect.OPACITY)
          .onError((): void => {
          })
      } else {
        SymbolGlyph(achievement.achieved
          ? $r('sys.symbol.checkmark') : $r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([achievement.achieved
            ? SteamArkTheme.success(this.isDarkMode)
            : SteamArkTheme.textMuted(this.isDarkMode)])
      }
      Text(achievement.name.length > 0 ? achievement.name : achievement.apiName)
        .fontSize(10)
        .fontColor(achievement.achieved
          ? SteamArkTheme.textPrimary(this.isDarkMode)
          : SteamArkTheme.textSecondary(this.isDarkMode))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('31%')
    .padding({ top: 8, bottom: 8 })
    .margin({ right: '2.33%', bottom: 8 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .onClick((): void => {
      this.openAchievementDetail(achievement);
    })
  }

  /**
   * Achievement detail overlay (seamless): appears above the game detail
   * content; the tile icon unmounts while open so the pair has a genuine
   * appear/disappear in both flight directions.
   */
  @Builder
  private buildAchievementDetailOverlay(): void {
    if (this.achievementDetailVisible) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            if (this.achievementDetailRequest.iconUrl.length > 0) {
              Image(this.achievementDetailRequest.iconUrl)
                .width(96)
                .height(96)
                .objectFit(ImageFit.Contain)
                .clip(true)
                .borderRadius(12)
                .geometryTransition(SteamArkAchievementDetailRequest.iconGeometryId(
                  this.achievementDetailRequest.apiName, this.achievementDetailRequest.name))
                .transition(TransitionEffect.OPACITY)
            } else {
              SymbolGlyph(this.achievementDetailRequest.achieved
                ? $r('sys.symbol.checkmark') : $r('sys.symbol.xmark'))
                .fontSize(44)
                .fontColor([this.achievementDetailRequest.achieved
                  ? SteamArkTheme.success(this.isDarkMode)
                  : SteamArkTheme.textMuted(this.isDarkMode)])
            }
            Column({ space: 4 }) {
              Text(this.achievementDetailRequest.name.length > 0
                ? this.achievementDetailRequest.name : this.achievementDetailRequest.apiName)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.achievementDetailRequest.achieved) {
                Row({ space: 4 }) {
                  Text($r('app.string.steam_achievement_detail_unlocked_at'))
                    .fontSize(11)
                    .fontColor(SteamArkTheme.success(this.isDarkMode))
                  if (this.achievementDetailRequest.unlockTimeEpochSeconds > 0) {
                    Text(this.relativeDateText(this.achievementDetailRequest.unlockTimeEpochSeconds))
                      .fontSize(11)
                      .fontColor(SteamArkTheme.success(this.isDarkMode))
                  }
                }
              } else {
                Text($r('app.string.steam_achievement_detail_locked'))
                  .fontSize(11)
                  .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: SteamArkTheme.CONTENT_TOP_INSET + 56 })

          Scroll() {
            Column({ space: 12 }) {
              Column({ space: 8 }) {
                Row({ space: 6 }) {
                  SymbolGlyph($r('sys.symbol.doc_text'))
                    .fontSize(14)
                    .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
                  Text($r('app.string.steam_achievement_detail_description'))
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
                }
                .width('100%')
                Text(this.achievementDetailRequest.description.length > 0
                  ? this.achievementDetailRequest.description
                  : $r('app.string.steam_achievement_detail_no_description'))
                  .width('100%')
                  .fontSize(12)
                  .lineHeight(18)
                  .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
              }
              .width('100%')
              .padding(16)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
                SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
              .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
              .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
              .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 48 })
          }
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')

        this.buildAchievementPanelTopBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(SteamArkTheme.background(this.isDarkMode))
      .transition(SteamArkExperiencePolicy.seamlessBranchTransition())
    }
  }

  @Builder
  private buildAchievementPanelTopBar(): void {
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
      .id('steam-ark-achievement-detail-back')
      .onClick((): void => {
        this.closeAchievementDetail();
      })
      Text($r('app.string.steam_achievement_detail_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: SteamArkTheme.CONTENT_TOP_INSET - 44, bottom: 6 })
  }

  /** True when this achievement tile is the one whose detail is open. */
  private isOpenAchievementTile(achievement: SteamGameAchievementInfo): boolean {
    return this.achievementDetailVisible &&
      SteamArkAchievementDetailRequest.iconGeometryId(
        this.achievementDetailRequest.apiName, this.achievementDetailRequest.name) ===
      SteamArkAchievementDetailRequest.iconGeometryId(achievement.apiName, achievement.name);
  }

  private openAchievementDetail(achievement: SteamGameAchievementInfo): void {
    this.achievementDetailRequest = new SteamArkAchievementDetailRequest(
      achievement.apiName,
      achievement.name,
      achievement.description,
      achievement.iconUrl,
      achievement.achieved,
      achievement.unlockTimeEpochSeconds
    );
    // Official 一镜到底 (persistent-source variant): the tile icon unmounts
    // while the detail is open so the flight works in both directions.
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.EXPAND_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.achievementDetailVisible = true;
    });
  }

  private closeAchievementDetail(): void {
    if (!this.achievementDetailVisible) {
      return;
    }
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.EXPAND_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.achievementDetailVisible = false;
    });
  }

  @Builder
  private buildFeaturesCard(): void {
    if (this.info !== null && this.info.categories.length > 0) {
      Column({ space: 10 }) {
        this.buildSectionTitle($r('sys.symbol.archivebox'), $r('app.string.steam_game_detail_features_title'))
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.cloud'))
            .fontSize(16)
            .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
          Text(this.supportsCloudSaves(this.info)
            ? $r('app.string.steam_game_detail_cloud_supported')
            : $r('app.string.steam_game_detail_cloud_unsupported'))
            .fontSize(12)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        }
        .width('100%')
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
          ForEach(this.categoryChips(this.info), (category: string) => {
            Text(category)
              .fontSize(10)
              .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(SteamArkTheme.surfaceOverlay(this.isDarkMode))
              .borderRadius(8)
              .margin({ right: 6, bottom: 6 })
          }, (category: string): string => category)
        }
        .width('100%')
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
  private buildAboutCard(): void {
    if (this.info !== null) {
      Column({ space: 10 }) {
        this.buildSectionTitle($r('sys.symbol.doc_text'), $r('app.string.steam_game_detail_about_title'))
        if (this.info.shortDescription.length > 0) {
          Text(this.info.shortDescription)
            .width('100%')
            .fontSize(12)
            .lineHeight(18)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        } else if (this.info.detailedDescription.length > 0) {
          Text(this.info.detailedDescription)
            .width('100%')
            .fontSize(12)
            .lineHeight(18)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        this.buildAboutRow($r('app.string.steam_game_detail_about_developers'),
          this.info.developers.join('、'))
        this.buildAboutRow($r('app.string.steam_game_detail_about_publishers'),
          this.info.publishers.join('、'))
        this.buildAboutRow($r('app.string.steam_game_detail_about_genres'),
          this.info.genres.join('、'))
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
  private buildAboutRow(label: ResourceStr, value: string): void {
    if (value.length > 0) {
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
  }

  @Builder
  private buildNewsCard(): void {
    Column({ space: 10 }) {
      this.buildSectionTitle($r('sys.symbol.bell'), $r('app.string.steam_game_detail_news_title'))
      if (this.news.length <= 0) {
        Text($r('app.string.steam_game_detail_news_empty'))
          .fontSize(12)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      } else {
        ForEach(this.news.slice(0, MAX_NEWS_ITEMS), (item: SteamGameNewsItem) => {
          this.buildNewsRow(item)
        }, (item: SteamGameNewsItem): string =>
          item.gid.length > 0 ? item.gid : item.title + ':' + item.dateEpochSeconds.toString())
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
  private buildNewsRow(item: SteamGameNewsItem): void {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(item.title)
          .layoutWeight(1)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
      }
      .width('100%')
      Row({ space: 8 }) {
        if (item.feedLabel.length > 0) {
          Text(item.feedLabel)
            .fontSize(10)
            .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
        }
        if (item.dateEpochSeconds > 0) {
          Text(this.relativeDateText(item.dateEpochSeconds))
            .fontSize(10)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        }
      }
      .width('100%')
      if (item.contents.length > 0) {
        Text(item.contents)
          .width('100%')
          .fontSize(11)
          .lineHeight(16)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({
      width: { bottom: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(0.5, this.useSysMat) },
      color: SteamArkTheme.divider(this.isDarkMode)
    })
    .onClick((): void => {
      this.openNewsItem(item);
    })
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
    if (this.request.appId.length <= 0) {
      this.failed = true;
      this.loading = false;
      return;
    }
    const accountId: string = steamArkStateService.getSnapshot().selectedAccountId;
    if (accountId.length <= 0) {
      this.failed = true;
      this.loading = false;
      return;
    }
    this.loading = true;
    this.failed = false;
    try {
      // Default load + silent refresh: a cached bundle renders immediately and
      // a stale one is refreshed in the background through the callback.
      const bundle = await steamArkGameLibraryService.loadGameDetail(
        accountId, this.request.appId,
        (refreshed: SteamGameDetailBundle): void => {
          this.info = refreshed.info;
          this.news = refreshed.news;
          this.achievements = refreshed.achievements;
        });
      if (bundle === null) {
        throw new Error('Steam game detail is not available');
      }
      this.info = bundle.info;
      this.news = bundle.news;
      this.achievements = bundle.achievements;
    } catch (error) {
      SteamArkLog.warn(TAG, 'game detail load failed; appId=' + this.request.appId +
        ', errorType=' + SteamArkLog.errorKind(error));
      this.failed = true;
    } finally {
      this.loading = false;
    }
  }

  private displayName(): string {
    if (this.info !== null && this.info.name.length > 0) {
      return this.info.name;
    }
    return this.request.name.length > 0 ? this.request.name : this.request.appId;
  }

  private hoursText(seconds: number): string {
    if (seconds <= 0) {
      return '';
    }
    const hours: number = seconds / 3600;
    const value: string = hours >= 100 ? Math.round(hours).toString() : hours.toFixed(1);
    return value;
  }

  private lastPlayedText(): string {
    if (this.request.lastPlayedEpochSeconds <= 0) {
      return '';
    }
    return this.relativeDateText(this.request.lastPlayedEpochSeconds);
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

  /** Tile order: unlocked achievements first, locked after. */
  private achievementRows(result: SteamGameAchievementsResult): Array<SteamGameAchievementInfo> {
    if (result.achievements.length <= 0) {
      return [];
    }
    const unlocked: Array<SteamGameAchievementInfo> = [];
    const locked: Array<SteamGameAchievementInfo> = [];
    for (let index = 0; index < result.achievements.length; index++) {
      const achievement: SteamGameAchievementInfo = result.achievements[index];
      if (achievement.achieved) {
        unlocked.push(achievement);
      } else {
        locked.push(achievement);
      }
    }
    const rows: Array<SteamGameAchievementInfo> = [];
    for (let index = 0; index < unlocked.length; index++) {
      rows.push(unlocked[index]);
    }
    for (let index = 0; index < locked.length; index++) {
      rows.push(locked[index]);
    }
    return rows;
  }

  private supportsCloudSaves(info: SteamGameDetailInfo): boolean {
    for (let index = 0; index < info.categories.length; index++) {
      const category: SteamGameDetailCategory = info.categories[index];
      if (category.description.toLowerCase().indexOf('cloud') >= 0) {
        return true;
      }
    }
    return false;
  }

  private categoryChips(info: SteamGameDetailInfo): Array<string> {
    const chips: Array<string> = [];
    for (let index = 0; index < info.categories.length && chips.length < 8; index++) {
      const category: SteamGameDetailCategory = info.categories[index];
      if (category.description.length > 0) {
        chips.push(category.description);
      }
    }
    return chips;
  }

  private openCommunityPage(): void {
    SteamArkLog.info(TAG, 'community page opened; appId=' + this.request.appId);
    const request: SteamArkBrowserRequest = new SteamArkBrowserRequest(
      'https://steamcommunity.com/app/' + this.request.appId + '/',
      this.displayName(),
      this.request.appId
    );
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER, request);
  }

  private openNewsItem(item: SteamGameNewsItem): void {
    if (item.url.length <= 0) {
      return;
    }
    SteamArkLog.info(TAG, 'news item opened; gid=' + item.gid);
    const request: SteamArkBrowserRequest = new SteamArkBrowserRequest(
      item.url,
      item.title.length > 0 ? item.title : this.displayName(),
      item.feedLabel
    );
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER, request);
  }
}
