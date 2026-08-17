/**
 * Per-account Steam content region policy.
 *
 * Steam serves localized content through independent knobs:
 * - Community/store pages and read APIs accept `l=` with Steam language codes
 *   ('schinese', 'english', 'tchinese', 'japanese', 'koreana', 'russian', ...).
 * - Store APIs (e.g. featuredcategories) accept `cc=` country codes that drive
 *   store prices and availability.
 * - The market priceoverview API accepts `currency=` with the Steam currency
 *   enum (1=USD, 2=GBP, 3=EUR, 5=RUB, 8=JPY, 16=KRW, 23=CNY, 29=HKD, 30=TWD).
 * - ISteamNotificationService/GetSteamNotifications accepts `language=` with the
 *   Steamworks ELanguage integer enum (0=English, 4=Korean, 6=Simplified Chinese,
 *   7=Traditional Chinese, 8=Russian, 10=Japanese, 22=Brazilian).
 *
 * A region preset bundles these values so every content source (inventory,
 * badges/cards, messages, market prices and future sources) uses one account
 * decision. 'AUTO' derives the preset from the account's own wallet currency
 * first (the strongest signal of the account's home store region, delivered by
 * the CM logon response), then from the profile country code, falling back to US.
 */
export enum SteamArkAccountRegion {
  AUTO = 'AUTO',
  CN = 'CN',
  TW = 'TW',
  HK = 'HK',
  JP = 'JP',
  KR = 'KR',
  US = 'US',
  EU = 'EU',
  GB = 'GB',
  RU = 'RU',
  BR = 'BR'
}

/** The fully resolved content localization values for one account. */
export class SteamArkContentLocale {
  /** Effective region code; never SteamArkAccountRegion.AUTO. */
  readonly region: string;
  /** Steam language code used for `l=` on community/store requests. */
  readonly steamLanguage: string;
  /** Country code used for `cc=` on store requests. */
  readonly storeCountryCode: string;
  /** Steam currency enum id used for market priceoverview `currency=`. */
  readonly currencyId: number;
  /** ISO 4217 code used for display and cache validation. */
  readonly currencyCode: string;
  /** Steamworks ELanguage id used for GetSteamNotifications `language=`. */
  readonly notificationLanguageId: number;

  constructor(region: string, steamLanguage: string, storeCountryCode: string,
    currencyId: number, currencyCode: string, notificationLanguageId: number) {
    this.region = region;
    this.steamLanguage = steamLanguage;
    this.storeCountryCode = storeCountryCode;
    this.currencyId = currencyId;
    this.currencyCode = currencyCode;
    this.notificationLanguageId = notificationLanguageId;
  }
}

export class SteamArkRegionPolicy {
  private static readonly EUROZONE_COUNTRY_CODES: Array<string> = [
    'AT', 'BE', 'CY', 'DE', 'EE', 'ES', 'FI', 'FR', 'GR', 'IE', 'IT',
    'LT', 'LU', 'LV', 'MT', 'NL', 'PT', 'SI', 'SK'
  ];

  /** True when the value is a valid stored region setting (AUTO or a preset). */
  static isValid(region: string): boolean {
    const normalized: string = region.trim().toUpperCase();
    switch (normalized) {
      case SteamArkAccountRegion.AUTO:
      case SteamArkAccountRegion.CN:
      case SteamArkAccountRegion.TW:
      case SteamArkAccountRegion.HK:
      case SteamArkAccountRegion.JP:
      case SteamArkAccountRegion.KR:
      case SteamArkAccountRegion.US:
      case SteamArkAccountRegion.EU:
      case SteamArkAccountRegion.GB:
      case SteamArkAccountRegion.RU:
      case SteamArkAccountRegion.BR:
        return true;
      default:
        return false;
    }
  }

  /**
   * Resolves a stored setting to concrete localization values. AUTO derives from
   * the account's own wallet currency first (its home store region), then from
   * the profile country code, then falls back to US.
   */
  static resolve(regionSetting: string, countryCode: string, walletCurrency: string): SteamArkContentLocale {
    const normalizedSetting: string = regionSetting.trim().toUpperCase();
    if (normalizedSetting !== SteamArkAccountRegion.AUTO) {
      const explicit: SteamArkContentLocale | null = SteamArkRegionPolicy.preset(normalizedSetting);
      if (explicit !== null) {
        return explicit;
      }
    }
    const derivedFromCurrency: string = SteamArkRegionPolicy.deriveFromWalletCurrency(walletCurrency);
    if (derivedFromCurrency !== SteamArkAccountRegion.US) {
      const derived: SteamArkContentLocale | null = SteamArkRegionPolicy.preset(derivedFromCurrency);
      if (derived !== null) {
        return derived;
      }
    }
    const derivedFromCountry: string = SteamArkRegionPolicy.deriveFromCountryCode(countryCode);
    if (derivedFromCountry !== SteamArkAccountRegion.US) {
      const derived: SteamArkContentLocale | null = SteamArkRegionPolicy.preset(derivedFromCountry);
      if (derived !== null) {
        return derived;
      }
    }
    return SteamArkRegionPolicy.usLocale();
  }

  /** Maps a Steam ECurrencyCode enum id (as delivered by the CM logon response) to its ISO 4217 code. */
  static currencyCode(currencyId: number): string {
    switch (currencyId) {
      case 1: return 'USD';
      case 2: return 'GBP';
      case 3: return 'EUR';
      case 5: return 'RUB';
      case 7: return 'BRL';
      case 8: return 'JPY';
      case 16: return 'KRW';
      case 23: return 'CNY';
      case 29: return 'HKD';
      case 30: return 'TWD';
      default: return '';
    }
  }

  /** Derives a region preset from an ISO 3166-1 alpha-2 profile country code. */
  static deriveFromCountryCode(countryCode: string): string {
    const normalized: string = countryCode.trim().toUpperCase();
    switch (normalized) {
      case 'CN': return SteamArkAccountRegion.CN;
      case 'TW': return SteamArkAccountRegion.TW;
      case 'HK': return SteamArkAccountRegion.HK;
      case 'JP': return SteamArkAccountRegion.JP;
      case 'KR': return SteamArkAccountRegion.KR;
      case 'GB':
      case 'UK': return SteamArkAccountRegion.GB;
      case 'RU': return SteamArkAccountRegion.RU;
      case 'BR': return SteamArkAccountRegion.BR;
      default:
        break;
    }
    for (let index: number = 0; index < SteamArkRegionPolicy.EUROZONE_COUNTRY_CODES.length; index++) {
      if (SteamArkRegionPolicy.EUROZONE_COUNTRY_CODES[index] === normalized) {
        return SteamArkAccountRegion.EU;
      }
    }
    return SteamArkAccountRegion.US;
  }

  /** Derives a region preset from a wallet currency token such as 'CNY'. */
  static deriveFromWalletCurrency(walletCurrency: string): string {
    const normalized: string = walletCurrency.trim().toUpperCase();
    if (normalized.indexOf('CNY') >= 0 || normalized.indexOf('RMB') >= 0 || normalized.indexOf('¥') >= 0) {
      return SteamArkAccountRegion.CN;
    }
    if (normalized.indexOf('TWD') >= 0) {
      return SteamArkAccountRegion.TW;
    }
    if (normalized.indexOf('HKD') >= 0) {
      return SteamArkAccountRegion.HK;
    }
    if (normalized.indexOf('JPY') >= 0) {
      return SteamArkAccountRegion.JP;
    }
    if (normalized.indexOf('KRW') >= 0) {
      return SteamArkAccountRegion.KR;
    }
    if (normalized.indexOf('RUB') >= 0) {
      return SteamArkAccountRegion.RU;
    }
    if (normalized.indexOf('GBP') >= 0) {
      return SteamArkAccountRegion.GB;
    }
    if (normalized.indexOf('BRL') >= 0) {
      return SteamArkAccountRegion.BR;
    }
    if (normalized.indexOf('EUR') >= 0 || normalized.indexOf('€') >= 0) {
      return SteamArkAccountRegion.EU;
    }
    return SteamArkAccountRegion.US;
  }

  /** The neutral fallback localization (English / US dollars). */
  static defaultLocale(): SteamArkContentLocale {
    return SteamArkRegionPolicy.usLocale();
  }

  /** The selectable stored settings for the account region picker. */
  static availableSettings(): Array<string> {
    return [
      SteamArkAccountRegion.AUTO,
      SteamArkAccountRegion.CN,
      SteamArkAccountRegion.TW,
      SteamArkAccountRegion.HK,
      SteamArkAccountRegion.JP,
      SteamArkAccountRegion.KR,
      SteamArkAccountRegion.US,
      SteamArkAccountRegion.EU,
      SteamArkAccountRegion.GB,
      SteamArkAccountRegion.RU,
      SteamArkAccountRegion.BR
    ];
  }

  private static preset(region: string): SteamArkContentLocale | null {
    switch (region) {
      case SteamArkAccountRegion.CN:
        return new SteamArkContentLocale(SteamArkAccountRegion.CN, 'schinese', 'CN', 23, 'CNY', 6);
      case SteamArkAccountRegion.TW:
        return new SteamArkContentLocale(SteamArkAccountRegion.TW, 'tchinese', 'TW', 30, 'TWD', 7);
      case SteamArkAccountRegion.HK:
        return new SteamArkContentLocale(SteamArkAccountRegion.HK, 'tchinese', 'HK', 29, 'HKD', 7);
      case SteamArkAccountRegion.JP:
        return new SteamArkContentLocale(SteamArkAccountRegion.JP, 'japanese', 'JP', 8, 'JPY', 8);
      case SteamArkAccountRegion.KR:
        return new SteamArkContentLocale(SteamArkAccountRegion.KR, 'koreana', 'KR', 16, 'KRW', 4);
      case SteamArkAccountRegion.US:
        return SteamArkRegionPolicy.usLocale();
      case SteamArkAccountRegion.EU:
        return new SteamArkContentLocale(SteamArkAccountRegion.EU, 'english', 'DE', 3, 'EUR', 0);
      case SteamArkAccountRegion.GB:
        return new SteamArkContentLocale(SteamArkAccountRegion.GB, 'english', 'GB', 2, 'GBP', 0);
      case SteamArkAccountRegion.RU:
        return new SteamArkContentLocale(SteamArkAccountRegion.RU, 'russian', 'RU', 5, 'RUB', 9);
      case SteamArkAccountRegion.BR:
        return new SteamArkContentLocale(SteamArkAccountRegion.BR, 'brazilian', 'BR', 7, 'BRL', 25);
      default:
        return null;
    }
  }

  private static usLocale(): SteamArkContentLocale {
    return new SteamArkContentLocale(SteamArkAccountRegion.US, 'english', 'US', 1, 'USD', 0);
  }
}
