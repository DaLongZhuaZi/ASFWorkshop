import { HdsNavDestination } from '@kit.UIDesignKit';
import {
  NGFControlStyleTokens,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  NGFHoldingAwarenessSide,
  NGFHoldingUiAnchor,
  ngfHoldingAwarenessFacade,
  ngfSettingsStoreFacade,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import { SteamFarmingPreference, SteamProxyKind } from 'steam_core';
import {
  STEAM_ARK_PROFILE_BACKGROUND_ENABLED_STORAGE_KEY,
  SteamArkAccountRegion,
  SteamArkAccountSnapshot,
  SteamArkContentLocale,
  SteamArkFarmingListsUpdate,
  SteamArkFarmingSettingsUpdate,
  SteamArkRegionPolicy,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  SteamArkLog,
  steamArkStateService,
  steamArkSyncCoordinator
} from '../../steamServices';
import {
  STEAM_ARK_HYPER_SNAP_ENABLED_STORAGE_KEY,
  SteamArkHyperSnapFailureKind,
  SteamArkHyperSnapResult,
  steamArkHyperSnapManager
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { steamArkTabScrollers } from './SteamArkTabScrollers';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { SteamArkNetworkPage } from './SteamArkNetworkPage';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';
import { SteamArkLegalSheetContent, SteamArkLegalSheetKind } from './SteamArkLegalSheetContent';

class SteamArkSettingsSheetKind {
  static readonly HOLDING: number = 0;
  static readonly NETWORK: number = 1;
  static readonly LEGAL: number = 2;
}

@Component
export struct SteamArkSettingsPage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private selectedAccountId: string = '';
  @State private proxyKind: SteamProxyKind = SteamProxyKind.SYSTEM;
  @State private farmingEnabledDraft: boolean = false;
  @State private maxGamesDraft: number = 1;
  @State private dropHoursDraft: number = 0;
  @State private priorityQueueOnlyDraft: boolean = false;
  @State private priorityCount: number = 0;
  @State private farmingDraftInitialized: boolean = false;
  @State private farmingSaveInProgress: boolean = false;
  @State private farmingStatus: ResourceStr = $r('app.string.steam_settings_farming_effective_after_restart');
  @State private priorityListDraft: string = '';
  @State private blacklistDraft: string = '';
  @State private farmingListsInitialized: boolean = false;
  @State private farmingListsSaveInProgress: boolean = false;
  @State private farmingListsStatus: ResourceStr = $r('app.string.steam_settings_farming_lists_hint');
  @State private regionDraft: string = SteamArkAccountRegion.AUTO;
  @State private regionDraftInitialized: boolean = false;
  @State private regionSaveInProgress: boolean = false;
  @State private regionStatus: ResourceStr = $r('app.string.steam_settings_region_save');
  private readonly regionSettings: Array<string> = SteamArkRegionPolicy.availableSettings();
  @State private holdingPermissionRequesting: boolean = false;
  @State private settingsSheetVisible: boolean = false;
  @State private settingsSheetKind: number = SteamArkSettingsSheetKind.HOLDING;
  @State private legalSheetKind: number = SteamArkLegalSheetKind.ABOUT;
  @State private stateReady: boolean = false;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('steam_ark_profile_background_enabled') private backgroundEnabled: boolean = true;
  @StorageProp('ngf_holding_awareness_preferred_anchor') private preferredAnchor: string = NGFHoldingUiAnchor.RIGHT;
  @StorageProp('ngf_holding_awareness_side') private holdingSide: string = NGFHoldingAwarenessSide.UNKNOWN;
  @StorageProp('ngf_holding_awareness_available') private holdingAvailable: boolean = false;
  @StorageProp('ngf_holding_awareness_detect_gesture_granted') private detectGestureGranted: boolean = false;
  @StorageProp('ngf_holding_awareness_activity_motion_granted') private activityMotionGranted: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  @State private hyperSnapEnabledDraft: boolean = true;
  @State private hyperSnapSaveInProgress: boolean = false;
  @State private hyperSnapRebuilding: boolean = false;
  @State private hyperSnapStatus: ResourceStr = $r('app.string.steam_settings_hyper_snap_desc');
  private readonly scroller: Scroller = steamArkTabScrollers.settings;
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('SettingsPage', 'state snapshot received; accounts=' + snapshot.accounts.length.toString());
    this.applyStateSnapshot(snapshot);
  };

  aboutToAppear(): void {
    SteamArkLog.lifecycle('SettingsPage', 'aboutToAppear', 'embedded=' + String(this.embedded));
    this.lifecycleGeneration += 1;
    this.isPageActive = true;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    if (this.embedded) {
      this.topInsetVp = this.contentTopInsetVp;
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
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.SETTINGS);
    }
    steamArkStateService.subscribe('SteamArkSettingsPage', this.stateListener);
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    this.hyperSnapEnabledDraft = ngfSettingsStoreFacade.getBoolean(STEAM_ARK_HYPER_SNAP_ENABLED_STORAGE_KEY, true);
    void this.initializeStateService();
    SteamArkLog.info('SettingsPage', 'state subscription registered');
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle('SettingsPage', 'aboutToDisappear', 'embedded=' + String(this.embedded));
    this.isPageActive = false;
    this.lifecycleGeneration += 1;
    steamArkStateService.unsubscribe('SteamArkSettingsPage');
    if (!this.embedded) {
      SteamArkPageWindowSupport.restoreHome();
    }
  }

  build(): void {
    if (this.embedded) {
      this.buildPageBody();
    } else {
      HdsNavDestination() {
        this.buildPageBody();
      }
      .titleBar(NGFHdsTitleBarOptionsFactory.buildOverContentWithTitleColors(
        $r('app.string.steam_settings_title'),
        $r('app.string.steam_settings_subtitle'),
        $r('app.color.background_transparent'),
        SteamArkTheme.textPrimary(this.isDarkMode),
        SteamArkTheme.textSecondary(this.isDarkMode),
        true,
        false
      ))
      .backgroundImage(this.backgroundEnabled ? this.profileBackgroundUrl : '')
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
          this.buildHoldingEntry();
          if (!this.stateReady) {
            SteamArkStateUnavailableCard({
              isDarkMode: this.isDarkMode,
              useSysMat: this.useSysMat
            });
          } else {
            this.buildRegionCard();
            this.buildFarmingCard();
          }
          this.buildAppearanceCard();
          this.buildHyperSnapCard();
          this.buildNetworkCard();
          this.buildLegalCard();
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.embedded
      ? $r('app.color.background_transparent') : SteamArkTheme.background(this.isDarkMode))
    .opacity(this.stateReady ? 1 : 0.88)
    .animation({ duration: SteamArkExperiencePolicy.CONTENT_REFRESH_DURATION, curve: Curve.EaseOut })
    .bindSheet($$this.settingsSheetVisible, this.buildSettingsSheet(), {
      height: SheetSize.LARGE,
      showClose: true,
      preferType: SheetType.BOTTOM,
      systemMaterial: ngfVisualEffectsFacade.buildSystemMaterialForSheet(),
      backgroundColor: NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat)
    })
  }

  @Builder
  private buildHoldingEntry(): void {
    Button() {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.person_2'))
          .fontSize(22)
          .fontColor([this.operationAdaptationEnabled()
            ? SteamArkTheme.success(this.isDarkMode)
            : SteamArkTheme.accentCyan(this.isDarkMode)])
        Column({ space: 4 }) {
          Text($r('app.string.steam_settings_holding_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text(this.operationAdaptationEnabled()
            ? $r('app.string.steam_settings_holding_enabled')
            : $r('app.string.steam_settings_holding_desc'))
            .fontSize(12)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height(72)
    .padding(0)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForClickablePanel())
    .id('steam-ark-settings-open-holding')
    .onClick((): void => {
      this.openSettingsSheet(SteamArkSettingsSheetKind.HOLDING);
    })
  }

  @Builder
  private buildHoldingSheet(): void {
    Scroll() {
      Column({ space: 12 }) {
        Text($r('app.string.steam_settings_holding_title'))
          .width('100%')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_settings_holding_desc'))
          .width('100%')
          .fontSize(13)
          .lineHeight(20)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        this.buildInfoRow($r('app.string.steam_settings_holding_availability'), this.holdingAvailable
          ? $r('app.string.steam_settings_holding_available')
          : $r('app.string.steam_settings_holding_unavailable'))
        this.buildInfoRow($r('app.string.steam_settings_holding_gesture_permission'), this.detectGestureGranted
          ? $r('app.string.steam_settings_holding_granted')
          : $r('app.string.steam_settings_holding_not_granted'))
        this.buildInfoRow($r('app.string.steam_settings_holding_motion_permission'), this.activityMotionGranted
          ? $r('app.string.steam_settings_holding_granted')
          : $r('app.string.steam_settings_holding_not_granted'))
        this.buildInfoRow($r('app.string.steam_settings_holding_side'), this.holdingSideText())
        this.buildInfoRow($r('app.string.steam_settings_holding_anchor'), this.preferredAnchorText())
        this.buildHoldingPermissionButton();
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private buildHoldingPermissionButton(): void {
    Button() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(16)
          .fontColor([this.operationAdaptationEnabled()
            ? SteamArkTheme.success(this.isDarkMode)
            : SteamArkTheme.accentCyan(this.isDarkMode)])
        Text(this.holdingPermissionRequesting
          ? $r('app.string.steam_settings_holding_requesting')
          : this.operationAdaptationEnabled()
            ? $r('app.string.steam_settings_holding_enabled')
            : $r('app.string.steam_settings_holding_request'))
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .padding(0)
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .enabled(!this.operationAdaptationEnabled() && !this.holdingPermissionRequesting)
    .id('steam-ark-settings-request-holding-permission')
    .onClick((): void => {
      void this.requestHoldingPermission();
    })
  }

  @Builder
  private buildAppearanceCard(): void {
    Column({ space: 12 }) {
      this.buildSectionTitle($r('sys.symbol.paintbrush'), $r('app.string.steam_settings_appearance_title'))
      Text($r('app.string.steam_settings_appearance_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Row({ space: 8 }) {
        Text($r('app.string.steam_settings_profile_background_label'))
          .layoutWeight(1)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .maxLines(2)
        Toggle({ type: ToggleType.Switch, isOn: this.backgroundEnabled })
          .id('steam-ark-settings-profile-background')
          .onChange((value: boolean): void => {
            this.backgroundEnabled = value;
            AppStorage.setOrCreate<boolean>(STEAM_ARK_PROFILE_BACKGROUND_ENABLED_STORAGE_KEY, value);
            ngfSettingsStoreFacade.setBoolean(STEAM_ARK_PROFILE_BACKGROUND_ENABLED_STORAGE_KEY, value);
            SteamArkLog.info('SettingsPage', 'profile background preference changed; enabled=' + String(value));
          })
      }
      .width('100%')
      .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildHyperSnapCard(): void {
    Column({ space: 12 }) {
      this.buildSectionTitle($r('sys.symbol.info_circle'), $r('app.string.steam_settings_hyper_snap_title'))
      Text($r('app.string.steam_settings_hyper_snap_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Row({ space: 8 }) {
        Text($r('app.string.steam_settings_hyper_snap_enabled_label'))
          .layoutWeight(1)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .maxLines(2)
        Toggle({ type: ToggleType.Switch, isOn: this.hyperSnapEnabledDraft })
          .enabled(!this.hyperSnapSaveInProgress)
          .id('steam-ark-settings-hyper-snap-enabled')
          .onChange((value: boolean): void => {
            this.hyperSnapEnabledDraft = value;
            this.hyperSnapSaveInProgress = true;
            this.hyperSnapStatus = $r('app.string.steam_settings_hyper_snap_saving');
            const result: SteamArkHyperSnapResult = steamArkHyperSnapManager.setEnabled(value);
            ngfSettingsStoreFacade.setBoolean(STEAM_ARK_HYPER_SNAP_ENABLED_STORAGE_KEY, value);
            this.hyperSnapSaveInProgress = false;
            this.hyperSnapStatus = SteamArkSettingsPage.hyperSnapResultStatus(result);
          })
      }
      .width('100%')
      .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
      Text(this.hyperSnapStatus)
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(16)
            .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
          Text($r('app.string.steam_settings_hyper_snap_rebuild'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .padding(0)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
      .enabled(!this.hyperSnapRebuilding)
      .id('steam-ark-settings-rebuild-hyper-snap')
      .onClick((): void => {
        this.confirmRebuildHyperSnap();
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildRegionCard(): void {
    Column({ space: 12 }) {
      this.buildSectionTitle($r('sys.symbol.globe_badge_message'), $r('app.string.steam_settings_region_title'))
      Text($r('app.string.steam_settings_region_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      if (this.hasSelectedAccount()) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.regionSettings, (setting: string) => {
              if (this.regionDraft === setting) {
                Button() {
                  Row({ space: 6 }) {
                    SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                      .fontSize(14)
                      .fontColor([SteamArkTheme.buttonForeground(this.isDarkMode)])
                    Text(this.regionLabel(setting))
                      .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
                  }
                }
                .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
                .padding({ left: 12, right: 12 })
                .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
                .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
                .border({
                  width: 1.5,
                  color: SteamArkTheme.accent(this.isDarkMode)
                })
                .enabled(!this.regionSaveInProgress)
                .onClick((): void => {
                  this.regionDraft = setting;
                  this.regionStatus = $r('app.string.steam_settings_region_save');
                })
              } else {
                Button() {
                  Text(this.regionLabel(setting))
                    .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
                    .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
                }
                .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
                .padding({ left: 12, right: 12 })
                .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
                .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
                  SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
                .border({
                  width: 1,
                  color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
                    SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
                })
                .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
                .enabled(!this.regionSaveInProgress)
                .onClick((): void => {
                  this.regionDraft = setting;
                  this.regionStatus = $r('app.string.steam_settings_region_save');
                })
              }
            }, (setting: string) => setting)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .edgeEffect(EdgeEffect.Spring)
        this.buildInfoRow($r('app.string.steam_settings_region_effective'), this.effectiveRegionText())
        Text(this.regionStatus)
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        Button() {
          Row({ space: 8 }) {
            if (this.regionSaveInProgress) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color(SteamArkTheme.buttonForeground(this.isDarkMode))
            } else {
              SymbolGlyph($r('sys.symbol.checkmark_circle'))
                .fontSize(16)
                .fontColor([SteamArkTheme.buttonForeground(this.isDarkMode)])
            }
            Text(this.regionSaveInProgress
              ? $r('app.string.steam_settings_region_saving')
              : $r('app.string.steam_settings_region_save'))
              .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
              .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
          }
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
        .padding(0)
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(this.canSaveRegion()
          ? SteamArkTheme.accent(this.isDarkMode)
          : SteamArkTheme.buttonDisabled(this.isDarkMode))
        .enabled(this.canSaveRegion())
        .id('steam-ark-settings-save-region')
        .onClick((): void => {
          void this.saveRegion();
        })
      } else {
        Text($r('app.string.steam_settings_region_account_required'))
          .width('100%')
          .fontSize(13)
          .lineHeight(19)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildFarmingCard(): void {
    Column({ space: 12 }) {
      this.buildSectionTitle($r('sys.symbol.play_round_triangle_fill'), $r('app.string.steam_settings_farming_title'))
      Text($r('app.string.steam_settings_farming_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      if (this.hasSelectedAccount()) {
        this.buildFarmingToggle($r('app.string.steam_settings_enabled_label'), this.farmingEnabledDraft, 1)
        this.buildFarmingValueControl($r('app.string.steam_settings_max_games_label'), this.maxGamesDraft, 1)
        this.buildFarmingValueControl($r('app.string.steam_settings_drop_hours_label'), this.dropHoursDraft, 2)
        this.buildFarmingToggle(
          $r('app.string.steam_settings_farming_priority_queue_only'),
          this.priorityQueueOnlyDraft,
          2
        )
      } else {
        Text($r('app.string.steam_settings_farming_account_required'))
          .width('100%')
          .fontSize(13)
          .lineHeight(19)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      this.buildInfoRow($r('app.string.steam_settings_priority_label'), this.priorityCount.toString())
      if (this.priorityQueueOnlyDraft && this.priorityCount <= 0) {
        Text($r('app.string.steam_settings_farming_priority_queue_empty'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.warning(this.isDarkMode))
      }
      if (this.hasSelectedAccount()) {
        this.buildFarmingListsEditor()
      }
      Text(this.farmingStatus)
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Button() {
        Row({ space: 8 }) {
          if (this.farmingSaveInProgress) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(SteamArkTheme.buttonForeground(this.isDarkMode))
          } else {
            SymbolGlyph($r('sys.symbol.checkmark_circle'))
              .fontSize(16)
              .fontColor([SteamArkTheme.buttonForeground(this.isDarkMode)])
          }
          Text(this.farmingSaveInProgress
            ? $r('app.string.steam_settings_farming_saving')
            : $r('app.string.steam_settings_farming_save'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .padding(0)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(this.canSaveFarmingSettings()
        ? SteamArkTheme.accent(this.isDarkMode)
        : SteamArkTheme.buttonDisabled(this.isDarkMode))
      .enabled(this.canSaveFarmingSettings())
      .id('steam-ark-settings-save-farming')
      .onClick((): void => {
        void this.saveFarmingSettings();
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildFarmingListsEditor(): void {
    Column({ space: 8 }) {
      Divider()
        .color(SteamArkTheme.divider(this.isDarkMode))
      Text($r('app.string.steam_settings_farming_lists_title'))
        .width('100%')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_settings_farming_lists_hint'))
        .width('100%')
        .fontSize(11)
        .lineHeight(16)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Text($r('app.string.steam_settings_farming_lists_priority_label'))
        .width('100%')
        .fontSize(12)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      TextInput({ text: this.priorityListDraft,
        placeholder: $r('app.string.steam_settings_farming_lists_placeholder') })
        .id('steam-ark-settings-priority-list-input')
        .width('100%')
        .fontSize(13)
        .enabled(!this.farmingListsSaveInProgress)
        .onChange((value: string): void => {
          this.priorityListDraft = value;
        })
      Text($r('app.string.steam_settings_farming_lists_blacklist_label'))
        .width('100%')
        .fontSize(12)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      TextInput({ text: this.blacklistDraft,
        placeholder: $r('app.string.steam_settings_farming_lists_placeholder') })
        .id('steam-ark-settings-blacklist-input')
        .width('100%')
        .fontSize(13)
        .enabled(!this.farmingListsSaveInProgress)
        .onChange((value: string): void => {
          this.blacklistDraft = value;
        })
      Text(this.farmingListsStatus)
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Button() {
        Row({ space: 8 }) {
          if (this.farmingListsSaveInProgress) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(SteamArkTheme.buttonForeground(this.isDarkMode))
          } else {
            SymbolGlyph($r('sys.symbol.checkmark_circle'))
              .fontSize(16)
              .fontColor([SteamArkTheme.buttonForeground(this.isDarkMode)])
          }
          Text(this.farmingListsSaveInProgress
            ? $r('app.string.steam_settings_farming_lists_saving')
            : $r('app.string.steam_settings_farming_lists_save'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .padding(0)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(this.canSaveFarmingLists()
        ? SteamArkTheme.accent(this.isDarkMode)
        : SteamArkTheme.buttonDisabled(this.isDarkMode))
      .enabled(this.canSaveFarmingLists())
      .id('steam-ark-settings-save-farming-lists')
      .onClick((): void => {
        void this.saveFarmingLists();
      })
    }
    .width('100%')
  }

  @Builder
  private buildNetworkCard(): void {
    Button() {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.wifi'))
          .fontSize(22)
          .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
        Column({ space: 4 }) {
          Text($r('app.string.steam_settings_network_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text(this.proxyText())
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height(72)
    .padding(0)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForClickablePanel())
    .id('steam-ark-settings-open-network')
    .onClick((): void => {
      this.openSettingsSheet(SteamArkSettingsSheetKind.NETWORK);
    })
  }

  @Builder
  private buildNetworkSheet(): void {
    Column() {
      SteamArkNetworkPage({
        embedded: true,
        contentTopInsetVp: 0
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_transparent'))
  }

  @Builder
  private buildLegalCard(): void {
    Column({ space: 9 }) {
      this.buildSectionTitle($r('sys.symbol.info_circle'), $r('app.string.steam_settings_legal_title'))
      this.buildLegalActionButton(
        $r('sys.symbol.info_circle'),
        $r('app.string.steam_settings_open_about'),
        SteamArkLegalSheetKind.ABOUT,
        'steam-ark-settings-open-about'
      );
      this.buildLegalActionButton(
        $r('sys.symbol.doc_text'),
        $r('app.string.steam_settings_open_user_agreement'),
        SteamArkLegalSheetKind.USER_AGREEMENT,
        'steam-ark-settings-open-user-agreement'
      );
      this.buildLegalActionButton(
        $r('sys.symbol.lock_shield'),
        $r('app.string.steam_settings_open_privacy'),
        SteamArkLegalSheetKind.PRIVACY,
        'steam-ark-settings-open-privacy'
      );
      this.buildLegalActionButton(
        $r('sys.symbol.doc_text_magnifyingglass_fill'),
        $r('app.string.steam_settings_open_open_source'),
        SteamArkLegalSheetKind.OPEN_SOURCE,
        'steam-ark-settings-open-open-source'
      );
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
  private buildLegalActionButton(
    icon: Resource,
    title: ResourceStr,
    sheetKind: number,
    elementId: string
  ): void {
    Button() {
      Row({ space: 8 }) {
        SymbolGlyph(icon)
          .fontSize(17)
          .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)]);
        Text(title)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
          .layoutWeight(1)
          .textAlign(TextAlign.Start);
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)]);
      }
      .width('100%')
      .padding({ left: 12, right: 12 });
    }
    .width('100%')
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .padding(0)
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode),
      this.useSysMat
    ))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .id(elementId)
    .onClick((): void => {
      this.legalSheetKind = sheetKind;
      this.openSettingsSheet(SteamArkSettingsSheetKind.LEGAL);
    })
  }

  @Builder
  private buildSettingsSheet(): void {
    if (this.settingsSheetKind === SteamArkSettingsSheetKind.NETWORK) {
      this.buildNetworkSheet();
    } else if (this.settingsSheetKind === SteamArkSettingsSheetKind.LEGAL) {
      SteamArkLegalSheetContent({ kind: this.legalSheetKind });
    } else {
      this.buildHoldingSheet();
    }
  }

  @Builder
  private buildSectionTitle(icon: Resource, title: ResourceStr): void {
    Row({ space: 8 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
    }
    .width('100%')
  }

  @Builder
  private buildInfoRow(label: ResourceStr, value: ResourceStr): void {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .layoutWeight(1)
      Text(value)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  @Builder
  private buildFarmingToggle(title: ResourceStr, isOn: boolean, controlKey: number): void {
    Row({ space: 8 }) {
      Text(title)
        .layoutWeight(1)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .maxLines(2)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .enabled(!this.farmingSaveInProgress && this.hasSelectedAccount())
        .id(controlKey === 1
          ? 'steam-ark-settings-farming-enabled'
          : 'steam-ark-settings-farming-priority-only')
        .onChange((value: boolean): void => {
          if (controlKey === 1) {
            this.farmingEnabledDraft = value;
          } else {
            this.priorityQueueOnlyDraft = value;
          }
          this.farmingStatus = $r('app.string.steam_settings_farming_effective_after_restart');
        })
    }
    .width('100%')
    .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
  }

  @Builder
  private buildFarmingValueControl(label: ResourceStr, value: number, controlKey: number): void {
    Row({ space: 8 }) {
      Text(label)
        .layoutWeight(1)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .maxLines(2)
      this.buildValueAdjustmentButton(
        $r('sys.symbol.minus'),
        $r('app.string.steam_settings_farming_decrease'),
        controlKey,
        false
      )
      Text(value.toString())
        .width(34)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .textAlign(TextAlign.Center)
      this.buildValueAdjustmentButton(
        $r('sys.symbol.plus'),
        $r('app.string.steam_settings_farming_increase'),
        controlKey,
        true
      )
    }
    .width('100%')
    .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
  }

  @Builder
  private buildValueAdjustmentButton(
    icon: Resource,
    label: Resource,
    controlKey: number,
    increase: boolean
  ): void {
    Button() {
      SymbolGlyph(icon)
        .fontSize(16)
        .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
    }
    .width(34)
    .height(34)
    .padding(0)
    .borderRadius(17)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .accessibilityText(label)
    .enabled(!this.farmingSaveInProgress && this.hasSelectedAccount())
    .onClick((): void => {
      this.adjustFarmingValue(controlKey, increase);
    })
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    this.stateReady = snapshot.initialized;
    const previousAccountId: string = this.selectedAccountId;
    this.selectedAccountId = snapshot.selectedAccountId;
    const selected: SteamArkAccountSnapshot | null = steamArkStateService.getSelectedAccount();
    if (selected === null) {
      this.proxyKind = SteamProxyKind.SYSTEM;
      this.priorityCount = 0;
      this.farmingDraftInitialized = false;
      this.farmingEnabledDraft = false;
      this.maxGamesDraft = 1;
      this.dropHoursDraft = 0;
      this.priorityQueueOnlyDraft = false;
      this.farmingListsInitialized = false;
      this.priorityListDraft = '';
      this.blacklistDraft = '';
      this.farmingListsStatus = $r('app.string.steam_settings_farming_lists_hint');
      this.farmingStatus = $r('app.string.steam_settings_farming_account_required');
      return;
    }
    this.proxyKind = selected.profile.proxy.kind;
    this.priorityCount = selected.config.priorityAppIds.length;
    if (!this.regionDraftInitialized || previousAccountId !== this.selectedAccountId) {
      this.regionDraft = selected.region;
      this.regionDraftInitialized = true;
      this.regionStatus = $r('app.string.steam_settings_region_save');
    }
    if (!this.farmingDraftInitialized || previousAccountId !== this.selectedAccountId) {
      this.applyFarmingDraft(selected);
    }
    if (!this.farmingListsInitialized || previousAccountId !== this.selectedAccountId) {
      this.applyFarmingListsDraft(selected);
    }
    SteamArkLog.debug('SettingsPage', 'state applied; selectedAccount=' +
      SteamArkLog.accountId(this.selectedAccountId) + ', priorityGames=' + this.priorityCount.toString());
  }

  private applyFarmingDraft(selected: SteamArkAccountSnapshot): void {
    this.farmingEnabledDraft = selected.config.enabled;
    this.maxGamesDraft = selected.config.maxGamesPlayedConcurrently;
    this.dropHoursDraft = selected.config.hoursUntilCardDrops;
    this.priorityQueueOnlyDraft = selected.config.hasPreference(SteamFarmingPreference.FARM_PRIORITY_QUEUE_ONLY);
    this.farmingDraftInitialized = true;
    this.farmingStatus = $r('app.string.steam_settings_farming_effective_after_restart');
  }

  private applyFarmingListsDraft(selected: SteamArkAccountSnapshot): void {
    this.priorityListDraft = selected.config.priorityAppIds.join(',');
    this.blacklistDraft = selected.config.blacklist.join(',');
    this.farmingListsInitialized = true;
    this.farmingListsStatus = $r('app.string.steam_settings_farming_lists_hint');
  }

  private parseAppIdListDraft(value: string): Array<string> | null {
    const parts: Array<string> = value.split(',');
    const appIds: Array<string> = [];
    for (let index = 0; index < parts.length; index++) {
      const part: string = parts[index].trim();
      if (part.length <= 0) {
        continue;
      }
      if (!/^[0-9]+$/.test(part) || Number(part) <= 0) {
        return null;
      }
      const appId: string = part.replace(/^0+(?=\d)/, '');
      if (!appIds.includes(appId)) {
        appIds.push(appId);
      }
    }
    if (appIds.length > 128) {
      return null;
    }
    return appIds;
  }

  private canSaveFarmingLists(): boolean {
    return this.hasSelectedAccount() && !this.farmingListsSaveInProgress;
  }

  private async saveFarmingLists(): Promise<void> {
    if (!this.canSaveFarmingLists()) {
      return;
    }
    const priorityAppIds: Array<string> | null = this.parseAppIdListDraft(this.priorityListDraft);
    const blacklist: Array<string> | null = this.parseAppIdListDraft(this.blacklistDraft);
    if (priorityAppIds === null || blacklist === null) {
      this.farmingListsStatus = $r('app.string.steam_settings_farming_lists_invalid');
      return;
    }
    const accountId: string = this.selectedAccountId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.farmingListsSaveInProgress = true;
    this.farmingListsStatus = $r('app.string.steam_settings_farming_lists_saving');
    try {
      const saved: boolean = await steamArkStateService.saveFarmingLists(accountId,
        new SteamArkFarmingListsUpdate(blacklist, priorityAppIds));
      if (!this.isCurrentFarmingSave(accountId, lifecycleGeneration)) {
        return;
      }
      if (!saved) {
        this.farmingListsStatus = $r('app.string.steam_settings_farming_account_required');
        return;
      }
      const selected: SteamArkAccountSnapshot | null = steamArkStateService.getSelectedAccount();
      if (selected !== null && selected.profile.accountId === accountId) {
        this.priorityCount = selected.config.priorityAppIds.length;
        this.applyFarmingListsDraft(selected);
      }
      this.farmingListsStatus = $r('app.string.steam_settings_farming_lists_saved');
    } catch (_error) {
      if (this.isCurrentFarmingSave(accountId, lifecycleGeneration)) {
        this.farmingListsStatus = $r('app.string.steam_settings_farming_lists_failed');
      }
      SteamArkLog.error('SettingsPage', 'farming lists save failed; account=' +
        SteamArkLog.accountId(accountId));
    } finally {
      if (this.isCurrentFarmingSave(accountId, lifecycleGeneration)) {
        this.farmingListsSaveInProgress = false;
      }
    }
  }

  private hasSelectedAccount(): boolean {
    return this.stateReady && this.selectedAccountId.length > 0;
  }

  private canSaveFarmingSettings(): boolean {
    return this.hasSelectedAccount() && !this.farmingSaveInProgress;
  }

  private adjustFarmingValue(controlKey: number, increase: boolean): void {
    if (!this.canSaveFarmingSettings()) {
      return;
    }
    const direction: number = increase ? 1 : -1;
    if (controlKey === 1) {
      this.maxGamesDraft = Math.max(1, Math.min(32, this.maxGamesDraft + direction));
    } else {
      this.dropHoursDraft = Math.max(0, Math.min(255, this.dropHoursDraft + direction));
    }
    this.farmingStatus = $r('app.string.steam_settings_farming_effective_after_restart');
  }

  private async saveFarmingSettings(): Promise<void> {
    if (!this.canSaveFarmingSettings()) {
      return;
    }
    const accountId: string = this.selectedAccountId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.farmingSaveInProgress = true;
    this.farmingStatus = $r('app.string.steam_settings_farming_saving');
    try {
      const update = new SteamArkFarmingSettingsUpdate(
        this.farmingEnabledDraft,
        this.dropHoursDraft,
        this.maxGamesDraft,
        this.priorityQueueOnlyDraft
      );
      const saved: boolean = await steamArkStateService.saveFarmingSettings(accountId, update);
      if (!this.isCurrentFarmingSave(accountId, lifecycleGeneration)) {
        return;
      }
      if (!saved) {
        this.farmingStatus = $r('app.string.steam_settings_farming_account_required');
        return;
      }
      const selected: SteamArkAccountSnapshot | null = steamArkStateService.getSelectedAccount();
      if (selected !== null && selected.profile.accountId === accountId) {
        this.applyFarmingDraft(selected);
      }
      this.farmingStatus = $r('app.string.steam_settings_farming_saved');
    } catch (_error) {
      if (this.isCurrentFarmingSave(accountId, lifecycleGeneration)) {
        this.farmingStatus = $r('app.string.steam_settings_farming_save_failed');
      }
      SteamArkLog.error('SettingsPage', 'farming settings save failed; account=' +
        SteamArkLog.accountId(accountId));
    } finally {
      if (this.isCurrentFarmingSave(accountId, lifecycleGeneration)) {
        this.farmingSaveInProgress = false;
      }
    }
  }

  private canSaveRegion(): boolean {
    return this.hasSelectedAccount() && !this.regionSaveInProgress;
  }

  private async saveRegion(): Promise<void> {
    if (!this.canSaveRegion()) {
      return;
    }
    const accountId: string = this.selectedAccountId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.regionSaveInProgress = true;
    this.regionStatus = $r('app.string.steam_settings_region_saving');
    try {
      const saved: boolean = await steamArkStateService.saveRegion(accountId, this.regionDraft);
      if (!this.isCurrentFarmingSave(accountId, lifecycleGeneration)) {
        return;
      }
      if (!saved) {
        this.regionStatus = $r('app.string.steam_settings_region_save_failed');
        return;
      }
      this.regionStatus = $r('app.string.steam_settings_region_saved');
      // The region save already dropped the language-dependent caches; pull a
      // full silent sync so badges, inventory, library, messages and detail
      // data come back in the new language right away.
      void steamArkSyncCoordinator.requestAccountSync(accountId, 'region_changed')
        .then((): void => {
          SteamArkLog.info('SettingsPage', 'region change resync completed; account=' +
            SteamArkLog.accountId(accountId));
        })
        .catch((error: Error): void => {
          SteamArkLog.warn('SettingsPage', 'region change resync failed; account=' +
            SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
        });
    } catch (_error) {
      if (this.isCurrentFarmingSave(accountId, lifecycleGeneration)) {
        this.regionStatus = $r('app.string.steam_settings_region_save_failed');
      }
      SteamArkLog.error('SettingsPage', 'region save failed; account=' + SteamArkLog.accountId(accountId));
    } finally {
      if (this.isCurrentFarmingSave(accountId, lifecycleGeneration)) {
        this.regionSaveInProgress = false;
      }
    }
  }

  /** Live preview: resolves the currently drafted region, not the stored one. */
  private effectiveRegionText(): string {
    const selected: SteamArkAccountSnapshot | null = steamArkStateService.getSelectedAccount();
    if (selected === null) {
      return '';
    }
    const locale: SteamArkContentLocale = SteamArkRegionPolicy.resolve(
      this.regionDraft, selected.profile.countryCode, selected.profile.walletCurrency);
    return locale.region + ' · ' + locale.steamLanguage + ' · ' + locale.currencyCode;
  }

  private regionLabel(setting: string): ResourceStr {
    switch (setting) {
      case SteamArkAccountRegion.CN:
        return $r('app.string.steam_settings_region_cn');
      case SteamArkAccountRegion.TW:
        return $r('app.string.steam_settings_region_tw');
      case SteamArkAccountRegion.HK:
        return $r('app.string.steam_settings_region_hk');
      case SteamArkAccountRegion.JP:
        return $r('app.string.steam_settings_region_jp');
      case SteamArkAccountRegion.KR:
        return $r('app.string.steam_settings_region_kr');
      case SteamArkAccountRegion.US:
        return $r('app.string.steam_settings_region_us');
      case SteamArkAccountRegion.EU:
        return $r('app.string.steam_settings_region_eu');
      case SteamArkAccountRegion.GB:
        return $r('app.string.steam_settings_region_gb');
      case SteamArkAccountRegion.RU:
        return $r('app.string.steam_settings_region_ru');
      case SteamArkAccountRegion.BR:
        return $r('app.string.steam_settings_region_br');
      case SteamArkAccountRegion.AUTO:
      default:
        return $r('app.string.steam_settings_region_auto');
    }
  }

  private isCurrentFarmingSave(accountId: string, lifecycleGeneration: number): boolean {
    return this.isPageActive && this.lifecycleGeneration === lifecycleGeneration && this.selectedAccountId === accountId;
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
      SteamArkLog.info('SettingsPage', 'state service ready; initialized=' + String(initialized));
      SteamArkLog.performance('SettingsPage', 'state initialization', startedAt);
    } catch (_error) {
      SteamArkLog.error('SettingsPage', 'state service initialization failed');
    }
  }

  private async requestHoldingPermission(): Promise<void> {
    if (!this.isPageActive || this.operationAdaptationEnabled() || this.holdingPermissionRequesting) {
      SteamArkLog.debug('SettingsPage', 'holding permission request skipped; already granted or busy');
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.holdingPermissionRequesting = true;
    SteamArkLog.info('SettingsPage', 'holding awareness permission request started');
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext === undefined) {
        SteamArkLog.warn('SettingsPage', 'holding awareness permission request skipped; host context unavailable');
        return;
      }
      const requestGranted: boolean = await ngfHoldingAwarenessFacade.requestActivityMotionPermission(hostContext);
      await ngfHoldingAwarenessFacade.resume();
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      const snapshot = ngfHoldingAwarenessFacade.getSnapshot();
      SteamArkLog.info('SettingsPage', 'holding awareness permission request completed; requestGranted=' +
        String(requestGranted) + ', snapshotGranted=' + String(snapshot.activityMotionGranted));
    } catch (_error) {
      SteamArkLog.warn('SettingsPage', 'holding awareness permission request failed');
    } finally {
      if (this.isPageActive && this.lifecycleGeneration === lifecycleGeneration) {
        this.holdingPermissionRequesting = false;
      }
    }
  }

  private operationAdaptationEnabled(): boolean {
    return this.activityMotionGranted;
  }

  private confirmRebuildHyperSnap(): void {
    if (!this.isPageActive || this.hyperSnapRebuilding) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.steam_settings_hyper_snap_rebuild_title'),
      message: $r('app.string.steam_settings_hyper_snap_rebuild_message'),
      primaryButton: {
        value: $r('app.string.steam_settings_hyper_snap_rebuild_confirm'),
        action: (): void => {
          this.rebuildHyperSnap();
        }
      },
      secondaryButton: {
        value: $r('app.string.steam_accounts_cancel'),
        action: (): void => {
          return;
        }
      }
    });
  }

  private rebuildHyperSnap(): void {
    if (this.hyperSnapRebuilding) {
      return;
    }
    this.hyperSnapRebuilding = true;
    this.hyperSnapStatus = $r('app.string.steam_settings_hyper_snap_rebuilding');
    const result: SteamArkHyperSnapResult = steamArkHyperSnapManager.rebuildSnapshot();
    this.hyperSnapRebuilding = false;
    this.hyperSnapStatus = SteamArkSettingsPage.hyperSnapResultStatus(result);
  }

  private static hyperSnapResultStatus(result: SteamArkHyperSnapResult): ResourceStr {
    if (result.applied) {
      return $r('app.string.steam_settings_hyper_snap_saved');
    }
    if (result.failureKind === SteamArkHyperSnapFailureKind.SERVICE_UNAVAILABLE) {
      return $r('app.string.steam_settings_hyper_snap_unavailable');
    }
    return $r('app.string.steam_settings_hyper_snap_save_failed');
  }

  private openSettingsSheet(kind: number): void {
    this.settingsSheetKind = kind;
    this.settingsSheetVisible = true;
  }

  private holdingSideText(): ResourceStr {
    switch (this.holdingSide) {
      case NGFHoldingAwarenessSide.LEFT:
        return $r('app.string.steam_settings_holding_side_left');
      case NGFHoldingAwarenessSide.RIGHT:
        return $r('app.string.steam_settings_holding_side_right');
      case NGFHoldingAwarenessSide.BOTH:
        return $r('app.string.steam_settings_holding_side_both');
      case NGFHoldingAwarenessSide.NONE:
        return $r('app.string.steam_settings_holding_side_none');
      case NGFHoldingAwarenessSide.UNKNOWN:
      default:
        return $r('app.string.steam_settings_holding_side_unknown');
    }
  }

  private preferredAnchorText(): ResourceStr {
    return this.preferredAnchor === NGFHoldingUiAnchor.LEFT
      ? $r('app.string.steam_settings_holding_anchor_left')
      : $r('app.string.steam_settings_holding_anchor_right');
  }

  private proxyText(): ResourceStr {
    switch (this.proxyKind) {
      case SteamProxyKind.DIRECT:
        return $r('app.string.steam_network_mode_direct');
      case SteamProxyKind.HTTP:
        return $r('app.string.steam_network_mode_http');
      case SteamProxyKind.SOCKS5:
        return $r('app.string.steam_network_mode_socks5');
      case SteamProxyKind.SYSTEM:
      default:
        return $r('app.string.steam_settings_proxy_system');
    }
  }
}
