import { rcp } from '@kit.RemoteCommunicationKit';
import { INetworkClient, NGFNetworkRequest, NGFNetworkResponse } from '../contracts/INetworkClient';
import { logger } from '../../utils/Logger';

const TAG: string = 'NetworkManagerFacade';

export class NetworkManagerFacade implements INetworkClient {
  private session: rcp.Session;
  private globalHeaders: Map<string, string> = new Map<string, string>();

  constructor() {
    // 默认创建一个通用的 session 并在内部维护连接池
    const sessionConfig: rcp.SessionConfiguration = {
      connectionConfiguration: {
      }
    };
    this.session = rcp.createSession(sessionConfig);
  }

  setGlobalHeader(key: string, value: string): void {
    this.globalHeaders.set(key, value);
    logger.debug(TAG, '设置全局 Header: ' + key);
  }

  removeGlobalHeader(key: string): void {
    const deleted = this.globalHeaders.delete(key);
    if (deleted) {
      logger.debug(TAG, '已移除全局 Header: ' + key);
    } else {
      logger.debug(TAG, '移除全局 Header 跳过（不存在）: ' + key);
    }
  }

  async request(req: NGFNetworkRequest): Promise<NGFNetworkResponse> {
    const url = req.url;
    const methodStr = req.method || 'GET';
    const reqHeaders: Record<string, string> = {};
    const headerKeys: Array<string> = Array.from(this.globalHeaders.keys());
    for (let i: number = 0; i < headerKeys.length; i++) {
      const val = this.globalHeaders.get(headerKeys[i]);
      if (val !== undefined) {
        reqHeaders[headerKeys[i]] = val;
      }
    }
    if (req.headers) {
      Object.keys(req.headers).forEach(k => { reqHeaders[k] = (req.headers as Record<string, string>)[k]; });
    }
    
    logger.info(TAG, '发起网络请求 [' + methodStr + '] ' + NetworkManagerFacade.logSafeUrl(url));

    const rcpReq = new rcp.Request(url, methodStr, reqHeaders, req.body);
    
    // 如果配置了超时
    if (req.timeoutMs) {
      rcpReq.configuration = {
        transfer: {
          timeout: {
            connectMs: req.timeoutMs,
            transferMs: req.timeoutMs
          }
        }
      };
    }

    try {
      const rcpRes = await this.session.fetch(rcpReq);
      
      const resHeaders: Record<string, string> = {};
      // 遍历 rcp 返回的 headers（注意类型安全，需要进行判空处理）
      if (rcpRes.headers) {
        const keys = Object.keys(rcpRes.headers);
        for (let i: number = 0; i < keys.length; i++) {
          resHeaders[keys[i]] = String(rcpRes.headers[keys[i]]);
        }
      }

      const bodyStr = rcpRes.toString() || '';
      
      logger.info(TAG, '网络请求完成 [' + methodStr + '] ' + NetworkManagerFacade.logSafeUrl(url) + ' - Status: ' + rcpRes.statusCode);
      
      return {
        statusCode: rcpRes.statusCode,
        headers: resHeaders,
        body: bodyStr
      };
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      logger.error(TAG, '网络请求异常 [' + methodStr + '] ' + NetworkManagerFacade.logSafeUrl(url) + ' - ' + err.message);
      throw err;
    }
  }

  /** Strips the query string so tokens in URLs never reach the log. */
  private static logSafeUrl(url: string): string {
    const queryIndex = url.indexOf('?');
    return queryIndex >= 0 ? url.substring(0, queryIndex) : url;
  }

  async get(url: string, headers?: Record<string, string>): Promise<NGFNetworkResponse> {
    return this.request({ url, method: 'GET', headers });
  }

  async post(url: string, body: string | Record<string, Object>, headers?: Record<string, string>): Promise<NGFNetworkResponse> {
    return this.request({ url, method: 'POST', body, headers });
  }
}

export const ngfNetworkClient: INetworkClient = new NetworkManagerFacade();
