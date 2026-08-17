import {
  IHttpSession,
  NGFHttpSession,
  NGFProxyConfiguration
} from 'ngf_framework';
import {
  IClock,
  SteamAccountProfile,
  SteamCmClient,
  SteamCmClientOptions,
  SteamCmEndpoint,
  SteamCredentialSet,
  SteamGameAchievementsResult,
  SteamGameDetailBundle,
  SteamGameDetailInfo,
  SteamGameLibraryMerger,
  SteamGameLibraryResult,
  SteamGameNewsItem,
  SteamOwnedGamesClient,
  SteamProxyKind,
  SteamProxySettings,
  SteamSessionSnapshot,
  SteamSessionState,
  SteamWebSession
} from 'steam_core';
import {
  ISteamArkGameLibraryAdapter,
  ISteamArkGameLibraryAdapterFactory,
  SteamLibraryUpdateListener
} from '../steamServices/SteamArkGameLibraryContracts';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';
import { HarmonySteamCmClientFactory } from './HarmonySteamCmClientFactory';
import {
  HarmonySteamCmMultiDecompressor,
  HarmonySteamClock
} from './HarmonySteamCmRuntime';
import {
  HarmonySteamCmWireTransportOptions
} from './HarmonySteamCmWireTransport';
import { HarmonySteamWebSessionFactory } from './HarmonySteamWebSessionFactory';

const TAG: string = 'HarmonySteamGameLibraryAdapter';
// Steam CM can take a long time to answer the first request on a cold
// connection (the authentication factory allows up to 90 seconds for the
// first QR session request). The library sync never blocks on this: the Web
// sources return first and the CM result is merged in silently when ready.
const CM_LOGON_TIMEOUT_ATTEMPTS: number = 90;
const CM_LOGON_POLL_MILLISECONDS: number = 1000;

/**
 * HarmonyOS composition root for one account's read-only Steam library path.
 *
 * The Steam community games page only server-renders the first screen of
 * DesktopUI tiles, so it can no longer provide the full library. This adapter
 * therefore prefers the authenticated IPlayerService/GetOwnedGames Web API
 * (fast HTTPS, full list with playtime and artwork), merges the tile page
 * details (logo images, favorite markers) on top, and keeps the CM
 * "Player.GetOwnedGames#1" unified message running in the background as the
 * same authoritative channel the Steam client uses. Each source can fail
 * independently and the others still succeed; a late CM completion silently
 * updates the library through the registered update listener.
 */
export class HarmonySteamGameLibraryAdapter implements ISteamArkGameLibraryAdapter {
  private readonly accountId: string;
  private readonly steamId64: string;
  private readonly webSession: SteamWebSession;
  private readonly proxy: NGFProxyConfiguration;
  private cmClient: SteamCmClient | null = null;
  private credentials: SteamCredentialSet | null = null;
  private libraryUpdateListener: SteamLibraryUpdateListener | null = null;
  private lateMergedResult: SteamGameLibraryResult | null = null;

  constructor(profile: SteamAccountProfile, proxyPassword: string = '') {
    this.accountId = profile.accountId;
    this.steamId64 = profile.steamId64;
    const httpSession: IHttpSession = new NGFHttpSession();
    const clock: IClock = new HarmonySteamClock();
    this.proxy = HarmonySteamGameLibraryAdapter.toProxy(profile.proxy, proxyPassword);
    this.webSession = HarmonySteamWebSessionFactory.create(
      httpSession,
      clock,
      profile.steamId64,
      this.proxy
    );
    SteamArkLog.debug(TAG, 'game library adapter constructed; account=' + SteamArkLog.accountId(this.accountId) +
      ', steamId64=' + SteamArkLog.steamId64(profile.steamId64) + ', proxyKind=' + String(profile.proxy.kind));
  }

  async open(accountId: string, credentials: SteamCredentialSet): Promise<SteamSessionSnapshot> {
    this.assertAccount(accountId);
    this.credentials = credentials;
    SteamArkLog.info(TAG, 'game library Web session open started; account=' + SteamArkLog.accountId(accountId) +
      ', credentialFieldsPresent=' + String(credentials.accessToken.length > 0 || credentials.refreshToken.length > 0));
    try {
      const session = await this.webSession.open(accountId, credentials);
      SteamArkLog.info(TAG, 'game library Web session open completed; account=' +
        SteamArkLog.accountId(accountId) + ', state=' + String(session.state));
      return session;
    } catch (error) {
      SteamArkLog.warn(TAG, 'game library Web session open failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('Steam game library Web session open failed');
    }
  }

  async syncGameLibrary(accountId: string, language: string): Promise<SteamGameLibraryResult> {
    this.assertAccount(accountId);
    SteamArkLog.info(TAG, 'game library sync started; account=' + SteamArkLog.accountId(accountId) +
      ', language=' + language);
    // Fire all sources concurrently. CM is the slowest (cold logon can take
    // well over 20 seconds), so it never blocks the fast Web sources.
    const cmTask: Promise<SteamGameLibraryResult | null> =
      this.trySyncOwnedGamesViaCm(accountId, language);
    const countTask: Promise<SteamGameLibraryResult | null> =
      this.trySyncOwnedCount(accountId);
    const webApi: SteamGameLibraryResult | null =
      await this.trySyncOwnedGamesViaWebApi(accountId, language);
    const tiles: SteamGameLibraryResult | null =
      await this.trySyncWebTiles(accountId, language);
    if (webApi !== null) {
      if (webApi.games.length > 0) {
        const fast: SteamGameLibraryResult = SteamGameLibraryMerger.merge(webApi, tiles);
        this.attachCmLateMerge(cmTask, fast, accountId);
        SteamArkLog.info(TAG, 'game library sync completed; account=' + SteamArkLog.accountId(accountId) +
          ', games=' + fast.games.length.toString() + ', total=' + fast.totalCount.toString() +
          ', source=' + fast.source);
        return fast;
      }
      if (webApi.totalCount > 0 && tiles !== null && webApi.totalCount > tiles.games.length) {
        // The API acknowledged the account but returned no entries (private
        // list edge case): keep the tile list and the authoritative total.
        const counted: SteamGameLibraryResult = new SteamGameLibraryResult(
          tiles.games,
          webApi.totalCount,
          tiles.warnings,
          tiles.source
        );
        this.attachCmLateMerge(cmTask, counted, accountId);
        SteamArkLog.info(TAG, 'game library sync completed with Web API count; account=' +
          SteamArkLog.accountId(accountId) + ', games=' + counted.games.length.toString() +
          ', total=' + counted.totalCount.toString());
        return counted;
      }
      if (webApi.totalCount > 0) {
        this.attachCmLateMerge(cmTask, webApi, accountId);
        SteamArkLog.info(TAG, 'game library sync completed with Web API count only; account=' +
          SteamArkLog.accountId(accountId) + ', total=' + webApi.totalCount.toString() +
          ', source=' + webApi.source);
        return webApi;
      }
      SteamArkLog.warn(TAG, 'owned games Web API returned an empty library; account=' +
        SteamArkLog.accountId(accountId));
    }
    const cm: SteamGameLibraryResult | null = await cmTask;
    if (cm !== null) {
      const merged: SteamGameLibraryResult = SteamGameLibraryMerger.merge(cm, tiles);
      SteamArkLog.info(TAG, 'game library sync completed; account=' + SteamArkLog.accountId(accountId) +
        ', games=' + merged.games.length.toString() + ', total=' + merged.totalCount.toString() +
        ', source=' + merged.source);
      return merged;
    }
    const count: SteamGameLibraryResult | null = await countTask;
    if (tiles !== null) {
      if (count !== null && count.totalCount > tiles.games.length) {
        // The tile page only renders the first screen; the store
        // personalization count still knows the full owned set.
        const counted: SteamGameLibraryResult = new SteamGameLibraryResult(
          tiles.games,
          count.totalCount,
          tiles.warnings,
          tiles.source
        );
        SteamArkLog.info(TAG, 'game library sync completed with Web fallback; account=' +
          SteamArkLog.accountId(accountId) + ', games=' + counted.games.length.toString() +
          ', total=' + counted.totalCount.toString() + ', source=' + counted.source);
        return counted;
      }
      SteamArkLog.info(TAG, 'game library sync completed with Web fallback; account=' +
        SteamArkLog.accountId(accountId) + ', games=' + tiles.games.length.toString() +
        ', source=' + tiles.source);
      return tiles;
    }
    if (count !== null && count.totalCount > 0) {
      SteamArkLog.info(TAG, 'game library sync completed with owned-count fallback; account=' +
        SteamArkLog.accountId(accountId) + ', total=' + count.totalCount.toString() +
        ', source=' + count.source);
      return count;
    }
    SteamArkLog.warn(TAG, 'game library sync failed; all sources unavailable; account=' +
      SteamArkLog.accountId(accountId));
    throw new Error('Steam game library synchronization failed');
  }

  /**
   * Fetches everything the game detail page shows. Every section is fetched
   * independently so one failing source never hides the others.
   */
  async fetchGameDetail(accountId: string, appId: string, language: string): Promise<SteamGameDetailBundle> {
    this.assertAccount(accountId);
    SteamArkLog.info(TAG, 'game detail fetch started; account=' + SteamArkLog.accountId(accountId) +
      ', appId=' + appId + ', language=' + language);
    let info: SteamGameDetailInfo | null = null;
    try {
      info = await this.webSession.fetchGameDetail(accountId, appId, language);
    } catch (error) {
      SteamArkLog.warn(TAG, 'game detail fetch failed; account=' + SteamArkLog.accountId(accountId) +
        ', appId=' + appId + ', errorType=' + SteamArkLog.errorKind(error));
    }
    let news: Array<SteamGameNewsItem> = [];
    try {
      news = await this.webSession.fetchGameNews(accountId, appId);
    } catch (error) {
      SteamArkLog.warn(TAG, 'game news fetch failed; account=' + SteamArkLog.accountId(accountId) +
        ', appId=' + appId + ', errorType=' + SteamArkLog.errorKind(error));
    }
    let achievements: SteamGameAchievementsResult | null = null;
    try {
      achievements = await this.webSession.fetchGameAchievements(
        accountId,
        appId,
        this.credentials !== null ? this.credentials.accessToken : '',
        language
      );
    } catch (error) {
      SteamArkLog.warn(TAG, 'game achievements fetch failed; account=' + SteamArkLog.accountId(accountId) +
        ', appId=' + appId + ', errorType=' + SteamArkLog.errorKind(error));
    }
    SteamArkLog.info(TAG, 'game detail fetch completed; account=' + SteamArkLog.accountId(accountId) +
      ', appId=' + appId + ', infoPresent=' + String(info !== null) +
      ', news=' + news.length.toString() + ', achievementsPresent=' + String(achievements !== null));
    return new SteamGameDetailBundle(info, news, achievements);
  }

  setLibraryUpdateListener(listener: SteamLibraryUpdateListener | null): void {
    this.libraryUpdateListener = listener;
    SteamArkLog.debug(TAG, 'game library update listener ' +
      (listener !== null ? 'registered' : 'cleared') + '; account=' +
      SteamArkLog.accountId(this.accountId));
  }

  /**
   * Returns and clears a late CM-merged result that settled before the sync
   * task finished persisting, so the service never publishes a less complete
   * fast result over an already merged one.
   */
  drainPendingLibraryUpdate(): SteamGameLibraryResult | null {
    const pending: SteamGameLibraryResult | null = this.lateMergedResult;
    this.lateMergedResult = null;
    return pending;
  }

  async close(accountId: string): Promise<void> {
    this.assertAccount(accountId);
    SteamArkLog.debug(TAG, 'game library Web session close requested; account=' + SteamArkLog.accountId(accountId));
    const cm: SteamCmClient | null = this.cmClient;
    this.cmClient = null;
    this.credentials = null;
    try {
      await this.webSession.close(accountId);
    } finally {
      if (cm !== null) {
        try {
          await cm.disconnect();
        } catch (error) {
          SteamArkLog.warn(TAG, 'game library CM disconnect failed; account=' +
            SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
        }
        cm.dispose();
      }
    }
    SteamArkLog.debug(TAG, 'game library Web session closed; account=' + SteamArkLog.accountId(accountId));
  }

  get session(): SteamSessionSnapshot {
    return this.webSession.session;
  }

  private async trySyncOwnedGamesViaCm(accountId: string, language: string): Promise<SteamGameLibraryResult | null> {
    try {
      return await this.syncOwnedGamesViaCm(accountId, language);
    } catch (error) {
      SteamArkLog.warn(TAG, 'owned games synchronization failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      return null;
    }
  }

  private async trySyncOwnedGamesViaWebApi(accountId: string, language: string): Promise<SteamGameLibraryResult | null> {
    const credentials: SteamCredentialSet | null = this.credentials;
    if (credentials === null || credentials.accessToken.trim().length <= 0) {
      SteamArkLog.warn(TAG, 'owned games Web API skipped; access token unavailable; account=' +
        SteamArkLog.accountId(accountId));
      return null;
    }
    try {
      return await this.webSession.syncOwnedGamesViaWebApi(accountId, credentials.accessToken, language);
    } catch (error) {
      SteamArkLog.warn(TAG, 'owned games Web API synchronization failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      return null;
    }
  }

  private async trySyncWebTiles(accountId: string, language: string): Promise<SteamGameLibraryResult | null> {
    try {
      return await this.webSession.syncGameLibrary(accountId, language);
    } catch (error) {
      SteamArkLog.warn(TAG, 'game library Web page synchronization failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      return null;
    }
  }

  private async trySyncOwnedCount(accountId: string): Promise<SteamGameLibraryResult | null> {
    try {
      return await this.webSession.syncOwnedGameCountViaDynamicStore(accountId);
    } catch (error) {
      SteamArkLog.warn(TAG, 'owned games count synchronization failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      return null;
    }
  }

  /**
   * Merges the CM result into the already returned library once the slow CM
   * logon completes and silently notifies the service, so the full list can
   * replace the fast Web result without a user-visible reload.
   */
  private attachCmLateMerge(
    cmTask: Promise<SteamGameLibraryResult | null>,
    current: SteamGameLibraryResult,
    accountId: string
  ): void {
    cmTask.then((cmResult: SteamGameLibraryResult | null): void => {
      if (cmResult === null || cmResult.games.length <= 0) {
        return;
      }
      const merged: SteamGameLibraryResult = SteamGameLibraryMerger.merge(cmResult, current);
      this.lateMergedResult = merged;
      SteamArkLog.info(TAG, 'game library CM merge completed; account=' +
        SteamArkLog.accountId(accountId) + ', games=' + merged.games.length.toString() +
        ', total=' + merged.totalCount.toString());
      this.notifyLibraryUpdate(merged);
    }).catch((error: Error): void => {
      SteamArkLog.warn(TAG, 'game library CM merge failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    });
  }

  private notifyLibraryUpdate(result: SteamGameLibraryResult): void {
    const listener: SteamLibraryUpdateListener | null = this.libraryUpdateListener;
    if (listener === null) {
      return;
    }
    try {
      listener(result);
    } catch (error) {
      SteamArkLog.warn(TAG, 'game library update listener failed; errorType=' +
        SteamArkLog.errorKind(error));
    }
  }

  private async syncOwnedGamesViaCm(accountId: string, language: string): Promise<SteamGameLibraryResult> {
    const credentials: SteamCredentialSet | null = this.credentials;
    if (credentials === null) {
      throw new Error('Steam owned games requires an opened credential session');
    }
    const cmClient: SteamCmClient = this.requireCmClient(language);
    await cmClient.connect();
    await this.waitForCmLogon(cmClient);
    try {
      return await SteamOwnedGamesClient.fetch(
        cmClient,
        this.steamId64,
        language,
        steamArkCoreLogger
      );
    } finally {
      try {
        await cmClient.disconnect();
      } catch (error) {
        SteamArkLog.warn(TAG, 'owned games CM disconnect failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
  }

  private requireCmClient(language: string): SteamCmClient {
    const existing: SteamCmClient | null = this.cmClient;
    if (existing !== null) {
      return existing;
    }
    const credentials: SteamCredentialSet | null = this.credentials;
    if (credentials === null) {
      throw new Error('Steam owned games requires credentials');
    }
    const options: SteamCmClientOptions = new SteamCmClientOptions(
      SteamCmEndpoint.DEFAULT_SERVER,
      this.steamId64,
      ASFWorkshopProductIdentity.DEVICE_FRIENDLY_NAME,
      65581,
      1771,
      language,
      0,
      30,
      2,
      60,
      0,
      1,
      '',
      '',
      true,
      false,
      steamArkCoreLogger,
      30000,
      new HarmonySteamCmMultiDecompressor()
    );
    const wireOptions: HarmonySteamCmWireTransportOptions = new HarmonySteamCmWireTransportOptions(
      this.proxy,
      ASFWorkshopProductIdentity.userAgent('SteamCm')
    );
    this.cmClient = HarmonySteamCmClientFactory.create(
      this.accountId,
      credentials,
      options,
      wireOptions
    );
    return this.cmClient;
  }

  private async waitForCmLogon(client: SteamCmClient): Promise<void> {
    SteamArkLog.debug(TAG, 'CM logon wait started; account=' + SteamArkLog.accountId(this.accountId));
    for (let attempt = 0; attempt < CM_LOGON_TIMEOUT_ATTEMPTS; attempt++) {
      const state: SteamSessionState = client.session.state;
      if (state === SteamSessionState.LOGGED_ON) {
        SteamArkLog.debug(TAG, 'CM logon wait completed; account=' + SteamArkLog.accountId(this.accountId) +
          ', attempts=' + attempt.toString());
        return;
      }
      if (state === SteamSessionState.ERROR) {
        throw new Error('Steam CM logon failed for owned games');
      }
      if (state === SteamSessionState.NEEDS_EMAIL_CODE ||
        state === SteamSessionState.NEEDS_TWO_FACTOR ||
        state === SteamSessionState.NEEDS_MOBILE_CONFIRMATION ||
        state === SteamSessionState.EXPIRED) {
        throw new Error('Steam CM authentication challenge is required for owned games');
      }
      await this.waitMilliseconds(CM_LOGON_POLL_MILLISECONDS);
    }
    throw new Error('Steam CM logon timed out for owned games');
  }

  private waitMilliseconds(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, milliseconds);
    });
  }

  private assertAccount(accountId: string): void {
    if (accountId !== this.accountId) {
      throw new Error('Steam game library adapter account mismatch');
    }
  }

  private static toProxy(settings: SteamProxySettings, proxyPassword: string = ''): NGFProxyConfiguration {
    if (settings.kind === SteamProxyKind.DIRECT) {
      return NGFProxyConfiguration.direct();
    }
    if (settings.kind === SteamProxyKind.HTTP) {
      return NGFProxyConfiguration.http(settings.host, settings.port, settings.username, proxyPassword);
    }
    if (settings.kind === SteamProxyKind.SOCKS5) {
      return NGFProxyConfiguration.socks5(settings.host, settings.port, settings.username, proxyPassword);
    }
    return NGFProxyConfiguration.system();
  }
}

/** Default factory; tests can inject a fake factory into SteamArkGameLibraryService. */
export class HarmonySteamGameLibraryAdapterFactory implements ISteamArkGameLibraryAdapterFactory {
  create(profile: SteamAccountProfile, proxyPassword: string = ''): ISteamArkGameLibraryAdapter {
    SteamArkLog.debug(TAG, 'game library adapter factory create; account=' + SteamArkLog.accountId(profile.accountId));
    return new HarmonySteamGameLibraryAdapter(profile, proxyPassword);
  }
}
