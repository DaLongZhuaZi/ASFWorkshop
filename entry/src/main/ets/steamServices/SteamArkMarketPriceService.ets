import {
  NGFHttpMethod,
  NGFHttpSession,
  NGFHttpSessionRequest,
  NGFHttpSessionResponse,
  NGFProxyConfiguration,
  NGFProxyMode,
  ngfContentCacheFacade
} from 'ngf_framework';
import { SteamAccountProfile, SteamCredentialSet, SteamInventoryItem, SteamJsonParser, SteamJsonValue, SteamJsonValueKind, SteamProxyKind } from 'steam_core';
import { SteamArkLog } from './SteamArkLogger';
import { SteamArkContentLocale } from './SteamArkRegionPolicy';
import { steamArkCoreLogger } from './SteamArkCoreLogger';
import { ASFWorkshopProductIdentity } from './ASFWorkshopProductIdentity';

const TAG: string = 'SteamArkMarketPriceService';
const PRICE_TTL_MS: number = 6 * 60 * 60 * 1000;
const FAILED_PRICE_TTL_MS: number = 10 * 60 * 1000;
const CACHE_NAMESPACE: string = 'steam.market.price.v2';
const DEFAULT_CACHE_GENERATION: number = 1;
const RATE_LIMIT_HTTP_STATUS: number = 429;
// Steam's market priceoverview endpoint throttles bursty clients; pace every
// network lookup and pause the whole batch for a cooldown once throttled.
const MARKET_REQUEST_PACING_MS: number = 2000;
const MARKET_RATE_LIMIT_COOLDOWN_MS: number = 60 * 1000;
/** Price-history trend data changes slowly; a short TTL avoids refetching on every detail open. */
const HISTORY_CACHE_TTL_MS: number = 30 * 60 * 1000;

/** One read-only community market listing row from the search/render endpoint. */
export class SteamArkMarketListing {
  readonly appId: string;
  readonly marketHashName: string;
  readonly displayName: string;
  readonly iconUrl: string;
  readonly sellListings: number;
  readonly sellPriceText: string;
  readonly sellPriceMinorUnits: number;

  constructor(appId: string, marketHashName: string, displayName: string, iconUrl: string,
    sellListings: number, sellPriceText: string, sellPriceMinorUnits: number) {
    this.appId = appId;
    this.marketHashName = marketHashName;
    this.displayName = displayName;
    this.iconUrl = iconUrl;
    this.sellListings = sellListings;
    this.sellPriceText = sellPriceText;
    this.sellPriceMinorUnits = sellPriceMinorUnits;
  }
}

/** One page of read-only market search results. */
export class SteamArkMarketBrowseResult {
  readonly success: boolean;
  readonly totalCount: number;
  readonly pageSize: number;
  readonly start: number;
  readonly currencyCode: string;
  readonly listings: Array<SteamArkMarketListing>;
  readonly errorMessage: string;

  constructor(success: boolean, totalCount: number, pageSize: number, start: number,
    currencyCode: string, listings: Array<SteamArkMarketListing> = [],
    errorMessage: string = '') {
    this.success = success;
    this.totalCount = totalCount;
    this.pageSize = pageSize;
    this.start = start;
    this.currencyCode = currencyCode;
    this.listings = listings.slice();
    this.errorMessage = errorMessage;
  }
}

export class SteamArkMarketPrice {
  readonly accountId: string;
  readonly appId: string;
  readonly marketHashName: string;
  readonly currencyId: number;
  readonly currencyCode: string;
  readonly lowestPriceText: string;
  readonly medianPriceText: string;
  readonly lowestMinorUnits: number;
  readonly medianMinorUnits: number;
  readonly fetchedAtEpochSeconds: number;
  readonly available: boolean;
  /** Total units sold in the last 24 hours as reported by priceoverview; 0 when unknown. */
  readonly volumeCount: number;

  constructor(accountId: string, appId: string, marketHashName: string, currencyId: number,
    currencyCode: string, lowestPriceText: string, medianPriceText: string,
    lowestMinorUnits: number, medianMinorUnits: number, fetchedAtEpochSeconds: number,
    available: boolean, volumeCount: number = 0) {
    this.accountId = accountId;
    this.appId = appId;
    this.marketHashName = marketHashName;
    this.currencyId = currencyId;
    this.currencyCode = currencyCode;
    this.lowestPriceText = lowestPriceText;
    this.medianPriceText = medianPriceText;
    this.lowestMinorUnits = lowestMinorUnits;
    this.medianMinorUnits = medianMinorUnits;
    this.fetchedAtEpochSeconds = fetchedAtEpochSeconds;
    this.available = available;
    this.volumeCount = volumeCount;
  }
}

export class SteamArkMarketPriceBatch {
  readonly prices: Array<SteamArkMarketPrice>;
  readonly currencyId: number;
  readonly currencyCode: string;

  constructor(prices: Array<SteamArkMarketPrice>, currencyId: number, currencyCode: string) {
    this.prices = prices;
    this.currencyId = currencyId;
    this.currencyCode = currencyCode;
  }
}

/** One bucket of the community market price history chart. */
export class SteamArkMarketPriceHistoryPoint {
  readonly epochSeconds: number;
  readonly minorUnits: number;
  readonly volumeCount: number;

  constructor(epochSeconds: number, minorUnits: number, volumeCount: number = 0) {
    this.epochSeconds = epochSeconds;
    this.minorUnits = minorUnits;
    this.volumeCount = volumeCount;
  }
}

/** Parsed pricehistory response; the chart is drawn from these points. */
export class SteamArkMarketPriceHistory {
  readonly success: boolean;
  readonly pricePrefix: string;
  readonly priceSuffix: string;
  readonly points: Array<SteamArkMarketPriceHistoryPoint>;

  constructor(success: boolean, pricePrefix: string = '', priceSuffix: string = '',
    points: Array<SteamArkMarketPriceHistoryPoint> = []) {
    this.success = success;
    this.pricePrefix = pricePrefix;
    this.priceSuffix = priceSuffix;
    this.points = points.slice();
  }
}

class SteamArkMarketPriceCacheRecord {
  readonly accountId: string;
  readonly appId: string;
  readonly marketHashName: string;
  readonly currencyId: number;
  readonly currencyCode: string;
  readonly lowestPriceText: string;
  readonly medianPriceText: string;
  readonly lowestMinorUnits: number;
  readonly medianMinorUnits: number;
  readonly fetchedAtEpochSeconds: number;
  readonly available: boolean;
  readonly volumeCount: number;

  constructor(accountId: string, appId: string, marketHashName: string, currencyId: number,
    currencyCode: string, lowestPriceText: string, medianPriceText: string,
    lowestMinorUnits: number, medianMinorUnits: number, fetchedAtEpochSeconds: number,
    available: boolean, volumeCount: number = 0) {
    this.accountId = accountId;
    this.appId = appId;
    this.marketHashName = marketHashName;
    this.currencyId = currencyId;
    this.currencyCode = currencyCode;
    this.lowestPriceText = lowestPriceText;
    this.medianPriceText = medianPriceText;
    this.lowestMinorUnits = lowestMinorUnits;
    this.medianMinorUnits = medianMinorUnits;
    this.fetchedAtEpochSeconds = fetchedAtEpochSeconds;
    this.available = available;
    this.volumeCount = volumeCount;
  }
}

export class SteamArkMarketPriceService {
  private static readonly accountGenerations: Map<string, number> = new Map<string, number>();
  private static lastMarketRequestAtEpochMs: number = 0;
  private static marketRateLimitedUntilEpochMs: number = 0;

  private static isMarketRateLimited(): boolean {
    return Date.now() < SteamArkMarketPriceService.marketRateLimitedUntilEpochMs;
  }

  private static markMarketRateLimited(): void {
    SteamArkMarketPriceService.marketRateLimitedUntilEpochMs =
      Date.now() + MARKET_RATE_LIMIT_COOLDOWN_MS;
  }

  private static delayMarket(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private static async paceMarketRequest(): Promise<void> {
    const now: number = Date.now();
    const elapsed: number = now - SteamArkMarketPriceService.lastMarketRequestAtEpochMs;
    if (elapsed < MARKET_REQUEST_PACING_MS) {
      await SteamArkMarketPriceService.delayMarket(MARKET_REQUEST_PACING_MS - elapsed);
    }
    SteamArkMarketPriceService.lastMarketRequestAtEpochMs = Date.now();
  }

  /**
   * Invalidates all indexed price entries for a deleted account. The generation changes first so
   * an in-flight request from the removed account cannot repopulate its former cache namespace.
   */
  static clearCachedAccount(accountId: string): void {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0) {
      return;
    }
    const previousGeneration: number = SteamArkMarketPriceService.accountGeneration(normalizedAccountId);
    const nextGeneration: number = previousGeneration + 1;
    SteamArkMarketPriceService.accountGenerations.set(normalizedAccountId, nextGeneration);
    ngfContentCacheFacade.put(
      SteamArkMarketPriceService.generationCacheKey(normalizedAccountId),
      nextGeneration.toString(),
      0
    );
    const indexCacheKey: string = SteamArkMarketPriceService.indexCacheKey(normalizedAccountId, previousGeneration);
    const cachedKeys: Array<string> = SteamArkMarketPriceService.readIndexedCacheKeys(indexCacheKey);
    for (let index: number = 0; index < cachedKeys.length; index++) {
      ngfContentCacheFacade.remove(cachedKeys[index]);
    }
    ngfContentCacheFacade.remove(indexCacheKey);
    SteamArkLog.debug(TAG, 'market price cache invalidated after account deletion; account=' +
      SteamArkLog.accountId(normalizedAccountId) + ', removed=' + cachedKeys.length.toString());
  }

  async loadBatch(account: SteamAccountProfile, items: Array<SteamInventoryItem>,
    locale: SteamArkContentLocale | null = null,
    credentials: SteamCredentialSet | null = null,
    proxyPassword: string = ''): Promise<SteamArkMarketPriceBatch> {
    const accountId: string = account.accountId.trim();
    // The account region is authoritative for the price unit; the wallet currency
    // derived from the profile remains the fallback when no locale is supplied.
    const currencyId: number = locale !== null ? locale.currencyId : this.currencyId(account.walletCurrency);
    const currencyCode: string = locale !== null ? locale.currencyCode : this.currencyCode(currencyId);
    const prices: Array<SteamArkMarketPrice> = [];
    if (accountId.length <= 0) {
      return new SteamArkMarketPriceBatch(prices, currencyId, currencyCode);
    }
    const cacheGeneration: number = SteamArkMarketPriceService.accountGeneration(accountId);
    const seen: Set<string> = new Set<string>();
    let networkRequestCount: number = 0;
    for (let index = 0; index < items.length; index++) {
      if (!SteamArkMarketPriceService.isGenerationCurrent(accountId, cacheGeneration)) {
        break;
      }
      const item: SteamInventoryItem = items[index];
      const marketHashName: string = item.marketHashName.trim();
      if (!item.marketable || marketHashName.length <= 0) {
        continue;
      }
      const identity: string = item.appId + '|' + marketHashName;
      if (seen.has(identity)) {
        continue;
      }
      seen.add(identity);
      const cached: SteamArkMarketPrice | null = this.readCached(
        accountId, item.appId, marketHashName, currencyId, cacheGeneration
      );
      if (cached !== null && SteamArkMarketPriceService.isGenerationCurrent(accountId, cacheGeneration) &&
        Date.now() - cached.fetchedAtEpochSeconds * 1000 < PRICE_TTL_MS) {
        prices.push(cached);
        continue;
      }
      if (networkRequestCount >= 24) {
        continue;
      }
      if (SteamArkMarketPriceService.isMarketRateLimited()) {
        SteamArkLog.info(TAG, 'market price batch paused; rate limited by Steam');
        break;
      }
      await SteamArkMarketPriceService.paceMarketRequest();
      networkRequestCount += 1;
      const fetched: SteamArkMarketPrice | null = await this.fetchOne(
        account, accountId, item.appId, marketHashName, currencyId, currencyCode, cacheGeneration,
        credentials, proxyPassword
      );
      if (fetched !== null && SteamArkMarketPriceService.isGenerationCurrent(accountId, cacheGeneration)) {
        prices.push(fetched);
      }
    }
    return new SteamArkMarketPriceBatch(prices, currencyId, currencyCode);
  }

  /**
   * Read-only community market search via `market/search/render?norender=1`.
   * Buy and sell actions stay in the in-app browser handoff; this only lists.
   */
  async browse(account: SteamAccountProfile, query: string, appId: string,
    start: number, count: number, locale: SteamArkContentLocale | null = null): Promise<SteamArkMarketBrowseResult> {
    const currencyId: number = locale !== null ? locale.currencyId : this.currencyId(account.walletCurrency);
    const currencyCode: string = locale !== null ? locale.currencyCode : this.currencyCode(currencyId);
    const normalizedQuery: string = query.trim();
    const normalizedAppId: string = appId.trim();
    const pageSize: number = Math.max(1, Math.min(50, Math.floor(count)));
    const pageStart: number = Math.max(0, Math.floor(start));
    const empty: SteamArkMarketBrowseResult = new SteamArkMarketBrowseResult(
      false, 0, pageSize, pageStart, currencyCode, [], '');
    if (SteamArkMarketPriceService.isMarketRateLimited()) {
      return new SteamArkMarketBrowseResult(false, 0, pageSize, pageStart, currencyCode, [],
        'rate_limited');
    }
    await SteamArkMarketPriceService.paceMarketRequest();
    let url: string = 'https://steamcommunity.com/market/search/render/?norender=1&count=' +
      pageSize.toString() + '&start=' + pageStart.toString() +
      '&currency=' + currencyId.toString();
    if (normalizedQuery.length > 0) {
      url += '&query=' + encodeURIComponent(normalizedQuery);
    }
    if (normalizedAppId.length > 0 && normalizedAppId !== '0') {
      url += '&appid=' + encodeURIComponent(normalizedAppId);
    }
    const session = new NGFHttpSession();
    const headers = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('SteamMarketBrowse'));
    try {
      let response = await session.request(new NGFHttpSessionRequest(
        NGFHttpMethod.GET, url, headers, '', 15000, false, this.toProxy(account)
      ));
      if (response.statusCode === RATE_LIMIT_HTTP_STATUS) {
        SteamArkMarketPriceService.markMarketRateLimited();
        return new SteamArkMarketBrowseResult(false, 0, pageSize, pageStart, currencyCode, [],
          'rate_limited');
      }
      if (!response.isOk() && this.toProxy(account).mode === NGFProxyMode.SYSTEM) {
        response = await session.request(new NGFHttpSessionRequest(
          NGFHttpMethod.GET, url, headers, '', 15000, false, NGFProxyConfiguration.direct()
        ));
        if (response.statusCode === RATE_LIMIT_HTTP_STATUS) {
          SteamArkMarketPriceService.markMarketRateLimited();
          return new SteamArkMarketBrowseResult(false, 0, pageSize, pageStart, currencyCode, [],
            'rate_limited');
        }
      }
      if (!response.isOk()) {
        return new SteamArkMarketBrowseResult(false, 0, pageSize, pageStart, currencyCode, [],
          'http_' + response.statusCode.toString());
      }
      return this.parseBrowseResponse(response.body, pageSize, pageStart, currencyCode);
    } catch (error) {
      SteamArkLog.warn(TAG, 'market browse failed; errorType=' + SteamArkLog.errorKind(error));
      return new SteamArkMarketBrowseResult(false, 0, pageSize, pageStart, currencyCode, [],
        error instanceof Error ? error.message : 'network');
    } finally {
      session.clear();
    }
  }

  private parseBrowseResponse(body: string, pageSize: number, pageStart: number,
    currencyCode: string): SteamArkMarketBrowseResult {
    const root: SteamJsonValue = SteamJsonParser.parse(body, steamArkCoreLogger);
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      return new SteamArkMarketBrowseResult(false, 0, pageSize, pageStart, currencyCode, [], 'malformed');
    }
    const success: boolean = this.readBoolean(root, 'success');
    const totalCount: number = this.readListingInteger(root.getProperty('total_count'));
    const resultsNode: SteamJsonValue | null = root.getProperty('results');
    const listings: Array<SteamArkMarketListing> = [];
    if (resultsNode !== null && resultsNode.kind === SteamJsonValueKind.ARRAY) {
      for (let index = 0; index < resultsNode.items.length; index++) {
        const item: SteamJsonValue = resultsNode.items[index];
        if (item.kind !== SteamJsonValueKind.OBJECT) {
          continue;
        }
        const hashName: string = this.readListingString(item.getProperty('hash_name'));
        if (hashName.length <= 0) {
          continue;
        }
        const listingAppId: string = this.readListingString(item.getProperty('appid'));
        const nameNode: SteamJsonValue | null = item.getProperty('name');
        const displayName: string = nameNode !== null && nameNode.kind === SteamJsonValueKind.STRING
          ? nameNode.stringValue.trim() : hashName;
        const iconUrl: string = this.readListingString(item.getProperty('asset_description')) === ''
          ? '' : this.readIconUrl(item.getProperty('asset_description'));
        const sellListings: number = this.readListingInteger(item.getProperty('sell_listings'));
        const sellPriceText: string = this.readListingString(item.getProperty('sell_price_text'));
        const sellPrice: number = this.readListingInteger(item.getProperty('sell_price'));
        listings.push(new SteamArkMarketListing(
          listingAppId.length > 0 ? listingAppId : '753', hashName, displayName, iconUrl,
          sellListings, sellPriceText, sellPrice));
      }
    }
    return new SteamArkMarketBrowseResult(
      success && listings.length > 0, totalCount, pageSize, pageStart, currencyCode, listings);
  }

  private readIconUrl(value: SteamJsonValue | null): string {
    if (value === null || value.kind !== SteamJsonValueKind.OBJECT) {
      return '';
    }
    const url: string = this.readListingString(value.getProperty('icon_url'));
    return url.length > 0
      ? 'https://community.cloudflare.steamstatic.com/economy/image/' + url + '/96fx96f'
      : '';
  }

  private readListingString(value: SteamJsonValue | null): string {
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

  private readListingInteger(value: SteamJsonValue | null): number {
    const parsed: number = Number(this.readListingString(value));
    return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
  }

  /**
   * Authenticated GET for market endpoints that require a logged-in session
   * (pricehistory) or throttle anonymous clients harder (priceoverview).
   * Credentials stay in this call's memory only; the cookie mirrors the
   * in-app browser handoff (sessionid + steamLoginSecure).
   */
  private async authenticatedMarketGet(
    url: string,
    account: SteamAccountProfile,
    credentials: SteamCredentialSet | null,
    proxyPassword: string
  ): Promise<string | null> {
    const token: string = credentials === null ? '' : credentials.accessToken.trim();
    const steamId64: string = account.steamId64.trim();
    if (token.length <= 0 || steamId64.length <= 0) {
      return null;
    }
    const sessionId: string = 'steamark' + Date.now().toString(36) +
      Math.floor(Math.random() * 1000000).toString(36);
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('SteamMarketAuth'));
    headers.set('Cookie', 'sessionid=' + sessionId + '; steamLoginSecure=' +
      encodeURIComponent(steamId64 + '||' + token));
    const session: NGFHttpSession = new NGFHttpSession();
    try {
      const response: NGFHttpSessionResponse = await session.request(new NGFHttpSessionRequest(
        NGFHttpMethod.GET, url, headers, '', 15000, false, this.toProxyWithPassword(account, proxyPassword)
      ));
      if (response.isOk()) {
        return response.body;
      }
      SteamArkLog.debug(TAG, 'authenticated market GET failed; status=' + response.statusCode.toString());
      return null;
    } finally {
      session.clear();
    }
  }

  private toProxyWithPassword(account: SteamAccountProfile, proxyPassword: string): NGFProxyConfiguration {
    if (proxyPassword.trim().length <= 0) {
      return this.toProxy(account);
    }
    if (account.proxy.kind === SteamProxyKind.HTTP) {
      return NGFProxyConfiguration.http(account.proxy.host, account.proxy.port,
        account.proxy.username, proxyPassword);
    }
    if (account.proxy.kind === SteamProxyKind.SOCKS5) {
      return NGFProxyConfiguration.socks5(account.proxy.host, account.proxy.port,
        account.proxy.username, proxyPassword);
    }
    return this.toProxy(account);
  }

  /**
   * Fetches the public community market price history (line + volume chart)
   * for one market hash name. pricehistory requires a logged-in session, so
   * the authenticated cookie path is tried first whenever credentials are
   * supplied. Successful responses are cached with a short TTL so reopening a
   * detail page does not re-hit pricehistory on every visit.
   */
  async fetchPriceHistory(account: SteamAccountProfile, appId: string,
    marketHashName: string, credentials: SteamCredentialSet | null = null,
    proxyPassword: string = ''): Promise<SteamArkMarketPriceHistory | null> {
    const cacheKey: string = 'steam.market.history.v2.' + account.accountId.trim() +
      '.' + appId + '.' + marketHashName;
    const cached: SteamArkMarketPriceHistory | null = this.readHistoryCache(cacheKey);
    if (cached !== null) {
      return cached;
    }
    const encodedName: string = encodeURIComponent(marketHashName);
    const url: string = 'https://steamcommunity.com/market/pricehistory/?appid=' + appId +
      '&market_hash_name=' + encodedName;
    let body: string | null = null;
    if (credentials !== null) {
      await SteamArkMarketPriceService.paceMarketRequest();
      body = await this.authenticatedMarketGet(url, account, credentials, proxyPassword);
    }
    const fetched: SteamArkMarketPriceHistory | null = body !== null
      ? this.parsePriceHistoryBody(body)
      : await this.fetchPriceHistoryUncached(account, appId, marketHashName);
    if (fetched !== null && fetched.success) {
      this.writeHistoryCache(cacheKey, fetched);
    }
    return fetched;
  }

  /** Parses a pricehistory response body into chart points. */
  private parsePriceHistoryBody(body: string): SteamArkMarketPriceHistory | null {
    try {
      const root: SteamJsonValue = SteamJsonParser.parse(body, steamArkCoreLogger);
      const success: boolean = this.readBoolean(root, 'success');
      const pricePrefix: string = this.readString(root, 'price_prefix');
      const priceSuffix: string = this.readString(root, 'price_suffix');
      const points: Array<SteamArkMarketPriceHistoryPoint> = [];
      if (root.kind === SteamJsonValueKind.OBJECT) {
        const pricesNode: SteamJsonValue | null = root.getProperty('prices');
        if (pricesNode !== null && pricesNode.kind === SteamJsonValueKind.ARRAY) {
          for (let index = 0; index < pricesNode.items.length; index++) {
            const entry: SteamJsonValue = pricesNode.items[index];
            if (entry.kind !== SteamJsonValueKind.ARRAY || entry.items.length < 3) {
              continue;
            }
            const dateText: string = entry.items[0].kind === SteamJsonValueKind.STRING
              ? entry.items[0].stringValue : '';
            const rawPrice: string = entry.items[1].kind === SteamJsonValueKind.NUMBER
              ? entry.items[1].numberValue : '';
            const rawVolume: string = entry.items[2].kind === SteamJsonValueKind.STRING
              ? entry.items[2].stringValue : '';
            const epochSeconds: number = this.parseMarketDateEpochSeconds(dateText);
            const minorUnits: number = rawPrice.length > 0 ? this.parseMinorUnits(rawPrice) : -1;
            if (epochSeconds > 0 && this.isValidMinorUnits(minorUnits)) {
              points.push(new SteamArkMarketPriceHistoryPoint(
                epochSeconds, minorUnits, this.parseVolumeCount(rawVolume)));
            }
          }
        }
      }
      return new SteamArkMarketPriceHistory(success && points.length > 0, pricePrefix,
        priceSuffix, points);
    } catch (_error) {
      return null;
    }
  }

  private readHistoryCache(cacheKey: string): SteamArkMarketPriceHistory | null {
    const raw: string = ngfContentCacheFacade.get(cacheKey);
    if (raw.length <= 0) {
      return null;
    }
    try {
      const root: SteamJsonValue = SteamJsonParser.parse(raw, steamArkCoreLogger);
      if (root.kind !== SteamJsonValueKind.OBJECT) {
        return null;
      }
      const prefix: string = this.readString(root, 'prefix');
      const suffix: string = this.readString(root, 'suffix');
      const pointsNode: SteamJsonValue | null = root.getProperty('points');
      const points: Array<SteamArkMarketPriceHistoryPoint> = [];
      if (pointsNode !== null && pointsNode.kind === SteamJsonValueKind.ARRAY) {
        for (let index = 0; index < pointsNode.items.length; index++) {
          const entry: SteamJsonValue = pointsNode.items[index];
          if (entry.kind !== SteamJsonValueKind.ARRAY || entry.items.length < 3) {
            continue;
          }
          const epoch: number = Number(entry.items[0].kind === SteamJsonValueKind.NUMBER
            ? entry.items[0].numberValue : '');
          const minor: number = Number(entry.items[1].kind === SteamJsonValueKind.NUMBER
            ? entry.items[1].numberValue : '');
          const volume: number = Number(entry.items[2].kind === SteamJsonValueKind.NUMBER
            ? entry.items[2].numberValue : '');
          if (Number.isSafeInteger(epoch) && epoch > 0 && this.isValidMinorUnits(minor)) {
            points.push(new SteamArkMarketPriceHistoryPoint(epoch, minor, volume));
          }
        }
      }
      if (points.length <= 0) {
        return null;
      }
      return new SteamArkMarketPriceHistory(true, prefix, suffix, points);
    } catch (_error) {
      return null;
    }
  }

  private writeHistoryCache(cacheKey: string, history: SteamArkMarketPriceHistory): void {
    const points: Array<Array<number>> = [];
    for (let index = 0; index < history.points.length; index++) {
      const point: SteamArkMarketPriceHistoryPoint = history.points[index];
      points.push([point.epochSeconds, point.minorUnits, point.volumeCount]);
    }
    const payload: string = JSON.stringify({
      prefix: history.pricePrefix,
      suffix: history.priceSuffix,
      points: points
    });
    ngfContentCacheFacade.put(cacheKey, payload, HISTORY_CACHE_TTL_MS);
  }

  private async fetchPriceHistoryUncached(account: SteamAccountProfile, appId: string,
    marketHashName: string): Promise<SteamArkMarketPriceHistory | null> {
    const encodedName: string = encodeURIComponent(marketHashName);
    const url: string = 'https://steamcommunity.com/market/pricehistory/?appid=' + appId +
      '&market_hash_name=' + encodedName;
    const session = new NGFHttpSession();
    const headers = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('SteamMarketPriceHistory'));
    try {
      await SteamArkMarketPriceService.paceMarketRequest();
      let response = await session.request(new NGFHttpSessionRequest(
        NGFHttpMethod.GET, url, headers, '', 15000, false, this.toProxy(account)
      ));
      if (!response.isOk() && this.toProxy(account).mode === NGFProxyMode.SYSTEM) {
        response = await session.request(new NGFHttpSessionRequest(
          NGFHttpMethod.GET, url, headers, '', 15000, false, NGFProxyConfiguration.direct()
        ));
      }
      if (!response.isOk()) {
        throw new Error('market price history HTTP ' + response.statusCode.toString());
      }
      return this.parsePriceHistoryBody(response.body);
    } catch (error) {
      SteamArkLog.warn(TAG, 'market price history failed; appId=' + appId +
        ', errorType=' + SteamArkLog.errorKind(error));
      return null;
    } finally {
      session.clear();
    }
  }

  private async fetchOne(account: SteamAccountProfile, accountId: string, appId: string, marketHashName: string,
    currencyId: number, currencyCode: string, cacheGeneration: number,
    credentials: SteamCredentialSet | null = null, proxyPassword: string = ''): Promise<SteamArkMarketPrice | null> {
    if (!SteamArkMarketPriceService.isGenerationCurrent(accountId, cacheGeneration)) {
      return null;
    }
    const encodedName: string = encodeURIComponent(marketHashName);
    const url: string = 'https://steamcommunity.com/market/priceoverview/?appid=' + appId +
      '&currency=' + currencyId.toString() + '&market_hash_name=' + encodedName;
    const now: number = Math.floor(Date.now() / 1000);
    let body: string | null = null;
    if (credentials !== null) {
      await SteamArkMarketPriceService.paceMarketRequest();
      if (SteamArkMarketPriceService.isMarketRateLimited()) {
        SteamArkLog.info(TAG, 'market price paused; rate limited by Steam');
        return null;
      }
      body = await this.authenticatedMarketGet(url, account, credentials, proxyPassword);
    }
    if (body === null) {
      const session = new NGFHttpSession();
      const headers = new Map<string, string>();
      headers.set('Accept', 'application/json');
      headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('SteamMarketPrice'));
      try {
        let response = await session.request(new NGFHttpSessionRequest(
          NGFHttpMethod.GET, url, headers, '', 15000, false, this.toProxy(account)
        ));
        if (response.statusCode === RATE_LIMIT_HTTP_STATUS) {
          SteamArkMarketPriceService.markMarketRateLimited();
          SteamArkLog.warn(TAG, 'market price rate limited by Steam; pausing lookups');
          return null;
        }
        if (!response.isOk() && response.statusCode !== RATE_LIMIT_HTTP_STATUS &&
          this.toProxy(account).mode === NGFProxyMode.SYSTEM) {
          response = await session.request(new NGFHttpSessionRequest(
            NGFHttpMethod.GET, url, headers, '', 15000, false, NGFProxyConfiguration.direct()
          ));
          if (response.statusCode === RATE_LIMIT_HTTP_STATUS) {
            SteamArkMarketPriceService.markMarketRateLimited();
            SteamArkLog.warn(TAG, 'market price rate limited by Steam (direct); pausing lookups');
            return null;
          }
        }
        if (!response.isOk()) {
          throw new Error('market price HTTP ' + response.statusCode.toString());
        }
        body = response.body;
      } catch (error) {
        if (!SteamArkMarketPriceService.isGenerationCurrent(accountId, cacheGeneration)) {
          return null;
        }
        SteamArkLog.warn(TAG, 'market price lookup failed; appId=' + appId + ', errorType=' + SteamArkLog.errorKind(error));
        const failed = new SteamArkMarketPrice(accountId, appId, marketHashName, currencyId,
          currencyCode, '', '', 0, 0, now, false);
        return this.writeCached(failed, FAILED_PRICE_TTL_MS, cacheGeneration) ? failed : null;
      } finally {
        session.clear();
      }
    }
    try {
      if (body === null) {
        throw new Error('market price body missing');
      }
      const root: SteamJsonValue = SteamJsonParser.parse(body, steamArkCoreLogger);
      const success: boolean = this.readBoolean(root, 'success');
      const rawLowest: string = this.readString(root, 'lowest_price');
      const rawMedian: string = this.readString(root, 'median_price');
      const parsedLowestMinorUnits: number = this.parseMinorUnits(rawLowest);
      const parsedMedianMinorUnits: number = this.parseMinorUnits(rawMedian);
      const lowestUsable: boolean = this.isUsablePriceText(rawLowest) &&
        this.isValidMinorUnits(parsedLowestMinorUnits);
      const medianUsable: boolean = this.isUsablePriceText(rawMedian) &&
        this.isValidMinorUnits(parsedMedianMinorUnits);
      const lowest: string = lowestUsable ? rawLowest : '';
      const median: string = medianUsable ? rawMedian : '';
      const lowestMinorUnits: number = lowestUsable ? parsedLowestMinorUnits : 0;
      const medianMinorUnits: number = medianUsable ? parsedMedianMinorUnits : 0;
      const available: boolean = success && lowestUsable;
      const volumeCount: number = this.parseVolumeCount(this.readString(root, 'volume'));
      const result = new SteamArkMarketPrice(accountId, appId, marketHashName, currencyId,
        currencyCode, lowest, median, lowestMinorUnits, medianMinorUnits, now,
        available, volumeCount);
      return this.writeCached(result, available ? PRICE_TTL_MS : FAILED_PRICE_TTL_MS, cacheGeneration)
        ? result : null;
    } catch (error) {
      if (!SteamArkMarketPriceService.isGenerationCurrent(accountId, cacheGeneration)) {
        return null;
      }
      SteamArkLog.warn(TAG, 'market price lookup failed; appId=' + appId + ', errorType=' + SteamArkLog.errorKind(error));
      const failed = new SteamArkMarketPrice(accountId, appId, marketHashName, currencyId,
        currencyCode, '', '', 0, 0, now, false);
      return this.writeCached(failed, FAILED_PRICE_TTL_MS, cacheGeneration) ? failed : null;
    }
  }

  private readString(root: SteamJsonValue, key: string): string {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      return '';
    }
    const value: SteamJsonValue | null = root.getProperty(key);
    return value !== null && value.kind === SteamJsonValueKind.STRING ? value.stringValue.trim() : '';
  }

  private readBoolean(root: SteamJsonValue, key: string): boolean {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      return false;
    }
    const value: SteamJsonValue | null = root.getProperty(key);
    return value !== null && value.kind === SteamJsonValueKind.BOOLEAN && value.booleanValue;
  }

  private readCached(accountId: string, appId: string, marketHashName: string, currencyId: number,
    cacheGeneration: number): SteamArkMarketPrice | null {
    if (!SteamArkMarketPriceService.isGenerationCurrent(accountId, cacheGeneration)) {
      return null;
    }
    const cacheKey: string = SteamArkMarketPriceService.priceCacheKey(
      accountId, appId, marketHashName, currencyId, cacheGeneration
    );
    const serialized: string = ngfContentCacheFacade.get(cacheKey);
    if (serialized.length <= 0) {
      return null;
    }
    try {
      const root: SteamJsonValue = SteamJsonParser.parse(serialized, steamArkCoreLogger);
      if (root.kind !== SteamJsonValueKind.OBJECT) {
        throw new Error('market price cache root is not an object');
      }
      const cachedAccountId: string = this.readString(root, 'accountId');
      const cachedAppId: string = this.readString(root, 'appId');
      const cachedMarketHashName: string = this.readString(root, 'marketHashName');
      const cachedCurrencyId: number = this.readNumber(root, 'currencyId');
      const fetchedAtEpochSeconds: number = this.readNumber(root, 'fetchedAtEpochSeconds');
      if (cachedAccountId !== accountId || cachedAppId !== appId || cachedMarketHashName !== marketHashName ||
        cachedCurrencyId !== currencyId || !Number.isSafeInteger(fetchedAtEpochSeconds) ||
        fetchedAtEpochSeconds <= 0) {
        throw new Error('market price cache metadata is invalid');
      }
      const cachedCurrencyCode: string = this.readString(root, 'currencyCode');
      const cachedLowestPriceText: string = this.readString(root, 'lowestPriceText');
      const cachedMedianPriceText: string = this.readString(root, 'medianPriceText');
      const cachedAvailable: boolean = this.readBoolean(root, 'available');
      const cachedVolumeCount: number = this.readNumber(root, 'volumeCount');
      const cachedLowestMinorUnits: number = this.parseMinorUnits(cachedLowestPriceText);
      const cachedMedianMinorUnits: number = this.parseMinorUnits(cachedMedianPriceText);
      if (cachedCurrencyCode !== this.currencyCode(cachedCurrencyId)) {
        throw new Error('market price cache currency is invalid');
      }
      if (cachedAvailable && (!this.isUsablePriceText(cachedLowestPriceText) ||
        !this.isValidMinorUnits(cachedLowestMinorUnits))) {
        throw new Error('market price cache value is invalid');
      }
      return new SteamArkMarketPrice(
        cachedAccountId,
        cachedAppId,
        cachedMarketHashName,
        cachedCurrencyId,
        cachedCurrencyCode,
        cachedAvailable ? cachedLowestPriceText : '',
        this.isUsablePriceText(cachedMedianPriceText) && this.isValidMinorUnits(cachedMedianMinorUnits)
          ? cachedMedianPriceText : '',
        cachedAvailable ? cachedLowestMinorUnits : 0,
        this.isUsablePriceText(cachedMedianPriceText) && this.isValidMinorUnits(cachedMedianMinorUnits)
          ? cachedMedianMinorUnits : 0,
        fetchedAtEpochSeconds,
        cachedAvailable,
        cachedVolumeCount
      );
    } catch (error) {
      ngfContentCacheFacade.remove(cacheKey);
      return null;
    }
  }

  private writeCached(price: SteamArkMarketPrice, ttlMs: number, cacheGeneration: number): boolean {
    if (!SteamArkMarketPriceService.isGenerationCurrent(price.accountId, cacheGeneration)) {
      return false;
    }
    const cacheKey: string = SteamArkMarketPriceService.priceCacheKey(
      price.accountId, price.appId, price.marketHashName, price.currencyId, cacheGeneration
    );
    const indexCacheKey: string = SteamArkMarketPriceService.indexCacheKey(price.accountId, cacheGeneration);
    if (!SteamArkMarketPriceService.trackCacheKey(price.accountId, cacheGeneration, indexCacheKey, cacheKey)) {
      return false;
    }
    if (!SteamArkMarketPriceService.isGenerationCurrent(price.accountId, cacheGeneration)) {
      return false;
    }
    const record = new SteamArkMarketPriceCacheRecord(
      price.accountId,
      price.appId,
      price.marketHashName,
      price.currencyId,
      price.currencyCode,
      price.lowestPriceText,
      price.medianPriceText,
      price.lowestMinorUnits,
      price.medianMinorUnits,
      price.fetchedAtEpochSeconds,
      price.available,
      price.volumeCount
    );
    ngfContentCacheFacade.put(cacheKey, JSON.stringify(record), ttlMs);
    return SteamArkMarketPriceService.isGenerationCurrent(price.accountId, cacheGeneration);
  }

  private readNumber(root: SteamJsonValue, key: string): number {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      return 0;
    }
    const value: SteamJsonValue | null = root.getProperty(key);
    if (value === null) {
      return 0;
    }
    if (value.kind === SteamJsonValueKind.NUMBER) {
      return Number(value.numberValue);
    }
    if (value.kind === SteamJsonValueKind.STRING) {
      return Number(value.stringValue);
    }
    return 0;
  }

  private static accountGeneration(accountId: string): number {
    const inMemory: number | undefined = SteamArkMarketPriceService.accountGenerations.get(accountId);
    if (inMemory !== undefined) {
      return inMemory;
    }
    const serialized: string = ngfContentCacheFacade.get(
      SteamArkMarketPriceService.generationCacheKey(accountId)
    ).trim();
    const parsed: number = Number(serialized);
    const generation: number = Number.isFinite(parsed) && parsed >= DEFAULT_CACHE_GENERATION &&
      Math.floor(parsed) === parsed ? parsed : DEFAULT_CACHE_GENERATION;
    SteamArkMarketPriceService.accountGenerations.set(accountId, generation);
    if (serialized.length <= 0 || generation !== parsed) {
      ngfContentCacheFacade.put(
        SteamArkMarketPriceService.generationCacheKey(accountId),
        generation.toString(),
        0
      );
    }
    return generation;
  }

  private static isGenerationCurrent(accountId: string, generation: number): boolean {
    return SteamArkMarketPriceService.accountGeneration(accountId) === generation;
  }

  private static trackCacheKey(accountId: string, generation: number, indexCacheKey: string, cacheKey: string): boolean {
    if (!SteamArkMarketPriceService.isGenerationCurrent(accountId, generation)) {
      return false;
    }
    const cachedKeys: Array<string> = SteamArkMarketPriceService.readIndexedCacheKeys(indexCacheKey);
    let alreadyTracked: boolean = false;
    for (let index: number = 0; index < cachedKeys.length; index++) {
      if (cachedKeys[index] === cacheKey) {
        alreadyTracked = true;
        break;
      }
    }
    if (!alreadyTracked) {
      cachedKeys.push(cacheKey);
      ngfContentCacheFacade.put(indexCacheKey, cachedKeys.join('\n'), 0);
    }
    return SteamArkMarketPriceService.isGenerationCurrent(accountId, generation);
  }

  private static readIndexedCacheKeys(indexCacheKey: string): Array<string> {
    const serialized: string = ngfContentCacheFacade.get(indexCacheKey).trim();
    const cachedKeys: Array<string> = [];
    if (serialized.length <= 0) {
      return cachedKeys;
    }
    const candidates: Array<string> = serialized.split('\n');
    for (let index: number = 0; index < candidates.length; index++) {
      const candidate: string = candidates[index].trim();
      if (candidate.length <= 0) {
        continue;
      }
      let duplicate: boolean = false;
      for (let existingIndex: number = 0; existingIndex < cachedKeys.length; existingIndex++) {
        if (cachedKeys[existingIndex] === candidate) {
          duplicate = true;
          break;
        }
      }
      if (!duplicate) {
        cachedKeys.push(candidate);
      }
    }
    return cachedKeys;
  }

  private static generationCacheKey(accountId: string): string {
    return CACHE_NAMESPACE + '.generation.' + encodeURIComponent(accountId);
  }

  private static indexCacheKey(accountId: string, generation: number): string {
    return CACHE_NAMESPACE + '.index.' + encodeURIComponent(accountId) + '.g' + generation.toString();
  }

  private static priceCacheKey(accountId: string, appId: string, marketHashName: string, currencyId: number,
    generation: number): string {
    return CACHE_NAMESPACE + '.entry.' + encodeURIComponent(accountId) + '.g' + generation.toString() + '.' +
      currencyId.toString() + '.' + encodeURIComponent(appId) + '.' + encodeURIComponent(marketHashName);
  }

  private currencyId(value: string): number {
    // Steam market currency enum: 1=USD, 2=GBP, 3=EUR, 5=RUB, 7=BRL, 8=JPY,
    // 16=KRW, 23=CNY, 29=HKD, 30=TWD.
    const normalized: string = value.trim().toUpperCase();
    if (normalized.indexOf('JPY') >= 0) return 8;
    if (normalized.indexOf('RUB') >= 0) return 5;
    if (normalized.indexOf('CNY') >= 0 || normalized.indexOf('RMB') >= 0 || normalized.indexOf('¥') >= 0) return 23;
    if (normalized.indexOf('KRW') >= 0) return 16;
    if (normalized.indexOf('HKD') >= 0) return 29;
    if (normalized.indexOf('TWD') >= 0) return 30;
    if (normalized.indexOf('BRL') >= 0) return 7;
    if (normalized.indexOf('EUR') >= 0 || normalized.indexOf('€') >= 0) return 3;
    if (normalized.indexOf('GBP') >= 0 || normalized.indexOf('£') >= 0) return 2;
    return 1;
  }

  private currencyCode(currencyId: number): string {
    switch (currencyId) {
      case 23: return 'CNY';
      case 16: return 'KRW';
      case 29: return 'HKD';
      case 30: return 'TWD';
      case 7: return 'BRL';
      case 3: return 'EUR';
      case 2: return 'GBP';
      case 5: return 'RUB';
      case 8: return 'JPY';
      default: return 'USD';
    }
  }

  private parseMinorUnits(value: string): number {
    const normalized: string = value.replace(/[^0-9,.-]/g, '').trim();
    if (normalized.length <= 0) return 0;
    const lastDot: number = normalized.lastIndexOf('.');
    const lastComma: number = normalized.lastIndexOf(',');
    let decimalSeparator: string = '';
    if (lastDot >= 0 && lastComma >= 0) decimalSeparator = lastDot > lastComma ? '.' : ',';
    else if (lastDot >= 0 && normalized.length - lastDot - 1 <= 2) decimalSeparator = '.';
    else if (lastComma >= 0 && normalized.length - lastComma - 1 <= 2) decimalSeparator = ',';
    let canonical: string = normalized;
    if (decimalSeparator.length > 0) {
      const decimalIndex: number = normalized.lastIndexOf(decimalSeparator);
      canonical = normalized.substring(0, decimalIndex).replace(/[.,]/g, '') + '.' + normalized.substring(decimalIndex + 1).replace(/[.,]/g, '');
    } else {
      canonical = normalized.replace(/[.,]/g, '');
    }
    const parsed: number = Number(canonical);
    if (!Number.isFinite(parsed) || parsed < 0) {
      return -1;
    }
    const minorUnits: number = Math.round(parsed * 100);
    return this.isValidMinorUnits(minorUnits) ? minorUnits : -1;
  }

  private isUsablePriceText(value: string): boolean {
    const normalized: string = value.trim();
    return normalized.toLowerCase().indexOf('[object object]') < 0 && /[0-9]/.test(normalized);
  }

  private isValidMinorUnits(value: number): boolean {
    return Number.isSafeInteger(value) && value >= 0;
  }

  /** Parses a pricehistory volume bucket such as "12" or "1,234". */
  private parseVolumeCount(value: string): number {
    const normalized: string = value.replace(/[^0-9]/g, '');
    if (normalized.length <= 0) {
      return 0;
    }
    const parsed: number = Number(normalized);
    return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
  }

  /**
   * Parses Steam's pricehistory timestamp like "Aug 17 2025 01: +0" into
   * UTC epoch seconds. The trailing value is the timezone offset of the
   * timestamp, so the local wall clock is shifted back to UTC.
   */
  private parseMarketDateEpochSeconds(value: string): number {
    const match: RegExpExecArray | null = /^([A-Za-z]{3})\s+(\d{1,2})\s+(\d{4})\s+(\d{1,2}):\s*([+-]\d+)$/.exec(value.trim());
    if (match === null) {
      return 0;
    }
    const month: number = this.marketMonthIndex(match[1]);
    const day: number = Number(match[2]);
    const year: number = Number(match[3]);
    const hour: number = Number(match[4]);
    const offsetHours: number = Number(match[5]);
    if (month < 0 || !Number.isFinite(day) || !Number.isFinite(year) ||
      !Number.isFinite(hour) || !Number.isFinite(offsetHours)) {
      return 0;
    }
    const epochMs: number = Date.UTC(year, month, day, hour, 0, 0) - offsetHours * 3600 * 1000;
    const epochSeconds: number = Math.floor(epochMs / 1000);
    return Number.isSafeInteger(epochSeconds) && epochSeconds > 0 ? epochSeconds : 0;
  }

  private marketMonthIndex(name: string): number {
    const normalized: string = name.trim().toLowerCase();
    if (normalized === 'jan') return 0;
    if (normalized === 'feb') return 1;
    if (normalized === 'mar') return 2;
    if (normalized === 'apr') return 3;
    if (normalized === 'may') return 4;
    if (normalized === 'jun') return 5;
    if (normalized === 'jul') return 6;
    if (normalized === 'aug') return 7;
    if (normalized === 'sep') return 8;
    if (normalized === 'oct') return 9;
    if (normalized === 'nov') return 10;
    if (normalized === 'dec') return 11;
    return -1;
  }

  private toProxy(profile: SteamAccountProfile): NGFProxyConfiguration {
    if (profile.proxy.kind === SteamProxyKind.DIRECT) return NGFProxyConfiguration.direct();
    if (profile.proxy.kind === SteamProxyKind.HTTP) return NGFProxyConfiguration.http(profile.proxy.host, profile.proxy.port, profile.proxy.username, '');
    if (profile.proxy.kind === SteamProxyKind.SOCKS5) return NGFProxyConfiguration.socks5(profile.proxy.host, profile.proxy.port, profile.proxy.username, '');
    return NGFProxyConfiguration.system();
  }
}
