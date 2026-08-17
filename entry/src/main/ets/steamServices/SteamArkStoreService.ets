import {
  IHttpSession,
  NGFHttpMethod,
  NGFHttpSession,
  NGFHttpSessionRequest,
  NGFProxyConfiguration
} from 'ngf_framework';
import {
  SteamAccountProfile,
  SteamJsonParser,
  SteamJsonValue,
  SteamJsonValueKind,
  SteamProxyKind,
  SteamWebRequest,
  SteamWishlistItem,
  SteamWishlistParser,
  SteamWishlistParseResult
} from 'steam_core';
import {
  HarmonySteamWebTransport,
  HarmonySteamWebTransportOptions
} from '../steamAdapters/HarmonySteamWebTransport';
import { ASFWorkshopProductIdentity } from './ASFWorkshopProductIdentity';
import { SteamArkLog } from './SteamArkLogger';
import { SteamArkContentLocale } from './SteamArkRegionPolicy';
import { steamArkCoreLogger } from './SteamArkCoreLogger';
import { steamArkStateService } from './SteamArkStateService';

const TAG: string = 'SteamArkStoreService';

/** One read-only store search result row. */
export class SteamArkStoreSearchItem {
  readonly appId: string;
  readonly name: string;
  readonly tinyImageUrl: string;
  readonly priceText: string;
  readonly metascoreText: string;

  constructor(appId: string, name: string, tinyImageUrl: string, priceText: string,
    metascoreText: string) {
    this.appId = appId;
    this.name = name;
    this.tinyImageUrl = tinyImageUrl;
    this.priceText = priceText;
    this.metascoreText = metascoreText;
  }
}

export class SteamArkStoreSearchResult {
  readonly success: boolean;
  readonly total: number;
  readonly items: Array<SteamArkStoreSearchItem>;
  readonly errorMessage: string;

  constructor(success: boolean, total: number = 0, items: Array<SteamArkStoreSearchItem> = [],
    errorMessage: string = '') {
    this.success = success;
    this.total = total;
    this.items = items.slice();
    this.errorMessage = errorMessage;
  }
}

export class SteamArkWishlistResult {
  readonly success: boolean;
  readonly items: Array<SteamWishlistItem>;
  readonly errorMessage: string;

  constructor(success: boolean, items: Array<SteamWishlistItem> = [], errorMessage: string = '') {
    this.success = success;
    this.items = items.slice();
    this.errorMessage = errorMessage;
  }
}

/**
 * Read-only store browse boundary: public storesearch API plus the
 * authenticated wishlist page. Purchases stay in the in-app browser handoff.
 */
export class SteamArkStoreService {
  private static readonly instance: SteamArkStoreService = new SteamArkStoreService();

  static getInstance(): SteamArkStoreService {
    return SteamArkStoreService.instance;
  }

  async search(account: SteamAccountProfile, term: string,
    locale: SteamArkContentLocale | null): Promise<SteamArkStoreSearchResult> {
    const normalizedTerm: string = term.trim();
    if (normalizedTerm.length <= 0) {
      return new SteamArkStoreSearchResult(false);
    }
    const language: string = locale !== null ? locale.steamLanguage : 'schinese';
    const country: string = locale !== null ? locale.storeCountryCode : 'CN';
    const url: string = 'https://store.steampowered.com/api/storesearch/?term=' +
      encodeURIComponent(normalizedTerm) + '&l=' + encodeURIComponent(language) +
      '&cc=' + encodeURIComponent(country);
    const session: NGFHttpSession = new NGFHttpSession();
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('StoreSearch'));
    try {
      const response = await session.request(new NGFHttpSessionRequest(
        NGFHttpMethod.GET, url, headers, '', 15000, false, this.toProxy(account, '')
      ));
      if (!response.isOk()) {
        return new SteamArkStoreSearchResult(false, 0, [], 'http_' + response.statusCode.toString());
      }
      const root: SteamJsonValue = SteamJsonParser.parse(response.body, steamArkCoreLogger);
      const total: number = this.readInteger(root.getProperty('total'));
      const itemsNode: SteamJsonValue | null = root.getProperty('items');
      const items: Array<SteamArkStoreSearchItem> = [];
      if (itemsNode !== null && itemsNode.kind === SteamJsonValueKind.ARRAY) {
        for (let index = 0; index < itemsNode.items.length && items.length < 20; index++) {
          const item: SteamJsonValue = itemsNode.items[index];
          if (item.kind !== SteamJsonValueKind.OBJECT) {
            continue;
          }
          const appId: number = this.readInteger(item.getProperty('id'));
          const name: string = this.readString(item.getProperty('name'));
          if (appId <= 0 || name.length <= 0) {
            continue;
          }
          items.push(new SteamArkStoreSearchItem(
            appId.toString(),
            name,
            this.readString(item.getProperty('tiny_image')),
            this.readPriceText(item.getProperty('price')),
            this.readString(item.getProperty('metascore'))
          ));
        }
      }
      return new SteamArkStoreSearchResult(true, total, items);
    } catch (error) {
      SteamArkLog.warn(TAG, 'store search failed; errorType=' + SteamArkLog.errorKind(error));
      return new SteamArkStoreSearchResult(false, 0, [],
        error instanceof Error ? error.message : 'network');
    } finally {
      session.clear();
    }
  }

  async loadWishlist(accountId: string): Promise<SteamArkWishlistResult> {
    const account = steamArkStateService.getSelectedAccount();
    if (account === null || account.profile.accountId !== accountId.trim()) {
      return new SteamArkWishlistResult(false, [], 'account_unavailable');
    }
    const credentials = await steamArkStateService.getCredentials(accountId);
    const proxyPassword: string = await steamArkStateService.getProxyPassword(accountId);
    const session: IHttpSession = new NGFHttpSession();
    const transport: HarmonySteamWebTransport = new HarmonySteamWebTransport(session,
      new HarmonySteamWebTransportOptions(this.toProxy(account.profile, proxyPassword),
        ASFWorkshopProductIdentity.userAgent('Wishlist'), 30000));
    try {
      await transport.open(account.profile.steamId64, credentials.accessToken);
      const profilePath: string = account.profile.steamId64.length > 0
        ? 'profiles/' + account.profile.steamId64
        : 'id/' + account.profile.displayName;
      const request: SteamWebRequest = new SteamWebRequest(
        'https://steamcommunity.com/' + profilePath + '/wishlist/');
      const response = await transport.get(request);
      if (!response.isOk()) {
        return new SteamArkWishlistResult(false, [], 'http_' + response.statusCode.toString());
      }
      const parsed: SteamWishlistParseResult = SteamWishlistParser.parse(response.body);
      if (!parsed.success) {
        return new SteamArkWishlistResult(false, [], parsed.errorMessage);
      }
      return new SteamArkWishlistResult(true, parsed.items);
    } catch (error) {
      SteamArkLog.warn(TAG, 'wishlist fetch failed; errorType=' + SteamArkLog.errorKind(error));
      return new SteamArkWishlistResult(false, [],
        error instanceof Error ? error.message : 'network');
    } finally {
      try {
        await transport.close();
      } catch (_error) {
        SteamArkLog.debug(TAG, 'wishlist transport close failed');
      }
      session.clear();
    }
  }

  private readPriceText(value: SteamJsonValue | null): string {
    if (value === null || value.kind !== SteamJsonValueKind.OBJECT) {
      return '';
    }
    const finalRaw: string = this.readString(value.getProperty('final'));
    if (finalRaw.length <= 0) {
      return '';
    }
    const minorUnits: number = Number(finalRaw);
    const currency: string = this.readString(value.getProperty('currency'));
    if (!Number.isFinite(minorUnits)) {
      return '';
    }
    return currency.length > 0 ? currency + ' ' + (minorUnits / 100).toFixed(2)
      : (minorUnits / 100).toFixed(2);
  }

  private readString(value: SteamJsonValue | null): string {
    if (value === null) {
      return '';
    }
    if (value.kind === SteamJsonValueKind.STRING) {
      return value.stringValue.trim();
    }
    if (value.kind === SteamJsonValueKind.NUMBER) {
      return value.numberValue.trim();
    }
    return '';
  }

  private readInteger(value: SteamJsonValue | null): number {
    const parsed: number = Number(this.readString(value));
    return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
  }

  private toProxy(profile: SteamAccountProfile, proxyPassword: string): NGFProxyConfiguration {
    if (profile.proxy.kind === SteamProxyKind.DIRECT) {
      return NGFProxyConfiguration.direct();
    }
    if (profile.proxy.kind === SteamProxyKind.HTTP) {
      return NGFProxyConfiguration.http(profile.proxy.host, profile.proxy.port,
        profile.proxy.username, proxyPassword);
    }
    if (profile.proxy.kind === SteamProxyKind.SOCKS5) {
      return NGFProxyConfiguration.socks5(profile.proxy.host, profile.proxy.port,
        profile.proxy.username, proxyPassword);
    }
    return NGFProxyConfiguration.system();
  }
}

export const steamArkStoreService: SteamArkStoreService = SteamArkStoreService.getInstance();
