import {
  IWebSocketClient,
  NGFProxyConfiguration,
  WebSocketClientFacade
} from 'ngf_framework';
import {
  IClock,
  ISteamAuthService,
  SteamCmAuthClient,
  SteamCmAuthClientOptions,
  SteamCmAuthService,
  SteamAccountProfile,
  SteamCmEndpoint,
  SteamProxyKind,
  SteamProxySettings
} from 'steam_core';
import { ISteamArkAuthServiceFactory } from '../steamServices/SteamArkAuthContracts';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';
import {
  HarmonyBinaryCryptoAdapter
} from './HarmonyBinaryCryptoAdapter';
import {
  HarmonySteamCmWireTransport,
  HarmonySteamCmWireTransportOptions
} from './HarmonySteamCmWireTransport';
import { HarmonySteamCmIdentityResolver } from './HarmonySteamCmIdentityResolver';
import {
  HarmonySteamClock,
  HarmonySteamCmMultiDecompressor,
  HarmonySteamCmScheduler
} from './HarmonySteamCmRuntime';

const DEFAULT_CM_SERVER: string = SteamCmEndpoint.DEFAULT_SERVER;
// Steam may take more than 30 seconds to answer the first QR session request
// on a cold CM connection. Keep this aligned with the ASF connection timeout.
const DEFAULT_CM_REQUEST_TIMEOUT_MS: number = 90000;
const TAG: string = 'HarmonySteamAuthServiceFactory';

/** Composition root for one account's isolated modern Steam auth session. */
export class HarmonySteamAuthServiceFactory implements ISteamArkAuthServiceFactory {
  create(profile: SteamAccountProfile, proxyPassword: string = ''): ISteamAuthService {
    SteamArkLog.info(TAG, 'authentication service factory create started; account=' +
      SteamArkLog.accountId(profile.accountId) + ', proxyKind=' + String(profile.proxy.kind));
    const proxy = HarmonySteamAuthServiceFactory.toProxy(profile.proxy, proxyPassword);
    const wireOptions = new HarmonySteamCmWireTransportOptions(proxy);
    const identityResolver = new HarmonySteamCmIdentityResolver(DEFAULT_CM_SERVER, wireOptions);
    const client: IWebSocketClient = new WebSocketClientFacade();
    const wire = new HarmonySteamCmWireTransport(client, wireOptions);
    const authClientOptions = new SteamCmAuthClientOptions(
      DEFAULT_CM_SERVER,
      65581,
      DEFAULT_CM_REQUEST_TIMEOUT_MS,
      steamArkCoreLogger,
      new HarmonySteamCmMultiDecompressor()
    );
    const authClient = new SteamCmAuthClient(
      wire,
      new HarmonySteamCmScheduler(),
      authClientOptions
    );
    const clock: IClock = new HarmonySteamClock();
    const service = new SteamCmAuthService(
      authClient,
      new HarmonyBinaryCryptoAdapter(),
      clock,
      DEFAULT_CM_SERVER,
      profile.accountId,
      profile.steamId64,
      identityResolver,
      steamArkCoreLogger
    );
    SteamArkLog.info(TAG, 'authentication service factory create completed; account=' +
      SteamArkLog.accountId(profile.accountId));
    return service;
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
