import { describe, expect, it } from '@ohos/hypium';
import {
  IWebSocketClient,
  NGFProxyConfiguration,
  NGFProxyMode,
  NGFWebSocketCloseListener,
  NGFWebSocketErrorListener,
  NGFWebSocketMessageListener,
  NGFWebSocketOptions,
  NGFWebSocketState,
  NGFWebSocketStateListener,
  NGFTlsProtocol,
  WebSocketClientFacade
} from 'ngf_framework';
import {
  HarmonySteamCmWireTransport,
  HarmonySteamCmWireTransportOptions
} from '../main/ets/steamAdapters';

class ProxyFixture {
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

class FakeWebSocketClient implements IWebSocketClient {
  private currentState: NGFWebSocketState = NGFWebSocketState.IDLE;
  private readonly messageListeners: Array<NGFWebSocketMessageListener> = [];
  private readonly stateListeners: Array<NGFWebSocketStateListener> = [];
  private readonly closeListeners: Array<NGFWebSocketCloseListener> = [];
  private readonly errorListeners: Array<NGFWebSocketErrorListener> = [];
  lastUrl: string = '';
  lastOptions: NGFWebSocketOptions | null = null;

  get state(): NGFWebSocketState {
    return this.currentState;
  }

  async connect(url: string, options: NGFWebSocketOptions = new NGFWebSocketOptions()): Promise<void> {
    this.lastUrl = url;
    this.lastOptions = options;
    this.setState(NGFWebSocketState.OPEN);
  }

  async send(_data: string | ArrayBuffer): Promise<void> {
    if (this.currentState !== NGFWebSocketState.OPEN) {
      throw new Error('Fake WebSocket is not open');
    }
  }

  async close(_code: number = 1000, _reason: string = ''): Promise<void> {
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

export default function steamArkNetworkAdapterTest(): void {
  describe('SteamArkNetworkAdapter', () => {
    it('passesWssProxyCombinationsToTheInjectedHost', 0, async () => {
      const fixtures: Array<ProxyFixture> = [
        new ProxyFixture(NGFProxyConfiguration.system(), NGFProxyMode.SYSTEM, '', 0),
        new ProxyFixture(NGFProxyConfiguration.direct(), NGFProxyMode.DIRECT, '', 0),
        new ProxyFixture(NGFProxyConfiguration.http('proxy.example', 8080, 'user'), NGFProxyMode.HTTP, 'proxy.example', 8080),
        new ProxyFixture(NGFProxyConfiguration.socks5('socks.example', 1080, 'user'), NGFProxyMode.SOCKS5, 'socks.example', 1080)
      ];
      for (let index = 0; index < fixtures.length; index++) {
        const fixture = fixtures[index];
        const host = new FakeWebSocketClient();
        const transport = new HarmonySteamCmWireTransport(
          host,
          new HarmonySteamCmWireTransportOptions(fixture.proxy, 'ASF Workshop Test')
        );
        await transport.connect('cm.example:443');
        expect(host.lastUrl).assertEqual('wss://cm.example:443/cmsocket/');
        expect(host.lastOptions !== null).assertTrue();
        if (host.lastOptions !== null) {
          expect(host.lastOptions.proxy.mode).assertEqual(fixture.mode);
          expect(host.lastOptions.proxy.host).assertEqual(fixture.host);
          expect(host.lastOptions.proxy.port).assertEqual(fixture.port);
          expect(host.lastOptions.header).assertEqual('User-Agent: ASF Workshop Test');
          expect(host.lastOptions.minSupportTlsProtocol).assertEqual(NGFTlsProtocol.TLS_1_2);
        }
        await transport.close();
      }
    });

    it('canonicalizesAWebSocketUrlFromTheSteamKitEndpointForm', 0, async () => {
      const host = new FakeWebSocketClient();
      const transport = new HarmonySteamCmWireTransport(host);
      await transport.connect('wss://cm.example:8443/legacy-path');
      expect(host.lastUrl).assertEqual('wss://cm.example:8443/cmsocket/');
      await transport.close();
    });

    it('keepsSocks5WssAsAnExplicitHostCapabilityBoundary', 0, () => {
      const options = new HarmonySteamCmWireTransportOptions(
        NGFProxyConfiguration.socks5('socks.example', 1080)
      ).toWebSocketOptions();
      expect(options.proxy.mode).assertEqual(NGFProxyMode.SOCKS5);
      expect(options.proxy.host).assertEqual('socks.example');
      expect(options.proxy.port).assertEqual(1080);
    });

    it('allowsAnExplicitTls13MinimumForCmWss', 0, async () => {
      const host = new FakeWebSocketClient();
      const transport = new HarmonySteamCmWireTransport(
        host,
        new HarmonySteamCmWireTransportOptions(
          NGFProxyConfiguration.direct(),
          'ASF Workshop Test',
          30,
          30,
          NGFTlsProtocol.TLS_1_3
        )
      );
      await transport.connect('wss://cm.example/cmsocket/');
      expect(host.lastOptions !== null).assertTrue();
      if (host.lastOptions !== null) {
        expect(host.lastOptions.minSupportTlsProtocol).assertEqual(NGFTlsProtocol.TLS_1_3);
      }
      await transport.close();
    });

    it('rejectsSocks5BeforeCreatingAWebSocket', 0, async () => {
      const client = new WebSocketClientFacade();
      let observedError: string = '';
      client.onError((error: Error): void => {
        observedError = error.message;
      });
      let rejected: boolean = false;
      try {
        await client.connect(
          'wss://cm.example/cmsocket/',
          new NGFWebSocketOptions('', NGFProxyConfiguration.socks5('socks.example', 1080))
        );
      } catch {
        rejected = true;
      }
      expect(rejected).assertTrue();
      expect(client.state).assertEqual(NGFWebSocketState.ERROR);
      expect(observedError).assertEqual('HarmonyOS WebSocket does not support SOCKS5 proxy configuration');
    });
  });
}
