import { http } from '@kit.NetworkKit';
import { logger } from '../../utils/Logger';
import { NGFHttpMethod } from '../../contentSource/contracts/IHttpClient';
import { NGFProxyMode } from '../contracts/NGFProxyConfiguration';
import { NGFHttpHeaderObject } from '../NGFHttpHeaderObject';
import {
  IHttpSession,
  NGFCookieJar,
  NGFHttpSessionRequest,
  NGFHttpSessionResponse
} from '../contracts/IHttpSession';

const TAG: string = 'NGFHttpSession';

export class NGFHttpSession implements IHttpSession {
  readonly cookieJar: NGFCookieJar = new NGFCookieJar();

  async request(options: NGFHttpSessionRequest): Promise<NGFHttpSessionResponse> {
    const request = http.createHttp();
    const headers = new Map<string, string>();
    options.headers.forEach((value: string, key: string): void => {
      headers.set(key, value);
    });
    const cookieHeader = this.cookieJar.getCookieHeader(options.url);
    if (cookieHeader.length > 0 && !this.hasCallerCookieHeader(options.headers)) {
      // An explicit caller Cookie header wins; the jar would otherwise drop it.
      headers.set('Cookie', cookieHeader);
    }
    const requestOptions = this.buildOptions(options, headers);
    try {
      const response = await request.request(options.url, requestOptions) as http.HttpResponse;
      const responseHeaders = this.readHeaders(response.header);
      const body = this.readBody(response.result);
      this.cookieJar.setFromResponse(options.url, response.cookies);
      logger.debug(TAG, 'HTTP session request completed, status=' + String(response.responseCode));
      return new NGFHttpSessionResponse(
        response.responseCode,
        responseHeaders,
        body.text,
        body.bytes,
        response.cookies
      );
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error(String(error));
      logger.warn(TAG, 'HTTP session request failed: ' + normalized.message);
      throw normalized;
    } finally {
      request.destroy();
    }
  }

  clear(): void {
    this.cookieJar.clear();
  }

  private hasCallerCookieHeader(headers: Map<string, string>): boolean {
    let present = false;
    headers.forEach((value: string, key: string): void => {
      if (key.toLowerCase() === 'cookie' && value.length > 0) {
        present = true;
      }
    });
    return present;
  }

  private buildOptions(options: NGFHttpSessionRequest, headers: Map<string, string>): http.HttpRequestOptions {
    const result: http.HttpRequestOptions = {
      method: this.mapMethod(options.method),
      connectTimeout: options.timeoutMs,
      readTimeout: options.timeoutMs,
      expectDataType: options.expectBinary ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
      header: this.buildHeaderObject(headers)
    };
    if (options.body.length > 0) {
      result.extraData = options.body;
    }
    if (options.proxy.mode === NGFProxyMode.DIRECT) {
      result.usingProxy = false;
    } else if (options.proxy.mode === NGFProxyMode.SYSTEM) {
      // NetStack treats an unset usingProxy as "no proxy"; true explicitly asks
      // for the system default proxy (falls back to direct when none is set).
      result.usingProxy = true;
    } else if (options.proxy.mode === NGFProxyMode.HTTP) {
      result.usingProxy = options.proxy.toHttpProxy();
    } else if (options.proxy.mode === NGFProxyMode.SOCKS5) {
      result.usingSocks5Proxy = options.proxy.toSocks5Proxy();
    }
    return result;
  }

  private mapMethod(method: NGFHttpMethod): http.RequestMethod {
    if (method === NGFHttpMethod.POST) {
      return http.RequestMethod.POST;
    }
    if (method === NGFHttpMethod.PUT) {
      return http.RequestMethod.PUT;
    }
    if (method === NGFHttpMethod.DELETE) {
      return http.RequestMethod.DELETE;
    }
    if (method === NGFHttpMethod.PATCH) {
      return http.RequestMethod.PATCH;
    }
    if (method === NGFHttpMethod.HEAD) {
      return http.RequestMethod.HEAD;
    }
    return http.RequestMethod.GET;
  }

  private buildHeaderObject(headers: Map<string, string>): Object {
    const result: NGFHttpHeaderObject = new NGFHttpHeaderObject();
    headers.forEach((value: string, key: string): void => {
      result.set(key, value);
    });
    return result.asObject();
  }

  private readHeaders(header: Object): Map<string, string> {
    const result = new Map<string, string>();
    try {
      const entries = Object.entries(header) as Array<[string, string | Array<string> | undefined]>;
      for (let index = 0; index < entries.length; index++) {
        const entry = entries[index];
        const value = entry[1];
        if (value === undefined) {
          continue;
        }
        result.set(entry[0], Array.isArray(value) ? value.join(', ') : value);
      }
    } catch {
      return result;
    }
    return result;
  }

  private readBody(result: string | Object | ArrayBuffer): NGFBodyReadResult {
    if (typeof result === 'string') {
      return new NGFBodyReadResult(result, new Uint8Array(0));
    }
    if (result instanceof ArrayBuffer) {
      return new NGFBodyReadResult('', new Uint8Array(result));
    }
    // NetStack can still return an Object for a text request. Preserve its JSON payload instead
    // of coercing it to "[object Object]", which cannot be consumed by JSON-based callers.
    const serialized: string = JSON.stringify(result);
    logger.warn(TAG, 'HTTP session returned object response body; serialized JSON fallback used');
    return new NGFBodyReadResult(serialized, new Uint8Array(0));
  }
}

class NGFBodyReadResult {
  readonly text: string;
  readonly bytes: Uint8Array;

  constructor(text: string, bytes: Uint8Array) {
    this.text = text;
    this.bytes = bytes;
  }
}
