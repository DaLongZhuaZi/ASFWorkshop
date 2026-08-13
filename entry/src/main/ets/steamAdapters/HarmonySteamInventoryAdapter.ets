import {
  IHttpSession,
  NGFHttpSession,
  NGFProxyConfiguration
} from 'ngf_framework';
import {
  IClock,
  SteamAccountProfile,
  SteamCredentialSet,
  SteamInventoryPage,
  SteamInventoryQuery,
  SteamInventoryService,
  SteamProxyKind,
  SteamProxySettings,
  SteamSessionSnapshot,
  SteamWebSession
} from 'steam_core';
import {
  ISteamArkInventoryAdapter,
  ISteamArkInventoryAdapterFactory
} from '../steamServices/SteamArkInventoryContracts';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';
import { HarmonySteamClock } from './HarmonySteamCmRuntime';
import { HarmonySteamWebSessionFactory } from './HarmonySteamWebSessionFactory';

const TAG: string = 'HarmonySteamInventoryAdapter';

/** HarmonyOS composition root for one account's read-only Web inventory path. */
export class HarmonySteamInventoryAdapter implements ISteamArkInventoryAdapter {
  private readonly accountId: string;
  private readonly webSession: SteamWebSession;
  private readonly inventoryService: SteamInventoryService;

  constructor(profile: SteamAccountProfile, proxyPassword: string = '') {
    this.accountId = profile.accountId;
    const httpSession: IHttpSession = new NGFHttpSession();
    const clock: IClock = new HarmonySteamClock();
    const proxy: NGFProxyConfiguration = HarmonySteamInventoryAdapter.toProxy(profile.proxy, proxyPassword);
    this.webSession = HarmonySteamWebSessionFactory.create(
      httpSession,
      clock,
      profile.steamId64,
      proxy
    );
    this.inventoryService = new SteamInventoryService(this.webSession, steamArkCoreLogger);
    SteamArkLog.debug(TAG, 'inventory adapter constructed; account=' + SteamArkLog.accountId(this.accountId) +
      ', steamId64=' + SteamArkLog.steamId64(profile.steamId64) + ', proxyKind=' + String(profile.proxy.kind));
  }

  async open(accountId: string, credentials: SteamCredentialSet): Promise<SteamSessionSnapshot> {
    this.assertAccount(accountId);
    SteamArkLog.info(TAG, 'inventory Web session open started; account=' + SteamArkLog.accountId(accountId) +
      ', credentialFieldsPresent=' + String(credentials.accessToken.length > 0 || credentials.refreshToken.length > 0));
    try {
      const session = await this.webSession.open(accountId, credentials);
      SteamArkLog.info(TAG, 'inventory Web session open completed; account=' +
        SteamArkLog.accountId(accountId) + ', state=' + String(session.state));
      return session;
    } catch (error) {
      SteamArkLog.warn(TAG, 'inventory Web session open failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('Steam inventory Web session open failed');
    }
  }

  async sync(accountId: string, query: SteamInventoryQuery): Promise<SteamInventoryPage> {
    this.assertAccount(accountId);
    SteamArkLog.info(TAG, 'inventory sync started; account=' + SteamArkLog.accountId(accountId) +
      ', page=' + query.page.toString() + ', pageSize=' + query.pageSize.toString() +
      ', marketableOnly=' + String(query.marketableOnly) + ', tradableOnly=' + String(query.tradableOnly));
    try {
      const page = await this.inventoryService.sync(accountId, query);
      SteamArkLog.info(TAG, 'inventory sync completed; account=' + SteamArkLog.accountId(accountId) +
        ', items=' + page.items.length.toString() + ', total=' + page.totalCount.toString() +
        ', hasMore=' + String(page.hasMore));
      return page;
    } catch (error) {
      SteamArkLog.warn(TAG, 'inventory sync failed; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('Steam inventory synchronization failed');
    }
  }

  async close(accountId: string): Promise<void> {
    this.assertAccount(accountId);
    SteamArkLog.debug(TAG, 'inventory Web session close requested; account=' + SteamArkLog.accountId(accountId));
    await this.webSession.close(accountId);
    SteamArkLog.debug(TAG, 'inventory Web session closed; account=' + SteamArkLog.accountId(accountId));
  }

  get session(): SteamSessionSnapshot {
    return this.webSession.session;
  }

  private assertAccount(accountId: string): void {
    if (accountId !== this.accountId) {
      throw new Error('Steam inventory adapter account mismatch');
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

/** Default factory; tests can inject a fake factory into SteamArkStateService. */
export class HarmonySteamInventoryAdapterFactory implements ISteamArkInventoryAdapterFactory {
  create(profile: SteamAccountProfile, proxyPassword: string = ''): ISteamArkInventoryAdapter {
    SteamArkLog.debug(TAG, 'inventory adapter factory create; account=' + SteamArkLog.accountId(profile.accountId));
    return new HarmonySteamInventoryAdapter(profile, proxyPassword);
  }
}
