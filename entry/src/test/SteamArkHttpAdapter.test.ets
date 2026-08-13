import { describe, expect, it } from '@ohos/hypium';
import {
  IHttpSession,
  NGFCookieJar,
  NGFHttpMethod,
  NGFHttpHeaderObject,
  NGFHttpSessionRequest,
  NGFHttpSessionResponse,
  NGFProxyConfiguration,
  NGFProxyMode
} from 'ngf_framework';
import {
  HarmonySteamAuthTransport,
  HarmonySteamAuthTransportOptions,
  HarmonySteamWebTransport,
  HarmonySteamWebTransportOptions,
  SteamWebSessionIdGenerator
} from '../main/ets/steamAdapters';
import {
  SteamAuthEndpoint,
  SteamFormField,
  SteamWebRequest
} from 'steam_core';

class FakeHttpResponseFixture {
  readonly statusCode: number;
  readonly body: string;
  readonly cookies: string;

  constructor(statusCode: number, body: string, cookies: string = '') {
    this.statusCode = statusCode;
    this.body = body;
    this.cookies = cookies;
  }
}

class FakeHttpRequestRecord {
  readonly options: NGFHttpSessionRequest;
  readonly effectiveHeaders: Map<string, string>;

  constructor(options: NGFHttpSessionRequest, effectiveHeaders: Map<string, string>) {
    this.options = options;
    this.effectiveHeaders = effectiveHeaders;
  }

  safeSummary(): string {
    return this.options.method + ' ' + this.options.url +
      ' proxy=' + this.options.proxy.mode;
  }

  requiredHeader(name: string): string {
    const value = this.effectiveHeaders.get(name);
    if (value === undefined) {
      throw new Error('Missing effective header: ' + name);
    }
    return value;
  }
}

/** Fake host that models NGF's cookie injection and response-cookie update. */
class FakeHttpSession implements IHttpSession {
  readonly cookieJar: NGFCookieJar = new NGFCookieJar();
  readonly requests: Array<FakeHttpRequestRecord> = [];
  private readonly responses: Array<FakeHttpResponseFixture> = [];

  enqueue(response: FakeHttpResponseFixture): void {
    this.responses.push(response);
  }

  async request(options: NGFHttpSessionRequest): Promise<NGFHttpSessionResponse> {
    const effectiveHeaders = new Map<string, string>();
    options.headers.forEach((value: string, key: string): void => {
      effectiveHeaders.set(key, value);
    });
    const cookieHeader = this.cookieJar.getCookieHeader(options.url);
    if (cookieHeader.length > 0) {
      effectiveHeaders.set('Cookie', cookieHeader);
    }
    this.requests.push(new FakeHttpRequestRecord(options, effectiveHeaders));

    if (this.responses.length <= 0) {
      return new NGFHttpSessionResponse(
        200,
        new Map<string, string>(),
        '',
        new Uint8Array(0),
        ''
      );
    }
    const response: FakeHttpResponseFixture = this.responses.splice(0, 1)[0];
    this.cookieJar.setFromResponse(options.url, response.cookies);
    return new NGFHttpSessionResponse(
      response.statusCode,
      new Map<string, string>(),
      response.body,
      new Uint8Array(0),
      response.cookies
    );
  }

  clear(): void {
    this.cookieJar.clear();
  }
}

class HttpProxyFixture {
  readonly proxy: NGFProxyConfiguration;
  readonly mode: NGFProxyMode;
  readonly host: string;
  readonly port: number;

  constructor(proxy: NGFProxyConfiguration, mode: NGFProxyMode, host: string, port: number) {
    this.proxy = proxy;
    this.mode = mode;
    this.host = host;
    this.port = port;
  }
}

class FixedSessionIdGenerator extends SteamWebSessionIdGenerator {
  generate(byteLength: number): string {
    return '0123456789abcdef0123456789abcdef';
  }
}

export default function steamArkHttpAdapterTest(): void {
  describe('SteamArkHttpAdapter', () => {
    it('convertsHeaderBlocksToNetworkKitObjects', 0, () => {
      const header: NGFHttpHeaderObject = NGFHttpHeaderObject.fromBlock(
        'User-Agent: ASF Workshop Test\r\nAccept: application/json\r\nInvalidHeader'
      );
      const entries = Object.entries(header.asObject()) as Array<[string, string]>;
      expect(entries.length).assertEqual(2);
      expect(entries[0][0]).assertEqual('User-Agent');
      expect(entries[0][1]).assertEqual('ASF Workshop Test');
      expect(entries[1][0]).assertEqual('Accept');
      expect(entries[1][1]).assertEqual('application/json');
    });

    it('keepsWebCookiesHeadersAndProxyInAnIsolatedSession', 0, async () => {
      const session = new FakeHttpSession();
      session.cookieJar.setCookieHeader(
        'https://steamcommunity.com/',
        'stale_cookie=stale-value; Path=/; Secure'
      );
      session.enqueue(new FakeHttpResponseFixture(
        200,
        '{"ok":true}',
        'server_session=server-value; Domain=.steamcommunity.com; Path=/; Secure\r\n' +
        'server_path=path-value; Domain=.steamcommunity.com; Path=/inventory; Secure'
      ));
      session.enqueue(new FakeHttpResponseFixture(200, '{"ok":true}'));
      const transport = new HarmonySteamWebTransport(
        session,
        new HarmonySteamWebTransportOptions(
          NGFProxyConfiguration.http('proxy.example', 8080, 'proxy-user'),
          'ASF Workshop HTTP Test',
          12345,
          new FixedSessionIdGenerator()
        )
      );

      await transport.open('76561197960287930', 'access-token');
      const communityCookieHeader = session.cookieJar.getCookieHeader('https://steamcommunity.com/');
      const storeCookieHeader = session.cookieJar.getCookieHeader('https://store.steampowered.com/');
      const unrelatedCookieHeader = session.cookieJar.getCookieHeader('https://example.com/');
      expect(communityCookieHeader.indexOf('stale_cookie=')).assertEqual(-1);
      expect(storeCookieHeader.indexOf('sessionid=') >= 0).assertTrue();
      expect(storeCookieHeader.indexOf('steamLoginSecure=76561197960287930||access-token') >= 0).assertTrue();
      expect(storeCookieHeader.indexOf('Path=')).assertEqual(-1);
      expect(session.cookieJar.getCookieHeader('http://steamcommunity.com/').indexOf('sessionid=')).assertEqual(-1);
      expect(session.cookieJar.getCookieHeader('http://steamcommunity.com/').indexOf('steamLoginSecure=')).assertEqual(-1);
      expect(unrelatedCookieHeader).assertEqual('');
      const requestHeaders = new Map<string, string>();
      requestHeaders.set('Referer', 'https://steamcommunity.com/');
      const firstResponse = await transport.get(new SteamWebRequest(
        'https://steamcommunity.com/inventory/76561197960287930/753/6',
        requestHeaders
      ));
      expect(firstResponse.statusCode).assertEqual(200);
      expect(session.requests.length).assertEqual(1);

      const first = session.requests[0];
      expect(first.options.method).assertEqual(NGFHttpMethod.GET);
      expect(first.options.proxy.mode).assertEqual(NGFProxyMode.HTTP);
      expect(first.options.proxy.host).assertEqual('proxy.example');
      expect(first.options.proxy.port).assertEqual(8080);
      expect(first.options.timeoutMs).assertEqual(12345);
      expect(first.requiredHeader('Accept')).assertEqual('application/json');
      expect(first.requiredHeader('User-Agent')).assertEqual('ASF Workshop HTTP Test');
      const firstCookieHeader: string = first.requiredHeader('Cookie');
      expect(firstCookieHeader.indexOf('sessionid=') >= 0).assertTrue();
      expect(firstCookieHeader.indexOf('steamLoginSecure=76561197960287930||access-token') >= 0).assertTrue();

      const secondResponse = await transport.get(new SteamWebRequest(
        'https://steamcommunity.com/inventory/76561197960287930/753/6?start_assetid=1'
      ));
      expect(secondResponse.statusCode).assertEqual(200);
      expect(session.requests.length).assertEqual(2);
      const second: FakeHttpRequestRecord = session.requests[1];
      const secondCookieHeader: string = second.requiredHeader('Cookie');
      expect(secondCookieHeader.indexOf('server_session=server-value') >= 0).assertTrue();
      expect(secondCookieHeader.indexOf('server_path=path-value') >= 0).assertTrue();
      expect(first.safeSummary().indexOf('access-token')).assertEqual(-1);
      await transport.close();
      expect(session.cookieJar.getCookieHeader('https://steamcommunity.com/')).assertEqual('');
    });

    it('routesHttpAndSocks5RequestsThroughTheSelectedProxyMode', 0, async () => {
      const fixtures: Array<HttpProxyFixture> = [
        new HttpProxyFixture(NGFProxyConfiguration.system(), NGFProxyMode.SYSTEM, '', 0),
        new HttpProxyFixture(NGFProxyConfiguration.direct(), NGFProxyMode.DIRECT, '', 0),
        new HttpProxyFixture(NGFProxyConfiguration.http('proxy.example', 8080), NGFProxyMode.HTTP, 'proxy.example', 8080),
        new HttpProxyFixture(NGFProxyConfiguration.socks5('socks.example', 1080), NGFProxyMode.SOCKS5, 'socks.example', 1080)
      ];
      for (let index = 0; index < fixtures.length; index++) {
        const fixture: HttpProxyFixture = fixtures[index];
        const session = new FakeHttpSession();
        session.enqueue(new FakeHttpResponseFixture(204, ''));
        const transport = new HarmonySteamAuthTransport(
          session,
          new HarmonySteamAuthTransportOptions(fixture.proxy, 'ASF Workshop Auth Test')
        );
        const response = await transport.postForm(
          SteamAuthEndpoint.POLL_AUTH_SESSION,
          [new SteamFormField('request_id', 'request-' + index.toString())]
        );
        expect(response.statusCode).assertEqual(204);
        const request: FakeHttpRequestRecord = session.requests[0];
        expect(request.options.proxy.mode).assertEqual(fixture.mode);
        expect(request.options.proxy.host).assertEqual(fixture.host);
        expect(request.options.proxy.port).assertEqual(fixture.port);
      }
    });

    it('encodesAuthFormFieldsWithoutPuttingSecretsInSafeDiagnostics', 0, async () => {
      const session = new FakeHttpSession();
      session.enqueue(new FakeHttpResponseFixture(200, '{"response":{"success":1}}'));
      const transport = new HarmonySteamAuthTransport(
        session,
        new HarmonySteamAuthTransportOptions(NGFProxyConfiguration.direct(), 'ASF Workshop Auth Test')
      );
      const secretValue = 'p@ss word+&';
      await transport.postForm(
        SteamAuthEndpoint.BEGIN_AUTH_SESSION,
        [
          new SteamFormField('account_name', 'alice name'),
          new SteamFormField('encrypted_password', secretValue),
          new SteamFormField('device_details', '{"device_friendly_name":"ASF Workshop"}')
        ]
      );

      const request: FakeHttpRequestRecord = session.requests[0];
      expect(request.options.method).assertEqual(NGFHttpMethod.POST);
      expect(request.options.headers.get('Content-Type')).assertEqual(
        'application/x-www-form-urlencoded; charset=UTF-8'
      );
      expect(request.options.headers.get('User-Agent')).assertEqual('ASF Workshop Auth Test');
      expect(request.options.body).assertEqual(
        'account_name=alice+name&encrypted_password=p%40ss+word%2B%26&' +
        'device_details=%7B%22device_friendly_name%22%3A%22ASF+Workshop%22%7D'
      );
      expect(request.safeSummary().indexOf(secretValue)).assertEqual(-1);
    });

    it('honorsSecureCookieAndPathBoundaries', 0, () => {
      const jar = new NGFCookieJar();
      jar.setFromResponse(
        'https://steamcommunity.com/login',
        'secure_cookie=secure-value; Domain=.steamcommunity.com; Path=/; Secure\r\n' +
        'plain_cookie=plain-value; Domain=.steamcommunity.com; Path=/;\r\n' +
        'login_cookie=login-value; Domain=.steamcommunity.com; Path=/login; Secure'
      );
      const httpsHeader = jar.getCookieHeader('https://steamcommunity.com/login');
      expect(httpsHeader.indexOf('secure_cookie=secure-value') >= 0).assertTrue();
      expect(httpsHeader.indexOf('plain_cookie=plain-value') >= 0).assertTrue();
      expect(httpsHeader.indexOf('login_cookie=login-value') >= 0).assertTrue();
      const httpHeader = jar.getCookieHeader('http://steamcommunity.com/login');
      expect(httpHeader.indexOf('secure_cookie=secure-value')).assertEqual(-1);
      expect(httpHeader.indexOf('plain_cookie=plain-value') >= 0).assertTrue();
      expect(jar.getCookieHeader('https://steamcommunity.com/inventory').indexOf('login_cookie=')).assertEqual(-1);
    });

    it('parsesCombinedSetCookieRecordsAndHonorsExpiryPrecedence', 0, () => {
      const jar = new NGFCookieJar();
      const now = 1700000000;
      jar.setFromResponse(
        'https://steamcommunity.com/account/login',
        'root=root-value; Domain=.steamcommunity.com; Path=/; Secure; ' +
          'Expires=Wed, 21 Oct 2037 07:28:00 GMT, ' +
          'scoped=scoped-value; Path=/account/login; Secure; Max-Age=3600',
        now
      );

      const header = jar.getCookieHeader(
        'https://steamcommunity.com/account/login',
        now
      );
      expect(header.indexOf('scoped=scoped-value') >= 0).assertTrue();
      expect(header.indexOf('root=root-value') >= 0).assertTrue();
      expect(header.indexOf('scoped=scoped-value') < header.indexOf('root=root-value')).assertTrue();

      jar.setFromResponse(
        'https://steamcommunity.com/account/login',
        'scoped=deleted; Path=/account/login; Max-Age=0',
        now + 1
      );
      const afterDeletion = jar.getCookieHeader(
        'https://steamcommunity.com/account/login',
        now + 1
      );
      expect(afterDeletion.indexOf('scoped=')).assertEqual(-1);
      expect(afterDeletion.indexOf('root=root-value') >= 0).assertTrue();
    });

    it('keepsHostOnlyCookiesAndDefaultPathsWithinTheirOrigin', 0, () => {
      const jar = new NGFCookieJar();
      const now = 1700000000;
      jar.setFromResponse(
        'https://steamcommunity.com/account/login',
        'host_only=host-value; Secure\n' +
          'default_path=path-value; Secure\n' +
          'shared=shared-value; Domain=.steamcommunity.com; Path=/; Secure',
        now
      );

      const sameHost = jar.getCookieHeader(
        'https://steamcommunity.com/account/profile',
        now
      );
      expect(sameHost.indexOf('host_only=host-value') >= 0).assertTrue();
      expect(sameHost.indexOf('default_path=path-value') >= 0).assertTrue();
      expect(sameHost.indexOf('shared=shared-value') >= 0).assertTrue();

      const outsidePath = jar.getCookieHeader(
        'https://steamcommunity.com/accounting',
        now
      );
      expect(outsidePath.indexOf('default_path=')).assertEqual(-1);

      const subdomain = jar.getCookieHeader(
        'https://store.steamcommunity.com/account/profile',
        now
      );
      expect(subdomain.indexOf('host_only=')).assertEqual(-1);
      expect(subdomain.indexOf('default_path=')).assertEqual(-1);
      expect(subdomain.indexOf('shared=shared-value') >= 0).assertTrue();

      const restored = new NGFCookieJar();
      restored.restoreFromSecureStore(jar.serializeForSecureStore(), now);
      expect(restored.getCookieHeader('https://steamcommunity.com/account/profile', now))
        .assertEqual(sameHost);
    });

    it('removesExpiredCookiesBeforeHeaderConstruction', 0, () => {
      const jar = new NGFCookieJar();
      const now = 1700000000;
      jar.setFromResponse(
        'https://steamcommunity.com/',
        'short_lived=value; Path=/; Max-Age=1',
        now
      );
      expect(jar.getCookieHeader('https://steamcommunity.com/', now).indexOf('short_lived=value') >= 0)
        .assertTrue();
      expect(jar.getCookieHeader('https://steamcommunity.com/', now + 1).indexOf('short_lived='))
        .assertEqual(-1);
      expect(jar.serializeForSecureStore().indexOf('short_lived')).assertEqual(-1);
    });
  });
}
