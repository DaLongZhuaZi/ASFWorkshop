import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { IKeyStoreManager } from '../contracts/IKeyStoreManager';
import { logger } from '../../utils/Logger';

const TAG: string = 'KeyStoreManagerFacade';
const ASSET_NOT_FOUND_ERROR_CODE: number = 24000002;

export class KeyStoreManagerFacade implements IKeyStoreManager {

  /**
   * 存储极度敏感数据 (如支付密码、长期 Token) 到芯片级安全环境
   */
  async addSecret(alias: string, secretString: string): Promise<boolean> {
    try {
      const secretBuffer: Uint8Array = this.encodeUtf8(secretString);

      const attr: asset.AssetMap = new Map();
      attr.set(asset.Tag.ALIAS, this.encodeUtf8(alias));
      attr.set(asset.Tag.SECRET, secretBuffer);
      attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attr.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);

      await asset.add(attr);
      logger.info(TAG, '安全数据存入成功: ' + alias);
      return true;
    } catch (e) {
      logger.error(TAG, '安全数据存入失败 [' + alias + ']: ' + e);
      return false;
    }
  }

  /**
   * 读取极度敏感数据
   */
  async querySecret(alias: string): Promise<string | null> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, this.encodeUtf8(alias));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);

      const results = await asset.query(query);
      if (results && results.length > 0) {
        const secretAttr = results[0].get(asset.Tag.SECRET);
        if (secretAttr) {
          const secretArr: Uint8Array = secretAttr as Uint8Array;
          const str: string = this.decodeUtf8(secretArr);
          logger.info(TAG, '安全数据读取成功: ' + alias);
          return str;
        }
      }
      return null;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      if (businessError.code === ASSET_NOT_FOUND_ERROR_CODE) {
        logger.debug(TAG, '安全数据未找到，按未配置处理: ' + alias);
        return null;
      }
      logger.error(TAG, '安全数据读取失败 [' + alias + ']: ' + String(error));
      const errorCode: number = typeof businessError.code === 'number' ? businessError.code : -1;
      throw new Error('AssetStore query failed; code=' + errorCode.toString());
    }
  }

  /**
   * 删除敏感数据
   */
  async removeSecret(alias: string): Promise<boolean> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, this.encodeUtf8(alias));
      await asset.remove(query);
      logger.info(TAG, '安全数据删除成功: ' + alias);
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      if (businessError.code === ASSET_NOT_FOUND_ERROR_CODE) {
        logger.debug(TAG, '安全数据不存在，删除按幂等成功处理: ' + alias);
        return true;
      }
      logger.error(TAG, '安全数据删除失败 [' + alias + ']: ' + String(error));
      return false;
    }
  }

  private encodeUtf8(value: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encodeInto(value);
  }

  private decodeUtf8(value: Uint8Array): string {
    const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
    return decoder.decodeToString(value);
  }
}

export const ngfKeyStoreManagerFacade: IKeyStoreManager = new KeyStoreManagerFacade();
