import {
  IHttpSession,
  NGFHttpMethod,
  NGFHttpSessionRequest,
  NGFHttpSessionResponse,
  NGFProxyConfiguration,
  NGFProxyMode,
  securityToolkit
} from 'ngf_framework';
import {
  ISteamWebTransport,
  SteamWebRequest,
  SteamWebResponse
} from 'steam_core';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';

const TAG: string = 'HarmonySteamWebTransport';
const DEFAULT_USER_AGENT: string = ASFWorkshopProductIdentity.userAgent('SteamWeb');
const WEB_COOKIE_URLS: Array<string> = [
  'https://steamcommunity.com/',
  'https://store.steampowered.com/',
  'https://help.steampowered.com/',
  'https://checkout.steampowered.com/'
];

export abstract class SteamWebSessionIdGenerator {
  abstract generate(byteLength: number): string;
}

class HarmonySteamWebSessionIdGenerator extends SteamWebSessionIdGenerator {
  generate(byteLength: number): string {
    return securityToolkit.generateRandomHex(byteLength);
  }
}

/** Host-side settings for one isolated Steam Web cookie session. */
export class HarmonySteamWebTransportOptions {
  readonly proxy: NGFProxyConfiguration;
  readonly userAgent: string;
  readonly timeoutMs: number;
  readonly sessionIdGenerator: SteamWebSessionIdGenerator;

  constructor(
    proxy: NGFProxyConfiguration = NGFProxyConfiguration.system(),
    userAgent: string = DEFAULT_USER_AGENT,
    timeoutMs: number = 30000,
    sessionIdGenerator: SteamWebSessionIdGenerator = new HarmonySteamWebSessionIdGenerator()
  ) {
    this.proxy = proxy;
    this.userAgent = userAgent;
    this.timeoutMs = timeoutMs;
    this.sessionIdGenerator = sessionIdGenerator;
  }
}

/**
 * Bridges the detachable Web transport to NGF's cookie-aware HTTP session.
 * This adapter is read-only: it exposes GET and has no POST/PUT/DELETE path.
 */
export class HarmonySteamWebTransport implements ISteamWebTransport {
  private readonly session: IHttpSession;
  private readonly options: HarmonySteamWebTransportOptions;
  private opened: boolean = false;

  constructor(session: IHttpSession, options: HarmonySteamWebTransportOptions = new HarmonySteamWebTransportOptions()) {
    this.session = session;
    this.options = options;
  }

  async open(steamId64: string, accessToken: string): Promise<void> {
    SteamArkLog.info(TAG, 'Steam Web session open started; steamId64=' + SteamArkLog.steamId64(steamId64) +
      ', accessTokenPresent=' + String(accessToken.length > 0));
    if (steamId64.length === 0 || accessToken.length === 0) {
      throw new Error('Steam Web transport requires steamId64 and accessToken');
    }
    const sessionId: string = this.options.sessionIdGenerator.generate(16);
    if (sessionId.length === 0) {
      throw new Error('Unable to generate Steam Web session id');
    }
    this.session.clear();
    const secureValue = steamId64 + '%7C%7C' + accessToken;
    for (let index = 0; index < WEB_COOKIE_URLS.length; index++) {
      const url = WEB_COOKIE_URLS[index];
      this.session.cookieJar.setFromResponse(url, 'sessionid=' + sessionId + '; Path=/; Secure');
      this.session.cookieJar.setFromResponse(url, 'steamLoginSecure=' + secureValue + '; Path=/; Secure');
    }
    this.opened = true;
    SteamArkLog.info(TAG, 'Steam Web session open completed; steamId64=' + SteamArkLog.steamId64(steamId64) +
      ', cookieDomainCount=' + WEB_COOKIE_URLS.length.toString());
  }

  async get(request: SteamWebRequest): Promise<SteamWebResponse> {
    if (!this.opened) {
      throw new Error('Steam Web transport is not open');
    }
    const headers = new Map<string, string>();
    request.headers.forEach((value: string, key: string): void => {
      headers.set(key, value);
    });
    if (headers.get('Accept') === undefined) {
      headers.set('Accept', 'application/json');
    }
    if (headers.get('User-Agent') === undefined) {
      headers.set('User-Agent', this.options.userAgent);
    }
    const options = new NGFHttpSessionRequest(
      NGFHttpMethod.GET,
      request.url,
      headers,
      '',
      this.options.timeoutMs,
      false,
      this.options.proxy
    );
    SteamArkLog.debug(TAG, 'Steam Web GET started; headerCount=' + headers.size.toString());
    try {
      let response: NGFHttpSessionResponse;
      try {
        response = await this.session.request(options);
      } catch (error) {
        if (this.options.proxy.mode !== NGFProxyMode.SYSTEM) {
          throw error instanceof Error ? error : new Error('Steam Web system proxy request failed');
        }
        SteamArkLog.warn(TAG, 'Steam Web GET system proxy failed; retrying direct once');
        const directOptions = new NGFHttpSessionRequest(
          NGFHttpMethod.GET,
          request.url,
          headers,
          '',
          this.options.timeoutMs,
          false,
          NGFProxyConfiguration.direct()
        );
        response = await this.session.request(directOptions);
      }
      SteamArkLog.debug(TAG, 'Steam Web GET completed; status=' + response.statusCode.toString());
      return new SteamWebResponse(response.statusCode, response.body, response.headers);
    } catch (error) {
      SteamArkLog.warn(TAG, 'Steam Web GET failed; errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('Steam Web GET failed');
    }
  }

  async close(): Promise<void> {
    SteamArkLog.debug(TAG, 'Steam Web session close started; wasOpen=' + String(this.opened));
    this.opened = false;
    this.session.clear();
    SteamArkLog.debug(TAG, 'Steam Web session close completed');
  }
}
