export { INetworkClient, NGFNetworkRequest, NGFNetworkResponse } from './contracts/INetworkClient';
export { NetworkManagerFacade, ngfNetworkClient } from './facades/NetworkManagerFacade';
export { NGFProxyConfiguration, NGFProxyMode } from './contracts/NGFProxyConfiguration';
export {
  IWebSocketClient,
  NGFWebSocketCloseEvent,
  NGFWebSocketCloseListener,
  NGFWebSocketErrorListener,
  NGFWebSocketMessageListener,
  NGFWebSocketOptions,
  NGFWebSocketState,
  NGFWebSocketStateListener,
  NGFTlsProtocol
} from './contracts/IWebSocketClient';
export { WebSocketClientFacade } from './facades/WebSocketClientFacade';
export { NGFHttpHeaderObject } from './NGFHttpHeaderObject';
export {
  IHttpSession,
  NGFCookie,
  NGFCookieJar,
  NGFHttpSessionRequest,
  NGFHttpSessionResponse
} from './contracts/IHttpSession';
export { NGFHttpSession } from './facades/HttpSessionFacade';
