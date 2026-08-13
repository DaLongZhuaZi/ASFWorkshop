import {
  IHttpSession,
  NGFHttpMethod,
  NGFHttpSessionRequest,
  NGFProxyConfiguration
} from 'ngf_framework';
import {
  ISteamAuthTransport,
  SteamAuthEndpoint,
  SteamAuthHttpResponse,
  SteamFormField
} from 'steam_core';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';

const TAG: string = 'HarmonySteamAuthTransport';
const DEFAULT_USER_AGENT: string = ASFWorkshopProductIdentity.userAgent('SteamAuth');

/** Host-side options for Steam AuthenticationService requests. */
export class HarmonySteamAuthTransportOptions {
  readonly proxy: NGFProxyConfiguration;
  readonly userAgent: string;
  readonly timeoutMs: number;

  constructor(
    proxy: NGFProxyConfiguration = NGFProxyConfiguration.system(),
    userAgent: string = DEFAULT_USER_AGENT,
    timeoutMs: number = 30000
  ) {
    this.proxy = proxy;
    this.userAgent = userAgent;
    this.timeoutMs = timeoutMs;
  }
}

/**
 * HarmonyOS HTTP adapter for the detachable steam_core authentication flow.
 * Cookie state remains owned by the injected NGF session.
 */
export class HarmonySteamAuthTransport implements ISteamAuthTransport {
  private readonly session: IHttpSession;
  private readonly options: HarmonySteamAuthTransportOptions;

  constructor(
    session: IHttpSession,
    options: HarmonySteamAuthTransportOptions = new HarmonySteamAuthTransportOptions()
  ) {
    this.session = session;
    this.options = options;
  }

  async postForm(endpoint: SteamAuthEndpoint, fields: Array<SteamFormField>): Promise<SteamAuthHttpResponse> {
    const startedAt: number = Date.now();
    SteamArkLog.debug(TAG, 'Steam authentication form request started; fieldCount=' + fields.length.toString() +
      ', endpointConfigured=' + String(endpoint.length > 0));
    const headers = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
    headers.set('User-Agent', this.options.userAgent);
    const request = new NGFHttpSessionRequest(
      NGFHttpMethod.POST,
      endpoint,
      headers,
      this.encodeForm(fields),
      this.options.timeoutMs,
      false,
      this.options.proxy
    );
    try {
      const response = await this.session.request(request);
      SteamArkLog.info(TAG, 'Steam authentication form request completed; status=' +
        response.statusCode.toString());
      SteamArkLog.performance(TAG, 'Steam authentication HTTP request', startedAt);
      return new SteamAuthHttpResponse(response.statusCode, response.body);
    } catch (error) {
      SteamArkLog.warn(TAG, 'Steam authentication form request failed; errorType=' +
        SteamArkLog.errorKind(error));
      SteamArkLog.performance(TAG, 'Steam authentication HTTP request failed', startedAt);
      throw error instanceof Error ? error : new Error('Steam authentication HTTP request failed');
    }
  }

  clearSession(): void {
    this.session.clear();
    SteamArkLog.debug(TAG, 'Steam authentication HTTP session cleared');
  }

  private encodeForm(fields: Array<SteamFormField>): string {
    const encoded: Array<string> = [];
    for (let index = 0; index < fields.length; index++) {
      const field = fields[index];
      encoded.push(
        this.encodeFormComponent(field.name) + '=' + this.encodeFormComponent(field.value)
      );
    }
    return encoded.join('&');
  }

  private encodeFormComponent(value: string): string {
    return encodeURIComponent(value)
      .replace(/%20/g, '+')
      .replace(/!/g, '%21')
      .replace(/'/g, '%27')
      .replace(/\(/g, '%28')
      .replace(/\)/g, '%29')
      .replace(/\*/g, '%2A');
  }
}
