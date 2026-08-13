import {
  IHttpSession,
  IWebSocketClient,
  NGFHttpMethod,
  NGFHttpSession,
  NGFHttpSessionRequest,
  NGFProxyConfiguration,
  NGFProxyMode,
  NGFWebSocketOptions,
  WebSocketClientFacade
} from 'ngf_framework';
import { SteamCmEndpoint, SteamErrorLike } from 'steam_core';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';

const TAG: string = 'HarmonySteamNetworkProbe';
const DEFAULT_HTTP_PROBE_URL: string = 'https://steamcommunity.com/';
const DEFAULT_WSS_PROBE_URL: string = SteamCmEndpoint.toWebSocketUrl(SteamCmEndpoint.DEFAULT_SERVER);
const DEFAULT_USER_AGENT: string = ASFWorkshopProductIdentity.userAgent('NetworkProbe');
const DEFAULT_TIMEOUT_MS: number = 10000;

export enum SteamArkNetworkProbeTargetKind {
  HTTP = 'http',
  WSS = 'wss'
}

export class SteamArkNetworkProbeTarget {
  readonly targetId: string;
  readonly url: string;
  readonly kind: SteamArkNetworkProbeTargetKind;

  constructor(targetId: string, url: string, kind: SteamArkNetworkProbeTargetKind) {
    this.targetId = targetId;
    this.url = url;
    this.kind = kind;
  }
}

const DEFAULT_HTTP_TARGETS: Array<SteamArkNetworkProbeTarget> = [
  new SteamArkNetworkProbeTarget('store', 'https://store.steampowered.com/', SteamArkNetworkProbeTargetKind.HTTP),
  new SteamArkNetworkProbeTarget('community', 'https://steamcommunity.com/', SteamArkNetworkProbeTargetKind.HTTP),
  new SteamArkNetworkProbeTarget('login', 'https://steamcommunity.com/login/home/', SteamArkNetworkProbeTargetKind.HTTP),
  new SteamArkNetworkProbeTarget('market', 'https://steamcommunity.com/market/', SteamArkNetworkProbeTargetKind.HTTP),
  new SteamArkNetworkProbeTarget('cdn', 'https://steamcdn-a.akamaihd.net/', SteamArkNetworkProbeTargetKind.HTTP),
  new SteamArkNetworkProbeTarget('api', 'https://api.steampowered.com/ISteamWebAPIUtil/GetServerInfo/v1/?format=json', SteamArkNetworkProbeTargetKind.HTTP),
  new SteamArkNetworkProbeTarget('help', 'https://help.steampowered.com/', SteamArkNetworkProbeTargetKind.HTTP),
  new SteamArkNetworkProbeTarget('checkout', 'https://checkout.steampowered.com/', SteamArkNetworkProbeTargetKind.HTTP)
];

/** Overall result of a read-only HTTP and CM/WSS capability probe. */
export enum SteamArkNetworkProbeStatus {
  SUCCESS = 'success',
  PARTIAL = 'partial',
  FAILED = 'failed',
  UNSUPPORTED = 'unsupported'
}

/** A bounded, secret-free diagnostic for one probe stage. */
export class SteamArkNetworkProbeError {
  readonly stage: string;
  readonly errorType: string;
  readonly code: number;
  readonly message: string;

  constructor(stage: string, errorType: string, code: number, message: string) {
    this.stage = stage;
    this.errorType = errorType;
    this.code = code;
    this.message = message;
  }
}

export class SteamArkNetworkProbeSiteResult {
  readonly targetId: string;
  readonly url: string;
  readonly kind: SteamArkNetworkProbeTargetKind;
  readonly statusCode: number;
  readonly succeeded: boolean;
  readonly supported: boolean;
  readonly durationMs: number;
  readonly testedAtEpochMs: number;
  readonly error: SteamArkNetworkProbeError | null;

  constructor(target: SteamArkNetworkProbeTarget, statusCode: number, succeeded: boolean,
    supported: boolean, durationMs: number, testedAtEpochMs: number,
    error: SteamArkNetworkProbeError | null = null) {
    this.targetId = target.targetId;
    this.url = target.url;
    this.kind = target.kind;
    this.statusCode = statusCode;
    this.succeeded = succeeded;
    this.supported = supported;
    this.durationMs = durationMs;
    this.testedAtEpochMs = testedAtEpochMs;
    this.error = error;
  }
}

/** Options for a probe that never sends Steam credentials or protocol payloads. */
export class HarmonySteamNetworkProbeOptions {
  readonly proxy: NGFProxyConfiguration;
  readonly httpProbeUrl: string;
  readonly wssProbeUrl: string;
  readonly userAgent: string;
  readonly timeoutMs: number;

  constructor(
    proxy: NGFProxyConfiguration = NGFProxyConfiguration.system(),
    httpProbeUrl: string = DEFAULT_HTTP_PROBE_URL,
    wssProbeUrl: string = DEFAULT_WSS_PROBE_URL,
    userAgent: string = DEFAULT_USER_AGENT,
    timeoutMs: number = DEFAULT_TIMEOUT_MS
  ) {
    if (httpProbeUrl.trim().length <= 0 || wssProbeUrl.trim().length <= 0) {
      throw new Error('Steam network probe URLs are required');
    }
    if (timeoutMs <= 0 || Math.floor(timeoutMs) !== timeoutMs) {
      throw new Error('Steam network probe timeout must be a positive integer');
    }
    this.proxy = proxy;
    this.httpProbeUrl = httpProbeUrl;
    this.wssProbeUrl = wssProbeUrl;
    this.userAgent = userAgent;
    this.timeoutMs = timeoutMs;
  }
}

/** Injectable factory keeps platform WebSocket creation outside the probe logic. */
export interface ISteamArkNetworkWebSocketFactory {
  create(): IWebSocketClient;
}

export class HarmonySteamNetworkWebSocketFactory implements ISteamArkNetworkWebSocketFactory {
  create(): IWebSocketClient {
    return new WebSocketClientFacade();
  }
}

/** Strongly typed, secret-free output from a network probe. */
export class SteamArkNetworkProbeResult {
  readonly status: SteamArkNetworkProbeStatus;
  readonly httpStatusCode: number;
  readonly httpSucceeded: boolean;
  readonly wssSucceeded: boolean;
  readonly wssSupported: boolean;
  readonly httpError: SteamArkNetworkProbeError | null;
  readonly wssError: SteamArkNetworkProbeError | null;
  readonly sites: Array<SteamArkNetworkProbeSiteResult>;
  readonly testedAtEpochMs: number;

  constructor(
    status: SteamArkNetworkProbeStatus,
    httpStatusCode: number,
    httpSucceeded: boolean,
    wssSucceeded: boolean,
    wssSupported: boolean,
    httpError: SteamArkNetworkProbeError | null = null,
    wssError: SteamArkNetworkProbeError | null = null,
    sites: Array<SteamArkNetworkProbeSiteResult> = [],
    testedAtEpochMs: number = 0
  ) {
    this.status = status;
    this.httpStatusCode = httpStatusCode;
    this.httpSucceeded = httpSucceeded;
    this.wssSucceeded = wssSucceeded;
    this.wssSupported = wssSupported;
    this.httpError = httpError;
    this.wssError = wssError;
    this.sites = sites;
    this.testedAtEpochMs = testedAtEpochMs;
  }
}

class SteamArkHttpProbeResult {
  readonly statusCode: number;
  readonly succeeded: boolean;
  readonly error: SteamArkNetworkProbeError | null;

  constructor(statusCode: number, succeeded: boolean, error: SteamArkNetworkProbeError | null = null) {
    this.statusCode = statusCode;
    this.succeeded = succeeded;
    this.error = error;
  }
}

class SteamArkWssProbeResult {
  readonly succeeded: boolean;
  readonly error: SteamArkNetworkProbeError | null;
  readonly durationMs: number;

  constructor(succeeded: boolean, error: SteamArkNetworkProbeError | null = null, durationMs: number = 0) {
    this.succeeded = succeeded;
    this.error = error;
    this.durationMs = durationMs;
  }
}

/**
 * Performs only public reachability checks. It does not send ClientHello,
 * login messages, Cookie, access tokens, inventory requests, or writes.
 */
export class HarmonySteamNetworkProbe {
  private readonly options: HarmonySteamNetworkProbeOptions;
  private readonly session: IHttpSession;
  private readonly webSocketFactory: ISteamArkNetworkWebSocketFactory;

  constructor(
    options: HarmonySteamNetworkProbeOptions = new HarmonySteamNetworkProbeOptions(),
    session: IHttpSession = new NGFHttpSession(),
    webSocketFactory: ISteamArkNetworkWebSocketFactory = new HarmonySteamNetworkWebSocketFactory()
  ) {
    this.options = options;
    this.session = session;
    this.webSocketFactory = webSocketFactory;
  }

  async probe(): Promise<SteamArkNetworkProbeResult> {
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'network capability probe started; proxyMode=' + String(this.options.proxy.mode));
    this.session.clear();
    try {
      const result = await this.runProbe();
      SteamArkLog.info(TAG, 'network capability probe completed; status=' + String(result.status) +
        ', http=' + String(result.httpSucceeded) + ', wss=' + String(result.wssSucceeded) +
        ', wssSupported=' + String(result.wssSupported));
      SteamArkLog.performance(TAG, 'network capability probe', startedAt);
      return result;
    } catch (error) {
      SteamArkLog.error(TAG, 'network capability probe failed; errorType=' + SteamArkLog.errorKind(error));
      SteamArkLog.performance(TAG, 'network capability probe failed', startedAt);
      throw error instanceof Error ? error : new Error('Steam network capability probe failed');
    } finally {
      this.session.clear();
      SteamArkLog.debug(TAG, 'network capability probe HTTP session cleared');
    }
  }

  private async runProbe(): Promise<SteamArkNetworkProbeResult> {
    const sites: Array<SteamArkNetworkProbeSiteResult> = [];
    const httpTargets: Array<SteamArkNetworkProbeTarget> = this.httpTargets();
    for (let index = 0; index < httpTargets.length; index++) {
      sites.push(await this.probeHttpSite(httpTargets[index]));
    }
    const wssSupported: boolean = this.options.proxy.mode !== NGFProxyMode.SOCKS5;
    let wssResult: SteamArkWssProbeResult = new SteamArkWssProbeResult(false);
    if (wssSupported) {
      wssResult = await this.probeWss();
    }
    const wssTarget = new SteamArkNetworkProbeTarget('cm', this.options.wssProbeUrl, SteamArkNetworkProbeTargetKind.WSS);
    sites.push(new SteamArkNetworkProbeSiteResult(wssTarget, 0, wssResult.succeeded, wssSupported,
      wssResult.durationMs, Date.now(), wssResult.error));
    const firstHttp: SteamArkNetworkProbeSiteResult = sites[0];
    return new SteamArkNetworkProbeResult(
      this.resolveStatus(sites),
      firstHttp.statusCode,
      firstHttp.succeeded,
      wssResult.succeeded,
      wssSupported,
      firstHttp.error,
      wssResult.error,
      sites,
      Date.now()
    );
  }

  private httpTargets(): Array<SteamArkNetworkProbeTarget> {
    if (this.options.httpProbeUrl !== DEFAULT_HTTP_PROBE_URL) {
      return [new SteamArkNetworkProbeTarget('custom-http', this.options.httpProbeUrl, SteamArkNetworkProbeTargetKind.HTTP)];
    }
    return DEFAULT_HTTP_TARGETS.slice();
  }

  private async probeHttp(): Promise<SteamArkHttpProbeResult> {
    const target: SteamArkNetworkProbeTarget = new SteamArkNetworkProbeTarget('http', this.options.httpProbeUrl,
      SteamArkNetworkProbeTargetKind.HTTP);
    const site: SteamArkNetworkProbeSiteResult = await this.probeHttpSite(target);
    return new SteamArkHttpProbeResult(site.statusCode, site.succeeded, site.error);
  }

  private async probeHttpSite(target: SteamArkNetworkProbeTarget): Promise<SteamArkNetworkProbeSiteResult> {
    const startedAt: number = Date.now();
    const headers = new Map<string, string>();
    headers.set('Accept', 'text/html,application/xhtml+xml');
    headers.set('User-Agent', this.options.userAgent);
    const request = new NGFHttpSessionRequest(
      NGFHttpMethod.GET,
      target.url,
      headers,
      '',
      this.options.timeoutMs,
      false,
      this.options.proxy
    );
    try {
      const response = await this.session.request(request);
      const succeeded: boolean = response.statusCode >= 200 && response.statusCode < 400;
      SteamArkLog.debug(TAG, 'public HTTP probe completed; status=' + response.statusCode.toString() +
        ', success=' + String(succeeded));
      const responseError: SteamArkNetworkProbeError | null = succeeded
        ? null
        : this.httpStatusError(response.statusCode);
      return new SteamArkNetworkProbeSiteResult(target, response.statusCode, succeeded, true,
        Date.now() - startedAt, Date.now(), responseError);
    } catch (error) {
      const detail = this.toProbeError(error, 'http_request', 'HTTP probe request failed');
      SteamArkLog.warn(TAG, 'public HTTP probe failed; errorType=' + SteamArkLog.errorKind(error) +
        ', stage=' + detail.stage + ', code=' + detail.code.toString());
      return new SteamArkNetworkProbeSiteResult(target, 0, false, true,
        Date.now() - startedAt, Date.now(), detail);
    }
  }

  private async probeWss(): Promise<SteamArkWssProbeResult> {
    const startedAt: number = Date.now();
    let client: IWebSocketClient | null = null;
    try {
      client = this.webSocketFactory.create();
      const header: string = this.options.userAgent.length > 0
        ? 'User-Agent: ' + this.options.userAgent
        : '';
      const socketOptions = new NGFWebSocketOptions(
        header,
        this.options.proxy,
        15,
        15
      );
      await client.connect(this.options.wssProbeUrl, socketOptions);
      SteamArkLog.debug(TAG, 'public WSS probe completed; success=true');
      return new SteamArkWssProbeResult(true, null, Date.now() - startedAt);
    } catch (error) {
      const detail = this.toProbeError(error, 'wss_connect', 'WSS probe connection failed');
      SteamArkLog.warn(TAG, 'public WSS probe failed; errorType=' + SteamArkLog.errorKind(error) +
        ', stage=' + detail.stage + ', code=' + detail.code.toString());
      return new SteamArkWssProbeResult(false, detail, Date.now() - startedAt);
    } finally {
      if (client !== null) {
        try {
          await client.close();
        } catch (error) {
          SteamArkLog.debug(TAG, 'public WSS probe cleanup failed; errorType=' + SteamArkLog.errorKind(error));
          // The probe result is already determined by the connection attempt.
        }
      }
    }
  }

  private toProbeError(
    error: Error | Object,
    stage: string,
    fallbackMessage: string
  ): SteamArkNetworkProbeError {
    const errorLike: SteamErrorLike = error as SteamErrorLike;
    const errorType: string = error instanceof Error && error.name.length > 0
      ? error.name
      : errorLike.name === undefined || errorLike.name.length <= 0 ? 'NonError' : errorLike.name;
    const code: number = errorLike.code !== undefined && Number.isSafeInteger(errorLike.code)
      ? errorLike.code
      : 0;
    const rawMessage: string = error instanceof Error
      ? error.message
      : errorLike.message === undefined ? '' : errorLike.message;
    return new SteamArkNetworkProbeError(
      stage,
      errorType,
      code,
      this.sanitizeProbeMessage(rawMessage, fallbackMessage)
    );
  }

  private sanitizeProbeMessage(message: string, fallbackMessage: string): string {
    let normalized = message.replace(/\r/g, ' ').replace(/\n/g, ' ').trim();
    if (normalized.length <= 0) {
      normalized = fallbackMessage;
    }
    const proxyPassword = this.options.proxy.password;
    if (proxyPassword.length > 0) {
      normalized = normalized.split(proxyPassword).join('[redacted]');
    }
    normalized = normalized.replace(/(https?:\/\/[^\s/:]+:)[^@\s]+@/gi, '$1[redacted]@');
    normalized = normalized.replace(/(password\s*[=:])[^\s,;]+/gi, '$1[redacted]');
    return normalized.length <= 512 ? normalized : normalized.substring(0, 512);
  }

  private httpStatusError(statusCode: number): SteamArkNetworkProbeError {
    if (statusCode >= 400 && statusCode < 500) {
      return new SteamArkNetworkProbeError(
        'http_response',
        'ApiRestricted',
        statusCode,
        'Endpoint is reachable but this request is restricted by Steam.'
      );
    }
    return new SteamArkNetworkProbeError(
      'http_response',
      'HttpStatus',
      statusCode,
      'HTTP probe returned status ' + statusCode.toString()
    );
  }

  private resolveStatus(sites: Array<SteamArkNetworkProbeSiteResult>): SteamArkNetworkProbeStatus {
    let supportedCount: number = 0;
    let successCount: number = 0;
    for (let index = 0; index < sites.length; index++) {
      if (sites[index].supported) {
        supportedCount += 1;
      }
      if (sites[index].succeeded) {
        successCount += 1;
      }
    }
    if (supportedCount > 0 && successCount === supportedCount) {
      return SteamArkNetworkProbeStatus.SUCCESS;
    }
    if (successCount > 0) {
      return SteamArkNetworkProbeStatus.PARTIAL;
    }
    if (supportedCount <= 0) {
      return SteamArkNetworkProbeStatus.UNSUPPORTED;
    }
    return SteamArkNetworkProbeStatus.FAILED;
  }
}
