import window from '@ohos.window';
import {
  NGFDisplayMode,
  NGFPageWindowProfile,
  NGFWindowOrientationPreference,
  NGFWindowSystemBarPolicy,
  NGFWindowSystemBarStyle,
  NGFColorToken,
  ngfPagePolicyHostFacade,
  ngfPlatformWindowManagerFacade,
  ngfThemeManagerFacade,
  ngfColorTokenProviderFacade
} from 'ngf_framework';
import { SteamArkLog } from '../../steamServices/SteamArkLogger';
import { SteamArkRouteName } from './SteamArkRoutes';

export class SteamArkPageWindowName {
  static readonly HOME: string = SteamArkRouteName.HOME;
  static readonly WORKSPACE: string = SteamArkRouteName.WORKSPACE;
  static readonly ACCOUNTS: string = SteamArkRouteName.ACCOUNTS;
  static readonly INVENTORY: string = SteamArkRouteName.INVENTORY;
  static readonly NETWORK: string = SteamArkRouteName.NETWORK;
  static readonly TOKENS: string = SteamArkRouteName.TOKENS;
  static readonly SETTINGS: string = SteamArkRouteName.SETTINGS;
  static readonly DIAGNOSTICS: string = SteamArkRouteName.DIAGNOSTICS;
}

class SteamArkPageWindowStyleFactory {
  static buildTransparentStyle(isDarkMode: boolean): NGFWindowSystemBarStyle {
    const style = new NGFWindowSystemBarStyle();
    style.enabled = true;
    style.statusBarColor = '#00000000';
    style.navigationBarColor = '#00000000';
    const contentColor: string = ngfColorTokenProviderFacade.resolveColor(NGFColorToken.ON_BACKGROUND);
    style.statusBarContentColor = contentColor;
    style.navigationBarContentColor = contentColor;
    style.isStatusBarLightIcon = isDarkMode;
    style.isNavigationBarLightIcon = isDarkMode;
    style.enableStatusBarAnimation = true;
    style.enableNavigationBarAnimation = true;
    return style;
  }
}

export class SteamArkPageWindowSupport {
  private static initialized: boolean = false;
  private static registeredDarkMode: boolean = false;
  private static activePageName: string = SteamArkPageWindowName.HOME;

  static loadDynamicTopInset(
    uiCtx: UIContext | undefined,
    baseTitleHeight: number,
    fallbackInset: number,
    callback: (inset: number) => void
  ): void {
    if (!uiCtx) {
      callback(fallbackInset);
      SteamArkLog.debug('PageWindowSupport', 'top inset fallback used; reason=no UI context');
      return;
    }
    const hostCtx = uiCtx.getHostContext();
    if (!hostCtx) {
      callback(fallbackInset);
      SteamArkLog.debug('PageWindowSupport', 'top inset fallback used; reason=no host context');
      return;
    }
    window.getLastWindow(hostCtx).then((lastWindow: window.Window): void => {
      const topArea: window.AvoidArea = lastWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const statusBarHeightVp: number = uiCtx.px2vp(topArea.topRect.height);
      callback(statusBarHeightVp + baseTitleHeight);
      SteamArkLog.debug('PageWindowSupport', 'top inset resolved');
    }).catch((_err: Error): void => {
      callback(fallbackInset);
      SteamArkLog.warn('PageWindowSupport', 'top inset resolution failed; fallback used');
    });
  }

  static loadDynamicBottomInset(
    uiCtx: UIContext | undefined,
    fallbackInset: number,
    callback: (inset: number) => void
  ): void {
    if (!uiCtx) {
      callback(fallbackInset);
      SteamArkLog.debug('PageWindowSupport', 'bottom inset fallback used; reason=no UI context');
      return;
    }
    const hostCtx = uiCtx.getHostContext();
    if (!hostCtx) {
      callback(fallbackInset);
      SteamArkLog.debug('PageWindowSupport', 'bottom inset fallback used; reason=no host context');
      return;
    }
    window.getLastWindow(hostCtx).then((lastWindow: window.Window): void => {
      const bottomArea: window.AvoidArea = lastWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      callback(uiCtx.px2vp(bottomArea.bottomRect.height));
      SteamArkLog.debug('PageWindowSupport', 'bottom inset resolved');
    }).catch((_err: Error): void => {
      callback(fallbackInset);
      SteamArkLog.warn('PageWindowSupport', 'bottom inset resolution failed; fallback used');
    });
  }

  static apply(pageName: string): void {
    SteamArkPageWindowSupport.activePageName = pageName;
    SteamArkLog.debug('PageWindowSupport', 'window policy apply requested; page=' + pageName);
    SteamArkPageWindowSupport.ensureProfilesRegistered(ngfThemeManagerFacade.isDarkMode());
    ngfPagePolicyHostFacade.applyPolicy(pageName);
    ngfPagePolicyHostFacade.reapplyPolicy(pageName);
  }

  static refreshTheme(): void {
    if (!SteamArkPageWindowSupport.initialized) {
      SteamArkLog.debug('PageWindowSupport', 'theme refresh skipped; profiles not initialized');
      return;
    }
    SteamArkPageWindowSupport.ensureProfilesRegistered(ngfThemeManagerFacade.isDarkMode());
    ngfPagePolicyHostFacade.applyPolicy(SteamArkPageWindowSupport.activePageName);
    ngfPagePolicyHostFacade.reapplyPolicy(SteamArkPageWindowSupport.activePageName);
    SteamArkLog.info('PageWindowSupport', 'window policy theme refreshed; page=' +
      SteamArkPageWindowSupport.activePageName);
  }

  static restoreHome(): void {
    SteamArkLog.debug('PageWindowSupport', 'restoring home window policy');
    SteamArkPageWindowSupport.apply(SteamArkPageWindowName.HOME);
  }

  private static ensureProfilesRegistered(isDarkMode: boolean): void {
    if (SteamArkPageWindowSupport.initialized && SteamArkPageWindowSupport.registeredDarkMode === isDarkMode) {
      return;
    }

    const profiles: Array<NGFPageWindowProfile> = [];
    profiles.push(SteamArkPageWindowSupport.buildProfile(SteamArkPageWindowName.HOME, 0, isDarkMode));
    profiles.push(SteamArkPageWindowSupport.buildProfile(SteamArkPageWindowName.WORKSPACE, 48, isDarkMode));
    profiles.push(SteamArkPageWindowSupport.buildProfile(SteamArkPageWindowName.ACCOUNTS, 48, isDarkMode));
    profiles.push(SteamArkPageWindowSupport.buildProfile(SteamArkPageWindowName.INVENTORY, 48, isDarkMode));
    profiles.push(SteamArkPageWindowSupport.buildProfile(SteamArkPageWindowName.NETWORK, 48, isDarkMode));
    profiles.push(SteamArkPageWindowSupport.buildProfile(SteamArkPageWindowName.TOKENS, 48, isDarkMode));
    profiles.push(SteamArkPageWindowSupport.buildProfile(SteamArkPageWindowName.SETTINGS, 48, isDarkMode));
    profiles.push(SteamArkPageWindowSupport.buildProfile(SteamArkPageWindowName.DIAGNOSTICS, 48, isDarkMode));

    for (let index = 0; index < profiles.length; index++) {
      ngfPlatformWindowManagerFacade.registerPageProfile(profiles[index]);
    }

    SteamArkPageWindowSupport.initialized = true;
    SteamArkPageWindowSupport.registeredDarkMode = isDarkMode;
    SteamArkLog.info('PageWindowSupport', 'window profiles registered; count=' + String(profiles.length) +
      ', darkMode=' + String(isDarkMode));
  }

  private static buildProfile(pageName: string, reapplyDelayMs: number, isDarkMode: boolean): NGFPageWindowProfile {
    const displayMode: NGFDisplayMode = NGFDisplayMode.IMMERSIVE_WITH_BARS;
    const style: NGFWindowSystemBarStyle = SteamArkPageWindowStyleFactory.buildTransparentStyle(isDarkMode);
    const policy: NGFWindowSystemBarPolicy = new NGFWindowSystemBarPolicy(
      true,
      true,
      true,
      true,
      style
    );
    return new NGFPageWindowProfile(
      pageName,
      displayMode,
      NGFWindowOrientationPreference.UNSPECIFIED,
      true,
      policy,
      reapplyDelayMs
    );
  }
}
