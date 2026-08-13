import { describe, expect, it } from '@ohos/hypium';
import {
  IHttpSession,
  IWebSocketClient,
  NGFCookieJar,
  NGFHttpSessionRequest,
  NGFHttpSessionResponse,
  NGFProxyConfiguration,
  NGFProxyMode,
  NGFWebSocketCloseListener,
  NGFWebSocketErrorListener,
  NGFWebSocketMessageListener,
  NGFWebSocketOptions,
  NGFWebSocketState,
  NGFWebSocketStateListener
} from 'ngf_framework';
import {
  HarmonySteamNetworkProbe,
  HarmonySteamNetworkProbeOptions,
  ISteamArkNetworkWebSocketFactory,
  SteamArkNetworkProbeStatus
} from '../main/ets/steamAdapters';

class FakeHttpSession implements IHttpSession {
  readonly cookieJar: NGFCookieJar = new NGFCookieJar();
  readonly requests: Array<NGFHttpSessionRequest> = [];
  statusCode: number = 204;
  shouldFail: boolean = false;
  failureMessage: string = 'fake HTTP probe failure';
  observedCookieHeader: string = '';
  clearCount: number = 0;

  async request(options: NGFHttpSessionRequest): Promise<NGFHttpSessionResponse> {
    this.requests.push(options);
    this.observedCookieHeader = this.cookieJar.getCookieHeader(options.url);
    if (this.shouldFail) {
      throw new Error(this.failureMessage);
    }
    return new NGFHttpSessionResponse(
      this.statusCode,
      new Map<string, string>(),
      '',
      new Uint8Array(0),
      ''
    );
  }

  clear(): void {
    this.clearCount += 1;
    this.cookieJar.clear();
  }
}

class FakeWebSocketClient implements IWebSocketClient {
  private currentState: NGFWebSocketState = NGFWebSocketState.IDLE;
  private readonly messageListeners: Array<NGFWebSocketMessageListener> = [];
  private readonly stateListeners: Array<NGFWebSocketStateListener> = [];
  private readonly closeListeners: Array<NGFWebSocketCloseListener> = [];
  private readonly errorListeners: Array<NGFWebSocketErrorListener> = [];
  readonly shouldFail: boolean;
  lastOptions: NGFWebSocketOptions | null = null;
  connectCount: number = 0;
  closeCount: number = 0;

  constructor(shouldFail: boolean = false) {
    this.shouldFail = shouldFail;
  }

  get state(): NGFWebSocketState {
    return this.currentState;
  }

  async connect(url: string, options: NGFWebSocketOptions = new NGFWebSocketOptions()): Promise<void> {
    this.connectCount += 1;
    this.lastOptions = options;
    if (url.length <= 0) {
      throw new Error('fake WSS URL is empty');
    }
    if (this.shouldFail) {
      this.setState(NGFWebSocketState.ERROR);
      throw new Error('fake WSS probe failure');
    }
    this.setState(NGFWebSocketState.OPEN);
  }

  async send(_data: string | ArrayBuffer): Promise<void> {
    if (this.currentState !== NGFWebSocketState.OPEN) {
      throw new Error('fake WSS client is not open');
    }
  }

  async close(_code: number = 1000, _reason: string = ''): Promise<void> {
    this.closeCount += 1;
    this.setState(NGFWebSocketState.CLOSED);
  }

  onMessage(listener: NGFWebSocketMessageListener): void {
    this.messageListeners.push(listener);
  }

  onStateChange(listener: NGFWebSocketStateListener): void {
    this.stateListeners.push(listener);
  }

  onClose(listener: NGFWebSocketCloseListener): void {
    this.closeListeners.push(listener);
  }

  onError(listener: NGFWebSocketErrorListener): void {
    this.errorListeners.push(listener);
  }

  clearListeners(): void {
    this.messageListeners.splice(0, this.messageListeners.length);
    this.stateListeners.splice(0, this.stateListeners.length);
    this.closeListeners.splice(0, this.closeListeners.length);
    this.errorListeners.splice(0, this.errorListeners.length);
  }

  private setState(state: NGFWebSocketState): void {
    this.currentState = state;
    for (let index = 0; index < this.stateListeners.length; index++) {
      this.stateListeners[index](state);
    }
  }
}

class FakeWebSocketFactory implements ISteamArkNetworkWebSocketFactory {
  readonly clients: Array<FakeWebSocketClient> = [];
  shouldFail: boolean = false;

  create(): IWebSocketClient {
    const client = new FakeWebSocketClient(this.shouldFail);
    this.clients.push(client);
    return client;
  }
}

export default function steamArkNetworkProbeTest(): void {
  describe('SteamArkNetworkProbe', () => {
    it('reportsDirectHttpAndWssSuccessWithoutSendingPayloads', 0, async () => {
      const session = new FakeHttpSession();
      const factory = new FakeWebSocketFactory();
      const probe = new HarmonySteamNetworkProbe(
        new HarmonySteamNetworkProbeOptions(
          NGFProxyConfiguration.direct(),
          'https://probe.example/',
          'wss://probe.example/cmsocket/',
          'ASF Workshop Probe Test',
          1200
        ),
        session,
        factory
      );

      const result = await probe.probe();

      expect(result.status).assertEqual(SteamArkNetworkProbeStatus.SUCCESS);
      expect(result.httpStatusCode).assertEqual(204);
      expect(result.httpSucceeded).assertTrue();
      expect(result.wssSucceeded).assertTrue();
      expect(result.wssSupported).assertTrue();
      expect(session.requests.length).assertEqual(1);
      expect(session.requests[0].headers.get('Cookie') === undefined).assertTrue();
      expect(session.requests[0].headers.get('Authorization') === undefined).assertTrue();
      expect(factory.clients.length).assertEqual(1);
      expect(factory.clients[0].closeCount).assertEqual(1);
    });

    it('passesHttpProxyToBothReadOnlyChannels', 0, async () => {
      const session = new FakeHttpSession();
      const factory = new FakeWebSocketFactory();
      const proxy = NGFProxyConfiguration.http(
        'proxy.example',
        8080,
        'proxy-user',
        'proxy-password'
      );
      const probe = new HarmonySteamNetworkProbe(
        new HarmonySteamNetworkProbeOptions(proxy),
        session,
        factory
      );

      const result = await probe.probe();

      expect(result.status).assertEqual(SteamArkNetworkProbeStatus.SUCCESS);
      expect(session.requests[0].proxy.mode).assertEqual(NGFProxyMode.HTTP);
      expect(session.requests[0].proxy.host).assertEqual('proxy.example');
      expect(session.requests[0].proxy.port).assertEqual(8080);
      expect(factory.clients[0].lastOptions !== null).assertTrue();
      if (factory.clients[0].lastOptions !== null) {
        expect(factory.clients[0].lastOptions.proxy.mode).assertEqual(NGFProxyMode.HTTP);
        expect(factory.clients[0].lastOptions.proxy.host).assertEqual('proxy.example');
        expect(factory.clients[0].lastOptions.proxy.port).assertEqual(8080);
      }
      expect(JSON.stringify(result).indexOf('proxy-password')).assertEqual(-1);
    });

    it('keepsSocks5HttpSupportAndRejectsWssBeforeFactoryCreation', 0, async () => {
      const session = new FakeHttpSession();
      const factory = new FakeWebSocketFactory();
      const probe = new HarmonySteamNetworkProbe(
        new HarmonySteamNetworkProbeOptions(NGFProxyConfiguration.socks5('socks.example', 1080)),
        session,
        factory
      );

      const result = await probe.probe();

      expect(result.status).assertEqual(SteamArkNetworkProbeStatus.PARTIAL);
      expect(result.httpSucceeded).assertTrue();
      expect(result.wssSucceeded).assertFalse();
      expect(result.wssSupported).assertFalse();
      expect(factory.clients.length).assertEqual(0);
      expect(session.requests[0].proxy.mode).assertEqual(NGFProxyMode.SOCKS5);
    });

    it('returnsSafeFailureWhenHttpAndWssFail', 0, async () => {
      const session = new FakeHttpSession();
      session.shouldFail = true;
      session.failureMessage = 'proxy password=proxy-password';
      const factory = new FakeWebSocketFactory();
      factory.shouldFail = true;
      const probe = new HarmonySteamNetworkProbe(
        new HarmonySteamNetworkProbeOptions(NGFProxyConfiguration.direct()),
        session,
        factory
      );

      const result = await probe.probe();

      expect(result.status).assertEqual(SteamArkNetworkProbeStatus.FAILED);
      expect(result.httpStatusCode).assertEqual(0);
      expect(result.httpSucceeded).assertFalse();
      expect(result.wssSucceeded).assertFalse();
      expect(result.wssSupported).assertTrue();
      expect(result.httpError !== null).assertTrue();
      expect(result.wssError !== null).assertTrue();
      if (result.httpError !== null && result.wssError !== null) {
        expect(result.httpError.stage).assertEqual('http_request');
        expect(result.httpError.errorType).assertEqual('Error');
        expect(result.wssError.stage).assertEqual('wss_connect');
        expect(result.wssError.errorType).assertEqual('Error');
      }
      expect(JSON.stringify(result).indexOf('proxy-password')).assertEqual(-1);
      expect(factory.clients.length).assertEqual(1);
      expect(factory.clients[0].closeCount).assertEqual(1);
    });

    it('clearsExistingCookiesBeforeAndAfterTheProbe', 0, async () => {
      const session = new FakeHttpSession();
      session.cookieJar.setCookieHeader(
        'https://steamcommunity.com/',
        'probe_secret=should-not-be-sent'
      );
      const factory = new FakeWebSocketFactory();
      const probe = new HarmonySteamNetworkProbe(
        new HarmonySteamNetworkProbeOptions(NGFProxyConfiguration.direct()),
        session,
        factory
      );

      await probe.probe();

      expect(session.observedCookieHeader).assertEqual('');
      expect(session.cookieJar.getCookieHeader('https://steamcommunity.com/')).assertEqual('');
      expect(session.clearCount >= 2).assertTrue();
    });
  });
}
