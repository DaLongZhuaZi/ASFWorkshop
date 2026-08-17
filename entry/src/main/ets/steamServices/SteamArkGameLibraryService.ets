import { ngfContentCacheFacade, ngfSettingsStoreFacade } from 'ngf_framework';
import {
  SteamAccountProfile,
  SteamCredentialSet,
  SteamGameAchievementInfo,
  SteamGameAchievementsResult,
  SteamGameDetailBundle,
  SteamGameDetailCategory,
  SteamGameDetailInfo,
  SteamGameLibraryResult,
  SteamGameNewsItem,
  SteamLibraryGame,
  SteamSessionState
} from 'steam_core';
import {
  ISteamArkGameLibraryAdapter,
  ISteamArkGameLibraryAdapterFactory,
  SteamArkGameLibrarySnapshot,
  SteamArkGameLibrarySnapshotListener
} from './SteamArkGameLibraryContracts';
import { SteamArkAccountSnapshot, SteamArkStateSnapshot, steamArkStateService } from './SteamArkStateService';
import { SteamArkLog } from './SteamArkLogger';

const TAG: string = 'SteamArkGameLibraryService';
const CACHE_NAMESPACE: string = 'steam-ark-library-v1';
/** Detail bundles are cached per account+language+app so reopening is instant. */
const DETAIL_CACHE_PREFIX: string = 'steam-ark-game-detail-v1';
const DETAIL_CACHE_TTL_MS: number = 30 * 60 * 1000;

interface SteamArkLibraryCacheItem {
  appId: string;
  name: string;
  logoUrl: string;
  iconUrl: string;
  playtimeForeverSeconds: number;
  playtimeTwoWeeksSeconds: number;
  lastPlayedEpochSeconds: number;
  favorite: boolean;
}

interface SteamArkLibraryCacheDocument {
  accountId: string;
  updatedAtEpochSeconds: number;
  games: Array<SteamArkLibraryCacheItem>;
}

/** Serializable shape of a cached SteamGameDetailBundle. */
interface SteamArkDetailCategoryJson {
  id: string;
  description: string;
}

interface SteamArkDetailInfoJson {
  appId: string;
  name: string;
  headerImageUrl: string;
  capsuleImageUrl: string;
  shortDescription: string;
  detailedDescription: string;
  developers: Array<string>;
  publishers: Array<string>;
  releaseDateText: string;
  genres: Array<string>;
  categories: Array<SteamArkDetailCategoryJson>;
  isFree: boolean;
}

interface SteamArkDetailNewsJson {
  gid: string;
  title: string;
  url: string;
  author: string;
  dateEpochSeconds: number;
  contents: string;
  feedLabel: string;
}

interface SteamArkDetailAchievementJson {
  apiName: string;
  name: string;
  achieved: boolean;
  unlockTimeEpochSeconds: number;
  description: string;
  iconUrl: string;
}

interface SteamArkDetailAchievementsJson {
  totalCount: number;
  unlockedCount: number;
  achievements: Array<SteamArkDetailAchievementJson>;
}

interface SteamArkDetailBundleJson {
  info: SteamArkDetailInfoJson | null;
  news: Array<SteamArkDetailNewsJson>;
  achievements: SteamArkDetailAchievementsJson | null;
}

interface SteamArkDetailCacheDocument {
  accountId: string;
  appId: string;
  language: string;
  updatedAtEpochSeconds: number;
  bundle: SteamArkDetailBundleJson;
}

/** A ready adapter plus the account's resolved Steam language. */
interface SteamArkPreparedLibraryAdapter {
  adapter: ISteamArkGameLibraryAdapter;
  language: string;
}

/**
 * Owns each account's Steam game library: adapter lifecycle, one coalesced
 * sync task per account, a persisted cache and snapshot listeners for the UI.
 */
export class SteamArkGameLibraryService {
  private adapterFactory: ISteamArkGameLibraryAdapterFactory | null = null;
  private readonly adapters: Map<string, ISteamArkGameLibraryAdapter> = new Map<string, ISteamArkGameLibraryAdapter>();
  private readonly snapshots: Map<string, SteamArkGameLibrarySnapshot> = new Map<string, SteamArkGameLibrarySnapshot>();
  private readonly listeners: Map<string, SteamArkGameLibrarySnapshotListener> =
    new Map<string, SteamArkGameLibrarySnapshotListener>();
  private readonly syncTasks: Map<string, Promise<SteamArkGameLibrarySnapshot>> =
    new Map<string, Promise<SteamArkGameLibrarySnapshot>>();
  private disposed: boolean = false;

  setAdapterFactory(factory: ISteamArkGameLibraryAdapterFactory | null): void {
    this.adapterFactory = factory;
    for (const accountId of Array.from(this.adapters.keys())) {
      const adapter = this.adapters.get(accountId);
      if (adapter !== undefined) {
        void adapter.close(accountId).catch((_error: Error): void => {
          SteamArkLog.debug(TAG, 'game library adapter close failed during factory reset; account=' +
            SteamArkLog.accountId(accountId));
        });
      }
    }
    this.adapters.clear();
    SteamArkLog.info(TAG, 'game library adapter factory configured; enabled=' + String(factory !== null));
  }

  subscribe(listenerId: string, listener: SteamArkGameLibrarySnapshotListener): void {
    this.listeners.set(listenerId, listener);
    SteamArkLog.debug(TAG, 'game library listener registered; id=' + listenerId +
      ', count=' + this.listeners.size.toString());
  }

  unsubscribe(listenerId: string): void {
    this.listeners.delete(listenerId);
    SteamArkLog.debug(TAG, 'game library listener unregistered; id=' + listenerId);
  }

  getSnapshot(accountId: string): SteamArkGameLibrarySnapshot | null {
    const snapshot = this.snapshots.get(accountId);
    return snapshot === undefined ? null : snapshot;
  }

  restore(accountId: string): SteamArkGameLibrarySnapshot | null {
    const normalizedId = accountId.trim();
    if (normalizedId.length <= 0) {
      return null;
    }
    const serialized: string = ngfSettingsStoreFacade.getString(this.cacheKey(normalizedId), '');
    if (serialized.length <= 0) {
      return null;
    }
    try {
      const document: SteamArkLibraryCacheDocument = JSON.parse(serialized) as SteamArkLibraryCacheDocument;
      const games: Array<SteamLibraryGame> = [];
      if (document.games !== undefined) {
        for (let index = 0; index < document.games.length; index++) {
          const item = document.games[index];
          if (item !== undefined && item.appId !== undefined && item.name !== undefined) {
            games.push(new SteamLibraryGame(
              item.appId,
              item.name,
              item.logoUrl === undefined ? '' : item.logoUrl,
              item.iconUrl === undefined ? '' : item.iconUrl,
              item.playtimeForeverSeconds === undefined ? 0 : item.playtimeForeverSeconds,
              item.playtimeTwoWeeksSeconds === undefined ? 0 : item.playtimeTwoWeeksSeconds,
              item.lastPlayedEpochSeconds === undefined ? 0 : item.lastPlayedEpochSeconds,
              item.favorite === undefined ? false : item.favorite
            ));
          }
        }
      }
      const snapshot = new SteamArkGameLibrarySnapshot(
        document.accountId === undefined ? normalizedId : document.accountId,
        games,
        games.length,
        document.updatedAtEpochSeconds === undefined ? 0 : document.updatedAtEpochSeconds
      );
      this.snapshots.set(normalizedId, snapshot);
      SteamArkLog.debug(TAG, 'game library cache restored; account=' + SteamArkLog.accountId(normalizedId) +
        ', games=' + games.length.toString());
      return snapshot;
    } catch (error) {
      SteamArkLog.warn(TAG, 'game library cache restore failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(error));
      return null;
    }
  }

  /** Clears the persisted and in-memory library data of one account. */
  clearCache(accountId: string): void {
    const normalizedId = accountId.trim();
    ngfSettingsStoreFacade.setString(this.cacheKey(normalizedId), '');
    this.snapshots.delete(normalizedId);
    SteamArkLog.debug(TAG, 'game library cache cleared; account=' + SteamArkLog.accountId(normalizedId));
  }

  async sync(accountId: string): Promise<SteamArkGameLibrarySnapshot> {
    const normalizedId = accountId.trim();
    if (normalizedId.length <= 0) {
      throw new Error('Steam game library account is empty');
    }
    if (this.disposed) {
      throw new Error('Steam game library service is disposed');
    }
    const existing: Promise<SteamArkGameLibrarySnapshot> | undefined = this.syncTasks.get(normalizedId);
    if (existing !== undefined) {
      return existing;
    }
    const task: Promise<SteamArkGameLibrarySnapshot> = this.syncInternal(normalizedId).finally((): void => {
      this.syncTasks.delete(normalizedId);
    });
    this.syncTasks.set(normalizedId, task);
    return task;
  }

  private async syncInternal(accountId: string): Promise<SteamArkGameLibrarySnapshot> {
    SteamArkLog.info(TAG, 'game library synchronization started; account=' + SteamArkLog.accountId(accountId));
    const cached: SteamArkGameLibrarySnapshot | null = this.restore(accountId);
    try {
      const prepared: SteamArkPreparedLibraryAdapter = await this.prepareAdapter(accountId);
      const adapter: ISteamArkGameLibraryAdapter = prepared.adapter;
      const result = await adapter.syncGameLibrary(accountId, prepared.language);
      // A CM channel that settled during the sync may already carry the more
      // complete merged library; never publish the fast result over it.
      const lateResult: SteamGameLibraryResult | null = adapter.drainPendingLibraryUpdate();
      const effectiveResult: SteamGameLibraryResult = lateResult !== null ? lateResult : result;
      const mergedGames: Array<SteamLibraryGame> = this.mergeCachedFavorites(effectiveResult.games, cached);
      const snapshot = new SteamArkGameLibrarySnapshot(
        accountId,
        mergedGames,
        effectiveResult.totalCount > 0 ? effectiveResult.totalCount : mergedGames.length,
        Math.floor(Date.now() / 1000)
      );
      this.persist(accountId, snapshot);
      this.setSnapshot(accountId, snapshot);
      SteamArkLog.info(TAG, 'game library synchronization completed; account=' +
        SteamArkLog.accountId(accountId) + ', games=' + mergedGames.length.toString());
      return snapshot;
    } catch (error) {
      const failed: SteamArkGameLibrarySnapshot = new SteamArkGameLibrarySnapshot(
        accountId,
        cached !== null ? cached.games : [],
        cached !== null ? cached.totalCount : 0,
        cached !== null ? cached.updatedAtEpochSeconds : 0,
        this.errorMessage(error)
      );
      this.setSnapshot(accountId, failed);
      SteamArkLog.warn(TAG, 'game library synchronization failed; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
      if (cached !== null) {
        // A cached library exists: keep showing it and report the soft
        // failure through the snapshot instead of throwing, so the UI can
        // stay on cached data and silently retry later.
        SteamArkLog.info(TAG, 'game library synchronization degraded; cached snapshot kept; account=' +
          SteamArkLog.accountId(accountId));
        return failed;
      }
      throw error instanceof Error ? error : new Error('Steam game library synchronization failed');
    }
  }

  /**
   * Fetches the detail bundle of one game (store info, news, achievements)
   * for the game detail page. Every section degrades independently.
   */
  async fetchGameDetail(accountId: string, appId: string): Promise<SteamGameDetailBundle> {
    const normalizedId: string = accountId.trim();
    if (normalizedId.length <= 0) {
      throw new Error('Steam game detail account is empty');
    }
    if (this.disposed) {
      throw new Error('Steam game library service is disposed');
    }
    if (appId.trim().length <= 0 || appId.trim() === '0') {
      throw new Error('Steam game detail app id is required');
    }
    const prepared: SteamArkPreparedLibraryAdapter = await this.prepareAdapter(normalizedId);
    SteamArkLog.info(TAG, 'game detail synchronization started; account=' +
      SteamArkLog.accountId(normalizedId) + ', appId=' + appId.trim());
    const bundle: SteamGameDetailBundle = await prepared.adapter.fetchGameDetail(
      normalizedId,
      appId.trim(),
      prepared.language
    );
    SteamArkLog.info(TAG, 'game detail synchronization completed; account=' +
      SteamArkLog.accountId(normalizedId) + ', appId=' + appId.trim() +
      ', infoPresent=' + String(bundle.info !== null) +
      ', news=' + bundle.news.length.toString() +
      ', achievementsPresent=' + String(bundle.achievements !== null));
    return bundle;
  }

  /**
   * Default-load + silent-refresh entry for the detail pages: returns the
   * cached bundle immediately when present (regardless of staleness) and, once
   * it is older than the TTL, refreshes in the background and reports the new
   * bundle through onRefreshed. With no cache it fetches in the foreground and
   * populates the cache.
   */
  async loadGameDetail(
    accountId: string,
    appId: string,
    onRefreshed: ((bundle: SteamGameDetailBundle) => void) | null = null
  ): Promise<SteamGameDetailBundle | null> {
    const normalizedId: string = accountId.trim();
    const normalizedAppId: string = appId.trim();
    if (normalizedId.length <= 0 || normalizedAppId.length <= 0 || normalizedAppId === '0') {
      throw new Error('Steam game detail requires an account and an app id');
    }
    const language: string = this.resolveLanguage(normalizedId);
    const cached: SteamGameDetailBundle | null = this.readDetailCache(normalizedId, normalizedAppId, language);
    if (cached !== null) {
      const ageMs: number = Date.now() - this.readDetailCacheAge(normalizedId, normalizedAppId, language);
      if (ageMs > DETAIL_CACHE_TTL_MS) {
        SteamArkLog.debug(TAG, 'game detail cache stale; silent refresh scheduled; account=' +
          SteamArkLog.accountId(normalizedId) + ', appId=' + normalizedAppId);
        void this.refreshGameDetailInBackground(normalizedId, normalizedAppId, language, onRefreshed);
      }
      return cached;
    }
    const bundle: SteamGameDetailBundle = await this.fetchGameDetail(normalizedId, normalizedAppId);
    this.writeDetailCache(normalizedId, normalizedAppId, language, bundle);
    return bundle;
  }

  /** Drops the list cache and every cached detail bundle of one account. */
  clearCachedAccount(accountId: string): void {
    const normalizedId: string = accountId.trim();
    if (normalizedId.length <= 0) {
      return;
    }
    const indexKey: string = this.detailIndexKey(normalizedId);
    const indexRaw: string = ngfContentCacheFacade.get(indexKey);
    if (indexRaw.length > 0) {
      try {
        const keys: Array<string> = JSON.parse(indexRaw) as Array<string>;
        if (keys instanceof Array) {
          for (let index = 0; index < keys.length; index++) {
            ngfContentCacheFacade.remove(keys[index]);
          }
        }
      } catch (_error) {
        SteamArkLog.warn(TAG, 'game detail cache index ignored during clear; account=' +
          SteamArkLog.accountId(normalizedId));
      }
    }
    ngfContentCacheFacade.remove(indexKey);
    void ngfSettingsStoreFacade.setStringAsync(this.cacheKey(normalizedId), '');
    this.snapshots.delete(normalizedId);
    SteamArkLog.debug(TAG, 'game library caches cleared; account=' + SteamArkLog.accountId(normalizedId));
  }

  private async refreshGameDetailInBackground(
    accountId: string,
    appId: string,
    language: string,
    onRefreshed: ((bundle: SteamGameDetailBundle) => void) | null
  ): Promise<void> {
    try {
      const bundle: SteamGameDetailBundle = await this.fetchGameDetail(accountId, appId);
      this.writeDetailCache(accountId, appId, language, bundle);
      if (onRefreshed !== null) {
        onRefreshed(bundle);
      }
      SteamArkLog.debug(TAG, 'game detail silent refresh completed; account=' +
        SteamArkLog.accountId(accountId) + ', appId=' + appId);
    } catch (error) {
      SteamArkLog.warn(TAG, 'game detail silent refresh failed; cached bundle kept; account=' +
        SteamArkLog.accountId(accountId) + ', appId=' + appId +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private resolveLanguage(accountId: string): string {
    const locale = steamArkStateService.resolveAccountLocale(accountId);
    return locale !== null ? locale.steamLanguage : 'english';
  }

  private detailCacheKey(accountId: string, appId: string, language: string): string {
    return DETAIL_CACHE_PREFIX + '.' + accountId + '.' + language + '.' + appId;
  }

  private detailIndexKey(accountId: string): string {
    return DETAIL_CACHE_PREFIX + '.index.' + accountId;
  }

  private readDetailCache(accountId: string, appId: string, language: string): SteamGameDetailBundle | null {
    try {
      const raw: string = ngfContentCacheFacade.get(this.detailCacheKey(accountId, appId, language));
      if (raw.length <= 0) {
        return null;
      }
      const document: SteamArkDetailCacheDocument = JSON.parse(raw) as SteamArkDetailCacheDocument;
      if (document === null || document.bundle === undefined ||
        document.accountId !== accountId || document.appId !== appId) {
        return null;
      }
      return SteamArkGameLibraryService.bundleFromJson(document.bundle);
    } catch (_error) {
      return null;
    }
  }

  private readDetailCacheAge(accountId: string, appId: string, language: string): number {
    try {
      const raw: string = ngfContentCacheFacade.get(this.detailCacheKey(accountId, appId, language));
      if (raw.length <= 0) {
        return 0;
      }
      const document: SteamArkDetailCacheDocument = JSON.parse(raw) as SteamArkDetailCacheDocument;
      return document.updatedAtEpochSeconds === undefined ? 0 : document.updatedAtEpochSeconds * 1000;
    } catch (_error) {
      return 0;
    }
  }

  private writeDetailCache(accountId: string, appId: string, language: string, bundle: SteamGameDetailBundle): void {
    const key: string = this.detailCacheKey(accountId, appId, language);
    const document: SteamArkDetailCacheDocument = {
      accountId: accountId,
      appId: appId,
      language: language,
      updatedAtEpochSeconds: Math.floor(Date.now() / 1000),
      bundle: SteamArkGameLibraryService.bundleToJson(bundle)
    };
    ngfContentCacheFacade.put(key, JSON.stringify(document), 0);
    const indexKey: string = this.detailIndexKey(accountId);
    let keys: Array<string> = [];
    try {
      const indexRaw: string = ngfContentCacheFacade.get(indexKey);
      if (indexRaw.length > 0) {
        const parsed: Array<string> = JSON.parse(indexRaw) as Array<string>;
        if (parsed instanceof Array) {
          keys = parsed;
        }
      }
    } catch (_error) {
      keys = [];
    }
    if (!keys.includes(key)) {
      keys.push(key);
      ngfContentCacheFacade.put(indexKey, JSON.stringify(keys), 0);
    }
  }

  private static bundleToJson(bundle: SteamGameDetailBundle): SteamArkDetailBundleJson {
    const news: Array<SteamArkDetailNewsJson> = [];
    for (let index = 0; index < bundle.news.length; index++) {
      const item: SteamGameNewsItem = bundle.news[index];
      news.push({
        gid: item.gid,
        title: item.title,
        url: item.url,
        author: item.author,
        dateEpochSeconds: item.dateEpochSeconds,
        contents: item.contents,
        feedLabel: item.feedLabel
      });
    }
    let achievements: SteamArkDetailAchievementsJson | null = null;
    if (bundle.achievements !== null) {
      const rows: Array<SteamArkDetailAchievementJson> = [];
      const source: SteamGameAchievementsResult = bundle.achievements;
      for (let index = 0; index < source.achievements.length; index++) {
        const row: SteamGameAchievementInfo = source.achievements[index];
        rows.push({
          apiName: row.apiName,
          name: row.name,
          achieved: row.achieved,
          unlockTimeEpochSeconds: row.unlockTimeEpochSeconds,
          description: row.description,
          iconUrl: row.iconUrl
        });
      }
      achievements = {
        totalCount: source.totalCount,
        unlockedCount: source.unlockedCount,
        achievements: rows
      };
    }
    let info: SteamArkDetailInfoJson | null = null;
    if (bundle.info !== null) {
      const source: SteamGameDetailInfo = bundle.info;
      const categories: Array<SteamArkDetailCategoryJson> = [];
      for (let index = 0; index < source.categories.length; index++) {
        categories.push({
          id: source.categories[index].id,
          description: source.categories[index].description
        });
      }
      info = {
        appId: source.appId,
        name: source.name,
        headerImageUrl: source.headerImageUrl,
        capsuleImageUrl: source.capsuleImageUrl,
        shortDescription: source.shortDescription,
        detailedDescription: source.detailedDescription,
        developers: source.developers.slice(),
        publishers: source.publishers.slice(),
        releaseDateText: source.releaseDateText,
        genres: source.genres.slice(),
        categories: categories,
        isFree: source.isFree
      };
    }
    return { info: info, news: news, achievements: achievements };
  }

  private static bundleFromJson(value: SteamArkDetailBundleJson): SteamGameDetailBundle {
    let info: SteamGameDetailInfo | null = null;
    if (value.info !== null && value.info !== undefined) {
      const source: SteamArkDetailInfoJson = value.info;
      const categories: Array<SteamGameDetailCategory> = [];
      if (source.categories !== undefined) {
        for (let index = 0; index < source.categories.length; index++) {
          categories.push(new SteamGameDetailCategory(
            source.categories[index].id, source.categories[index].description));
        }
      }
      info = new SteamGameDetailInfo(
        source.appId,
        source.name,
        source.headerImageUrl,
        source.capsuleImageUrl,
        source.shortDescription,
        source.detailedDescription,
        source.developers === undefined ? [] : source.developers,
        source.publishers === undefined ? [] : source.publishers,
        source.releaseDateText,
        source.genres === undefined ? [] : source.genres,
        categories,
        source.isFree
      );
    }
    const news: Array<SteamGameNewsItem> = [];
    if (value.news !== undefined) {
      for (let index = 0; index < value.news.length; index++) {
        const item: SteamArkDetailNewsJson = value.news[index];
        news.push(new SteamGameNewsItem(
          item.gid, item.title, item.url, item.author,
          item.dateEpochSeconds, item.contents, item.feedLabel));
      }
    }
    let achievements: SteamGameAchievementsResult | null = null;
    if (value.achievements !== null && value.achievements !== undefined) {
      const source: SteamArkDetailAchievementsJson = value.achievements;
      const rows: Array<SteamGameAchievementInfo> = [];
      if (source.achievements !== undefined) {
        for (let index = 0; index < source.achievements.length; index++) {
          const row: SteamArkDetailAchievementJson = source.achievements[index];
          rows.push(new SteamGameAchievementInfo(
            row.name, row.achieved, row.unlockTimeEpochSeconds,
            row.description, row.iconUrl, row.apiName));
        }
      }
      achievements = new SteamGameAchievementsResult(source.totalCount, source.unlockedCount, rows);
    }
    return new SteamGameDetailBundle(info, news, achievements);
  }

  /** Resolves the account, opens the adapter session and returns the Steam language. */
  private async prepareAdapter(accountId: string): Promise<SteamArkPreparedLibraryAdapter> {
    await steamArkStateService.initialize();
    const state: SteamArkStateSnapshot = steamArkStateService.getSnapshot();
    const account: SteamArkAccountSnapshot | null = this.findAccount(state, accountId);
    if (account === null || account.session.state !== SteamSessionState.LOGGED_ON) {
      throw new Error('Steam account must be logged on before game library access');
    }
    const credentials: SteamCredentialSet = await steamArkStateService.getCredentials(accountId);
    if (credentials.accessToken.trim().length <= 0 && credentials.refreshToken.trim().length <= 0) {
      throw new Error('Steam game library access requires a persisted access or refresh token. Please sign in again.');
    }
    const proxyPassword: string = await steamArkStateService.getProxyPassword(accountId);
    const profile: SteamAccountProfile = account.profile;
    const adapter: ISteamArkGameLibraryAdapter = await this.requireAdapter(
      accountId,
      profile,
      credentials,
      proxyPassword
    );
    adapter.setLibraryUpdateListener((result: SteamGameLibraryResult): void => {
      this.applyLibraryUpdate(accountId, result);
    });
    if (adapter.session.state !== SteamSessionState.LOGGED_ON) {
      const opened = await adapter.open(accountId, credentials);
      SteamArkLog.info(TAG, 'game library Web session state=' + String(opened.state));
    }
    const locale = steamArkStateService.resolveAccountLocale(accountId);
    const language: string = locale !== null ? locale.steamLanguage : 'english';
    return { adapter: adapter, language: language };
  }

  /**
   * Applies a late library update delivered by the adapter after the initial
   * synchronization already returned (for example when the slow CM channel
   * completes after the fast Web sources). Favorites from the current cache
   * are preserved, the result is persisted and published as a silent refresh.
   */
  private applyLibraryUpdate(accountId: string, result: SteamGameLibraryResult): void {
    SteamArkLog.info(TAG, 'game library late update received; account=' +
      SteamArkLog.accountId(accountId) + ', games=' + result.games.length.toString() +
      ', total=' + result.totalCount.toString() + ', source=' + result.source);
    const current: SteamArkGameLibrarySnapshot | undefined = this.snapshots.get(accountId);
    const cached: SteamArkGameLibrarySnapshot | null = current !== undefined
      ? current
      : this.restore(accountId);
    const mergedGames: Array<SteamLibraryGame> = this.mergeCachedFavorites(result.games, cached);
    const snapshot: SteamArkGameLibrarySnapshot = new SteamArkGameLibrarySnapshot(
      accountId,
      mergedGames,
      result.totalCount > 0 ? result.totalCount : mergedGames.length,
      Math.floor(Date.now() / 1000)
    );
    this.persist(accountId, snapshot);
    this.setSnapshot(accountId, snapshot);
    SteamArkLog.info(TAG, 'game library late update applied; account=' +
      SteamArkLog.accountId(accountId) + ', games=' + mergedGames.length.toString());
  }

  /**
   * Keeps favorite markers from the previous snapshot for games the fresh
   * sources no longer report as favorites. The redesigned community tile
   * page may not render the favorite state at all, so a previously known
   * favorite must never be lost across refreshes.
   */
  private mergeCachedFavorites(
    games: Array<SteamLibraryGame>,
    cached: SteamArkGameLibrarySnapshot | null
  ): Array<SteamLibraryGame> {
    if (cached === null || cached.games.length <= 0) {
      return games;
    }
    const cachedFavorites: Map<string, boolean> = new Map<string, boolean>();
    for (let index = 0; index < cached.games.length; index++) {
      if (cached.games[index].favorite) {
        cachedFavorites.set(cached.games[index].appId, true);
      }
    }
    const merged: Array<SteamLibraryGame> = [];
    for (let index = 0; index < games.length; index++) {
      const game: SteamLibraryGame = games[index];
      merged.push(new SteamLibraryGame(
        game.appId,
        game.name,
        game.logoUrl,
        game.iconUrl,
        game.playtimeForeverSeconds,
        game.playtimeTwoWeeksSeconds,
        game.lastPlayedEpochSeconds,
        game.favorite || cachedFavorites.get(game.appId) === true
      ));
    }
    return merged;
  }

  private async requireAdapter(
    accountId: string,
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    proxyPassword: string
  ): Promise<ISteamArkGameLibraryAdapter> {
    const existing: ISteamArkGameLibraryAdapter | undefined = this.adapters.get(accountId);
    if (existing !== undefined) {
      return existing;
    }
    const factory: ISteamArkGameLibraryAdapterFactory | null = this.adapterFactory;
    if (factory === null) {
      throw new Error('Steam game library adapter is not configured');
    }
    const adapter: ISteamArkGameLibraryAdapter = factory.create(profile, proxyPassword);
    this.adapters.set(accountId, adapter);
    return adapter;
  }

  private findAccount(state: SteamArkStateSnapshot, accountId: string): SteamArkAccountSnapshot | null {
    for (let index = 0; index < state.accounts.length; index++) {
      if (state.accounts[index].profile.accountId === accountId) {
        return state.accounts[index];
      }
    }
    return null;
  }

  private persist(accountId: string, snapshot: SteamArkGameLibrarySnapshot): void {
    const items: Array<SteamArkLibraryCacheItem> = [];
    for (let index = 0; index < snapshot.games.length; index++) {
      const game = snapshot.games[index];
      items.push({
        appId: game.appId,
        name: game.name,
        logoUrl: game.logoUrl,
        iconUrl: game.iconUrl,
        playtimeForeverSeconds: game.playtimeForeverSeconds,
        playtimeTwoWeeksSeconds: game.playtimeTwoWeeksSeconds,
        lastPlayedEpochSeconds: game.lastPlayedEpochSeconds,
        favorite: game.favorite
      });
    }
    const document: SteamArkLibraryCacheDocument = {
      accountId: accountId,
      updatedAtEpochSeconds: snapshot.updatedAtEpochSeconds,
      games: items
    };
    ngfSettingsStoreFacade.setString(this.cacheKey(accountId), JSON.stringify(document));
    SteamArkLog.debug(TAG, 'game library cache saved; account=' + SteamArkLog.accountId(accountId) +
      ', games=' + items.length.toString());
  }

  private setSnapshot(accountId: string, snapshot: SteamArkGameLibrarySnapshot): void {
    this.snapshots.set(accountId, snapshot);
    this.listeners.forEach((listener: SteamArkGameLibrarySnapshotListener): void => {
      listener(snapshot);
    });
  }

  private cacheKey(accountId: string): string {
    return CACHE_NAMESPACE + ':' + accountId;
  }

  private errorMessage(error: Object): string {
    return error instanceof Error && error.message.trim().length > 0 ? error.message : 'Steam game library sync failed';
  }
}

export const steamArkGameLibraryService = new SteamArkGameLibraryService();
