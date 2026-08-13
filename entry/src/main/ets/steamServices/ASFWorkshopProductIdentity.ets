import { SteamProtocolIdentity } from 'steam_core';

/**
 * Entry-layer identity for user-visible names and host integrations.
 * Compatibility identifiers such as SteamArk and steam_ark_* remain unchanged.
 */
export class ASFWorkshopProductIdentity {
  static readonly DISPLAY_NAME_ZH: string = 'ASF工坊';
  static readonly DISPLAY_NAME_EN: string = SteamProtocolIdentity.PRODUCT_NAME;
  static readonly DEVICE_FRIENDLY_NAME: string = SteamProtocolIdentity.PRODUCT_NAME;
  static readonly BACKGROUND_TASK_FARMING: string = SteamProtocolIdentity.PRODUCT_NAME + ' Farming';
  static readonly NOTIFICATION_TITLE: string = SteamProtocolIdentity.PRODUCT_NAME;

  /** Resolves the brand fallback used by system-facing text for the active locale. */
  static notificationTitle(locale: string): string {
    const normalizedLocale: string = locale.trim().toLowerCase();
    return normalizedLocale === 'zh' || normalizedLocale.indexOf('zh-') === 0
      ? ASFWorkshopProductIdentity.DISPLAY_NAME_ZH
      : ASFWorkshopProductIdentity.DISPLAY_NAME_EN;
  }

  static userAgent(component: string = ''): string {
    return SteamProtocolIdentity.userAgent(component);
  }
}
