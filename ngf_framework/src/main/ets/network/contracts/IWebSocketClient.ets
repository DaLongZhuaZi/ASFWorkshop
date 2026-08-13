import { NGFProxyConfiguration } from './NGFProxyConfiguration';

export enum NGFWebSocketState {
  IDLE = 'IDLE',
  CONNECTING = 'CONNECTING',
  OPEN = 'OPEN',
  CLOSING = 'CLOSING',
  CLOSED = 'CLOSED',
  ERROR = 'ERROR'
}

/** Minimum TLS protocol accepted by an API26 WebSocket connection. */
export enum NGFTlsProtocol {
  TLS_1_0 = 'TLS1.0',
  TLS_1_1 = 'TLS1.1',
  TLS_1_2 = 'TLS1.2',
  TLS_1_3 = 'TLS1.3'
}

export class NGFWebSocketOptions {
  readonly header: string;
  readonly proxy: NGFProxyConfiguration;
  readonly pingIntervalSeconds: number;
  readonly pongTimeoutSeconds: number;
  readonly minSupportTlsProtocol: NGFTlsProtocol;

  constructor(
    header: string = '',
    proxy: NGFProxyConfiguration = NGFProxyConfiguration.system(),
    pingIntervalSeconds: number = 30,
    pongTimeoutSeconds: number = 30,
    minSupportTlsProtocol: NGFTlsProtocol = NGFTlsProtocol.TLS_1_2
  ) {
    this.header = header;
    this.proxy = proxy;
    this.pingIntervalSeconds = pingIntervalSeconds;
    this.pongTimeoutSeconds = pongTimeoutSeconds;
    this.minSupportTlsProtocol = minSupportTlsProtocol;
  }
}

export class NGFWebSocketCloseEvent {
  readonly code: number;
  readonly reason: string;

  constructor(code: number, reason: string) {
    this.code = code;
    this.reason = reason;
  }
}

export type NGFWebSocketMessageListener = (data: string | ArrayBuffer) => void;
export type NGFWebSocketStateListener = (state: NGFWebSocketState) => void;
export type NGFWebSocketCloseListener = (event: NGFWebSocketCloseEvent) => void;
export type NGFWebSocketErrorListener = (error: Error) => void;

export interface IWebSocketClient {
  readonly state: NGFWebSocketState;
  connect(url: string, options?: NGFWebSocketOptions): Promise<void>;
  send(data: string | ArrayBuffer): Promise<void>;
  close(code?: number, reason?: string): Promise<void>;
  onMessage(listener: NGFWebSocketMessageListener): void;
  onStateChange(listener: NGFWebSocketStateListener): void;
  onClose(listener: NGFWebSocketCloseListener): void;
  onError(listener: NGFWebSocketErrorListener): void;
  clearListeners(): void;
}
