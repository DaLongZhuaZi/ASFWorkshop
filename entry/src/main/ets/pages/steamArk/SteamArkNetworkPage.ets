import { HdsNavDestination } from '@kit.UIDesignKit';
import {
  NGFControlStyleTokens,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  NGFProxyConfiguration,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import { SteamProxyKind, SteamProxySettings } from 'steam_core';
import {
  HarmonySteamNetworkProbe,
  HarmonySteamNetworkProbeOptions,
  SteamArkNetworkProbeError,
  SteamArkNetworkProbeSiteResult,
  SteamArkNetworkProbeResult,
  SteamArkNetworkProbeStatus
} from '../../steamAdapters';
import {
  SteamArkLog,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';

enum SteamArkProxyMode {
  SYSTEM,
  DIRECT,
  HTTP,
  SOCKS5
}

@Component
export struct SteamArkNetworkPage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private proxyMode: SteamArkProxyMode = SteamArkProxyMode.SYSTEM;
  @State private proxyHost: string = '';
  @State private proxyPort: string = '';
  @State private proxyUsername: string = '';
  @State private proxyPassword: string = '';
  @State private hasAccount: boolean = false;
  @State private stateReady: boolean = false;
  @State private isProxyPasswordLoading: boolean = false;
  @State private selectedAccountId: string = '';
  @State private isProbeRunning: boolean = false;
  @State private isProxySaveRunning: boolean = false;
  @State private hasProbeResult: boolean = false;
  @State private lastProbeHttpStatus: number = 0;
  @State private lastProbeHttpSucceeded: boolean = false;
  @State private lastProbeWssSucceeded: boolean = false;
  @State private lastProbeWssSupported: boolean = false;
  @State private lastProbeHttpError: SteamArkNetworkProbeError | null = null;
  @State private lastProbeWssError: SteamArkNetworkProbeError | null = null;
  @State private probeSites: Array<SteamArkNetworkProbeSiteResult> = [];
  @State private statusMessage: ResourceStr = $r('app.string.steam_network_status_idle');
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly scroller: Scroller = new Scroller();
  private proxyPasswordLoadVersion: number = 0;
  private networkProbeVersion: number = 0;
  private proxySaveVersion: number = 0;
  private pageGeneration: number = 0;
  private isPageActive: boolean = false;
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('NetworkPage', 'state snapshot received; accounts=' + snapshot.accounts.length.toString());
    this.applyStateSnapshot(snapshot);
  };

  aboutToAppear(): void {
    SteamArkLog.lifecycle('NetworkPage', 'aboutToAppear', 'embedded=' + String(this.embedded));
    this.pageGeneration += 1;
    const pageGeneration: number = this.pageGeneration;
    this.isPageActive = true;
    this.proxyPasswordLoadVersion += 1;
    this.networkProbeVersion += 1;
    this.proxySaveVersion += 1;
    this.isProbeRunning = false;
    this.isProxySaveRunning = false;
    this.isProxyPasswordLoading = false;
    if (this.embedded) {
      this.topInsetVp = this.contentTopInsetVp;
    } else {
      SteamArkPageWindowSupport.loadDynamicTopInset(
        this.getUIContext(),
        108,
        SteamArkTheme.CONTENT_TOP_INSET,
        (inset: number): void => {
          if (this.isCurrentPageGeneration(pageGeneration)) {
            this.topInsetVp = inset;
          }
        }
      );
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.NETWORK);
    }
    steamArkStateService.subscribe('SteamArkNetworkPage', this.stateListener);
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    void this.initializeStateService();
    SteamArkLog.info('NetworkPage', 'state subscription registered');
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle('NetworkPage', 'aboutToDisappear', 'embedded=' + String(this.embedded));
    this.isPageActive = false;
    this.pageGeneration += 1;
    this.proxyPasswordLoadVersion += 1;
    this.networkProbeVersion += 1;
    this.proxySaveVersion += 1;
    this.isProbeRunning = false;
    this.isProxySaveRunning = false;
    this.isProxyPasswordLoading = false;
    this.proxyPassword = '';
    steamArkStateService.unsubscribe('SteamArkNetworkPage');
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
        $r('app.string.steam_network_title'),
        $r('app.string.steam_network_subtitle'),
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
      SteamArkProfileBackground()
      if (!this.embedded) {
      }

      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (!this.stateReady) {
            SteamArkStateUnavailableCard({
              isDarkMode: this.isDarkMode,
              useSysMat: this.useSysMat
            });
          }
          this.buildProxyCard();
          this.buildWssCard();
          this.buildStatusMessage();
          if (this.hasProbeResult) {
            this.buildProbeDetailsCard();
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
    .backgroundColor(SteamArkTheme.background(this.isDarkMode))
  }

  @Builder
  private buildProxyCard(): void {
    Column({ space: 12 }) {
      Text($r('app.string.steam_network_mode_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))

      Row({ space: 8 }) {
        this.buildModeButton(SteamArkProxyMode.SYSTEM, $r('app.string.steam_settings_proxy_system'))
        this.buildModeButton(SteamArkProxyMode.DIRECT, $r('app.string.steam_network_mode_direct'))
        this.buildModeButton(SteamArkProxyMode.HTTP, $r('app.string.steam_network_mode_http'))
        this.buildModeButton(SteamArkProxyMode.SOCKS5, $r('app.string.steam_network_mode_socks5'))
      }
      .width('100%')

      Row({ space: 10 }) {
        TextInput({
          placeholder: $r('app.string.steam_network_host_placeholder'),
          text: this.proxyHost
        })
          .id('steam-ark-network-proxy-host')
          .layoutWeight(1)
          .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
          .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
          .padding({ left: 12, right: 12 })
          .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
          .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
          .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
        .enabled(this.isProxyEndpointMode() && !this.isProbeRunning && !this.isProxySaveRunning)
        .onChange((value: string): void => {
          this.proxyHost = value;
          this.resetProbeForInput();
        })
        TextInput({
          placeholder: $r('app.string.steam_network_port_placeholder'),
          text: this.proxyPort
        })
          .id('steam-ark-network-proxy-port')
          .width(92)
          .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
          .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
          .padding({ left: 12, right: 12 })
          .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
          .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
          .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
        .enabled(this.isProxyEndpointMode() && !this.isProbeRunning && !this.isProxySaveRunning)
        .onChange((value: string): void => {
          this.proxyPort = value;
          this.resetProbeForInput();
        })
      }
      .width('100%')

      TextInput({
        placeholder: $r('app.string.steam_network_proxy_username_placeholder'),
        text: this.proxyUsername
      })
        .id('steam-ark-network-proxy-username')
        .width('100%')
        .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
        .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
        .padding({ left: 12, right: 12 })
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
        .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
        .enabled(this.isProxyEndpointMode() && !this.isProbeRunning && !this.isProxySaveRunning)
        .onChange((value: string): void => {
          this.proxyUsername = value;
          this.resetProbeForInput();
        })

      TextInput({
        placeholder: $r('app.string.steam_network_proxy_password_placeholder'),
        text: this.proxyPassword
      })
        .id('steam-ark-network-proxy-password')
        .width('100%')
        .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
        .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
        .padding({ left: 12, right: 12 })
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
        .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
        .type(InputType.Password)
        .enabled(this.isProxyEndpointMode() && !this.isProxyPasswordLoading &&
          !this.isProbeRunning && !this.isProxySaveRunning)
        .onChange((value: string): void => {
          this.proxyPassword = value;
          this.resetProbeForInput();
        })

      Text($r('app.string.steam_network_proxy_password_secure_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))

      Row({ space: 10 }) {
        this.buildNetworkActionButton(
          $r('sys.symbol.wifi'),
          $r('app.string.steam_network_test'),
          1
        )
        this.buildNetworkActionButton(
          $r('sys.symbol.save'),
          $r('app.string.steam_network_save'),
          2
        )
      }
      .width('100%')
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
  private buildModeButton(mode: SteamArkProxyMode, title: ResourceStr): void {
    Button() {
      Text(title)
        .fontSize(NGFControlStyleTokens.SEGMENT_BUTTON_FONT_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.proxyMode === mode
          ? SteamArkTheme.onAccent(this.isDarkMode)
          : SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .layoutWeight(1)
    .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
    .padding(0)
    .borderRadius(NGFControlStyleTokens.DENSE_BUTTON_RADIUS)
    .id(this.proxyModeId(mode))
    .backgroundColor(this.proxyMode === mode
      ? SteamArkTheme.accent(this.isDarkMode)
      : NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .fontColor(this.proxyMode === mode
      ? SteamArkTheme.onAccent(this.isDarkMode)
      : SteamArkTheme.buttonForeground(this.isDarkMode))
    .onClick((): void => {
      if (!this.isProbeRunning && !this.isProxySaveRunning) {
        this.selectProxyMode(mode);
      }
    })
    .enabled(!this.isProbeRunning && !this.isProxySaveRunning)
  }

  private selectProxyMode(mode: SteamArkProxyMode): void {
    if (this.isProbeRunning || this.isProxySaveRunning) {
      return;
    }
    this.proxyMode = mode;
    if (mode === SteamArkProxyMode.SYSTEM || mode === SteamArkProxyMode.DIRECT) {
      this.proxyHost = '';
      this.proxyPort = '';
      this.proxyUsername = '';
      this.proxyPassword = '';
    }
    this.resetProbeForInput();
    SteamArkLog.info('NetworkPage', 'proxy mode selected; mode=' + String(mode));
  }

  @Builder
  private buildNetworkActionButton(icon: Resource, title: ResourceStr, actionKey: number): void {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph(icon)
          .fontSize(15)
          .fontColor([this.isNetworkActionEnabled(actionKey)
            ? SteamArkTheme.onAccent(this.isDarkMode)
            : SteamArkTheme.buttonDisabledText(this.isDarkMode)])
        Text(title)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isNetworkActionEnabled(actionKey)
            ? SteamArkTheme.onAccent(this.isDarkMode)
            : SteamArkTheme.buttonDisabledText(this.isDarkMode))
      }
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .padding(0)
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .id(this.networkActionId(actionKey))
    .backgroundColor(this.isNetworkActionEnabled(actionKey)
      ? SteamArkTheme.accent(this.isDarkMode)
      : SteamArkTheme.buttonDisabled(this.isDarkMode))
    .fontColor(this.isNetworkActionEnabled(actionKey)
      ? SteamArkTheme.onAccent(this.isDarkMode)
      : SteamArkTheme.buttonDisabledText(this.isDarkMode))
    .enabled(this.isNetworkActionEnabled(actionKey))
    .onClick((): void => {
      this.handleNetworkAction(actionKey);
    })
  }

  private proxyModeId(mode: SteamArkProxyMode): string {
    switch (mode) {
      case SteamArkProxyMode.SYSTEM:
        return 'steam-ark-network-proxy-system';
      case SteamArkProxyMode.DIRECT:
        return 'steam-ark-network-proxy-direct';
      case SteamArkProxyMode.HTTP:
        return 'steam-ark-network-proxy-http';
      case SteamArkProxyMode.SOCKS5:
        return 'steam-ark-network-proxy-socks5';
      default:
        return 'steam-ark-network-proxy-mode';
    }
  }

  private networkActionId(actionKey: number): string {
    if (actionKey === 1) {
      return 'steam-ark-network-test';
    }
    return 'steam-ark-network-save';
  }

  private isNetworkActionEnabled(actionKey: number): boolean {
    if (this.isProxyPasswordLoading || this.isProbeRunning || this.isProxySaveRunning) {
      return false;
    }
    if (actionKey === 1) {
      return true;
    }
    return this.stateReady && this.hasAccount;
  }

  @Builder
  private buildWssCard(): void {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(23)
        .fontColor([SteamArkTheme.warning(this.isDarkMode)])
      Column({ space: 5 }) {
        Text($r('app.string.steam_network_wss_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_network_wss_desc'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
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

  @Builder
  private buildProbeDetailsCard(): void {
    Column({ space: 8 }) {
      Text($r('app.string.steam_network_probe_details_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      ForEach(this.probeSites, (site: SteamArkNetworkProbeSiteResult) => {
        this.buildProbeSite(site);
      }, (site: SteamArkNetworkProbeSiteResult) => site.targetId)
      Text($r('app.string.steam_network_probe_security_summary'))
        .width('100%')
        .fontSize(11)
        .lineHeight(16)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(14)
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
  private buildProbeSite(site: SteamArkNetworkProbeSiteResult): void {
    Column({ space: 4 }) {
      this.buildProbeDetailRow(this.probeSiteName(site.targetId), this.probeResultText(site.succeeded, site.supported))
      this.buildProbeDetailRow($r('app.string.steam_network_probe_site_url'), site.url)
      this.buildProbeDetailRow($r('app.string.steam_network_probe_site_status'),
        site.statusCode > 0 ? site.statusCode.toString() : $r('app.string.steam_network_probe_unavailable'))
      this.buildProbeDetailRow($r('app.string.steam_network_probe_site_latency'), site.durationMs.toString() + ' ms')
      if (site.error !== null) {
        this.buildProbeErrorRows($r('app.string.steam_network_probe_site_error'), site.error)
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .border({ width: { bottom: 1 }, color: SteamArkTheme.divider(this.isDarkMode) })
  }

  @Builder
  private buildProbeDetailRow(label: ResourceStr, value: ResourceStr): void {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(11)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Text(value)
        .layoutWeight(1)
        .fontSize(11)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  private handleNetworkAction(_actionKey: number): void {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.info('NetworkPage', 'network action requested; action=' + _actionKey.toString());
    if (this.isProbeRunning || this.isProxySaveRunning) {
      SteamArkLog.debug('NetworkPage', 'network action skipped; another operation is running');
      return;
    }
    if (_actionKey === 2 && !this.stateReady) {
      this.statusMessage = $r('app.string.steam_state_unavailable_status');
      SteamArkLog.warn('NetworkPage', 'network action blocked; state service unavailable');
      return;
    }
    if (_actionKey === 2 && !this.hasAccount) {
      this.statusMessage = $r('app.string.steam_network_status_no_account');
      SteamArkLog.warn('NetworkPage', 'network action blocked; no selected account');
      return;
    }
    const proxy = this.buildProxySettings();
    if (proxy === null) {
      this.statusMessage = $r('app.string.steam_network_status_validation_failed');
      SteamArkLog.warn('NetworkPage', 'network action blocked; proxy validation failed');
      return;
    }
    if (_actionKey === 1) {
      void this.testConnection(proxy);
      return;
    }
    void this.saveProxy(proxy);
  }

  private async testConnection(proxy: SteamProxySettings): Promise<void> {
    if (!this.isPageActive || this.isProbeRunning) {
      return;
    }
    this.isProbeRunning = true;
    const probeVersion = this.networkProbeVersion;
    const startedAt: number = Date.now();
    SteamArkLog.info('NetworkPage', 'network probe started; proxyMode=' + String(proxy.kind));
    this.statusMessage = $r('app.string.steam_network_status_probe_testing');
    try {
      const networkProxy = this.toNetworkProxy(proxy);
      const probe = new HarmonySteamNetworkProbe(
        new HarmonySteamNetworkProbeOptions(networkProxy)
      );
      const result = await probe.probe();
      if (this.isCurrentProbeOperation(probeVersion)) {
        this.hasProbeResult = true;
        this.lastProbeHttpStatus = result.httpStatusCode;
        this.lastProbeHttpSucceeded = result.httpSucceeded;
        this.lastProbeWssSucceeded = result.wssSucceeded;
        this.lastProbeWssSupported = result.wssSupported;
        this.lastProbeHttpError = result.httpError;
        this.lastProbeWssError = result.wssError;
        this.probeSites = result.sites.slice();
        this.statusMessage = this.probeStatusResource(result);
      }
      SteamArkLog.info('NetworkPage', 'network probe completed; status=' + String(result.status) +
        ', http=' + String(result.httpSucceeded) + ', wss=' + String(result.wssSucceeded) +
        ', wssSupported=' + String(result.wssSupported));
      SteamArkLog.performance('NetworkPage', 'network probe', startedAt);
    } catch (error) {
      if (this.isCurrentProbeOperation(probeVersion)) {
        this.clearProbeResult();
        const detail = this.safeDisplayError(error);
        this.statusMessage = detail.length > 0
          ? detail
          : $r('app.string.steam_network_status_probe_failed');
      }
      SteamArkLog.error('NetworkPage', 'network probe failed; errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentProbeOperation(probeVersion)) {
        this.isProbeRunning = false;
      }
    }
  }

  private async saveProxy(proxy: SteamProxySettings): Promise<void> {
    if (!this.isPageActive || !this.stateReady || this.isProxySaveRunning || this.isProbeRunning) {
      return;
    }
    const accountId = this.selectedAccountId;
    const saveVersion = this.proxySaveVersion;
    const proxyPassword = this.proxyPassword;
    this.isProxySaveRunning = true;
    SteamArkLog.info('NetworkPage', 'proxy settings save started; account=' +
      SteamArkLog.accountId(accountId) + ', mode=' + String(proxy.kind));
    try {
      const saved = await steamArkStateService.saveProxy(
        accountId,
        proxy,
        proxyPassword
      );
      if (this.isCurrentSaveOperation(saveVersion, accountId)) {
        this.statusMessage = saved
          ? $r('app.string.steam_network_status_saved')
          : $r('app.string.steam_network_status_no_account');
      }
      SteamArkLog.info('NetworkPage', 'proxy settings save completed; saved=' + String(saved));
    } catch (_error) {
      if (this.isCurrentSaveOperation(saveVersion, accountId)) {
        const detail = this.safeDisplayError(_error);
        this.statusMessage = detail.length > 0
          ? detail
          : $r('app.string.steam_network_status_save_failed');
      }
      SteamArkLog.error('NetworkPage', 'proxy settings save failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(_error));
    } finally {
      if (this.isCurrentSaveOperation(saveVersion, accountId)) {
        this.isProxySaveRunning = false;
        // Apply the committed snapshot after the save lock is released. State
        // notifications emitted inside saveProxy must not reload the password
        // while the write is still resolving.
        this.applyStateSnapshot(steamArkStateService.getSnapshot(), true);
      }
    }
  }

  private buildProxySettings(): SteamProxySettings | null {
    if (this.proxyMode === SteamArkProxyMode.SYSTEM) {
      return new SteamProxySettings(SteamProxyKind.SYSTEM);
    }
    if (this.proxyMode === SteamArkProxyMode.DIRECT) {
      return new SteamProxySettings(SteamProxyKind.DIRECT);
    }
    const host = this.proxyHost.trim();
    const port = Number(this.proxyPort.trim());
    const username = this.proxyUsername.trim();
    if (host.length <= 0 || !Number.isSafeInteger(port) || port < 1 || port > 65535) {
      SteamArkLog.warn('NetworkPage', 'proxy validation rejected host or port');
      return null;
    }
    if (this.proxyMode === SteamArkProxyMode.HTTP) {
      return new SteamProxySettings(SteamProxyKind.HTTP, host, port, username);
    }
    return new SteamProxySettings(SteamProxyKind.SOCKS5, host, port, username);
  }

  private toNetworkProxy(settings: SteamProxySettings): NGFProxyConfiguration {
    if (settings.kind === SteamProxyKind.DIRECT) {
      return NGFProxyConfiguration.direct();
    }
    if (settings.kind === SteamProxyKind.HTTP) {
      return NGFProxyConfiguration.http(
        settings.host,
        settings.port,
        settings.username,
        this.proxyPassword
      );
    }
    if (settings.kind === SteamProxyKind.SOCKS5) {
      return NGFProxyConfiguration.socks5(
        settings.host,
        settings.port,
        settings.username,
        this.proxyPassword
      );
    }
    return NGFProxyConfiguration.system();
  }

  private probeStatusResource(result: SteamArkNetworkProbeResult): ResourceStr {
    switch (result.status) {
      case SteamArkNetworkProbeStatus.SUCCESS:
        return $r('app.string.steam_network_status_probe_success');
      case SteamArkNetworkProbeStatus.PARTIAL:
        return $r('app.string.steam_network_status_probe_partial');
      case SteamArkNetworkProbeStatus.UNSUPPORTED:
        return $r('app.string.steam_network_status_probe_unsupported');
      case SteamArkNetworkProbeStatus.FAILED:
      default:
        return $r('app.string.steam_network_status_probe_failed');
    }
  }

  private applyStateSnapshot(
    snapshot: SteamArkStateSnapshot,
    reloadSelectedProxy: boolean = false
  ): void {
    if (!this.isPageActive) {
      return;
    }
    this.stateReady = snapshot.initialized;
    if (!this.stateReady) {
      this.statusMessage = $r('app.string.steam_state_unavailable_status');
    }
    const accountChanged = this.selectedAccountId !== snapshot.selectedAccountId;
    if (accountChanged) {
      this.networkProbeVersion += 1;
      this.proxySaveVersion += 1;
      this.isProbeRunning = false;
      this.isProxySaveRunning = false;
      this.clearProbeResult();
      this.statusMessage = $r('app.string.steam_network_status_idle');
      this.proxyPassword = '';
    }
    const shouldReloadProxyPassword = accountChanged || reloadSelectedProxy;
    if (shouldReloadProxyPassword) {
      this.proxyPasswordLoadVersion += 1;
    }
    const loadVersion = this.proxyPasswordLoadVersion;
    this.selectedAccountId = snapshot.selectedAccountId;
    this.hasAccount = snapshot.selectedAccountId.length > 0;
    const selected = steamArkStateService.getSelectedAccount();
    if (selected === null) {
      this.isProxyPasswordLoading = false;
      this.proxyMode = SteamArkProxyMode.SYSTEM;
      this.proxyHost = '';
      this.proxyPort = '';
      this.proxyUsername = '';
      this.proxyPassword = '';
      return;
    }
    if (accountChanged || reloadSelectedProxy) {
      this.isProxyPasswordLoading = true;
      this.proxyHost = selected.profile.proxy.host;
      this.proxyPort = selected.profile.proxy.port > 0 ? String(selected.profile.proxy.port) : '';
      this.proxyUsername = selected.profile.proxy.username;
      void this.loadProxyPassword(selected.profile.accountId, loadVersion);
      switch (selected.profile.proxy.kind) {
        case SteamProxyKind.SYSTEM:
          this.proxyMode = SteamArkProxyMode.SYSTEM;
          break;
        case SteamProxyKind.HTTP:
          this.proxyMode = SteamArkProxyMode.HTTP;
          break;
        case SteamProxyKind.SOCKS5:
          this.proxyMode = SteamArkProxyMode.SOCKS5;
          break;
        case SteamProxyKind.DIRECT:
        default:
          this.proxyMode = SteamArkProxyMode.DIRECT;
          break;
      }
    }
    SteamArkLog.debug('NetworkPage', 'state applied; selectedAccount=' +
      SteamArkLog.accountId(this.selectedAccountId) + ', proxyMode=' + String(this.proxyMode) +
      ', hasAccount=' + String(this.hasAccount));
  }

  private async loadProxyPassword(accountId: string, loadVersion: number): Promise<void> {
    try {
      const password = await steamArkStateService.getProxyPassword(accountId);
      if (this.isCurrentPasswordLoad(loadVersion, accountId)) {
        this.proxyPassword = password;
      }
      SteamArkLog.debug('NetworkPage', 'proxy password state loaded; account=' + SteamArkLog.accountId(accountId) +
        ', present=' + String(password.length > 0));
    } catch (_error) {
      if (this.isCurrentPasswordLoad(loadVersion, accountId)) {
        this.proxyPassword = '';
      }
      SteamArkLog.warn('NetworkPage', 'proxy password state load failed; account=' + SteamArkLog.accountId(accountId));
    } finally {
      if (this.isCurrentPasswordLoad(loadVersion, accountId)) {
        this.isProxyPasswordLoading = false;
      }
    }
  }

  private async initializeStateService(): Promise<void> {
    const startedAt: number = Date.now();
    const pageGeneration: number = this.pageGeneration;
    try {
      const initialized: boolean = await steamArkStateService.initialize();
      if (!this.isCurrentPageGeneration(pageGeneration)) {
        return;
      }
      this.applyStateSnapshot(steamArkStateService.getSnapshot());
      SteamArkLog.info('NetworkPage', 'state service ready; initialized=' + String(initialized));
      SteamArkLog.performance('NetworkPage', 'state initialization', startedAt);
    } catch (_error) {
      SteamArkLog.error('NetworkPage', 'state service initialization failed');
    }
  }

  private isProxyEndpointMode(): boolean {
    return this.proxyMode === SteamArkProxyMode.HTTP || this.proxyMode === SteamArkProxyMode.SOCKS5;
  }

  private resetProbeForInput(): void {
    if (this.isProbeRunning || this.isProxySaveRunning) {
      return;
    }
    this.clearProbeResult();
    this.statusMessage = $r('app.string.steam_network_status_idle');
  }

  private clearProbeResult(): void {
    this.hasProbeResult = false;
    this.lastProbeHttpStatus = 0;
    this.lastProbeHttpSucceeded = false;
    this.lastProbeWssSucceeded = false;
    this.lastProbeWssSupported = false;
    this.lastProbeHttpError = null;
    this.lastProbeWssError = null;
    this.probeSites = [];
  }

  @Builder
  private buildProbeErrorRows(prefix: ResourceStr, error: SteamArkNetworkProbeError): void {
    this.buildProbeDetailRow(
      prefix,
      error.stage + ' / ' + error.errorType
    )
    this.buildProbeDetailRow(
      $r('app.string.steam_network_probe_error_code'),
      error.code !== 0 ? error.code.toString() : $r('app.string.steam_network_probe_unavailable')
    )
    this.buildProbeDetailRow(
      $r('app.string.steam_network_probe_error_message'),
      error.message
    )
  }

  private isCurrentProbeOperation(version: number): boolean {
    return this.isPageActive && version === this.networkProbeVersion;
  }

  private isCurrentSaveOperation(version: number, accountId: string): boolean {
    return this.isPageActive && version === this.proxySaveVersion && this.selectedAccountId === accountId;
  }

  private isCurrentPasswordLoad(version: number, accountId: string): boolean {
    return this.isPageActive && version === this.proxyPasswordLoadVersion && this.selectedAccountId === accountId;
  }

  private isCurrentPageGeneration(generation: number): boolean {
    return this.isPageActive && generation === this.pageGeneration;
  }

  private safeDisplayError(error: Error | Object): string {
    if (!(error instanceof Error)) {
      return '';
    }
    let normalized = error.message.replace(/\r/g, ' ').replace(/\n/g, ' ').trim();
    if (this.proxyPassword.length > 0) {
      normalized = normalized.split(this.proxyPassword).join('[redacted]');
    }
    normalized = normalized.replace(/(https?:\/\/[^\s/:]+:)[^@\s]+@/gi, '$1[redacted]@');
    normalized = normalized.replace(/(password\s*[=:])[^\s,;]+/gi, '$1[redacted]');
    return normalized.length > 512 ? normalized.substring(0, 512) : normalized;
  }

  private probeResultText(succeeded: boolean, supported: boolean): ResourceStr {
    if (!supported) {
      return $r('app.string.steam_network_probe_unsupported');
    }
    return succeeded
      ? $r('app.string.steam_network_probe_passed')
      : $r('app.string.steam_network_probe_failed');
  }

  private probeSiteName(targetId: string): ResourceStr {
    switch (targetId) {
      case 'store':
        return $r('app.string.steam_network_site_store');
      case 'community':
        return $r('app.string.steam_network_site_community');
      case 'api':
        return $r('app.string.steam_network_site_api');
      case 'help':
        return $r('app.string.steam_network_site_help');
      case 'checkout':
        return $r('app.string.steam_network_site_checkout');
      case 'cm':
        return $r('app.string.steam_network_site_cm');
      default:
        return $r('app.string.steam_network_site_custom');
    }
  }
}
