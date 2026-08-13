import { HdsNavDestination } from '@kit.UIDesignKit';
import {
  NGFControlStyleTokens,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  NGFHoldingAwarenessSide,
  NGFHoldingUiAnchor,
  ngfHoldingAwarenessFacade,
  resolveResourceString,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import { SteamProxyKind, SteamSessionState } from 'steam_core';
import {
  SteamArkAccountSnapshot,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  SteamArkSensitiveAction,
  SteamArkSensitiveActionOutcome,
  SteamArkLog,
  steamArkSensitiveActionGate,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { steamArkTabScrollers } from './SteamArkTabScrollers';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { SteamArkNetworkPage } from './SteamArkNetworkPage';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';

@Component
export struct SteamArkSettingsPage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private selectedAccountId: string = '';
  @State private selectedAccountName: string = '';
  @State private sessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  @State private proxyKind: SteamProxyKind = SteamProxyKind.SYSTEM;
  @State private accountEnabled: boolean = false;
  @State private farmingEnabled: boolean = false;
  @State private maxGames: number = 0;
  @State private dropHours: number = 0;
  @State private priorityCount: number = 0;
  @State private hasCredentialMaterial: boolean = false;
  @State private holdingPermissionRequesting: boolean = false;
  @State private biometricBusy: boolean = false;
  @State private biometricStatus: ResourceStr = $r('app.string.steam_settings_biometric_ready');
  @State private routeErrorVisible: boolean = false;
  @State private routeErrorMessage: ResourceStr = $r('app.string.steam_navigation_route_failed');
  @State private stateReady: boolean = false;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_holding_awareness_preferred_anchor') private preferredAnchor: string = NGFHoldingUiAnchor.RIGHT;
  @StorageProp('ngf_holding_awareness_side') private holdingSide: string = NGFHoldingAwarenessSide.UNKNOWN;
  @StorageProp('ngf_holding_awareness_available') private holdingAvailable: boolean = false;
  @StorageProp('ngf_holding_awareness_detect_gesture_granted') private detectGestureGranted: boolean = false;
  @StorageProp('ngf_holding_awareness_activity_motion_granted') private activityMotionGranted: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
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
    this.routeErrorVisible = false;
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

  build() {
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
          if (this.routeErrorVisible) {
            Text(this.routeErrorMessage)
              .width('100%')
              .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
              .lineHeight(18)
              .fontColor(SteamArkTheme.error(this.isDarkMode))
          }
          this.buildHoldingCard();
          if (!this.stateReady) {
            SteamArkStateUnavailableCard({
              isDarkMode: this.isDarkMode,
              useSysMat: this.useSysMat
            });
          } else {
            this.buildAccountCard();
            this.buildFarmingCard();
            this.buildSafetyCard();
            this.buildNetworkCard();
            this.buildActionsCard();
          }
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
    .backgroundColor(this.embedded
      ? $r('app.color.background_transparent') : SteamArkTheme.background(this.isDarkMode))
    .opacity(this.stateReady ? 1 : 0.88)
    .animation({ duration: SteamArkExperiencePolicy.CONTENT_REFRESH_DURATION, curve: Curve.EaseOut })
  }

  @Builder
  private buildAccountCard(): void {
    Column({ space: 10 }) {
      this.buildSectionTitle($r('sys.symbol.person_2'), $r('app.string.steam_settings_account_title'))
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
          .fontSize(19)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        Column({ space: 3 }) {
          Text(this.selectedAccountName.length > 0
            ? this.selectedAccountName
            : $r('app.string.steam_settings_account_empty'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.selectedAccountId.length > 0 ? this.selectedAccountId : $r('app.string.steam_settings_account_desc'))
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      this.buildInfoRow($r('app.string.steam_settings_account_state'), this.accountEnabled
        ? $r('app.string.steam_settings_on')
        : $r('app.string.steam_settings_off'))
      this.buildInfoRow($r('app.string.steam_settings_session_label'), this.sessionText())
      this.buildInfoRow($r('app.string.steam_settings_proxy_label'), this.proxyText())
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
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildHoldingCard(): void {
    Column({ space: 10 }) {
      this.buildSectionTitle($r('sys.symbol.person_2'), $r('app.string.steam_settings_holding_title'))
      Text($r('app.string.steam_settings_holding_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
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
      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(16)
            .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
          Text(this.holdingPermissionRequesting
            ? $r('app.string.steam_settings_holding_requesting')
            : $r('app.string.steam_settings_holding_request'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
        }
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .padding(0)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
      .enabled(!this.activityMotionGranted && !this.holdingPermissionRequesting)
      .id('steam-ark-settings-request-holding-permission')
      .onClick((): void => {
        void this.requestHoldingPermission();
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
  private buildFarmingCard(): void {
    Column({ space: 9 }) {
      this.buildSectionTitle($r('sys.symbol.play_round_triangle_fill'), $r('app.string.steam_settings_farming_title'))
      Text($r('app.string.steam_settings_farming_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      this.buildInfoRow($r('app.string.steam_settings_enabled_label'), this.farmingEnabled
        ? $r('app.string.steam_settings_on')
        : $r('app.string.steam_settings_off'))
      this.buildInfoRow($r('app.string.steam_settings_max_games_label'), this.maxGames.toString())
      this.buildInfoRow($r('app.string.steam_settings_drop_hours_label'), this.dropHours.toString())
      this.buildInfoRow($r('app.string.steam_settings_priority_label'), this.priorityCount.toString())
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
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildSafetyCard(): void {
    Column({ space: 9 }) {
      this.buildSectionTitle($r('sys.symbol.lock_shield'), $r('app.string.steam_settings_safety_title'))
      Text($r('app.string.steam_settings_safety_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      this.buildInfoRow($r('app.string.steam_settings_inventory_writes'), $r('app.string.steam_settings_disabled_by_default'))
      this.buildInfoRow($r('app.string.steam_settings_high_risk'), $r('app.string.steam_settings_disabled_by_default'))
      this.buildInfoRow($r('app.string.steam_settings_secure_storage'), this.hasCredentialMaterial
        ? $r('app.string.steam_settings_secure_only')
        : $r('app.string.steam_settings_account_empty'))
      this.buildInfoRow($r('app.string.steam_settings_biometric_status'), this.biometricStatus)
      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.lock_shield'))
            .fontSize(16)
            .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
          Text(this.biometricBusy
            ? $r('app.string.steam_settings_biometric_requesting')
            : $r('app.string.steam_settings_biometric_action'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
        }
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .padding(0)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
      .enabled(!this.biometricBusy)
      .id('steam-ark-settings-verify-biometric')
      .onClick((): void => {
        void this.verifyBiometricForSensitiveOperation();
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildActionsCard(): void {
    Column({ space: 9 }) {
      this.buildSectionTitle($r('sys.symbol.list_bullet'), $r('app.string.steam_settings_actions_title'))
      if (!this.embedded) {
        this.buildActionButton($r('sys.symbol.person_2'), $r('app.string.steam_settings_open_accounts'), SteamArkRouteName.ACCOUNTS, 'steam-ark-settings-open-accounts')
      }
      this.buildActionButton($r('sys.symbol.doc_text_magnifyingglass_fill'), $r('app.string.steam_settings_open_diagnostics'), SteamArkRouteName.DIAGNOSTICS, 'steam-ark-settings-open-diagnostics')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildNetworkCard(): void {
    Column({ space: 8 }) {
      this.buildSectionTitle($r('sys.symbol.wifi'), $r('app.string.steam_settings_network_title'))
      Text($r('app.string.steam_settings_network_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      SteamArkNetworkPage({
        embedded: true,
        contentTopInsetVp: 0
      })
        .width('100%')
        .height(720)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
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
  private buildActionButton(icon: Resource, title: ResourceStr, routeName: string, elementId: string): void {
    Button() {
      Row({ space: 8 }) {
        SymbolGlyph(icon)
          .fontSize(17)
          .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
        Text(title)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .padding(0)
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .id(elementId)
    .onClick((): void => {
      this.openSettingsRoute(routeName);
    })
  }

  private openSettingsRoute(routeName: string): void {
    SteamArkLog.info('SettingsPage', 'settings route requested; route=' + routeName +
      ', embedded=' + String(this.embedded));
    if (this.embedded) {
      const pushed: boolean = SteamArkNavigationBridge.pushHomeRoute(routeName);
      if (!pushed && this.isPageActive) {
        this.routeErrorVisible = true;
      }
      return;
    }
    this.pathStack.pushPathByName(routeName, null);
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    this.stateReady = snapshot.initialized;
    this.selectedAccountId = snapshot.selectedAccountId;
    const selected: SteamArkAccountSnapshot | null = steamArkStateService.getSelectedAccount();
    if (selected === null) {
      this.selectedAccountName = '';
      this.sessionState = SteamSessionState.DISCONNECTED;
      this.proxyKind = SteamProxyKind.SYSTEM;
      this.accountEnabled = false;
      this.farmingEnabled = false;
      this.maxGames = 0;
      this.dropHours = 0;
      this.priorityCount = 0;
      this.hasCredentialMaterial = false;
      return;
    }
    this.selectedAccountName = selected.profile.displayName.length > 0
      ? selected.profile.displayName
      : selected.profile.accountId;
    this.sessionState = selected.session.state;
    this.proxyKind = selected.profile.proxy.kind;
    this.accountEnabled = selected.profile.enabled;
    this.farmingEnabled = selected.config.enabled;
    this.maxGames = selected.config.maxGamesPlayedConcurrently;
    this.dropHours = selected.config.hoursUntilCardDrops;
    this.priorityCount = selected.config.priorityAppIds.length;
    this.hasCredentialMaterial = selected.hasCredentialMaterial;
    SteamArkLog.debug('SettingsPage', 'state applied; selectedAccount=' +
      SteamArkLog.accountId(this.selectedAccountId) + ', session=' + String(this.sessionState) +
      ', credentialMaterial=' + String(this.hasCredentialMaterial));
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
    if (!this.isPageActive || this.activityMotionGranted || this.holdingPermissionRequesting) {
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

  private async verifyBiometricForSensitiveOperation(): Promise<void> {
    if (!this.isPageActive || this.biometricBusy) {
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.biometricBusy = true;
    this.biometricStatus = $r('app.string.steam_settings_biometric_requesting');
    SteamArkLog.info('SettingsPage', 'biometric verification started');
    try {
      const title: string = resolveResourceString(
        this.getUIContext().getHostContext(),
        $r('app.string.steam_settings_biometric_prompt_title')
      );
      const result = await steamArkSensitiveActionGate.verify(
        SteamArkSensitiveAction.PRIVACY_VERIFICATION,
        title
      );
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      SteamArkLog.info('SettingsPage', 'biometric verification completed; outcome=' + String(result.outcome) +
        ', auditPersisted=' + String(result.auditPersisted));
      switch (result.outcome) {
        case SteamArkSensitiveActionOutcome.GRANTED:
          this.biometricStatus = $r('app.string.steam_settings_biometric_verified');
          break;
        case SteamArkSensitiveActionOutcome.PERMISSION_DENIED:
          this.biometricStatus = $r('app.string.steam_settings_biometric_not_granted');
          break;
        case SteamArkSensitiveActionOutcome.UNSUPPORTED:
          this.biometricStatus = $r('app.string.steam_settings_biometric_unsupported');
          break;
        case SteamArkSensitiveActionOutcome.BUSY:
          this.biometricStatus = $r('app.string.steam_settings_biometric_busy');
          break;
        case SteamArkSensitiveActionOutcome.AUTHENTICATION_FAILED:
        case SteamArkSensitiveActionOutcome.INVALID_REQUEST:
        case SteamArkSensitiveActionOutcome.ERROR:
        default:
          this.biometricStatus = $r('app.string.steam_settings_biometric_failed');
          break;
      }
    } catch (error) {
      if (this.isPageActive && this.lifecycleGeneration === lifecycleGeneration) {
        this.biometricStatus = $r('app.string.steam_settings_biometric_failed');
      }
      SteamArkLog.error('SettingsPage', 'biometric verification failed');
    } finally {
      if (this.isPageActive && this.lifecycleGeneration === lifecycleGeneration) {
        this.biometricBusy = false;
      }
    }
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

  private sessionText(): ResourceStr {
    switch (this.sessionState) {
      case SteamSessionState.CONNECTING:
        return $r('app.string.steam_accounts_session_connecting');
      case SteamSessionState.CONNECTED:
        return $r('app.string.steam_accounts_session_connected');
      case SteamSessionState.LOGGED_ON:
        return $r('app.string.steam_accounts_session_logged_on');
      case SteamSessionState.NEEDS_EMAIL_CODE:
        return $r('app.string.steam_accounts_session_email_code');
      case SteamSessionState.NEEDS_TWO_FACTOR:
        return $r('app.string.steam_accounts_session_two_factor');
      case SteamSessionState.NEEDS_QR_SCAN:
        return $r('app.string.steam_accounts_session_qr_scan');
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
