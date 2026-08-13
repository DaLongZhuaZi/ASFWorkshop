import { securityToolkit } from 'ngf_framework';
import { IBinaryCrypto } from 'steam_core';
import { SteamArkLog } from '../steamServices/SteamArkLogger';

const TAG: string = 'HarmonyBinaryCryptoAdapter';

/**
 * HarmonyOS crypto adapter for the detachable steam_core module.
 *
 * The core only knows IBinaryCrypto; all CryptoArchitectureKit references
 * stay on the application side of the dependency boundary.
 */
export class HarmonyBinaryCryptoAdapter implements IBinaryCrypto {
  async hmacSha1(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    SteamArkLog.debug(TAG, 'HMAC-SHA1 started; keyBytes=' + key.length.toString() +
      ', dataBytes=' + data.length.toString());
    try {
      const result = await securityToolkit.hmacSha1(key, data);
      SteamArkLog.debug(TAG, 'HMAC-SHA1 completed; resultBytes=' + result.length.toString());
      return result;
    } catch (error) {
      SteamArkLog.error(TAG, 'HMAC-SHA1 failed; errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('HMAC-SHA1 failed');
    }
  }

  async rsaEncrypt(publicKeyPem: string, data: Uint8Array): Promise<Uint8Array> {
    SteamArkLog.debug(TAG, 'RSA encryption started; keyTextLength=' + publicKeyPem.length.toString() +
      ', dataBytes=' + data.length.toString());
    try {
      const result = await securityToolkit.rsaEncrypt(publicKeyPem, data);
      SteamArkLog.debug(TAG, 'RSA encryption completed; resultBytes=' + result.length.toString());
      return result;
    } catch (error) {
      SteamArkLog.error(TAG, 'RSA encryption failed; errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('RSA encryption failed');
    }
  }

  async aesCbcEncrypt(key: Uint8Array, iv: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    SteamArkLog.debug(TAG, 'AES-CBC encryption started; keyBytes=' + key.length.toString() +
      ', ivBytes=' + iv.length.toString() + ', dataBytes=' + data.length.toString());
    try {
      const result = await securityToolkit.aesCbcEncrypt(key, iv, data);
      SteamArkLog.debug(TAG, 'AES-CBC encryption completed; resultBytes=' + result.length.toString());
      return result;
    } catch (error) {
      SteamArkLog.error(TAG, 'AES-CBC encryption failed; errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('AES-CBC encryption failed');
    }
  }

  async aesCbcDecrypt(key: Uint8Array, iv: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    SteamArkLog.debug(TAG, 'AES-CBC decryption started; keyBytes=' + key.length.toString() +
      ', ivBytes=' + iv.length.toString() + ', dataBytes=' + data.length.toString());
    try {
      const result = await securityToolkit.aesCbcDecrypt(key, iv, data);
      SteamArkLog.debug(TAG, 'AES-CBC decryption completed; resultBytes=' + result.length.toString());
      return result;
    } catch (error) {
      SteamArkLog.error(TAG, 'AES-CBC decryption failed; errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('AES-CBC decryption failed');
    }
  }
}
