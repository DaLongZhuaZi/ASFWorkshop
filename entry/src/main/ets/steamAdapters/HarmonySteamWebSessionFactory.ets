import { IHttpSession, NGFProxyConfiguration } from 'ngf_framework';
import {
  IClock,
  SteamWebSession,
  SteamWebSessionOptions
} from 'steam_core';
import {
  HarmonySteamWebTransport,
  HarmonySteamWebTransportOptions
} from './HarmonySteamWebTransport';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';

const TAG: string = 'HarmonySteamWebSessionFactory';

/** Composition root for a single-account, read-only Steam Web session. */
export class HarmonySteamWebSessionFactory {
  static create(
    session: IHttpSession,
    clock: IClock,
    steamId64: string,
    proxy: NGFProxyConfiguration = NGFProxyConfiguration.system(),
    userAgent: string = ASFWorkshopProductIdentity.userAgent('SteamWeb'),
    language: string = 'english'
  ): SteamWebSession {
    SteamArkLog.debug(TAG, 'Web session creation started; steamId64=' + SteamArkLog.steamId64(steamId64));
    const transportOptions = new HarmonySteamWebTransportOptions(proxy, userAgent);
    const transport = new HarmonySteamWebTransport(session, transportOptions);
    const sessionOptions = new SteamWebSessionOptions(steamId64, userAgent, steamArkCoreLogger, language);
    const webSession = new SteamWebSession(transport, clock, sessionOptions);
    SteamArkLog.debug(TAG, 'Web session creation completed; steamId64=' + SteamArkLog.steamId64(steamId64));
    return webSession;
  }
}
