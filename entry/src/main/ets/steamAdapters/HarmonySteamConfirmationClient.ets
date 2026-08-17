import { IHttpSession, NGFHttpSession, NGFProxyConfiguration } from 'ngf_framework';
import {
  SteamAccountProfile,
  SteamConfirmationPageResult,
  SteamConfirmations,
  SteamCredentialSet,
  SteamProxyKind,
  SteamWebRequest
} from 'steam_core';
import {
  ISteamArkConfirmationClient
} from '../steamServices/SteamArkConfirmationService';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { SteamArkContentLocale } from '../steamServices/SteamArkRegionPolicy';
import { HarmonyBinaryCryptoAdapter } from './HarmonyBinaryCryptoAdapter';
import {
  HarmonySteamWebTransport,
  HarmonySteamWebTransportOptions
} from './HarmonySteamWebTransport';

/**
 * Fetches the read-only Steam mobile confirmation list through the logged-in
 * Web cookie session. Accept and cancel executions stay outside this client.
 */
export class HarmonySteamConfirmationClient implements ISteamArkConfirmationClient {
  private readonly crypto: HarmonyBinaryCryptoAdapter = new HarmonyBinaryCryptoAdapter();

  async fetchConfirmations(
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    proxyPassword: string,
    _locale: SteamArkContentLocale | null
  ): Promise<SteamConfirmationPageResult> {
    const session: IHttpSession = new NGFHttpSession();
    const proxy: NGFProxyConfiguration = HarmonySteamConfirmationClient.toProxy(profile, proxyPassword);
    const transport: HarmonySteamWebTransport = new HarmonySteamWebTransport(session,
      new HarmonySteamWebTransportOptions(proxy,
        ASFWorkshopProductIdentity.userAgent('Confirmations'), 20000));
    try {
      await transport.open(profile.steamId64, credentials.accessToken);
      const query: string = await SteamConfirmations.buildSignedQuery(
        credentials.identitySecret, credentials.deviceId, profile.steamId64,
        Math.floor(Date.now() / 1000), SteamConfirmations.CONF_TAG, this.crypto);
      const request: SteamWebRequest = new SteamWebRequest(
        SteamConfirmations.CONFIRMATIONS_URL + '?' + query);
      const response = await transport.get(request);
      if (!response.isOk()) {
        SteamArkLog.warn('HarmonySteamConfirmationClient',
          'confirmation list HTTP failed; status=' + response.statusCode.toString());
        return new SteamConfirmationPageResult(false, [], 'http_' + response.statusCode.toString());
      }
      return SteamConfirmations.parseConfirmationPage(response.body);
    } catch (error) {
      SteamArkLog.warn('HarmonySteamConfirmationClient',
        'confirmation fetch failed; errorType=' + SteamArkLog.errorKind(error));
      return new SteamConfirmationPageResult(false, [],
        error instanceof Error ? error.message : 'network');
    } finally {
      try {
        await transport.close();
      } catch (_error) {
        SteamArkLog.debug('HarmonySteamConfirmationClient', 'confirmation transport close failed');
      }
      session.clear();
    }
  }

  private static toProxy(profile: SteamAccountProfile, password: string): NGFProxyConfiguration {
    if (profile.proxy.kind === SteamProxyKind.DIRECT) {
      return NGFProxyConfiguration.direct();
    }
    if (profile.proxy.kind === SteamProxyKind.HTTP) {
      return NGFProxyConfiguration.http(profile.proxy.host, profile.proxy.port,
        profile.proxy.username, password);
    }
    if (profile.proxy.kind === SteamProxyKind.SOCKS5) {
      return NGFProxyConfiguration.socks5(profile.proxy.host, profile.proxy.port,
        profile.proxy.username, password);
    }
    return NGFProxyConfiguration.system();
  }
}
