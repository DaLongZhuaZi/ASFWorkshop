import {
  NGFHttpMethod,
  NGFHttpSession,
  NGFHttpSessionRequest,
  NGFProxyConfiguration,
  NGFProxyMode,
  ngfContentCacheFacade
} from 'ngf_framework';
import { SteamAccountProfile, SteamInventoryItem, SteamJsonParser, SteamJsonValue, SteamJsonValueKind, SteamProxyKind } from 'steam_core';
import { SteamArkLog } from './SteamArkLogger';
import { steamArkCoreLogger } from './SteamArkCoreLogger';
import { ASFWorkshopProductIdentity } from './ASFWorkshopProductIdentity';

const TAG: string = 'SteamArkMarketPriceService';
const PRICE_TTL_MS: number = 6 * 60 * 60 * 1000;
const FAILED_PRICE_TTL_MS: number = 10 * 60 * 1000;
const CACHE_NAMESPACE: string = 'steam.market.price.v2';
const DEFAULT_CACHE_GENERATION: number = 1;

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

  constructor(accountId: string, appId: string, marketHashName: string, currencyId: number,
    currencyCode: string, lowestPriceText: string, medianPriceText: string,
    lowestMinorUnits: number, medianMinorUnits: number, fetchedAtEpochSeconds: number,
    available: boolean) {
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

  constructor(accountId: string, appId: string, marketHashName: string, currencyId: number,
    currencyCode: string, lowestPriceText: string, medianPriceText: string,
    lowestMinorUnits: number, medianMinorUnits: number, fetchedAtEpochSeconds: number,
    available: boolean) {
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
  }
}

export class SteamArkMarketPriceService {
  private static readonly accountGenerations: Map<string, number> = new Map<string, number>();

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

  async loadBatch(account: SteamAccountProfile, items: Array<SteamInventoryItem>): Promise<SteamArkMarketPriceBatch> {
    const accountId: string = account.accountId.trim();
    const currencyId: number = this.currencyId(account.walletCurrency);
    const currencyCode: string = this.currencyCode(currencyId);
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
      networkRequestCount += 1;
      const fetched: SteamArkMarketPrice | null = await this.fetchOne(
        account, accountId, item.appId, marketHashName, currencyId, currencyCode, cacheGeneration
      );
      if (fetched !== null && SteamArkMarketPriceService.isGenerationCurrent(accountId, cacheGeneration)) {
        prices.push(fetched);
      }
    }
    return new SteamArkMarketPriceBatch(prices, currencyId, currencyCode);
  }

  private async fetchOne(account: SteamAccountProfile, accountId: string, appId: string, marketHashName: string,
    currencyId: number, currencyCode: string, cacheGeneration: number): Promise<SteamArkMarketPrice | null> {
    if (!SteamArkMarketPriceService.isGenerationCurrent(accountId, cacheGeneration)) {
      return null;
    }
    const encodedName: string = encodeURIComponent(marketHashName);
    const url: string = 'https://steamcommunity.com/market/priceoverview/?appid=' + appId +
      '&currency=' + currencyId.toString() + '&market_hash_name=' + encodedName;
    const session = new NGFHttpSession();
    const headers = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('SteamMarketPrice'));
    const now: number = Math.floor(Date.now() / 1000);
    try {
      let response = await session.request(new NGFHttpSessionRequest(
        NGFHttpMethod.GET, url, headers, '', 15000, false, this.toProxy(account)
      ));
      if (!response.isOk() && this.toProxy(account).mode === NGFProxyMode.SYSTEM) {
        response = await session.request(new NGFHttpSessionRequest(
          NGFHttpMethod.GET, url, headers, '', 15000, false, NGFProxyConfiguration.direct()
        ));
      }
      if (!response.isOk()) {
        throw new Error('market price HTTP ' + response.statusCode.toString());
      }
      const root: SteamJsonValue = SteamJsonParser.parse(response.body, steamArkCoreLogger);
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
      const result = new SteamArkMarketPrice(accountId, appId, marketHashName, currencyId,
        currencyCode, lowest, median, lowestMinorUnits, medianMinorUnits, now,
        available);
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
    } finally {
      session.clear();
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
        cachedAvailable
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
      price.available
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
    const normalized: string = value.trim().toUpperCase();
    if (normalized.indexOf('JPY') >= 0) return 5;
    if (normalized.indexOf('CNY') >= 0 || normalized.indexOf('RMB') >= 0 || normalized.indexOf('¥') >= 0) return 23;
    if (normalized.indexOf('EUR') >= 0 || normalized.indexOf('€') >= 0) return 3;
    if (normalized.indexOf('GBP') >= 0 || normalized.indexOf('£') >= 0) return 2;
    return 1;
  }

  private currencyCode(currencyId: number): string {
    switch (currencyId) {
      case 23: return 'CNY';
      case 3: return 'EUR';
      case 2: return 'GBP';
      case 5: return 'JPY';
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

  private toProxy(profile: SteamAccountProfile): NGFProxyConfiguration {
    if (profile.proxy.kind === SteamProxyKind.DIRECT) return NGFProxyConfiguration.direct();
    if (profile.proxy.kind === SteamProxyKind.HTTP) return NGFProxyConfiguration.http(profile.proxy.host, profile.proxy.port, profile.proxy.username, '');
    if (profile.proxy.kind === SteamProxyKind.SOCKS5) return NGFProxyConfiguration.socks5(profile.proxy.host, profile.proxy.port, profile.proxy.username, '');
    return NGFProxyConfiguration.system();
  }
}
