import {
  IHttpSession,
  NGFHttpMethod,
  NGFHttpSession,
  NGFHttpSessionRequest,
  NGFProxyConfiguration
} from 'ngf_framework';
import { SteamCmDirectoryCodec, SteamCmEndpoint } from 'steam_core';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';

const TAG: string = 'HarmonySteamCmDirectory';
const DIRECTORY_URL: string = 'https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/';
const SUCCESS_CACHE_MS: number = 10 * 60 * 1000;
const FAILURE_CACHE_MS: number = 60 * 1000;
const REQUEST_TIMEOUT_MS: number = 5000;

/**
 * Resolves live Steam CM websocket endpoints through ISteamDirectory so the
 * app is not pinned to a single hardcoded host. Any failure keeps the static
 * default endpoint, so directory outages never break connectivity.
 */
export class HarmonySteamCmDirectory {
  private static cachedServers: Array<string> = [];
  private static successCachedAtMs: number = 0;
  private static failureCachedAtMs: number = 0;
  private static inFlight: Promise<Array<string>> | null = null;

  /** Returns one usable CM websocket server; never throws. */
  static async resolveWebSocketServer(proxy: NGFProxyConfiguration): Promise<string> {
    const servers: Array<string> = await HarmonySteamCmDirectory.fetchServers(proxy);
    if (servers.length === 0) {
      return SteamCmEndpoint.DEFAULT_SERVER;
    }
    const index: number = Math.floor(Math.random() * servers.length);
    return servers[index];
  }

  private static async fetchServers(proxy: NGFProxyConfiguration): Promise<Array<string>> {
    const now: number = Date.now();
    if (HarmonySteamCmDirectory.cachedServers.length > 0 &&
      now - HarmonySteamCmDirectory.successCachedAtMs < SUCCESS_CACHE_MS) {
      return HarmonySteamCmDirectory.cachedServers;
    }
    if (HarmonySteamCmDirectory.cachedServers.length === 0 &&
      now - HarmonySteamCmDirectory.failureCachedAtMs < FAILURE_CACHE_MS) {
      return [];
    }
    if (HarmonySteamCmDirectory.inFlight !== null) {
      return await HarmonySteamCmDirectory.inFlight;
    }
    const task: Promise<Array<string>> = HarmonySteamCmDirectory.fetchFromNetwork(proxy);
    HarmonySteamCmDirectory.inFlight = task;
    try {
      return await task;
    } finally {
      HarmonySteamCmDirectory.inFlight = null;
    }
  }

  private static async fetchFromNetwork(proxy: NGFProxyConfiguration): Promise<Array<string>> {
    const startedAt: number = Date.now();
    SteamArkLog.debug(TAG, 'CM directory fetch started');
    const session: IHttpSession = new NGFHttpSession();
    const headers = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('SteamCmDirectory'));
    const request = new NGFHttpSessionRequest(
      NGFHttpMethod.GET,
      DIRECTORY_URL,
      headers,
      '',
      REQUEST_TIMEOUT_MS,
      false,
      proxy
    );
    try {
      const response = await session.request(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new Error('CM directory HTTP status ' + response.statusCode.toString());
      }
      const servers: Array<string> = SteamCmDirectoryCodec.extractWebsocketServers(
        response.body, steamArkCoreLogger);
      if (servers.length === 0) {
        throw new Error('CM directory response contained no websocket endpoints');
      }
      HarmonySteamCmDirectory.cachedServers = servers;
      HarmonySteamCmDirectory.successCachedAtMs = Date.now();
      HarmonySteamCmDirectory.failureCachedAtMs = 0;
      SteamArkLog.info(TAG, 'CM directory fetch completed; servers=' + servers.length.toString());
      SteamArkLog.performance(TAG, 'CM directory fetch', startedAt);
      return servers;
    } catch (error) {
      HarmonySteamCmDirectory.failureCachedAtMs = Date.now();
      SteamArkLog.warn(TAG, 'CM directory fetch failed; errorType=' +
        SteamArkLog.errorKind(error) + '; static default endpoint will be used');
      return [];
    }
  }
}
