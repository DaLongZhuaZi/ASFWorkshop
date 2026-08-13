import { HdsNavDestination } from '@kit.UIDesignKit';
import { webview } from '@kit.ArkWeb';
import {
  NGFHoldingAwarenessListener,
  NGFHoldingAwarenessSnapshot,
  NGFHoldingUiAnchor,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  ngfHoldingAwarenessFacade,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import { SteamCredentialSet } from 'steam_core';
import { ASFWorkshopProductIdentity, SteamArkLog, steamArkStateService } from '../../steamServices';
import { SteamArkBrowserRequest } from './SteamArkRoutes';
import { SteamArkTheme } from './SteamArkTheme';
import { SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';

@Component
export struct SteamArkBrowserPage {
  @Prop request: SteamArkBrowserRequest = new SteamArkBrowserRequest();
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private loading: boolean = true;
  @State private failed: boolean = false;
  @State private mainFrameLoaded: boolean = false;
  @State private pageUrl: string = '';
  @State private toolbarAnchor: string = NGFHoldingUiAnchor.RIGHT;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_holding_awareness_preferred_anchor') private preferredAnchor: string =
    NGFHoldingUiAnchor.RIGHT;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly controller: webview.WebviewController = new webview.WebviewController();
  private readonly holdingListener: NGFHoldingAwarenessListener =
    (snapshot: NGFHoldingAwarenessSnapshot): void => {
      this.getUIContext().animateTo({
        duration: 320,
        curve: Curve.EaseInOut
      }, (): void => {
        this.toolbarAnchor = snapshot.preferredAnchor;
      });
    };

  aboutToAppear(): void {
    SteamArkLog.lifecycle('BrowserPage', 'aboutToAppear', 'host=' + this.hostLabel());
    this.toolbarAnchor = this.preferredAnchor;
    ngfHoldingAwarenessFacade.addListener(this.holdingListener);
    void this.prepareAccountSession();
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle('BrowserPage', 'aboutToDisappear');
    ngfHoldingAwarenessFacade.removeListener(this.holdingListener);
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        SteamArkProfileBackground()
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            Stack({ alignContent: Alignment.Center }) {
            if (this.pageUrl.length > 0) {
              Web({ src: this.pageUrl, controller: this.controller })
                .width('100%')
                .height('100%')
                .backgroundColor(SteamArkTheme.background(this.isDarkMode))
                .javaScriptAccess(true)
                .domStorageAccess(true)
                .onControllerAttached((): void => {
                  this.controller.setCustomUserAgent(ASFWorkshopProductIdentity.userAgent('InAppBrowser'));
                })
                .onPageBegin((): void => {
                  this.loading = true;
                  this.failed = false;
                  this.mainFrameLoaded = false;
                })
                .onPageEnd((): void => {
                  this.loading = false;
                  this.failed = false;
                  this.mainFrameLoaded = true;
                  const loadedUrl: string = this.controller.getUrl();
                  if (loadedUrl.length > 0) {
                    this.pageUrl = loadedUrl;
                  }
                })
                .onErrorReceive((event: OnErrorReceiveEvent): void => {
                  if (!event.request.isMainFrame) {
                    SteamArkLog.debug('BrowserPage', 'Steam subresource load error ignored; host=' + this.hostLabel());
                    return;
                  }
                  if (this.mainFrameLoaded) {
                    SteamArkLog.debug('BrowserPage', 'late main-frame error ignored after page load; host=' + this.hostLabel());
                    return;
                  }
                  this.loading = false;
                  this.failed = true;
                  SteamArkLog.warn('BrowserPage', 'Steam page load failed; host=' + this.hostLabel());
                })
            }
            if (this.loading) {
              Column() {
                LoadingProgress()
                  .width(36)
                  .height(36)
                  .color(SteamArkTheme.accent(this.isDarkMode))
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor(SteamArkTheme.background(this.isDarkMode))
            }
            if (this.failed) {
              Column({ space: 10 }) {
                SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
                  .fontSize(28)
                  .fontColor([SteamArkTheme.warning(this.isDarkMode)])
                Text($r('app.string.steam_browser_load_failed'))
                  .fontSize(13)
                  .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
                Button($r('app.string.steam_browser_retry'))
                  .buttonStyle(ButtonStyleMode.TEXTUAL)
                  .onClick((): void => {
                    this.failed = false;
                    this.loading = true;
                    this.controller.refresh(true);
                  })
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor(SteamArkTheme.background(this.isDarkMode))
            }
          }
          .layoutWeight(1)
          .width('100%')
          this.buildAddressBar()
        }
        .width('100%')
        .height('100%')
        .padding({ top: SteamArkTheme.CONTENT_TOP_INSET, bottom: 12 })

          Stack({ alignContent: this.toolbarAnchor === NGFHoldingUiAnchor.LEFT
            ? Alignment.BottomStart : Alignment.BottomEnd }) {
            this.buildFloatingToolbar()
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)
          .animation({ duration: 320, curve: Curve.EaseInOut })
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(SteamArkTheme.background(this.isDarkMode))
    }
    .titleBar(NGFHdsTitleBarOptionsFactory.buildOverContentWithTitleColors(
      this.request.title.length > 0 ? this.request.title : $r('app.string.steam_browser_title'),
      this.request.subtitle.length > 0 ? this.request.subtitle : this.hostLabel(),
      $r('app.color.background_transparent'),
      SteamArkTheme.textPrimary(this.isDarkMode),
      SteamArkTheme.textSecondary(this.isDarkMode),
      true,
      false
    ))
    .backgroundImage(this.profileBackgroundUrl)
    .backgroundImageSize(ImageSize.Cover)
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

  @Builder
  private buildFloatingToolbar(): void {
    Column({ space: 6 }) {
      this.buildToolButton($r('sys.symbol.chevron_left'), $r('app.string.steam_browser_back'), (): void => {
        this.controller.backward();
      });
      this.buildToolButton($r('sys.symbol.chevron_right'), $r('app.string.steam_browser_forward'), (): void => {
        this.controller.forward();
      });
      this.buildToolButton($r('sys.symbol.arrow_clockwise'), $r('app.string.steam_browser_refresh'), (): void => {
        this.loading = true;
        this.failed = false;
        this.controller.refresh();
      });
    }
    .padding(6)
    .margin({
      left: 12,
      right: 12,
      bottom: 70
    })
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwareProminentShadow(this.useSysMat))
  }

  @Builder
  private buildAddressBar(): void {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.lock'))
        .fontSize(15)
        .fontColor([SteamArkTheme.success(this.isDarkMode)])
      Text(this.pageUrl.length > 0 ? this.pageUrl : this.hostLabel())
        .layoutWeight(1)
        .fontSize(13)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.loading) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(SteamArkTheme.accent(this.isDarkMode))
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 14, right: 14 })
    .margin({ left: 12, right: 12 })
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildToolButton(symbol: Resource, label: Resource, action: () => void): void {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(symbol)
        .fontSize(18)
        .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
    }
    .width(40)
    .height(40)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .accessibilityText(label)
    .onClick(action)
  }

  private safeUrl(): string {
    const normalized: string = this.request.url.trim();
    const separatorIndex: number = normalized.indexOf('://');
    if (separatorIndex <= 0) {
      return 'https://steamcommunity.com/';
    }
    const scheme: string = normalized.substring(0, separatorIndex).toLowerCase();
    if (scheme !== 'https') {
      return 'https://steamcommunity.com/';
    }
    const authorityAndPath: string = normalized.substring(separatorIndex + 3);
    const pathStart: number = this.firstPathSeparator(authorityAndPath);
    const authority: string = pathStart >= 0 ? authorityAndPath.substring(0, pathStart) : authorityAndPath;
    const host: string = this.hostWithoutPort(authority).toLowerCase();
    return this.isTrustedSteamHost(host) ? normalized : 'https://steamcommunity.com/';
  }

  private firstPathSeparator(value: string): number {
    const slashIndex: number = value.indexOf('/');
    const queryIndex: number = value.indexOf('?');
    const fragmentIndex: number = value.indexOf('#');
    let index: number = slashIndex;
    if (index < 0 || (queryIndex >= 0 && queryIndex < index)) {
      index = queryIndex;
    }
    if (index < 0 || (fragmentIndex >= 0 && fragmentIndex < index)) {
      index = fragmentIndex;
    }
    return index;
  }

  private hostWithoutPort(authority: string): string {
    const atIndex: number = authority.lastIndexOf('@');
    const hostPort: string = atIndex >= 0 ? authority.substring(atIndex + 1) : authority;
    const portIndex: number = hostPort.indexOf(':');
    return portIndex >= 0 ? hostPort.substring(0, portIndex) : hostPort;
  }

  private isTrustedSteamHost(host: string): boolean {
    return host === 'steamcommunity.com' || host === 'store.steampowered.com' ||
      host === 'help.steampowered.com' || host === 'checkout.steampowered.com';
  }

  private async prepareAccountSession(): Promise<void> {
    const selected = steamArkStateService.getSelectedAccount();
    if (selected !== null && selected.profile.steamId64.length > 0) {
      try {
        const credentials: SteamCredentialSet = await steamArkStateService.getCredentials(
          selected.profile.accountId
        );
        if (credentials.accessToken.length > 0) {
          const cookieValue: string = selected.profile.steamId64 + '%7C%7C' + credentials.accessToken;
          const cookie: string = 'steamLoginSecure=' + cookieValue +
            '; Path=/; Secure; HttpOnly; SameSite=None';
          const cookieUrls: Array<string> = [
            'https://steamcommunity.com/',
            'https://store.steampowered.com/',
            'https://help.steampowered.com/',
            'https://checkout.steampowered.com/'
          ];
          for (let index: number = 0; index < cookieUrls.length; index++) {
            webview.WebCookieManager.configCookieSync(cookieUrls[index], cookie, false, true);
          }
          SteamArkLog.info('BrowserPage', 'Steam account Web cookie configured; host=' + this.hostLabel());
        }
      } catch (error) {
        SteamArkLog.warn('BrowserPage', 'Steam account Web cookie setup failed; errorType=' +
          SteamArkLog.errorKind(error));
      }
    }
    this.pageUrl = this.safeUrl();
  }

  private hostLabel(): string {
    const url: string = this.safeUrl();
    const separatorIndex: number = url.indexOf('://');
    const authorityAndPath: string = separatorIndex >= 0 ? url.substring(separatorIndex + 3) : url;
    const pathStart: number = this.firstPathSeparator(authorityAndPath);
    const authority: string = pathStart >= 0 ? authorityAndPath.substring(0, pathStart) : authorityAndPath;
    return this.hostWithoutPort(authority);
  }
}
