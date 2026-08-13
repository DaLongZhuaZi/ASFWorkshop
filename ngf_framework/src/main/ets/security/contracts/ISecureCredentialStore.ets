export enum NGFCredentialKind {
  ACCOUNT_NAME = 'account_name',
  PASSWORD = 'password',
  REFRESH_TOKEN = 'refresh_token',
  LOGIN_KEY = 'login_key',
  SHARED_SECRET = 'shared_secret',
  IDENTITY_SECRET = 'identity_secret',
  DEVICE_ID = 'device_id',
  GUARD_DATA = 'guard_data',
  COOKIE_JAR = 'cookie_jar',
  ACCESS_TOKEN = 'access_token',
  OAUTH_TOKEN = 'oauth_token',
  CSRF_TOKEN = 'csrf_token',
  PROXY_PASSWORD = 'proxy_password'
}

export interface ISecureCredentialStore {
  set(accountId: string, kind: NGFCredentialKind, value: string): Promise<boolean>;
  get(accountId: string, kind: NGFCredentialKind): Promise<string | null>;
  remove(accountId: string, kind: NGFCredentialKind): Promise<boolean>;
  removeAll(accountId: string): Promise<boolean>;
  /** Generic secure namespace for non-account secrets such as app-level configuration passwords. */
  setNamed(scope: string, name: string, value: string): Promise<boolean>;
  getNamed(scope: string, name: string): Promise<string | null>;
  removeNamed(scope: string, name: string): Promise<boolean>;
}
