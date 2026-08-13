import { logger } from '../../utils/Logger';
import { ngfKeyStoreManagerFacade } from './KeyStoreManagerFacade';
import { ISecureCredentialStore, NGFCredentialKind } from '../contracts/ISecureCredentialStore';

const TAG: string = 'NGFSecureCredentialStore';

/** AssetStore-backed account credential store. Values never enter RDB or normal logs. */
export class SecureCredentialStoreFacade implements ISecureCredentialStore {
  async set(accountId: string, kind: NGFCredentialKind, value: string): Promise<boolean> {
    const alias = this.aliasFor(accountId, kind);
    const saved = await ngfKeyStoreManagerFacade.addSecret(alias, value);
    if (!saved) {
      logger.warn(TAG, 'credential store write failed for kind=' + kind);
      return false;
    }
    const persisted: string | null = await ngfKeyStoreManagerFacade.querySecret(alias);
    const verified: boolean = persisted === value;
    if (!verified) {
      logger.error(TAG, 'credential store write verification failed for kind=' + kind);
    }
    return verified;
  }

  async get(accountId: string, kind: NGFCredentialKind): Promise<string | null> {
    return ngfKeyStoreManagerFacade.querySecret(this.aliasFor(accountId, kind));
  }

  async remove(accountId: string, kind: NGFCredentialKind): Promise<boolean> {
    return ngfKeyStoreManagerFacade.removeSecret(this.aliasFor(accountId, kind));
  }

  async removeAll(accountId: string): Promise<boolean> {
    let success = true;
    const kinds: Array<NGFCredentialKind> = [
      NGFCredentialKind.ACCOUNT_NAME,
      NGFCredentialKind.PASSWORD,
      NGFCredentialKind.REFRESH_TOKEN,
      NGFCredentialKind.LOGIN_KEY,
      NGFCredentialKind.SHARED_SECRET,
      NGFCredentialKind.IDENTITY_SECRET,
      NGFCredentialKind.DEVICE_ID,
      NGFCredentialKind.GUARD_DATA,
      NGFCredentialKind.COOKIE_JAR,
      NGFCredentialKind.ACCESS_TOKEN,
      NGFCredentialKind.OAUTH_TOKEN,
      NGFCredentialKind.CSRF_TOKEN,
      NGFCredentialKind.PROXY_PASSWORD
    ];
    for (let index = 0; index < kinds.length; index++) {
      const removed = await this.remove(accountId, kinds[index]);
      success = success && removed;
    }
    return success;
  }

  async setNamed(scope: string, name: string, value: string): Promise<boolean> {
    const alias = this.aliasForNamed(scope, name);
    const saved = await ngfKeyStoreManagerFacade.addSecret(alias, value);
    if (!saved) {
      logger.warn(TAG, 'named credential store write failed');
      return false;
    }
    const persisted: string | null = await ngfKeyStoreManagerFacade.querySecret(alias);
    const verified: boolean = persisted === value;
    if (!verified) {
      logger.error(TAG, 'named credential store write verification failed');
    }
    return verified;
  }

  async getNamed(scope: string, name: string): Promise<string | null> {
    return ngfKeyStoreManagerFacade.querySecret(this.aliasForNamed(scope, name));
  }

  async removeNamed(scope: string, name: string): Promise<boolean> {
    return ngfKeyStoreManagerFacade.removeSecret(this.aliasForNamed(scope, name));
  }

  private aliasFor(accountId: string, kind: NGFCredentialKind): string {
    const normalized = accountId.trim();
    if (normalized.length <= 0) {
      throw new Error('accountId must not be empty');
    }
    return 'steam.' + normalized + '.' + kind;
  }

  private aliasForNamed(scope: string, name: string): string {
    const normalizedScope = scope.trim();
    const normalizedName = name.trim();
    if (normalizedScope.length <= 0 || normalizedName.length <= 0) {
      throw new Error('secure named credential scope and name must not be empty');
    }
    return 'app.' + normalizedScope + '.' + normalizedName;
  }
}

export const ngfSecureCredentialStore: ISecureCredentialStore = new SecureCredentialStoreFacade();
