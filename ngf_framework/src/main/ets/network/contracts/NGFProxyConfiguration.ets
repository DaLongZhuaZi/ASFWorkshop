import { connection } from '@kit.NetworkKit';

/** Proxy mode shared by HTTP and WebSocket clients. */
export enum NGFProxyMode {
  SYSTEM = 'system',
  DIRECT = 'direct',
  HTTP = 'http',
  SOCKS5 = 'socks5'
}

/**
 * Explicit proxy configuration. A SOCKS5 proxy is only valid for API26
 * HTTP requests; the WebSocket API accepts system, direct, or HTTP proxy.
 */
export class NGFProxyConfiguration {
  readonly mode: NGFProxyMode;
  readonly host: string;
  readonly port: number;
  readonly username: string;
  readonly password: string;
  readonly exclusionList: Array<string>;

  constructor(
    mode: NGFProxyMode = NGFProxyMode.SYSTEM,
    host: string = '',
    port: number = 0,
    username: string = '',
    password: string = '',
    exclusionList: Array<string> = []
  ) {
    this.mode = mode;
    this.host = host;
    this.port = port;
    this.username = username;
    this.password = password;
    this.exclusionList = exclusionList.slice();
  }

  static system(): NGFProxyConfiguration {
    return new NGFProxyConfiguration(NGFProxyMode.SYSTEM);
  }

  static direct(): NGFProxyConfiguration {
    return new NGFProxyConfiguration(NGFProxyMode.DIRECT);
  }

  static http(
    host: string,
    port: number,
    username: string = '',
    password: string = '',
    exclusionList: Array<string> = []
  ): NGFProxyConfiguration {
    return new NGFProxyConfiguration(
      NGFProxyMode.HTTP,
      host,
      port,
      username,
      password,
      exclusionList
    );
  }

  static socks5(
    host: string,
    port: number,
    username: string = '',
    password: string = '',
    exclusionList: Array<string> = []
  ): NGFProxyConfiguration {
    return new NGFProxyConfiguration(
      NGFProxyMode.SOCKS5,
      host,
      port,
      username,
      password,
      exclusionList
    );
  }

  toHttpProxy(): connection.HttpProxy {
    if (this.mode !== NGFProxyMode.HTTP) {
      throw new Error('HTTP proxy configuration required');
    }
    const proxy: connection.HttpProxy = {
      host: this.host,
      port: this.port,
      exclusionList: this.exclusionList.slice()
    };
    if (this.username.length > 0) {
      proxy.username = this.username;
    }
    if (this.password.length > 0) {
      proxy.password = this.password;
    }
    return proxy;
  }

  toSocks5Proxy(): connection.Socks5Proxy {
    if (this.mode !== NGFProxyMode.SOCKS5) {
      throw new Error('SOCKS5 proxy configuration required');
    }
    const proxy: connection.Socks5Proxy = {
      host: this.host,
      port: this.port,
      exclusionList: this.exclusionList.slice()
    };
    if (this.username.length > 0) {
      proxy.username = this.username;
    }
    if (this.password.length > 0) {
      proxy.password = this.password;
    }
    return proxy;
  }
}
