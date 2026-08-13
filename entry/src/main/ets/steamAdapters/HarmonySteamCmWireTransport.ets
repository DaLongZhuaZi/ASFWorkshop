import {
  IWebSocketClient,
  NGFProxyConfiguration,
  NGFWebSocketCloseEvent,
  NGFWebSocketOptions,
  NGFTlsProtocol,
  WebSocketClientFacade
} from 'ngf_framework';
import {
  ISteamCmWireTransport,
  SteamAuthError,
  SteamAuthErrorKind,
  SteamAuthErrorSupport,
  SteamCmWireCloseListener,
  SteamCmWireErrorListener,
  SteamCmWireMessageListener,
  SteamCmEndpoint
} from 'steam_core';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';

const TAG: string = 'HarmonySteamCmWireTransport';
const DEFAULT_USER_AGENT: string = ASFWorkshopProductIdentity.userAgent('SteamCm');

/** Host-side WebSocket settings for a single Steam CM session. */
export class HarmonySteamCmWireTransportOptions {
  readonly proxy: NGFProxyConfiguration;
  readonly userAgent: string;
  readonly pingIntervalSeconds: number;
  readonly pongTimeoutSeconds: number;
  readonly minSupportTlsProtocol: NGFTlsProtocol;

  constructor(
    proxy: NGFProxyConfiguration = NGFProxyConfiguration.system(),
    userAgent: string = DEFAULT_USER_AGENT,
    pingIntervalSeconds: number = 30,
    pongTimeoutSeconds: number = 30,
    minSupportTlsProtocol: NGFTlsProtocol = NGFTlsProtocol.TLS_1_2
  ) {
    this.proxy = proxy;
    this.userAgent = userAgent;
    this.pingIntervalSeconds = pingIntervalSeconds;
    this.pongTimeoutSeconds = pongTimeoutSeconds;
    this.minSupportTlsProtocol = minSupportTlsProtocol;
  }

  toWebSocketOptions(): NGFWebSocketOptions {
    const header: string = this.userAgent.length > 0 ? 'User-Agent: ' + this.userAgent : '';
    return new NGFWebSocketOptions(
      header,
      this.proxy,
      this.pingIntervalSeconds,
      this.pongTimeoutSeconds,
      this.minSupportTlsProtocol
    );
  }
}

/**
 * Adapts NGF's binary WebSocket contract to the platform-independent CM wire.
 * The adapter copies every received and sent buffer so the core never observes
 * a mutable platform-owned view.
 */
export class HarmonySteamCmWireTransport implements ISteamCmWireTransport {
  private readonly client: IWebSocketClient;
  private readonly options: HarmonySteamCmWireTransportOptions;
  private readonly messageListeners: Array<SteamCmWireMessageListener> = [];
  private readonly closeListeners: Array<SteamCmWireCloseListener> = [];
  private readonly errorListeners: Array<SteamCmWireErrorListener> = [];

  constructor(
    client: IWebSocketClient = new WebSocketClientFacade(),
    options: HarmonySteamCmWireTransportOptions = new HarmonySteamCmWireTransportOptions()
  ) {
    this.client = client;
    this.options = options;
    this.bindClientListeners();
  }

  async connect(server: string): Promise<void> {
    const webSocketUrl: string = SteamCmEndpoint.toWebSocketUrl(server);
    SteamArkLog.info(TAG, 'CM WebSocket connect started; serverConfigured=' + String(server.trim().length > 0));
    try {
      await this.client.connect(webSocketUrl, this.options.toWebSocketOptions());
      SteamArkLog.info(TAG, 'CM WebSocket connect completed');
    } catch (error) {
      const normalized: SteamAuthError = SteamAuthErrorSupport.normalize(
        error,
        SteamAuthErrorKind.TRANSPORT,
        'cm_websocket_connect',
        'Steam CM WebSocket connection failed'
      );
      SteamArkLog.warn(TAG, 'CM WebSocket connect failed; errorType=' +
        SteamArkLog.errorKind(normalized) + ', code=' + normalized.code.toString());
      throw normalized;
    }
  }

  async send(payload: Uint8Array): Promise<void> {
    const copy: Uint8Array = this.copyBytes(payload);
    SteamArkLog.debug(TAG, 'CM WebSocket send started; bytes=' + copy.length.toString());
    try {
      await this.client.send(copy.buffer);
      SteamArkLog.debug(TAG, 'CM WebSocket send completed; bytes=' + copy.length.toString());
    } catch (error) {
      const normalized: SteamAuthError = SteamAuthErrorSupport.normalize(
        error,
        SteamAuthErrorKind.TRANSPORT,
        'cm_websocket_send',
        'Steam CM WebSocket send failed'
      );
      SteamArkLog.warn(TAG, 'CM WebSocket send failed; bytes=' + copy.length.toString() +
        ', errorType=' + SteamArkLog.errorKind(normalized) + ', code=' + normalized.code.toString());
      throw normalized;
    }
  }

  async close(): Promise<void> {
    SteamArkLog.debug(TAG, 'CM WebSocket close requested');
    try {
      await this.client.close();
      SteamArkLog.debug(TAG, 'CM WebSocket close completed');
    } catch (error) {
      const normalized: SteamAuthError = SteamAuthErrorSupport.normalize(
        error,
        SteamAuthErrorKind.TRANSPORT,
        'cm_websocket_close',
        'Steam CM WebSocket close failed'
      );
      SteamArkLog.warn(TAG, 'CM WebSocket close failed; errorType=' +
        SteamArkLog.errorKind(normalized) + ', code=' + normalized.code.toString());
      throw normalized;
    }
  }

  onMessage(listener: SteamCmWireMessageListener): void {
    if (this.messageListeners.indexOf(listener) < 0) {
      this.messageListeners.push(listener);
    }
  }

  onClose(listener: SteamCmWireCloseListener): void {
    if (this.closeListeners.indexOf(listener) < 0) {
      this.closeListeners.push(listener);
    }
  }

  onError(listener: SteamCmWireErrorListener): void {
    if (this.errorListeners.indexOf(listener) < 0) {
      this.errorListeners.push(listener);
    }
  }

  clearListeners(): void {
    this.client.clearListeners();
    this.messageListeners.splice(0, this.messageListeners.length);
    this.closeListeners.splice(0, this.closeListeners.length);
    this.errorListeners.splice(0, this.errorListeners.length);
    SteamArkLog.debug(TAG, 'CM WebSocket listeners cleared');
  }

  private bindClientListeners(): void {
    this.client.onMessage((data: string | ArrayBuffer): void => {
      if (typeof data === 'string') {
        SteamArkLog.warn(TAG, 'CM WebSocket text message rejected');
        this.notifyError(new Error('Steam CM WebSocket returned a text message'));
        return;
      }
      const payload: Uint8Array = this.copyBytes(new Uint8Array(data));
      SteamArkLog.debug(TAG, 'CM WebSocket binary message received; bytes=' + payload.length.toString());
      for (let index = 0; index < this.messageListeners.length; index++) {
        this.messageListeners[index](payload);
      }
    });
    this.client.onClose((event: NGFWebSocketCloseEvent): void => {
      SteamArkLog.info(TAG, 'CM WebSocket closed; code=' + event.code.toString());
      const reason: string = event.reason.length > 0
        ? event.reason
        : 'WebSocket closed with code ' + event.code.toString();
      for (let index = 0; index < this.closeListeners.length; index++) {
        this.closeListeners[index](reason);
      }
    });
    this.client.onError((error: Error): void => {
      SteamArkLog.warn(TAG, 'CM WebSocket error event received; errorType=' + SteamArkLog.errorKind(error));
      this.notifyError(error);
    });
  }

  private copyBytes(source: Uint8Array): Uint8Array {
    const copy = new Uint8Array(source.length);
    copy.set(source);
    return copy;
  }

  private notifyError(error: Error): void {
    SteamArkLog.debug(TAG, 'CM WebSocket error listeners dispatching; count=' + this.errorListeners.length.toString());
    for (let index = 0; index < this.errorListeners.length; index++) {
      this.errorListeners[index](error);
    }
  }
}
