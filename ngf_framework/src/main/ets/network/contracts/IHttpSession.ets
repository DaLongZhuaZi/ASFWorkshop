import { NGFHttpMethod } from '../../contentSource/contracts/IHttpClient';
import { NGFProxyConfiguration } from './NGFProxyConfiguration';

export class NGFHttpSessionRequest {
  readonly method: NGFHttpMethod;
  readonly url: string;
  readonly headers: Map<string, string>;
  readonly body: string;
  readonly timeoutMs: number;
  readonly expectBinary: boolean;
  readonly proxy: NGFProxyConfiguration;

  constructor(
    method: NGFHttpMethod,
    url: string,
    headers: Map<string, string> = new Map<string, string>(),
    body: string = '',
    timeoutMs: number = 30000,
    expectBinary: boolean = false,
    proxy: NGFProxyConfiguration = NGFProxyConfiguration.system()
  ) {
    this.method = method;
    this.url = url;
    this.headers = new Map<string, string>();
    headers.forEach((value: string, key: string): void => {
      this.headers.set(key, value);
    });
    this.body = body;
    this.timeoutMs = timeoutMs;
    this.expectBinary = expectBinary;
    this.proxy = proxy;
  }
}

export class NGFHttpSessionResponse {
  readonly statusCode: number;
  readonly headers: Map<string, string>;
  readonly body: string;
  readonly bodyBytes: Uint8Array;
  readonly cookies: string;

  constructor(
    statusCode: number,
    headers: Map<string, string>,
    body: string,
    bodyBytes: Uint8Array,
    cookies: string
  ) {
    this.statusCode = statusCode;
    this.headers = headers;
    this.body = body;
    this.bodyBytes = bodyBytes;
    this.cookies = cookies;
  }

  isOk(): boolean {
    return this.statusCode >= 200 && this.statusCode < 300;
  }
}

export class NGFCookie {
  readonly name: string;
  readonly value: string;
  readonly domain: string;
  readonly path: string;
  readonly secure: boolean;
  readonly hostOnly: boolean;
  readonly expiresAtEpochSeconds: number;

  constructor(
    name: string,
    value: string,
    domain: string,
    path: string,
    secure: boolean,
    hostOnly: boolean = true,
    expiresAtEpochSeconds: number = 0
  ) {
    this.name = name;
    this.value = value;
    this.domain = domain;
    this.path = path;
    this.secure = secure;
    this.hostOnly = hostOnly;
    this.expiresAtEpochSeconds = expiresAtEpochSeconds;
  }
}

/**
 * In-memory cookie jar. Values are serialized only for the secure credential
 * store. The jar intentionally implements the subset needed by HTTP sessions:
 * host-only/domain cookies, path matching, Secure, Max-Age and Expires.
 */
export class NGFCookieJar {
  private readonly cookies: Map<string, NGFCookie> = new Map<string, NGFCookie>();

  setFromResponse(
    url: string,
    responseCookies: string,
    nowEpochSeconds: number = NGFCookieJar.nowEpochSeconds()
  ): void {
    if (responseCookies.trim().length <= 0) {
      return;
    }
    const defaultDomain = this.hostFromUrl(url);
    const defaultPath = this.defaultCookiePath(url);
    if (defaultDomain.length === 0) {
      return;
    }
    const records = this.splitSetCookieRecords(responseCookies);
    for (let index = 0; index < records.length; index++) {
      this.setCookieLine(records[index], defaultDomain, defaultPath, nowEpochSeconds);
    }
  }

  setCookieHeader(url: string, cookieHeader: string): void {
    if (cookieHeader.trim().length <= 0) {
      return;
    }
    const domain = this.hostFromUrl(url);
    if (domain.length === 0) {
      return;
    }
    const parts = cookieHeader.split(';');
    for (let index = 0; index < parts.length; index++) {
      const pair = parts[index].trim();
      const separator = pair.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      const name = pair.substring(0, separator).trim();
      if (!NGFCookieJar.isValidCookieName(name) || NGFCookieJar.isCookieAttribute(name)) {
        continue;
      }
      const value = pair.substring(separator + 1).trim();
      const cookie = new NGFCookie(name, value, domain, '/', false, true, 0);
      this.cookies.set(this.cookieKey(cookie), cookie);
    }
  }

  getCookieHeader(url: string, nowEpochSeconds: number = NGFCookieJar.nowEpochSeconds()): string {
    const host = this.hostFromUrl(url);
    const path = this.pathFromUrl(url);
    const secureRequest = this.schemeFromUrl(url) === 'https';
    const matched: Array<NGFCookie> = [];
    const expiredKeys: Array<string> = [];
    this.cookies.forEach((cookie: NGFCookie, key: string): void => {
      if (NGFCookieJar.isExpired(cookie, nowEpochSeconds)) {
        expiredKeys.push(key);
        return;
      }
      if (cookie.secure && !secureRequest) {
        return;
      }
      if (this.matchesDomain(host, cookie) && this.matchesPath(path, cookie.path)) {
        matched.push(cookie);
      }
    });
    for (let index = 0; index < expiredKeys.length; index++) {
      this.cookies.delete(expiredKeys[index]);
    }
    NGFCookieJar.sortByPathLength(matched);
    const values: Array<string> = [];
    for (let index = 0; index < matched.length; index++) {
      const cookie = matched[index];
      values.push(cookie.name + '=' + cookie.value);
    }
    return values.join('; ');
  }

  clear(): void {
    this.cookies.clear();
  }

  serializeForSecureStore(): string {
    const records: Array<NGFCookieRecord> = [];
    this.cookies.forEach((cookie: NGFCookie): void => {
      records.push(new NGFCookieRecord(
        cookie.name,
        cookie.value,
        cookie.domain,
        cookie.path,
        cookie.secure,
        cookie.hostOnly,
        cookie.expiresAtEpochSeconds
      ));
    });
    return JSON.stringify(records);
  }

  restoreFromSecureStore(
    serialized: string,
    nowEpochSeconds: number = NGFCookieJar.nowEpochSeconds()
  ): void {
    this.clear();
    if (serialized.trim().length <= 0) {
      return;
    }
    try {
      const records = JSON.parse(serialized) as Array<NGFCookieRecord>;
      for (let index = 0; index < records.length; index++) {
        const record = records[index];
        if (record.name.length <= 0 || record.domain.length <= 0) {
          continue;
        }
        const expiresAtEpochSeconds = Number.isSafeInteger(record.expiresAtEpochSeconds)
          ? record.expiresAtEpochSeconds
          : 0;
        if (expiresAtEpochSeconds > 0 && expiresAtEpochSeconds <= nowEpochSeconds) {
          continue;
        }
        const hostOnly = record.hostOnly !== false;
        const cookie = new NGFCookie(
          record.name,
          record.value,
          record.domain.toLowerCase(),
          record.path.startsWith('/') ? record.path : '/',
          record.secure,
          hostOnly,
          expiresAtEpochSeconds
        );
        this.cookies.set(this.cookieKey(cookie), cookie);
      }
    } catch {
      this.clear();
    }
  }

  private setCookieLine(
    line: string,
    defaultDomain: string,
    defaultPath: string,
    nowEpochSeconds: number
  ): void {
    const segments = line.trim().split(';');
    if (segments.length <= 0) {
      return;
    }
    const first = segments[0];
    const separator = first.indexOf('=');
    if (separator <= 0) {
      return;
    }
    const name = first.substring(0, separator).trim();
    if (!NGFCookieJar.isValidCookieName(name) || NGFCookieJar.isCookieAttribute(name)) {
      return;
    }
    const value = first.substring(separator + 1).trim();
    let domain = defaultDomain;
    let hostOnly = true;
    let path = defaultPath;
    let secure = false;
    let hasMaxAge = false;
    let maxAge = 0;
    let hasExpires = false;
    let expiresAtEpochSeconds = 0;
    for (let index = 1; index < segments.length; index++) {
      const attribute = segments[index].trim();
      const attributeSeparator = attribute.indexOf('=');
      const attributeName = (attributeSeparator > 0 ? attribute.substring(0, attributeSeparator) : attribute).trim().toLowerCase();
      const attributeValue = attributeSeparator > 0 ? attribute.substring(attributeSeparator + 1).trim() : '';
      if (attributeName === 'domain' && attributeValue.length > 0) {
        const candidateDomain = attributeValue.startsWith('.')
          ? attributeValue.substring(1).toLowerCase()
          : attributeValue.toLowerCase();
        if (!this.matchesDomainName(defaultDomain, candidateDomain)) {
          return;
        }
        domain = candidateDomain;
        hostOnly = false;
      } else if (attributeName === 'path' && attributeValue.length > 0) {
        path = attributeValue.startsWith('/') ? attributeValue : defaultPath;
      } else if (attributeName === 'secure') {
        secure = true;
      } else if (attributeName === 'max-age') {
        const parsedMaxAge = NGFCookieJar.parseMaxAge(attributeValue);
        if (parsedMaxAge !== null) {
          hasMaxAge = true;
          maxAge = parsedMaxAge;
        }
      } else if (attributeName === 'expires') {
        const parsedExpires = NGFCookieJar.parseExpires(attributeValue);
        if (parsedExpires !== null) {
          hasExpires = true;
          expiresAtEpochSeconds = parsedExpires;
        }
      }
    }
    if (hasMaxAge) {
      if (maxAge <= 0) {
        this.deleteCookie(name, domain, path, hostOnly);
        return;
      }
      expiresAtEpochSeconds = NGFCookieJar.addLifetime(nowEpochSeconds, maxAge);
    } else if (hasExpires && expiresAtEpochSeconds <= nowEpochSeconds) {
      this.deleteCookie(name, domain, path, hostOnly);
      return;
    }
    const cookie = new NGFCookie(name, value, domain, path, secure, hostOnly, expiresAtEpochSeconds);
    this.cookies.set(this.cookieKey(cookie), cookie);
  }

  private cookieKey(cookie: NGFCookie): string {
    return cookie.domain + '|' + cookie.path + '|' + cookie.name;
  }

  private hostFromUrl(url: string): string {
    const schemeEnd = url.indexOf('://');
    const start = schemeEnd >= 0 ? schemeEnd + 3 : 0;
    let end = url.length;
    const slash = url.indexOf('/', start);
    const query = url.indexOf('?', start);
    const fragment = url.indexOf('#', start);
    if (slash >= 0 && slash < end) {
      end = slash;
    }
    if (query >= 0 && query < end) {
      end = query;
    }
    if (fragment >= 0 && fragment < end) {
      end = fragment;
    }
    const authority = end >= 0 ? url.substring(start, end) : url.substring(start);
    if (authority.startsWith('[')) {
      const closingBracket = authority.indexOf(']');
      return closingBracket > 1 ? authority.substring(1, closingBracket).toLowerCase() : '';
    }
    const portSeparator = authority.lastIndexOf(':');
    return (portSeparator > 0 ? authority.substring(0, portSeparator) : authority).toLowerCase();
  }

  private pathFromUrl(url: string): string {
    const schemeEnd = url.indexOf('://');
    const authorityStart = schemeEnd >= 0 ? schemeEnd + 3 : 0;
    const start = url.indexOf('/', authorityStart);
    if (start < 0) {
      return '/';
    }
    let end = url.length;
    const query = url.indexOf('?', start);
    const fragment = url.indexOf('#', start);
    if (query >= 0 && query < end) {
      end = query;
    }
    if (fragment >= 0 && fragment < end) {
      end = fragment;
    }
    return url.substring(start, end).length > 0 ? url.substring(start, end) : '/';
  }

  private schemeFromUrl(url: string): string {
    const separator = url.indexOf('://');
    return separator >= 0 ? url.substring(0, separator).toLowerCase() : '';
  }

  private matchesDomain(host: string, cookie: NGFCookie): boolean {
    if (cookie.hostOnly) {
      return host === cookie.domain;
    }
    return this.matchesDomainName(host, cookie.domain);
  }

  private matchesPath(path: string, cookiePath: string): boolean {
    return path === cookiePath || path.startsWith(cookiePath.endsWith('/') ? cookiePath : cookiePath + '/');
  }

  private deleteCookie(name: string, domain: string, path: string, hostOnly: boolean): void {
    const cookie = new NGFCookie(name, '', domain, path, false, hostOnly, 0);
    this.cookies.delete(this.cookieKey(cookie));
  }

  private splitSetCookieRecords(value: string): Array<string> {
    const records: Array<string> = [];
    const lines = value.split(/\r?\n/);
    for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      let line = lines[lineIndex].trim();
      if (line.toLowerCase().startsWith('set-cookie:')) {
        line = line.substring('set-cookie:'.length).trim();
      }
      if (line.length === 0) {
        continue;
      }
      let start = 0;
      let quoted = false;
      for (let index = 0; index < line.length; index++) {
        const current = line.charAt(index);
        if (current === '"' && (index === 0 || line.charAt(index - 1) !== '\\')) {
          quoted = !quoted;
        }
        if (current === ',' && !quoted && this.isCookiePairStart(line, index + 1)) {
          const record = line.substring(start, index).trim();
          if (record.length > 0) {
            records.push(record);
          }
          start = index + 1;
        }
      }
      const last = line.substring(start).trim();
      if (last.length > 0) {
        records.push(last);
      }
    }
    return records;
  }

  private isCookiePairStart(value: string, start: number): boolean {
    let cursor = start;
    while (cursor < value.length && value.charAt(cursor) === ' ') {
      cursor++;
    }
    const separator = value.indexOf('=', cursor);
    if (separator <= cursor) {
      return false;
    }
    const semicolon = value.indexOf(';', cursor);
    if (semicolon >= 0 && separator > semicolon) {
      return false;
    }
    const name = value.substring(cursor, separator).trim();
    if (!NGFCookieJar.isValidCookieName(name)) {
      return false;
    }
    return !NGFCookieJar.isCookieAttribute(name);
  }

  private static isCookieAttribute(name: string): boolean {
    const normalized = name.trim().toLowerCase();
    return normalized === 'domain' || normalized === 'path' || normalized === 'secure' ||
      normalized === 'httponly' || normalized === 'samesite' || normalized === 'expires' ||
      normalized === 'max-age' || normalized === 'priority' || normalized === 'partitioned';
  }

  private static isValidCookieName(name: string): boolean {
    if (name.length === 0) {
      return false;
    }
    for (let index = 0; index < name.length; index++) {
      const code = name.charCodeAt(index);
      if (code <= 32 || code === 34 || code === 40 || code === 41 ||
        code === 44 || code === 47 || code === 58 || code === 59 ||
        code === 60 || code === 61 || code === 62 || code === 63 ||
        code === 64 || code === 91 || code === 92 || code === 93 ||
        code === 123 || code === 125) {
        return false;
      }
    }
    return true;
  }

  private static parseMaxAge(value: string): number | null {
    if (value.trim().length === 0) {
      return null;
    }
    const parsed = Number(value.trim());
    return Number.isSafeInteger(parsed) ? parsed : null;
  }

  private static parseExpires(value: string): number | null {
    const milliseconds = Date.parse(value.trim());
    if (isNaN(milliseconds)) {
      return null;
    }
    return Math.floor(milliseconds / 1000);
  }

  private static addLifetime(nowEpochSeconds: number, lifetimeSeconds: number): number {
    const result = nowEpochSeconds + lifetimeSeconds;
    return Number.isSafeInteger(result) ? result : Number.MAX_SAFE_INTEGER;
  }

  private static isExpired(cookie: NGFCookie, nowEpochSeconds: number): boolean {
    return cookie.expiresAtEpochSeconds > 0 && cookie.expiresAtEpochSeconds <= nowEpochSeconds;
  }

  private static sortByPathLength(cookies: Array<NGFCookie>): void {
    for (let index = 1; index < cookies.length; index++) {
      const current = cookies[index];
      let insertIndex = index;
      while (insertIndex > 0 &&
        cookies[insertIndex - 1].path.length < current.path.length) {
        cookies[insertIndex] = cookies[insertIndex - 1];
        insertIndex--;
      }
      cookies[insertIndex] = current;
    }
  }

  private static nowEpochSeconds(): number {
    return Math.floor(Date.now() / 1000);
  }

  private matchesDomainName(host: string, domain: string): boolean {
    return host === domain || host.endsWith('.' + domain);
  }

  private defaultCookiePath(url: string): string {
    const requestPath = this.pathFromUrl(url);
    const lastSlash = requestPath.lastIndexOf('/');
    if (lastSlash <= 0) {
      return '/';
    }
    return requestPath.substring(0, lastSlash);
  }
}

class NGFCookieRecord {
  name: string;
  value: string;
  domain: string;
  path: string;
  secure: boolean;
  hostOnly: boolean;
  expiresAtEpochSeconds: number;

  constructor(
    name: string,
    value: string,
    domain: string,
    path: string,
    secure: boolean,
    hostOnly: boolean = true,
    expiresAtEpochSeconds: number = 0
  ) {
    this.name = name;
    this.value = value;
    this.domain = domain;
    this.path = path;
    this.secure = secure;
    this.hostOnly = hostOnly;
    this.expiresAtEpochSeconds = expiresAtEpochSeconds;
  }
}

export interface IHttpSession {
  request(options: NGFHttpSessionRequest): Promise<NGFHttpSessionResponse>;
  readonly cookieJar: NGFCookieJar;
  clear(): void;
}
