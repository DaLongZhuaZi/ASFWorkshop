import { BusinessError } from '@kit.BasicServicesKit';
import { webSocket } from '@kit.NetworkKit';
import { logger } from '../../utils/Logger';
import {
  IWebSocketClient,
  NGFWebSocketCloseEvent,
  NGFWebSocketCloseListener,
  NGFWebSocketErrorListener,
  NGFWebSocketMessageListener,
  NGFWebSocketOptions,
  NGFWebSocketState,
  NGFWebSocketStateListener,
  NGFTlsProtocol
} from '../contracts/IWebSocketClient';
import { NGFProxyMode } from '../contracts/NGFProxyConfiguration';
import { NGFHttpHeaderObject } from '../NGFHttpHeaderObject';

const TAG: string = 'NGFWebSocketClient';

interface NGFWebSocketErrorLike {
  readonly code?: number;
  readonly message?: string;
}

class NGFWebSocketNativeError extends Error {
  readonly code: number;

  constructor(message: string, code: number) {
    super(message);
    this.name = 'NGFWebSocketNativeError';
    this.code = code;
  }
}

export class WebSocketClientFacade implements IWebSocketClient {
  private socket: webSocket.WebSocket | null = null;
  private currentState: NGFWebSocketState = NGFWebSocketState.IDLE;
  private connectionGeneration: number = 0;
  private readonly messageListeners: Array<NGFWebSocketMessageListener> = [];
  private readonly stateListeners: Array<NGFWebSocketStateListener> = [];
  private readonly closeListeners: Array<NGFWebSocketCloseListener> = [];
  private readonly errorListeners: Array<NGFWebSocketErrorListener> = [];

  get state(): NGFWebSocketState {
    return this.currentState;
  }

  async connect(url: string, options: NGFWebSocketOptions = new NGFWebSocketOptions()): Promise<void> {
    if (this.currentState === NGFWebSocketState.CONNECTING || this.currentState === NGFWebSocketState.OPEN) {
      throw new Error('WebSocket is already connected');
    }
    if (options.proxy.mode === NGFProxyMode.SOCKS5) {
      const error = new Error('HarmonyOS WebSocket does not support SOCKS5 proxy configuration');
      this.setState(NGFWebSocketState.ERROR);
      this.notifyError(error);
      throw error;
    }
    const generation: number = this.connectionGeneration + 1;
    this.connectionGeneration = generation;
    this.setState(NGFWebSocketState.CONNECTING);
    let socket: webSocket.WebSocket | null = null;
    try {
      const createdSocket: webSocket.WebSocket = webSocket.createWebSocket();
      socket = createdSocket;
      this.socket = createdSocket;
      this.bindNativeListeners(createdSocket, generation);
      const nativeOptions: webSocket.WebSocketRequestOptions = {
        pingInterval: options.pingIntervalSeconds,
        pongTimeout: options.pongTimeoutSeconds,
        minSupportTlsProtocol: this.toNativeTlsProtocol(options.minSupportTlsProtocol)
      };
      if (options.header.length > 0) {
        nativeOptions.header = NGFHttpHeaderObject.fromBlock(options.header).asObject();
      }
      if (options.proxy.mode === NGFProxyMode.SYSTEM) {
        nativeOptions.proxy = 'system';
      } else if (options.proxy.mode === NGFProxyMode.DIRECT) {
        nativeOptions.proxy = 'no-proxy';
      } else if (options.proxy.mode === NGFProxyMode.HTTP) {
        nativeOptions.proxy = options.proxy.toHttpProxy();
      }
      const connected: boolean = await createdSocket.connect(url, nativeOptions);
      if (!connected) {
        throw new Error('WebSocket connection was rejected');
      }
      if (this.socket !== createdSocket || this.connectionGeneration !== generation ||
        this.currentState === NGFWebSocketState.CLOSING ||
        this.currentState === NGFWebSocketState.CLOSED ||
        this.currentState === NGFWebSocketState.ERROR) {
        throw new Error('WebSocket connection was interrupted');
      }
      this.setState(NGFWebSocketState.OPEN);
      logger.info(TAG, 'WebSocket connected');
    } catch (error) {
      const normalized = this.normalizeError(error);
      const isCurrentAttempt: boolean = this.connectionGeneration === generation &&
        (socket === null || this.socket === socket);
      if (isCurrentAttempt) {
        this.connectionGeneration++;
        if (socket !== null && this.socket === socket) {
          this.socket = null;
        }
        if (this.currentState !== NGFWebSocketState.CLOSING &&
          this.currentState !== NGFWebSocketState.CLOSED) {
          this.setState(NGFWebSocketState.ERROR);
        }
      }
      if (socket !== null) {
        await this.cleanupFailedSocket(socket);
      }
      this.notifyError(normalized);
      throw normalized;
    }
  }

  async send(data: string | ArrayBuffer): Promise<void> {
    if (this.socket === null || this.currentState !== NGFWebSocketState.OPEN) {
      throw new Error('WebSocket is not open');
    }
    const sent = await this.socket.send(data);
    if (!sent) {
      throw new Error('WebSocket send failed');
    }
  }

  async close(code: number = 1000, reason: string = ''): Promise<void> {
    this.connectionGeneration++;
    if (this.socket === null || this.currentState === NGFWebSocketState.CLOSED || this.currentState === NGFWebSocketState.IDLE) {
      this.setState(NGFWebSocketState.CLOSED);
      return;
    }
    this.setState(NGFWebSocketState.CLOSING);
    const socket: webSocket.WebSocket = this.getCurrentSocket();
    try {
      await socket.close({ code, reason });
    } finally {
      this.setState(NGFWebSocketState.CLOSED);
      if (this.socket === socket) {
        this.socket = null;
      }
    }
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
    this.connectionGeneration++;
    this.messageListeners.splice(0, this.messageListeners.length);
    this.stateListeners.splice(0, this.stateListeners.length);
    this.closeListeners.splice(0, this.closeListeners.length);
    this.errorListeners.splice(0, this.errorListeners.length);
  }

  private bindNativeListeners(socket: webSocket.WebSocket, generation: number): void {
    socket.on('open', (error: BusinessError, _data: Object): void => {
      if (!this.isCurrentSocket(socket, generation)) {
        return;
      }
      if (error !== undefined && error.code !== 0) {
        this.connectionGeneration++;
        this.setState(NGFWebSocketState.ERROR);
        this.notifyError(error);
        return;
      }
      if (this.currentState === NGFWebSocketState.CLOSING ||
        this.currentState === NGFWebSocketState.CLOSED ||
        this.currentState === NGFWebSocketState.ERROR) {
        return;
      }
      this.setState(NGFWebSocketState.OPEN);
    });
    socket.on('message', (error: BusinessError, data: string | ArrayBuffer): void => {
      if (!this.isCurrentSocket(socket, generation)) {
        return;
      }
      if (error !== undefined && error.code !== 0) {
        this.notifyError(error);
        return;
      }
      for (let index = 0; index < this.messageListeners.length; index++) {
        this.messageListeners[index](data);
      }
    });
    socket.on('close', (error: BusinessError, data: webSocket.CloseResult): void => {
      if (!this.isCurrentSocket(socket, generation)) {
        return;
      }
      this.connectionGeneration++;
      if (error !== undefined && error.code !== 0) {
        this.notifyError(error);
      }
      const closeEvent = new NGFWebSocketCloseEvent(data.code, data.reason);
      for (let index = 0; index < this.closeListeners.length; index++) {
        this.closeListeners[index](closeEvent);
      }
      this.socket = null;
      this.setState(NGFWebSocketState.CLOSED);
    });
    socket.on('error', (error: BusinessError): void => {
      if (!this.isCurrentSocket(socket, generation)) {
        return;
      }
      this.connectionGeneration++;
      this.setState(NGFWebSocketState.ERROR);
      this.notifyError(error);
    });
  }

  private isCurrentSocket(socket: webSocket.WebSocket, generation: number): boolean {
    return this.socket === socket && this.connectionGeneration === generation;
  }

  private async cleanupFailedSocket(socket: webSocket.WebSocket): Promise<void> {
    try {
      await socket.close({ code: 1000, reason: 'Connection failed' });
    } catch (_error) {
      logger.debug(TAG, 'WebSocket cleanup after connection failure failed');
    }
  }

  private getCurrentSocket(): webSocket.WebSocket {
    if (this.socket === null) {
      throw new Error('WebSocket is not open');
    }
    return this.socket;
  }

  private setState(state: NGFWebSocketState): void {
    if (this.currentState === state) {
      return;
    }
    this.currentState = state;
    for (let index = 0; index < this.stateListeners.length; index++) {
      this.stateListeners[index](state);
    }
  }

  private notifyError(error: Error): void {
    logger.warn(TAG, 'WebSocket error: ' + error.message);
    for (let index = 0; index < this.errorListeners.length; index++) {
      this.errorListeners[index](error);
    }
  }

  private toNativeTlsProtocol(protocol: NGFTlsProtocol): webSocket.TlsProtocol {
    if (protocol === NGFTlsProtocol.TLS_1_0) {
      return webSocket.TlsProtocol.TLS_V_1_0;
    }
    if (protocol === NGFTlsProtocol.TLS_1_1) {
      return webSocket.TlsProtocol.TLS_V_1_1;
    }
    if (protocol === NGFTlsProtocol.TLS_1_3) {
      return webSocket.TlsProtocol.TLS_V_1_3;
    }
    return webSocket.TlsProtocol.TLS_V_1_2;
  }

  private normalizeError(error: Error | Object | string): Error {
    if (error instanceof Error) {
      return error;
    }
    if (typeof error === 'string') {
      return new Error(error);
    }
    const errorLike: NGFWebSocketErrorLike = error as NGFWebSocketErrorLike;
    const message: string = errorLike.message === undefined || errorLike.message.length === 0
      ? 'WebSocket operation failed'
      : errorLike.message;
    const code: number = errorLike.code !== undefined && Number.isSafeInteger(errorLike.code)
      ? errorLike.code
      : 0;
    return new NGFWebSocketNativeError(message, code);
  }
}
