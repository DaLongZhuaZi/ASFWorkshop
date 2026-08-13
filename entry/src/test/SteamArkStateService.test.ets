import { describe, it, expect } from '@ohos/hypium';
import {
  ISecureCredentialStore,
  ISettingsStore,
  NGFCredentialKind,
  ngfContentCacheFacade
} from 'ngf_framework';
import {
  ISteamArkAuthServiceFactory,
  ISteamArkInventoryAdapter,
  ISteamArkInventoryAdapterFactory,
  ISteamArkAccountLifecycle,
  ISteamArkProfileResolver,
  SteamArkImportSummary,
  SteamArkMessageCacheStore,
  SteamArkMarketPriceService,
  SteamArkResolvedProfile,
  SteamArkStateService,
  SteamArkStateServiceOptions
} from '../main/ets/steamServices';
import {
  ISteamAuthService,
  SteamAuthChallengeKind,
  SteamAuthError,
  SteamAuthErrorKind,
  SteamAuthFlowKind,
  SteamAuthPendingSnapshot,
  SteamAuthRequest,
  SteamAuthResult,
  SteamAccountProfile,
  SteamCredentialSet,
  SteamInventoryCardDropState,
  SteamInventoryItem,
  SteamInventoryPage,
  SteamInventoryQuery,
  SteamProxyKind,
  SteamProxySettings,
  SteamSessionSnapshot,
  SteamSessionState
} from 'steam_core';

class FakeSettingsStore implements ISettingsStore {
  private readonly stringValues: Map<string, string> = new Map<string, string>();
  writeCount: number = 0;
  failNextAsyncWrite: boolean = false;
  failAllAsyncWrites: boolean = false;

  getString(key: string, defaultValue: string): string {
    const value = this.stringValues.get(key);
    return value === undefined ? defaultValue : value;
  }

  getNumber(_key: string, defaultValue: number): number {
    return defaultValue;
  }

  getBoolean(_key: string, defaultValue: boolean): boolean {
    return defaultValue;
  }

  setString(key: string, value: string): void {
    this.stringValues.set(key, value);
  }

  async setStringAsync(key: string, value: string): Promise<boolean> {
    if (this.failAllAsyncWrites || this.failNextAsyncWrite) {
      this.failNextAsyncWrite = false;
      this.writeCount++;
      return false;
    }
    this.stringValues.set(key, value);
    this.writeCount++;
    return true;
  }

  setNumber(_key: string, _value: number): void {
    return;
  }

  setBoolean(_key: string, _value: boolean): void {
    return;
  }

  async waitUntilReady(): Promise<boolean> {
    return true;
  }
}

class TestAsyncGate {
  readonly entered: Promise<void>;
  private enterResolver: () => void = (): void => {
    return;
  };
  private releaseResolver: () => void = (): void => {
    return;
  };
  private released: boolean = false;

  constructor() {
    this.entered = new Promise<void>((resolve: () => void): void => {
      this.enterResolver = resolve;
    });
  }

  waitForRelease(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      this.releaseResolver = resolve;
    });
  }

  enter(): Promise<void> {
    this.enterResolver();
    return this.waitForRelease();
  }

  release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    this.releaseResolver();
  }
}

class FakeCredentialStore implements ISecureCredentialStore {
  private readonly values: Map<string, string> = new Map<string, string>();
  failSetKind: NGFCredentialKind | null = null;
  failSetValue: string = '';
  failSetNamedName: string = '';
  failRemoveAll: boolean = false;
  failSetOnce: boolean = true;
  failSetNamedOnce: boolean = true;

  async set(accountId: string, kind: NGFCredentialKind, value: string): Promise<boolean> {
    if (this.failSetKind === kind && (this.failSetValue.length <= 0 || this.failSetValue === value)) {
      if (this.failSetOnce) {
        this.failSetKind = null;
        this.failSetValue = '';
      }
      return false;
    }
    this.values.set(this.accountKey(accountId, kind), value);
    return true;
  }

  async get(accountId: string, kind: NGFCredentialKind): Promise<string | null> {
    return this.valueOrNull(this.accountKey(accountId, kind));
  }

  async remove(accountId: string, kind: NGFCredentialKind): Promise<boolean> {
    this.values.delete(this.accountKey(accountId, kind));
    return true;
  }

  async removeAll(accountId: string): Promise<boolean> {
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
      this.values.delete(this.accountKey(accountId, kinds[index]));
    }
    return !this.failRemoveAll;
  }

  async setNamed(scope: string, name: string, value: string): Promise<boolean> {
    if (name === this.failSetNamedName) {
      if (this.failSetNamedOnce) {
        this.failSetNamedName = '';
      }
      return false;
    }
    this.values.set('named|' + scope + '|' + name, value);
    return true;
  }

  async getNamed(scope: string, name: string): Promise<string | null> {
    return this.valueOrNull('named|' + scope + '|' + name);
  }

  async removeNamed(scope: string, name: string): Promise<boolean> {
    this.values.delete('named|' + scope + '|' + name);
    return true;
  }

  private accountKey(accountId: string, kind: NGFCredentialKind): string {
    return accountId + '|' + kind;
  }

  private valueOrNull(key: string): string | null {
    const value = this.values.get(key);
    return value === undefined ? null : value;
  }
}

class FakeProfileResolver implements ISteamArkProfileResolver {
  readonly response: SteamArkResolvedProfile;
  fail: boolean = false;
  failNextProfilePersistence: FakeSettingsStore | null = null;
  resolveGate: TestAsyncGate | null = null;
  resolveCount: number = 0;
  lastAccountId: string = '';
  lastSteamId64: string = '';

  constructor(
    displayName: string = 'Resolved QR Persona',
    avatarUrl: string = 'https://avatars.steamstatic.com/fake-profile.jpg',
    avatarFrameUrl: string = '',
    miniProfileBackgroundImageUrl: string = '',
    miniProfileBackgroundMovieUrl: string = ''
  ) {
    this.response = new SteamArkResolvedProfile(
      displayName,
      avatarUrl,
      '',
      '',
      false,
      avatarFrameUrl,
      '',
      0,
      '',
      '',
      '',
      miniProfileBackgroundImageUrl,
      miniProfileBackgroundMovieUrl
    );
  }

  async resolve(
    profile: SteamAccountProfile,
    _credentials: SteamCredentialSet,
    _proxyPassword: string = ''
  ): Promise<SteamArkResolvedProfile> {
    this.resolveCount++;
    this.lastAccountId = profile.accountId;
    this.lastSteamId64 = profile.steamId64;
    const gate = this.resolveGate;
    if (gate !== null) {
      await gate.enter();
    }
    if (this.fail) {
      throw new Error('fake Steam profile lookup failed');
    }
    const persistenceStore = this.failNextProfilePersistence;
    if (persistenceStore !== null) {
      persistenceStore.failNextAsyncWrite = true;
      this.failNextProfilePersistence = null;
    }
    return this.response;
  }
}

class FakeInventoryAdapter implements ISteamArkInventoryAdapter {
  readonly accountId: string;
  readonly steamId64: string;
  readonly assetId: string;
  openCount: number = 0;
  syncCount: number = 0;
  closeCount: number = 0;
  failClose: boolean = false;
  unauthorizedStatusCode: number = 0;
  syncGate: TestAsyncGate | null = null;
  lastCredentials: SteamCredentialSet | null = null;
  private currentSession: SteamSessionSnapshot;

  constructor(profile: SteamAccountProfile) {
    this.accountId = profile.accountId;
    this.steamId64 = profile.steamId64;
    this.assetId = profile.accountId === 'alice' ? '1001' : '2001';
    this.currentSession = new SteamSessionSnapshot(profile.accountId);
  }

  async open(accountId: string, credentials: SteamCredentialSet): Promise<SteamSessionSnapshot> {
    this.assertAccount(accountId);
    this.openCount++;
    this.lastCredentials = credentials;
    this.currentSession = new SteamSessionSnapshot(
      accountId,
      SteamSessionState.LOGGED_ON,
      this.steamId64,
      'fake-steam-web',
      1700000000
    );
    return this.currentSession;
  }

  async sync(accountId: string, query: SteamInventoryQuery): Promise<SteamInventoryPage> {
    this.assertAccount(accountId);
    this.syncCount++;
    const gate = this.syncGate;
    if (gate !== null) {
      await gate.enter();
    }
    if (this.unauthorizedStatusCode === 401 || this.unauthorizedStatusCode === 403) {
      this.currentSession = new SteamSessionSnapshot(
        accountId,
        SteamSessionState.EXPIRED,
        this.steamId64,
        'fake-steam-web',
        1700000000,
        0,
        this.unauthorizedStatusCode
      );
      throw new Error('fake inventory authorization failure');
    }
    const item = new SteamInventoryItem(
      this.assetId,
      '3001',
      '1',
      query.appId,
      query.contextId,
      1,
      this.accountId + ' card',
      'Trading Card',
      true,
      true,
      SteamInventoryCardDropState.AVAILABLE
    );
    const items: Array<SteamInventoryItem> = [item];
    return new SteamInventoryPage(query, items, 1, false, 1700000010, '');
  }

  async close(accountId: string): Promise<void> {
    this.assertAccount(accountId);
    this.closeCount++;
    if (this.failClose) {
      throw new Error('fake inventory close failure');
    }
    this.currentSession = new SteamSessionSnapshot(accountId);
  }

  get session(): SteamSessionSnapshot {
    return this.currentSession;
  }

  private assertAccount(accountId: string): void {
    if (accountId !== this.accountId) {
      throw new Error('fake inventory adapter account mismatch');
    }
  }
}

class FakeInventoryAdapterFactory implements ISteamArkInventoryAdapterFactory {
  readonly adapters: Map<string, FakeInventoryAdapter> = new Map<string, FakeInventoryAdapter>();
  readonly proxyPasswords: Map<string, string> = new Map<string, string>();
  readonly proxies: Map<string, SteamProxySettings> = new Map<string, SteamProxySettings>();
  createCount: number = 0;
  unauthorizedStatusCode: number = 0;
  syncGate: TestAsyncGate | null = null;

  create(profile: SteamAccountProfile, proxyPassword: string = ''): ISteamArkInventoryAdapter {
    this.createCount++;
    this.proxyPasswords.set(profile.accountId, proxyPassword);
    this.proxies.set(profile.accountId, new SteamProxySettings(
      profile.proxy.kind,
      profile.proxy.host,
      profile.proxy.port,
      profile.proxy.username
    ));
    const adapter = new FakeInventoryAdapter(profile);
    adapter.unauthorizedStatusCode = this.unauthorizedStatusCode;
    adapter.syncGate = this.syncGate;
    this.adapters.set(profile.accountId, adapter);
    return adapter;
  }

  get(accountId: string): FakeInventoryAdapter | null {
    const adapter = this.adapters.get(accountId);
    return adapter === undefined ? null : adapter;
  }

  getProxyPassword(accountId: string): string {
    const value = this.proxyPasswords.get(accountId);
    return value === undefined ? '' : value;
  }

  getProxy(accountId: string): SteamProxySettings | null {
    const value = this.proxies.get(accountId);
    return value === undefined ? null : value;
  }
}

class FakeAuthService implements ISteamAuthService {
  readonly accountId: string;
  readonly steamId64: string;
  failQrSignIn: boolean = false;
  failQrPollTransport: boolean = false;
  failQrPollTerminal: boolean = false;
  failChallengeTransport: boolean = false;
  failChallengeValidation: boolean = false;
  failCancelPending: boolean = false;
  failClose: boolean = false;
  qrStableAccountName: string = '';
  startupRefreshState: SteamSessionState = SteamSessionState.LOGGED_ON;
  signInCount: number = 0;
  completeChallengeCount: number = 0;
  pollCount: number = 0;
  refreshCount: number = 0;
  beginQrCount: number = 0;
  cancelPendingCount: number = 0;
  closeCount: number = 0;
  restorePendingCount: number = 0;
  lastSignInRequest: SteamAuthRequest | null = null;
  lastChallengeRequest: SteamAuthRequest | null = null;
  lastRefreshToken: string = '';
  private pendingAuth: SteamAuthPendingSnapshot | null = null;
  signInGate: TestAsyncGate | null = null;
  refreshGate: TestAsyncGate | null = null;
  omitPendingForChallenge: boolean = false;

  constructor(profile: SteamAccountProfile) {
    this.accountId = profile.accountId;
    this.steamId64 = profile.steamId64.length > 0 ? profile.steamId64 : '76561197960287932';
  }

  async signIn(request: SteamAuthRequest): Promise<SteamAuthResult> {
    this.assertAccount(request.accountId);
    this.signInCount++;
    this.lastSignInRequest = request;
    const gate = this.signInGate;
    if (gate !== null) {
      await gate.enter();
    }
    const session = new SteamSessionSnapshot(
      this.accountId,
      SteamSessionState.NEEDS_TWO_FACTOR,
      this.steamId64,
      'fake-auth',
      1700000100
    );
    const createdAt = Math.floor(Date.now() / 1000);
    if (!this.omitPendingForChallenge) {
      this.pendingAuth = new SteamAuthPendingSnapshot(
        this.accountId,
        'fake-client-' + this.accountId,
        'fake-request-' + this.accountId,
        this.steamId64,
        SteamAuthChallengeKind.TWO_FACTOR,
        5,
        createdAt,
        createdAt + SteamAuthPendingSnapshot.MAX_LIFETIME_SECONDS
      );
    }
    return new SteamAuthResult(
      session,
      new SteamCredentialSet(),
      SteamAuthChallengeKind.TWO_FACTOR
    );
  }

  async completeChallenge(request: SteamAuthRequest): Promise<SteamAuthResult> {
    this.assertAccount(request.accountId);
    if (this.pendingAuth === null) {
      throw new Error('fake auth pending session was not restored');
    }
    if (this.failChallengeTransport) {
      throw new SteamAuthError(
        'fake authentication challenge transport failure',
        SteamAuthErrorKind.TRANSPORT,
        'challenge_completion'
      );
    }
    if (this.failChallengeValidation) {
      throw new SteamAuthError(
        'fake authentication challenge code is invalid locally',
        SteamAuthErrorKind.VALIDATION,
        'challenge_completion'
      );
    }
    this.completeChallengeCount++;
    this.lastChallengeRequest = request;
    const session = new SteamSessionSnapshot(
      this.accountId,
      SteamSessionState.LOGGED_ON,
      this.steamId64,
      'fake-auth',
      1700000200
    );
    const credentials = new SteamCredentialSet(
      this.accountId,
      '',
      'refresh-' + this.accountId,
      '',
      '',
      '',
      '',
      'access-' + this.accountId,
      'oauth-' + this.accountId,
      'guard-data-' + this.accountId
    );
    this.pendingAuth = null;
    return new SteamAuthResult(session, credentials, SteamAuthChallengeKind.NONE);
  }

  async beginQr(request: SteamAuthRequest): Promise<SteamAuthResult> {
    this.assertAccount(request.accountId);
    this.beginQrCount++;
    if (this.failQrSignIn) {
      throw new Error('fake QR authentication request failed');
    }
    const createdAt = Math.floor(Date.now() / 1000);
    this.pendingAuth = new SteamAuthPendingSnapshot(
      this.accountId,
      'fake-qr-client-' + this.accountId,
      'AQIDBA==',
      '',
      SteamAuthChallengeKind.QR_SCAN,
      5,
      createdAt,
      createdAt + SteamAuthPendingSnapshot.MAX_LIFETIME_SECONDS,
      SteamAuthFlowKind.QR,
      'https://s.team/q/' + this.accountId
    );
    return new SteamAuthResult(
      new SteamSessionSnapshot(this.accountId, SteamSessionState.NEEDS_QR_SCAN),
      new SteamCredentialSet(),
      SteamAuthChallengeKind.QR_SCAN,
      SteamAuthFlowKind.QR,
      'https://s.team/q/' + this.accountId
    );
  }

  async poll(accountId: string): Promise<SteamAuthResult> {
    this.assertAccount(accountId);
    if (this.pendingAuth === null) {
      throw new Error('fake auth pending session was not restored');
    }
    this.pollCount++;
    if (this.failQrPollTransport) {
      throw new SteamAuthError(
        'fake QR polling transport failure',
        SteamAuthErrorKind.TRANSPORT,
        'qr_poll',
        0,
        0
      );
    }
    if (this.failQrPollTerminal) {
      this.pendingAuth = null;
      throw new SteamAuthError(
        'fake QR challenge rejected by server',
        SteamAuthErrorKind.SERVER,
        'qr_poll',
        65,
        0
      );
    }
    const session = new SteamSessionSnapshot(
      this.accountId,
      SteamSessionState.LOGGED_ON,
      this.steamId64,
      'fake-auth',
      1700000300
    );
    this.pendingAuth = null;
    const credentials: SteamCredentialSet = this.qrStableAccountName.length <= 0
      ? new SteamCredentialSet()
      : new SteamCredentialSet(
        this.qrStableAccountName,
        '',
        'refresh-' + this.qrStableAccountName,
        '',
        '',
        '',
        '',
        'access-' + this.qrStableAccountName
      );
    return new SteamAuthResult(session, credentials, SteamAuthChallengeKind.NONE);
  }

  async cancelPendingAuth(accountId: string): Promise<void> {
    this.assertAccount(accountId);
    this.cancelPendingCount++;
    if (this.failCancelPending) {
      throw new Error('fake authentication cancellation failure');
    }
    this.pendingAuth = null;
  }

  async close(accountId: string): Promise<void> {
    this.assertAccount(accountId);
    this.closeCount++;
    if (this.failClose) {
      throw new Error('fake authentication close failure');
    }
    this.pendingAuth = null;
  }

  async refresh(accountId: string, refreshToken: string): Promise<SteamAuthResult> {
    this.assertAccount(accountId);
    this.refreshCount++;
    this.lastRefreshToken = refreshToken;
    const gate = this.refreshGate;
    if (gate !== null) {
      await gate.enter();
    }
    const session = new SteamSessionSnapshot(
      this.accountId,
      this.startupRefreshState,
      '',
      'fake-auth',
      1700000400
    );
    const credentials = new SteamCredentialSet(
      this.accountId,
      '',
      'refresh-next-' + this.accountId,
      '',
      '',
      '',
      '',
      'access-next-' + this.accountId,
      'oauth-next-' + this.accountId,
      'guard-data-' + this.accountId
    );
    return new SteamAuthResult(session, credentials, SteamAuthChallengeKind.NONE);
  }

  getPendingAuthSnapshot(accountId: string): SteamAuthPendingSnapshot | null {
    this.assertAccount(accountId);
    if (this.pendingAuth === null) {
      return null;
    }
    return new SteamAuthPendingSnapshot(
      this.pendingAuth.accountId,
      this.pendingAuth.clientId,
      this.pendingAuth.requestId,
      this.pendingAuth.steamId64,
      this.pendingAuth.challenge,
      this.pendingAuth.intervalSeconds,
      this.pendingAuth.createdAtEpochSeconds,
      this.pendingAuth.expiresAtEpochSeconds,
      this.pendingAuth.flow,
      this.pendingAuth.challengeUrl
    );
  }

  restorePendingAuthSnapshot(snapshot: SteamAuthPendingSnapshot, _credentials: SteamCredentialSet): boolean {
    this.assertAccount(snapshot.accountId);
    if (!snapshot.isValidFor(this.accountId, Math.floor(Date.now() / 1000))) {
      return false;
    }
    this.restorePendingCount++;
    this.pendingAuth = snapshot;
    return true;
  }

  private assertAccount(accountId: string): void {
    if (accountId !== this.accountId) {
      throw new Error('fake auth service account mismatch');
    }
  }
}

class FakeAuthServiceFactory implements ISteamArkAuthServiceFactory {
  readonly services: Map<string, FakeAuthService> = new Map<string, FakeAuthService>();
  readonly proxyPasswords: Map<string, string> = new Map<string, string>();
  readonly proxies: Map<string, SteamProxySettings> = new Map<string, SteamProxySettings>();
  failQrSignIn: boolean = false;
  qrStableAccountName: string = '';
  omitPendingForChallenge: boolean = false;
  startupRefreshState: SteamSessionState = SteamSessionState.LOGGED_ON;
  createCount: number = 0;
  signInGate: TestAsyncGate | null = null;
  refreshGate: TestAsyncGate | null = null;

  create(profile: SteamAccountProfile, proxyPassword: string = ''): ISteamAuthService {
    this.createCount++;
    this.proxyPasswords.set(profile.accountId, proxyPassword);
    this.proxies.set(profile.accountId, new SteamProxySettings(
      profile.proxy.kind,
      profile.proxy.host,
      profile.proxy.port,
      profile.proxy.username
    ));
    const service = new FakeAuthService(profile);
    service.failQrSignIn = this.failQrSignIn;
    service.qrStableAccountName = this.qrStableAccountName;
    service.omitPendingForChallenge = this.omitPendingForChallenge;
    service.startupRefreshState = this.startupRefreshState;
    service.signInGate = this.signInGate;
    service.refreshGate = this.refreshGate;
    this.services.set(profile.accountId, service);
    return service;
  }

  get(accountId: string): FakeAuthService | null {
    const service = this.services.get(accountId);
    return service === undefined ? null : service;
  }

  getProxyPassword(accountId: string): string {
    const value = this.proxyPasswords.get(accountId);
    return value === undefined ? '' : value;
  }

  getProxy(accountId: string): SteamProxySettings | null {
    const value = this.proxies.get(accountId);
    return value === undefined ? null : value;
  }
}

class FakeAccountLifecycle implements ISteamArkAccountLifecycle {
  stopCount: number = 0;
  removeCount: number = 0;
  failStop: boolean = false;
  failRemove: boolean = false;

  async stop(_accountId: string): Promise<void> {
    this.stopCount++;
    if (this.failStop) {
      throw new Error('fake farming stop failed');
    }
  }

  async remove(_accountId: string): Promise<void> {
    this.removeCount++;
    if (this.failRemove) {
      throw new Error('fake farming removal failed');
    }
  }
}

class FakeStateHost {
  readonly settingsStore: FakeSettingsStore;
  readonly credentialStore: FakeCredentialStore;
  readonly adapterFactory: FakeInventoryAdapterFactory;
  readonly authFactory: FakeAuthServiceFactory;
  readonly lifecycle: FakeAccountLifecycle;
  readonly service: SteamArkStateService;

  constructor(
    settingsStore: FakeSettingsStore = new FakeSettingsStore(),
    credentialStore: FakeCredentialStore = new FakeCredentialStore()
  ) {
    this.settingsStore = settingsStore;
    this.credentialStore = credentialStore;
    this.adapterFactory = new FakeInventoryAdapterFactory();
    this.authFactory = new FakeAuthServiceFactory();
    this.lifecycle = new FakeAccountLifecycle();
    this.service = new SteamArkStateService(
      new SteamArkStateServiceOptions(this.settingsStore, this.credentialStore)
    );
    this.service.setAuthServiceFactory(this.authFactory);
    this.service.setInventoryAdapterFactory(this.adapterFactory);
    this.service.setAccountLifecycle(this.lifecycle);
  }
}

async function prepareLoggedOnAccount(
  host: FakeStateHost,
  accountId: string,
  steamId64: string
): Promise<void> {
  const json = '{"SteamLogin":"' + accountId + '","SteamPassword":"password-' + accountId + '"}';
  await host.service.importAsfBotJson('fake-' + accountId + '.json', json);
  const updated = await host.service.updateSession(
    new SteamSessionSnapshot(accountId, SteamSessionState.LOGGED_ON, steamId64, 'fake-cm', 1700000000)
  );
  if (!updated) {
    throw new Error('fake account session was not updated');
  }
}

export default function steamArkStateServiceTest(): void {
  describe('SteamArkStateService', () => {
    it('reportsSharedSecretCapabilityWithoutPersistingTheSecret', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'shared-secret-account.json',
        '{"SteamLogin":"shared-secret-account","SteamPassword":"password"}'
      );

      await host.credentialStore.set(
        'shared-secret-account',
        NGFCredentialKind.SHARED_SECRET,
        'shared-secret-value'
      );
      expect(await host.service.hasSharedSecret('shared-secret-account')).assertTrue();
      const serializedState = host.settingsStore.getString('steam_ark_state_v1', '');
      expect(serializedState.indexOf('shared-secret-value')).assertEqual(-1);

      await host.credentialStore.remove('shared-secret-account', NGFCredentialKind.SHARED_SECRET);
      expect(await host.service.hasSharedSecret('shared-secret-account')).assertFalse();
    });

    it('classifiesMissingPendingRestoreAsPendingAuthRestore', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'missing-pending-account.json',
        '{"SteamLogin":"missing-pending-account","SteamPassword":"password"}'
      );
      await host.service.signIn('missing-pending-account');
      expect(await host.service.cancelAuthentication('missing-pending-account')).assertTrue();

      let rejected: boolean = false;
      try {
        await host.service.completeAuthChallenge('missing-pending-account', '');
      } catch (error) {
        rejected = true;
        expect(error instanceof SteamAuthError).assertTrue();
        if (error instanceof SteamAuthError) {
          expect(error.stage).assertEqual('pending_auth_restore');
        }
      }
      expect(rejected).assertTrue();
      const snapshot = host.service.getSelectedAccount();
      expect(snapshot !== null).assertTrue();
      if (snapshot !== null) {
        expect(snapshot.session.state).assertEqual(SteamSessionState.EXPIRED);
        expect(snapshot.session.lastErrorStage).assertEqual('pending_auth_restore');
      }
    });

    it('rejectsChallengeResultWithoutPendingSnapshot', 0, async () => {
      const host = new FakeStateHost();
      host.authFactory.omitPendingForChallenge = true;
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'missing-challenge-snapshot.json',
        '{"SteamLogin":"missing-challenge-snapshot","SteamPassword":"password"}'
      );

      try {
        await host.service.signIn('missing-challenge-snapshot');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof SteamAuthError).assertTrue();
        if (error instanceof SteamAuthError) {
          expect(error.kind).assertEqual(SteamAuthErrorKind.RESPONSE);
          expect(error.stage).assertEqual('challenge_snapshot');
        }
      }

      const snapshot = host.service.getSelectedAccount();
      expect(snapshot !== null).assertTrue();
      if (snapshot !== null) {
        expect(snapshot.session.state).assertEqual(SteamSessionState.ERROR);
        expect(snapshot.session.lastErrorType).assertEqual(SteamAuthErrorKind.RESPONSE);
        expect(snapshot.session.lastErrorStage).assertEqual('challenge_snapshot');
        expect(snapshot.pendingAuth).assertNull();
      }
    });

    it('rejectsInventoryBeforeLoggedOnWithoutCreatingAdapter', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'fake-disconnected.json',
        '{"SteamLogin":"disconnected","SteamPassword":"password-disconnected"}'
      );

      try {
        await host.service.syncInventory('disconnected', new SteamInventoryQuery());
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }
      expect(host.adapterFactory.createCount).assertEqual(0);
    });

    it('opensAndCachesReadOnlyInventoryPerAccount', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await prepareLoggedOnAccount(host, 'alice', '76561197960287930');
      await prepareLoggedOnAccount(host, 'bob', '76561197960287931');

      const query = new SteamInventoryQuery('753', '6', 1, 100);
      const alicePage = await host.service.syncInventory('alice', query);
      const bobPage = await host.service.syncInventory('bob', query);
      expect(alicePage.items.length).assertEqual(1);
      expect(bobPage.items.length).assertEqual(1);
      expect(alicePage.items[0].assetId).assertEqual('1001');
      expect(bobPage.items[0].assetId).assertEqual('2001');
      expect(alicePage.items[0].name).assertEqual('alice card');
      expect(bobPage.items[0].name).assertEqual('bob card');
      expect(host.adapterFactory.createCount).assertEqual(2);

      const aliceAdapter = host.adapterFactory.get('alice');
      const bobAdapter = host.adapterFactory.get('bob');
      expect(aliceAdapter !== null).assertTrue();
      expect(bobAdapter !== null).assertTrue();
      if (aliceAdapter !== null && bobAdapter !== null) {
        expect(aliceAdapter.openCount).assertEqual(1);
        expect(bobAdapter.openCount).assertEqual(1);
        expect(aliceAdapter.lastCredentials !== null).assertTrue();
        if (aliceAdapter.lastCredentials !== null) {
          expect(aliceAdapter.lastCredentials.password).assertEqual('password-alice');
        }
      }

      const cachedAlice = await host.service.getCachedInventory('alice', query);
      const cachedBob = await host.service.getCachedInventory('bob', query);
      expect(cachedAlice !== null).assertTrue();
      expect(cachedBob !== null).assertTrue();
      const aliceItem = await host.service.getInventoryItem('alice', '1001');
      const bobItem = await host.service.getInventoryItem('bob', '1001');
      expect(aliceItem !== null).assertTrue();
      expect(bobItem).assertNull();

      const nextPageQuery = new SteamInventoryQuery('753', '6', 2, 100, '', false, false, '3001');
      await host.service.syncInventory('alice', nextPageQuery);
      if (aliceAdapter !== null) {
        expect(aliceAdapter.syncCount).assertEqual(2);
      }
      const cachedNextPage = await host.service.getCachedInventory('alice', nextPageQuery);
      expect(cachedNextPage !== null).assertTrue();
    });

    it('storesProxyPasswordOutsideStateAndInjectsItIntoHostFactories', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await prepareLoggedOnAccount(host, 'proxy-account', '76561197960287941');

      const proxy = new SteamProxySettings(
        SteamProxyKind.HTTP,
        'proxy.example',
        8080,
        'proxy-user'
      );
      expect(await host.service.saveProxy('proxy-account', proxy, 'proxy-secret')).assertTrue();
      expect(await host.service.getProxyPassword('proxy-account')).assertEqual('proxy-secret');

      const serializedState = host.settingsStore.getString('steam_ark_state_v1', '');
      expect(serializedState.indexOf('proxy-secret')).assertEqual(-1);

      await host.service.signIn('proxy-account');
      expect(host.authFactory.getProxyPassword('proxy-account')).assertEqual('proxy-secret');
      const authProxy: SteamProxySettings | null = host.authFactory.getProxy('proxy-account');
      expect(authProxy !== null).assertTrue();
      if (authProxy !== null) {
        expect(authProxy.kind).assertEqual(SteamProxyKind.HTTP);
        expect(authProxy.host).assertEqual('proxy.example');
        expect(authProxy.port).assertEqual(8080);
        expect(authProxy.username).assertEqual('proxy-user');
      }

      await host.service.updateSession(
        new SteamSessionSnapshot('proxy-account', SteamSessionState.LOGGED_ON, '76561197960287941')
      );
      await host.service.syncInventory('proxy-account', new SteamInventoryQuery());
      expect(host.adapterFactory.getProxyPassword('proxy-account')).assertEqual('proxy-secret');
      const inventoryProxy: SteamProxySettings | null = host.adapterFactory.getProxy('proxy-account');
      expect(inventoryProxy !== null).assertTrue();
      if (inventoryProxy !== null) {
        expect(inventoryProxy.kind).assertEqual(SteamProxyKind.HTTP);
        expect(inventoryProxy.host).assertEqual('proxy.example');
        expect(inventoryProxy.port).assertEqual(8080);
        expect(inventoryProxy.username).assertEqual('proxy-user');
      }

      expect(await host.service.saveProxy('proxy-account', new SteamProxySettings(SteamProxyKind.DIRECT))).assertTrue();
      expect(await host.service.getProxyPassword('proxy-account')).assertEqual('');
      const authService = host.authFactory.get('proxy-account');
      const inventoryAdapter = host.adapterFactory.get('proxy-account');
      expect(authService !== null).assertTrue();
      expect(inventoryAdapter !== null).assertTrue();
      if (authService !== null) {
        expect(authService.closeCount).assertEqual(1);
      }
      if (inventoryAdapter !== null) {
        expect(inventoryAdapter.closeCount).assertEqual(1);
      }
      const disconnected = host.service.getSelectedAccount();
      expect(disconnected !== null).assertTrue();
      if (disconnected !== null) {
        expect(disconnected.session.state).assertEqual(SteamSessionState.DISCONNECTED);
        expect(disconnected.pendingAuth).assertNull();
      }
      expect(await host.service.saveProxy('proxy-account', new SteamProxySettings(SteamProxyKind.SYSTEM))).assertTrue();
      const systemProxy = host.service.getSelectedAccount();
      expect(systemProxy !== null).assertTrue();
      if (systemProxy !== null) {
        expect(systemProxy.profile.proxy.kind).assertEqual(SteamProxyKind.SYSTEM);
      }
    });

    it('doesNotMutateProxyWhenAuthenticationCleanupFails', 0, async () => {
      const host = new FakeStateHost();
      const accountId: string = 'proxy-auth-close-failure';
      await host.service.initialize();
      await prepareLoggedOnAccount(host, accountId, '76561197960287951');
      await host.service.saveProxy(
        accountId,
        new SteamProxySettings(SteamProxyKind.HTTP, 'old.proxy.example', 8080, 'old-user'),
        'old-proxy-password'
      );
      await host.service.signIn(accountId);
      const authService: FakeAuthService | null = host.authFactory.get(accountId);
      expect(authService !== null).assertTrue();
      if (authService !== null) {
        authService.failClose = true;
      }

      try {
        await host.service.saveProxy(
          accountId,
          new SteamProxySettings(SteamProxyKind.HTTP, 'new.proxy.example', 9090, 'new-user'),
          'new-proxy-password'
        );
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }

      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.profile.proxy.host).assertEqual('old.proxy.example');
        expect(account.profile.proxy.port).assertEqual(8080);
        expect(account.profile.proxy.username).assertEqual('old-user');
        expect(account.session.state).assertEqual(SteamSessionState.NEEDS_TWO_FACTOR);
      }
      expect(await host.service.getProxyPassword(accountId)).assertEqual('old-proxy-password');

      if (authService !== null) {
        authService.failClose = false;
      }
      await host.service.signIn(accountId);
      expect(host.authFactory.createCount).assertEqual(2);
      expect(host.authFactory.getProxyPassword(accountId)).assertEqual('old-proxy-password');
      const recreatedProxy: SteamProxySettings | null = host.authFactory.getProxy(accountId);
      expect(recreatedProxy !== null).assertTrue();
      if (recreatedProxy !== null) {
        expect(recreatedProxy.host).assertEqual('old.proxy.example');
      }
    });

    it('evictsFailedInventoryAdapterAndKeepsPreviousProxy', 0, async () => {
      const host = new FakeStateHost();
      const accountId: string = 'proxy-inventory-close-failure';
      await host.service.initialize();
      await prepareLoggedOnAccount(host, accountId, '76561197960287952');
      await host.service.saveProxy(
        accountId,
        new SteamProxySettings(SteamProxyKind.HTTP, 'old.inventory.proxy', 8081),
        'old-inventory-password'
      );
      await host.service.updateSession(
        new SteamSessionSnapshot(accountId, SteamSessionState.LOGGED_ON, '76561197960287952')
      );
      await host.service.syncInventory(accountId, new SteamInventoryQuery());
      const firstAdapter: FakeInventoryAdapter | null = host.adapterFactory.get(accountId);
      expect(firstAdapter !== null).assertTrue();
      if (firstAdapter !== null) {
        firstAdapter.failClose = true;
      }

      try {
        await host.service.saveProxy(
          accountId,
          new SteamProxySettings(SteamProxyKind.HTTP, 'new.inventory.proxy', 9081),
          'new-inventory-password'
        );
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }

      expect(await host.service.getProxyPassword(accountId)).assertEqual('old-inventory-password');
      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.profile.proxy.host).assertEqual('old.inventory.proxy');
      }
      await host.service.updateSession(
        new SteamSessionSnapshot(accountId, SteamSessionState.LOGGED_ON, '76561197960287952')
      );
      await host.service.syncInventory(accountId, new SteamInventoryQuery());
      expect(host.adapterFactory.createCount).assertEqual(2);
      expect(host.adapterFactory.get(accountId) === firstAdapter).assertFalse();
      expect(host.adapterFactory.getProxyPassword(accountId)).assertEqual('old-inventory-password');
    });

    it('restoresCoherentPreviousProxyWhenStatePersistenceFails', 0, async () => {
      const host = new FakeStateHost();
      const accountId: string = 'proxy-state-rollback';
      await host.service.initialize();
      await prepareLoggedOnAccount(host, accountId, '76561197960287953');
      await host.service.saveProxy(
        accountId,
        new SteamProxySettings(SteamProxyKind.HTTP, 'old.state.proxy', 8082, 'old-user'),
        'old-state-password'
      );
      host.settingsStore.failNextAsyncWrite = true;

      try {
        await host.service.saveProxy(
          accountId,
          new SteamProxySettings(SteamProxyKind.SOCKS5, 'new.state.proxy', 9082, 'new-user'),
          'new-state-password'
        );
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }

      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.profile.proxy.kind).assertEqual(SteamProxyKind.HTTP);
        expect(account.profile.proxy.host).assertEqual('old.state.proxy');
        expect(account.profile.proxy.username).assertEqual('old-user');
        expect(account.session.state).assertEqual(SteamSessionState.DISCONNECTED);
      }
      expect(await host.service.getProxyPassword(accountId)).assertEqual('old-state-password');
      const persisted: string = host.settingsStore.getString('steam_ark_state_v1', '');
      expect(persisted.indexOf('old.state.proxy') >= 0).assertTrue();
      expect(persisted.indexOf('new.state.proxy')).assertEqual(-1);
      expect(persisted.indexOf('old-state-password')).assertEqual(-1);
      expect(persisted.indexOf('new-state-password')).assertEqual(-1);
    });

    it('forwardCommitsNewProxyWhenOldPasswordCannotBeRestored', 0, async () => {
      const host = new FakeStateHost();
      const accountId: string = 'proxy-forward-recovery';
      await host.service.initialize();
      await prepareLoggedOnAccount(host, accountId, '76561197960287954');
      await host.service.saveProxy(
        accountId,
        new SteamProxySettings(SteamProxyKind.HTTP, 'old.forward.proxy', 8083),
        'old-forward-password'
      );
      host.settingsStore.failNextAsyncWrite = true;
      host.credentialStore.failSetKind = NGFCredentialKind.PROXY_PASSWORD;
      host.credentialStore.failSetValue = 'old-forward-password';
      host.credentialStore.failSetOnce = false;

      expect(await host.service.saveProxy(
        accountId,
        new SteamProxySettings(SteamProxyKind.SOCKS5, 'new.forward.proxy', 9083),
        'new-forward-password'
      )).assertTrue();

      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.profile.proxy.kind).assertEqual(SteamProxyKind.SOCKS5);
        expect(account.profile.proxy.host).assertEqual('new.forward.proxy');
        expect(account.session.state).assertEqual(SteamSessionState.DISCONNECTED);
      }
      expect(await host.service.getProxyPassword(accountId)).assertEqual('new-forward-password');
      await host.service.signIn(accountId);
      expect(host.authFactory.getProxyPassword(accountId)).assertEqual('new-forward-password');
      const recreatedProxy: SteamProxySettings | null = host.authFactory.getProxy(accountId);
      expect(recreatedProxy !== null).assertTrue();
      if (recreatedProxy !== null) {
        expect(recreatedProxy.kind).assertEqual(SteamProxyKind.SOCKS5);
        expect(recreatedProxy.host).assertEqual('new.forward.proxy');
      }
    });

    it('clearsPendingAuthenticationWhenProxyChanges', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'proxy-pending.json',
        '{"SteamLogin":"proxy-pending","SteamPassword":"proxy-pending-password"}'
      );

      const challenge = await host.service.signIn('proxy-pending');
      expect(challenge.session.state).assertEqual(SteamSessionState.NEEDS_TWO_FACTOR);
      const before = host.service.getSelectedAccount();
      expect(before !== null).assertTrue();
      if (before !== null) {
        expect(before.pendingAuth !== null).assertTrue();
      }

      expect(await host.service.saveProxy(
        'proxy-pending',
        new SteamProxySettings(SteamProxyKind.HTTP, 'proxy.example', 8080),
        'proxy-password'
      )).assertTrue();

      const after = host.service.getSelectedAccount();
      expect(after !== null).assertTrue();
      if (after !== null) {
        expect(after.session.state).assertEqual(SteamSessionState.DISCONNECTED);
        expect(after.pendingAuth).assertNull();
      }
      const authService = host.authFactory.get('proxy-pending');
      expect(authService !== null).assertTrue();
      if (authService !== null) {
        expect(authService.closeCount).assertEqual(1);
      }
    });

    it('disposesAuthenticationInventoryCachesAndListeners', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await prepareLoggedOnAccount(host, 'dispose-account', '76561197960287942');
      await host.service.signIn('dispose-account');
      await host.service.updateSession(
        new SteamSessionSnapshot('dispose-account', SteamSessionState.LOGGED_ON, '76561197960287942')
      );
      await host.service.syncInventory('dispose-account', new SteamInventoryQuery());
      const authService = host.authFactory.get('dispose-account');
      const inventoryAdapter = host.adapterFactory.get('dispose-account');
      expect(authService !== null).assertTrue();
      expect(inventoryAdapter !== null).assertTrue();

      await host.service.dispose();
      await host.service.dispose();

      if (authService !== null) {
        expect(authService.closeCount).assertEqual(1);
      }
      if (inventoryAdapter !== null) {
        expect(inventoryAdapter.closeCount).assertEqual(1);
      }
      const snapshot = host.service.getSnapshot();
      expect(snapshot.initialized).assertFalse();
      expect(snapshot.accounts.length).assertEqual(0);
    });

    it('waitsForInFlightAuthenticationBeforeDisposingState', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'dispose-in-flight.json',
        '{"SteamLogin":"dispose-in-flight","SteamPassword":"dispose-password"}'
      );
      const gate = new TestAsyncGate();
      host.authFactory.signInGate = gate;
      const signInPromise: Promise<SteamAuthResult> = host.service.signIn('dispose-in-flight');
      await gate.entered;

      let disposed: boolean = false;
      const disposePromise: Promise<void> = host.service.dispose().then((): void => {
        disposed = true;
      });
      await Promise.resolve();
      expect(disposed).assertFalse();

      gate.release();
      const result = await signInPromise;
      expect(result.session.state).assertEqual(SteamSessionState.NEEDS_TWO_FACTOR);
      await disposePromise;
      expect(disposed).assertTrue();
      expect(host.service.getSnapshot().initialized).assertFalse();
    });

    it('preservesReplacementRuntimeDependenciesDuringAbilityTeardown', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'teardown-reconfigure.json',
        '{"SteamLogin":"teardown-reconfigure","SteamPassword":"teardown-password"}'
      );
      const gate = new TestAsyncGate();
      host.authFactory.signInGate = gate;
      const signInPromise: Promise<SteamAuthResult> = host.service.signIn('teardown-reconfigure');
      await gate.entered;

      const disposePromise: Promise<void> = host.service.dispose();
      const replacementAuthFactory = new FakeAuthServiceFactory();
      const replacementInventoryFactory = new FakeInventoryAdapterFactory();
      host.service.setAuthServiceFactory(replacementAuthFactory);
      host.service.setInventoryAdapterFactory(replacementInventoryFactory);
      host.service.setProfileResolver(new FakeProfileResolver('Replacement Profile'));
      host.service.setAccountLifecycle(new FakeAccountLifecycle());

      let reinitialized: boolean = false;
      const reinitializePromise: Promise<boolean> = host.service.initialize().then((initialized: boolean): boolean => {
        reinitialized = initialized;
        return initialized;
      });
      await Promise.resolve();
      expect(reinitialized).assertFalse();

      gate.release();
      await signInPromise;
      await disposePromise;
      expect(await reinitializePromise).assertTrue();
      expect(host.service.isAuthServiceReady()).assertTrue();
      expect(host.service.isInventoryAdapterReady()).assertTrue();

      const restoredSignIn: SteamAuthResult = await host.service.signIn('teardown-reconfigure');
      expect(restoredSignIn.session.state).assertEqual(SteamSessionState.NEEDS_TWO_FACTOR);
      expect(replacementAuthFactory.createCount).assertEqual(1);
    });

    it('serializesImportBehindAuthenticationAndClosesTheOldSession', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'import-queue.json',
        '{"SteamLogin":"import-queue","SteamPassword":"old-password"}'
      );
      const gate = new TestAsyncGate();
      host.authFactory.signInGate = gate;
      const signInPromise: Promise<SteamAuthResult> = host.service.signIn('import-queue');
      await gate.entered;

      const importPromise: Promise<SteamArkImportSummary> = host.service.importAsfBotJson(
        'replacement.json',
        '{"SteamLogin":"import-queue","SteamPassword":"new-password"}'
      );
      gate.release();
      await signInPromise;
      const imported = await importPromise;
      expect(imported.account.session.state).assertEqual(SteamSessionState.DISCONNECTED);
      const credentials = await host.service.getCredentials('import-queue');
      expect(credentials.password).assertEqual('new-password');
      const authService = host.authFactory.get('import-queue');
      expect(authService !== null).assertTrue();
      if (authService !== null) {
        expect(authService.closeCount).assertEqual(1);
      }
    });

    it('serializesInventoryCloseBehindAnInFlightSync', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await prepareLoggedOnAccount(host, 'inventory-close-queue', '76561197960287945');
      const gate = new TestAsyncGate();
      host.adapterFactory.syncGate = gate;
      const syncPromise: Promise<SteamInventoryPage> = host.service.syncInventory(
        'inventory-close-queue',
        new SteamInventoryQuery()
      );
      await gate.entered;
      const adapter = host.adapterFactory.get('inventory-close-queue');
      expect(adapter !== null).assertTrue();
      if (adapter === null) {
        gate.release();
        return;
      }

      const closePromise: Promise<void> = host.service.closeInventory('inventory-close-queue');
      await Promise.resolve();
      expect(adapter.closeCount).assertEqual(0);
      gate.release();
      await syncPromise;
      await closePromise;
      expect(adapter.closeCount).assertEqual(1);
      expect(await host.service.getCachedInventory('inventory-close-queue', new SteamInventoryQuery()))
        .assertNull();
    });

    it('rollsBackPartialImportedCredentialWrites', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'old-account.json',
        '{"SteamLogin":"rollback-account","SteamPassword":"old-password"}'
      );
      const before = await host.service.getCredentials('rollback-account');
      host.credentialStore.failSetKind = NGFCredentialKind.PASSWORD;

      try {
        await host.service.importAsfBotJson(
          'new-account.json',
          '{"SteamLogin":"rollback-account","SteamPassword":"new-password"}'
        );
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }

      const after = await host.service.getCredentials('rollback-account');
      expect(after.accountName).assertEqual(before.accountName);
      expect(after.password).assertEqual(before.password);
      expect(after.refreshToken).assertEqual(before.refreshToken);
      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.session.state).assertEqual(SteamSessionState.DISCONNECTED);
      }
    });

    it('replacesMaFileAuthenticatorMaterialWithoutOverwritingTheActiveSession', 0, async () => {
      const host = new FakeStateHost();
      const accountId: string = 'mafile-merge-account';
      const steamId64: string = '76561197960287947';
      await host.service.initialize();
      await prepareLoggedOnAccount(host, accountId, steamId64);
      await host.credentialStore.set(accountId, NGFCredentialKind.REFRESH_TOKEN, 'active-refresh');
      await host.credentialStore.set(accountId, NGFCredentialKind.LOGIN_KEY, 'active-login-key');
      await host.credentialStore.set(accountId, NGFCredentialKind.SHARED_SECRET, 'old-shared-secret');
      await host.credentialStore.set(accountId, NGFCredentialKind.IDENTITY_SECRET, 'old-identity-secret');
      await host.credentialStore.set(accountId, NGFCredentialKind.DEVICE_ID, 'android:old-device');
      await host.credentialStore.set(accountId, NGFCredentialKind.GUARD_DATA, 'active-guard-data');
      await host.credentialStore.set(accountId, NGFCredentialKind.COOKIE_JAR, 'active-cookie-jar');
      await host.credentialStore.set(accountId, NGFCredentialKind.ACCESS_TOKEN, 'active-access-token');
      await host.credentialStore.set(accountId, NGFCredentialKind.CSRF_TOKEN, 'active-csrf-token');

      const summary = await host.service.importMaFile(
        'mafile-merge-account.maFile',
        '{"steamid":"' + steamId64 + '","account_name":"' + accountId + '",' +
          '"shared_secret":"new-shared-secret","identity_secret":"new-identity-secret",' +
          '"Session":{"AccessToken":"mafile-access-token","OAuthToken":"mafile-oauth-token"}}'
      );

      expect(summary.mergedExistingAccount).assertTrue();
      const credentials = await host.service.getCredentials(accountId);
      expect(credentials.password).assertEqual('password-' + accountId);
      expect(credentials.refreshToken).assertEqual('active-refresh');
      expect(credentials.loginKey).assertEqual('active-login-key');
      expect(credentials.sharedSecret).assertEqual('new-shared-secret');
      expect(credentials.identitySecret).assertEqual('new-identity-secret');
      expect(credentials.deviceId).assertEqual('');
      expect(credentials.guardData).assertEqual('active-guard-data');
      expect(credentials.accessToken).assertEqual('active-access-token');
      expect(credentials.oauthToken).assertEqual('mafile-oauth-token');
      expect(await host.credentialStore.get(accountId, NGFCredentialKind.COOKIE_JAR))
        .assertEqual('active-cookie-jar');
      expect(await host.credentialStore.get(accountId, NGFCredentialKind.CSRF_TOKEN))
        .assertEqual('active-csrf-token');
    });

    it('rollsBackImportedCredentialsWhenStatePersistenceFails', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'old-account.json',
        '{"SteamLogin":"persist-rollback-account","SteamPassword":"old-password"}'
      );
      host.settingsStore.failNextAsyncWrite = true;

      try {
        await host.service.importAsfBotJson(
          'new-account.json',
          '{"SteamLogin":"persist-rollback-account","SteamPassword":"new-password"}'
        );
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }

      const credentials = await host.service.getCredentials('persist-rollback-account');
      expect(credentials.password).assertEqual('old-password');
      const persisted = host.settingsStore.getString('steam_ark_state_v1', '');
      expect(persisted.indexOf('old-password')).assertEqual(-1);
      expect(persisted.indexOf('persist-rollback-account') >= 0).assertTrue();
    });

    it('restoresAccountWhenSecureRemovalIsRejected', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'remove-account.json',
        '{"SteamLogin":"remove-retry-account","SteamPassword":"remove-password"}'
      );
      host.credentialStore.failRemoveAll = true;

      try {
        await host.service.removeAccount('remove-retry-account');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }

      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      const credentials = await host.service.getCredentials('remove-retry-account');
      expect(credentials.password).assertEqual('remove-password');
      if (account !== null) {
        expect(account.session.state).assertEqual(SteamSessionState.ERROR);
        expect(account.session.lastErrorStage).assertEqual('remove_account');
      }
    });

    it('restoresAccountAndCredentialsWhenRemovalPersistenceFails', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'remove-persist-account.json',
        '{"SteamLogin":"remove-persist-account","SteamPassword":"remove-persist-password"}'
      );
      host.settingsStore.failNextAsyncWrite = true;

      try {
        await host.service.removeAccount('remove-persist-account');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }

      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      const credentials = await host.service.getCredentials('remove-persist-account');
      expect(credentials.password).assertEqual('remove-persist-password');
      if (account !== null) {
        expect(account.session.state).assertEqual(SteamSessionState.ERROR);
        expect(account.session.lastErrorStage).assertEqual('remove_account');
      }
    });

    it('restoresAccountAndCredentialsWhenFarmingRemovalFailsAndAllowsRetry', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'remove-farming-failure.json',
        '{"SteamLogin":"remove-farming-failure","SteamPassword":"remove-farming-password"}'
      );
      host.lifecycle.failRemove = true;

      let failureMessage: string = '';
      try {
        await host.service.removeAccount('remove-farming-failure');
      } catch (error) {
        failureMessage = error instanceof Error ? error.message : 'unexpected failure';
      }

      expect(failureMessage).assertEqual('fake farming removal failed');
      expect(host.lifecycle.stopCount).assertEqual(1);
      expect(host.lifecycle.removeCount).assertEqual(1);
      expect(host.service.getSelectedAccount() !== null).assertTrue();
      const restoredCredentials = await host.service.getCredentials('remove-farming-failure');
      expect(restoredCredentials.password).assertEqual('remove-farming-password');

      host.lifecycle.failRemove = false;
      expect(await host.service.removeAccount('remove-farming-failure')).assertTrue();
      expect(host.lifecycle.removeCount).assertEqual(2);
      expect(host.service.getSelectedAccount()).assertNull();
      let credentialsReadAfterRemoval: boolean = true;
      try {
        await host.service.getCredentials('remove-farming-failure');
      } catch (error) {
        credentialsReadAfterRemoval = false;
      }
      expect(credentialsReadAfterRemoval).assertFalse();
      expect(await host.credentialStore.get(
        'remove-farming-failure',
        NGFCredentialKind.PASSWORD
      )).assertNull();
    });

    it('removesPersistedAccountCachesOnlyAfterAccountDeletionCommits', 0, async () => {
      const host = new FakeStateHost();
      const accountId: string = 'remove-inventory-cache';
      const inventoryCacheKey: string = 'steam.inventory.' + encodeURIComponent(accountId) + '.753.6';
      const priceGenerationKey: string = 'steam.market.price.v2.generation.' + encodeURIComponent(accountId);
      const messageGenerationKey: string = 'steam.messages.v2.generation.' + encodeURIComponent(accountId);
      const legacyMessageCacheKey: string = 'steam-ark-messages:' + accountId;
      await host.service.initialize();
      await prepareLoggedOnAccount(host, accountId, '76561197960287946');
      await host.service.syncInventory(accountId, new SteamInventoryQuery());
      SteamArkMarketPriceService.clearCachedAccount(accountId);
      const priceGeneration: number = Number(ngfContentCacheFacade.get(priceGenerationKey));
      const priceIndexKey: string = 'steam.market.price.v2.index.' + encodeURIComponent(accountId) + '.g' +
        priceGeneration.toString();
      const priceCacheKey: string = 'steam.market.price.v2.entry.' + encodeURIComponent(accountId) + '.g' +
        priceGeneration.toString() + '.23.753.' + encodeURIComponent('Test Item');
      ngfContentCacheFacade.put(priceIndexKey, priceCacheKey, 0);
      ngfContentCacheFacade.put(priceCacheKey, 'cached-price', 0);
      SteamArkMessageCacheStore.clearCachedAccount(accountId);
      const messageGeneration: number = SteamArkMessageCacheStore.captureGeneration(accountId);
      const messageCacheKey: string = 'steam.messages.v2.entry.' + encodeURIComponent(accountId) + '.g' +
        messageGeneration.toString();
      expect(SteamArkMessageCacheStore.write(accountId, messageGeneration, 'cached-message', 0)).assertTrue();
      ngfContentCacheFacade.put(legacyMessageCacheKey, 'legacy-cached-message', 0);
      expect(ngfContentCacheFacade.has(inventoryCacheKey)).assertTrue();
      expect(ngfContentCacheFacade.has(priceIndexKey)).assertTrue();
      expect(ngfContentCacheFacade.has(priceCacheKey)).assertTrue();
      expect(ngfContentCacheFacade.has(messageCacheKey)).assertTrue();
      expect(ngfContentCacheFacade.has(legacyMessageCacheKey)).assertTrue();

      host.lifecycle.failRemove = true;
      try {
        await host.service.removeAccount(accountId);
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }
      expect(ngfContentCacheFacade.has(inventoryCacheKey)).assertTrue();
      expect(ngfContentCacheFacade.has(priceIndexKey)).assertTrue();
      expect(ngfContentCacheFacade.has(priceCacheKey)).assertTrue();
      expect(ngfContentCacheFacade.has(messageCacheKey)).assertTrue();
      expect(ngfContentCacheFacade.has(legacyMessageCacheKey)).assertTrue();

      host.lifecycle.failRemove = false;
      expect(await host.service.removeAccount(accountId)).assertTrue();
      expect(ngfContentCacheFacade.has(inventoryCacheKey)).assertFalse();
      expect(ngfContentCacheFacade.has(priceIndexKey)).assertFalse();
      expect(ngfContentCacheFacade.has(priceCacheKey)).assertFalse();
      expect(ngfContentCacheFacade.has(messageCacheKey)).assertFalse();
      expect(ngfContentCacheFacade.has(legacyMessageCacheKey)).assertFalse();
      expect(Number(ngfContentCacheFacade.get(priceGenerationKey)) > priceGeneration).assertTrue();
      expect(Number(ngfContentCacheFacade.get(messageGenerationKey)) > messageGeneration).assertTrue();
      expect(SteamArkMessageCacheStore.write(accountId, messageGeneration, 'stale-message', 0)).assertFalse();
      expect(ngfContentCacheFacade.has(messageCacheKey)).assertFalse();
    });

    it('storesGlobalWebProxyPasswordOutsideGlobalState', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();

      const summary = await host.service.importAsfGlobalJson(
        'ASF.json',
        '{"WebProxy":"http://proxy.example:8080","WebProxyUsername":"proxy-user",' +
          '"WebProxyPassword":"global-proxy-secret","UnknownGlobalField":true}'
      );

      expect(summary.globalConfig.config.webProxyText).assertEqual('http://proxy.example:8080');
      expect(summary.globalConfig.config.webProxyUsername).assertEqual('proxy-user');
      expect(summary.globalConfig.hasCredentialMaterial).assertTrue();
      expect(summary.globalConfig.migrationReport.recognizedFields.includes('WebProxyPassword')).assertTrue();
      expect(summary.globalConfig.migrationReport.unknownFields.includes('UnknownGlobalField')).assertTrue();
      expect(await host.credentialStore.getNamed('steam_ark_global', 'web_proxy_password'))
        .assertEqual('global-proxy-secret');

      const serializedState = host.settingsStore.getString('steam_ark_global_config_v1', '');
      expect(serializedState.indexOf('global-proxy-secret')).assertEqual(-1);
      expect(serializedState.indexOf('proxy-user') >= 0).assertTrue();
    });

    it('rollsBackGlobalCredentialsWhenOneSecretWriteFails', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfGlobalJson(
        'old-global.json',
        '{"IPCPassword":"old-ipc","WebProxyPassword":"old-web"}'
      );
      host.credentialStore.failSetNamedName = 'web_proxy_password';

      try {
        await host.service.importAsfGlobalJson(
          'new-global.json',
          '{"IPCPassword":"new-ipc","WebProxyPassword":"new-web","WebProxy":"http://new"}'
        );
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }

      const snapshot = host.service.getGlobalConfigSnapshot();
      expect(snapshot.config.webProxyText).assertEqual('');
      expect(await host.credentialStore.getNamed('steam_ark_global', 'ipc_password'))
        .assertEqual('old-ipc');
      expect(await host.credentialStore.getNamed('steam_ark_global', 'web_proxy_password'))
        .assertEqual('old-web');
    });

    it('persistsExpiredSessionForUnauthorizedInventoryResponses', 0, async () => {
      const statusCodes: Array<number> = [401, 403];
      for (let index = 0; index < statusCodes.length; index++) {
        const host = new FakeStateHost();
        await host.service.initialize();
        const accountId: string = 'expired-' + statusCodes[index].toString();
        await prepareLoggedOnAccount(host, accountId, '76561197960287940');
        host.adapterFactory.unauthorizedStatusCode = statusCodes[index];

        try {
          await host.service.syncInventory(accountId, new SteamInventoryQuery());
          expect(false).assertTrue();
        } catch (error) {
          expect(error instanceof Error).assertTrue();
        }
        const snapshot = host.service.getSelectedAccount();
        expect(snapshot !== null).assertTrue();
        if (snapshot !== null) {
          expect(snapshot.session.state).assertEqual(SteamSessionState.EXPIRED);
          expect(snapshot.session.lastErrorCode).assertEqual(statusCodes[index]);
        }
        expect(host.settingsStore.writeCount > 0).assertTrue();
      }
    });

    it('persistsAuthChallengesAndTokensThroughSecureBoundary', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'fake-auth.json',
        '{"SteamLogin":"auth-account","SteamPassword":"password-auth-account"}'
      );

      const challenge = await host.service.signIn('auth-account');
      expect(challenge.session.state).assertEqual(SteamSessionState.NEEDS_TWO_FACTOR);
      expect(challenge.challenge).assertEqual(SteamAuthChallengeKind.TWO_FACTOR);
      const authService = host.authFactory.get('auth-account');
      expect(authService !== null).assertTrue();
      if (authService !== null) {
        expect(authService.signInCount).assertEqual(1);
        expect(authService.lastSignInRequest !== null).assertTrue();
        if (authService.lastSignInRequest !== null) {
          expect(authService.lastSignInRequest.credentials.password).assertEqual('password-auth-account');
        }
      }
      const challengeSnapshot = host.service.getSelectedAccount();
      expect(challengeSnapshot !== null).assertTrue();
      if (challengeSnapshot !== null) {
        expect(challengeSnapshot.session.state).assertEqual(SteamSessionState.NEEDS_TWO_FACTOR);
        expect(challengeSnapshot.profile.steamId64).assertEqual('76561197960287932');
      }

      const completed = await host.service.completeAuthChallenge('auth-account', 'ABCD1');
      expect(completed.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      expect(completed.credentials.accessToken).assertEqual('access-auth-account');
      if (authService !== null) {
        expect(authService.completeChallengeCount).assertEqual(1);
        expect(authService.lastChallengeRequest !== null).assertTrue();
        if (authService.lastChallengeRequest !== null) {
          expect(authService.lastChallengeRequest.challengeCode).assertEqual('ABCD1');
          expect(authService.lastChallengeRequest.challengeKind)
            .assertEqual(SteamAuthChallengeKind.TWO_FACTOR);
        }
      }

      const storedAfterLogin = await host.service.getCredentials('auth-account');
      expect(storedAfterLogin.password).assertEqual('password-auth-account');
      expect(storedAfterLogin.refreshToken).assertEqual('refresh-auth-account');
      expect(storedAfterLogin.accessToken).assertEqual('access-auth-account');
      expect(storedAfterLogin.guardData).assertEqual('guard-data-auth-account');
      const serializedState = host.settingsStore.getString('steam_ark_state_v1', '');
      expect(serializedState.indexOf('password-auth-account')).assertEqual(-1);
      expect(serializedState.indexOf('access-auth-account')).assertEqual(-1);

      const refreshed = await host.service.refreshAuthentication('auth-account');
      expect(refreshed.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      const storedAfterRefresh = await host.service.getCredentials('auth-account');
      expect(storedAfterRefresh.refreshToken).assertEqual('refresh-next-auth-account');
      expect(storedAfterRefresh.accessToken).assertEqual('access-next-auth-account');
      expect(storedAfterRefresh.guardData).assertEqual('guard-data-auth-account');
      const refreshedSnapshot = host.service.getSelectedAccount();
      expect(refreshedSnapshot !== null).assertTrue();
      if (refreshedSnapshot !== null) {
        expect(refreshedSnapshot.profile.steamId64).assertEqual('76561197960287932');
      }
      if (authService !== null) {
        expect(authService.refreshCount).assertEqual(1);
        expect(authService.lastRefreshToken).assertEqual('refresh-auth-account');
      }
    });

    it('retainsCodeChallengeAfterTransientFailureForRetry', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'transient-auth.json',
        '{"SteamLogin":"transient-auth","SteamPassword":"password-transient-auth"}'
      );

      await host.service.signIn('transient-auth');
      const authService = host.authFactory.get('transient-auth');
      expect(authService !== null).assertTrue();
      if (authService === null) {
        return;
      }
      authService.failChallengeTransport = true;
      try {
        await host.service.completeAuthChallenge('transient-auth', 'ABCD3');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof SteamAuthError).assertTrue();
      }

      const failed = host.service.getSelectedAccount();
      expect(failed !== null).assertTrue();
      if (failed !== null) {
        expect(failed.session.state).assertEqual(SteamSessionState.ERROR);
        expect(failed.session.lastErrorType).assertEqual(SteamAuthErrorKind.TRANSPORT);
        expect(failed.pendingAuth !== null).assertTrue();
        if (failed.pendingAuth !== null) {
          expect(failed.pendingAuth.challenge).assertEqual(SteamAuthChallengeKind.TWO_FACTOR);
        }
      }

      authService.failChallengeTransport = false;
      const completed = await host.service.completeAuthChallenge('transient-auth', 'ABCD4');
      expect(completed.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      expect(authService.completeChallengeCount).assertEqual(1);
      const recovered = host.service.getSelectedAccount();
      expect(recovered !== null).assertTrue();
      if (recovered !== null) {
        expect(recovered.pendingAuth).assertNull();
      }
    });

    it('retainsPendingChallengeAfterLocalValidationFailureForRetry', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'validation-retry-auth.json',
        '{"SteamLogin":"validation-retry-auth","SteamPassword":"password-validation-retry-auth"}'
      );

      await host.service.signIn('validation-retry-auth');
      const authService = host.authFactory.get('validation-retry-auth');
      expect(authService !== null).assertTrue();
      if (authService === null) {
        return;
      }

      authService.failChallengeValidation = true;
      try {
        await host.service.completeAuthChallenge('validation-retry-auth', '');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof SteamAuthError).assertTrue();
        if (error instanceof SteamAuthError) {
          expect(error.kind).assertEqual(SteamAuthErrorKind.VALIDATION);
          expect(error.stage).assertEqual('challenge_completion');
        }
      }

      const failed = host.service.getSelectedAccount();
      expect(failed !== null).assertTrue();
      if (failed !== null) {
        expect(failed.session.state).assertEqual(SteamSessionState.ERROR);
        expect(failed.session.lastErrorType).assertEqual(SteamAuthErrorKind.VALIDATION);
        expect(failed.pendingAuth !== null).assertTrue();
      }
      expect(authService.cancelPendingCount).assertEqual(0);

      authService.failChallengeValidation = false;
      const completed = await host.service.completeAuthChallenge('validation-retry-auth', 'ABCD5');
      expect(completed.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      expect(authService.completeChallengeCount).assertEqual(1);
      const recovered = host.service.getSelectedAccount();
      expect(recovered !== null).assertTrue();
      if (recovered !== null) {
        expect(recovered.pendingAuth).assertNull();
      }
    });

    it('closesAuthenticationServiceWhenPendingCancellationFails', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'cancel-close-fallback.json',
        '{"SteamLogin":"cancel-close-fallback","SteamPassword":"password-cancel-close-fallback"}'
      );
      await host.service.signIn('cancel-close-fallback');
      const authService = host.authFactory.get('cancel-close-fallback');
      expect(authService !== null).assertTrue();
      if (authService === null) {
        return;
      }

      authService.failCancelPending = true;
      try {
        await host.service.cancelAuthentication('cancel-close-fallback');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }
      expect(authService.cancelPendingCount).assertEqual(1);
      expect(authService.closeCount).assertEqual(1);
      expect(host.service.getSelectedAccount() !== null).assertTrue();
    });

    it('removesFailedAuthenticationServiceFromCacheAfterCloseFailure', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.importAsfBotJson(
        'close-cache.json',
        '{"SteamLogin":"close-cache","SteamPassword":"password-close-cache"}'
      );
      await host.service.signIn('close-cache');
      const authService = host.authFactory.get('close-cache');
      expect(authService !== null).assertTrue();
      if (authService === null) {
        return;
      }

      const createCountBeforeFailure: number = host.authFactory.createCount;
      authService.failClose = true;
      try {
        await host.service.cancelAuthentication('close-cache');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }
      authService.failClose = false;
      await host.service.signIn('close-cache');
      expect(host.authFactory.createCount).assertEqual(createCountBeforeFailure + 1);
    });

    it('serializesPasswordLoginAgainstRemovalUsingDurableAccountId', 0, async () => {
      const settingsStore = new FakeSettingsStore();
      const credentialStore = new FakeCredentialStore();
      settingsStore.setString(
        'steam_ark_state_v1',
        '{"version":1,"selectedAccountId":"internal-account-id","accounts":[' +
          '{"accountId":"internal-account-id","displayName":"steam-user"}]}'
      );
      await credentialStore.set('internal-account-id', NGFCredentialKind.ACCOUNT_NAME, 'steam-user');
      const host = new FakeStateHost(settingsStore, credentialStore);
      await host.service.initialize();
      const gate = new TestAsyncGate();
      host.authFactory.signInGate = gate;

      const signInPromise: Promise<SteamAuthResult> = host.service.signInWithPassword(
        'steam-user',
        'password-steam-user'
      );
      await gate.entered;
      let removeFinished: boolean = false;
      const removePromise: Promise<boolean> = host.service.removeAccount('internal-account-id').then(
        (removed: boolean): boolean => {
          removeFinished = true;
          return removed;
        }
      );
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      expect(removeFinished).assertFalse();

      gate.release();
      const signInResult = await signInPromise;
      expect(signInResult.session.accountId).assertEqual('internal-account-id');
      expect(await removePromise).assertTrue();
      expect(removeFinished).assertTrue();
      expect(host.service.getSelectedAccount()).assertNull();
    });

    it('restoresPendingAuthChallengeAfterStateServiceRestart', 0, async () => {
      const settingsStore = new FakeSettingsStore();
      const credentialStore = new FakeCredentialStore();
      const firstHost = new FakeStateHost(settingsStore, credentialStore);
      await firstHost.service.initialize();
      await firstHost.service.importAsfBotJson(
        'restart-auth.json',
        '{"SteamLogin":"restart-auth","SteamPassword":"password-restart-auth"}'
      );

      const challenge = await firstHost.service.signIn('restart-auth');
      expect(challenge.session.state).assertEqual(SteamSessionState.NEEDS_TWO_FACTOR);
      const firstSnapshot = firstHost.service.getSelectedAccount();
      expect(firstSnapshot !== null).assertTrue();
      if (firstSnapshot === null) {
        return;
      }
      expect(firstSnapshot.pendingAuth !== null).assertTrue();
      const serializedState = settingsStore.getString('steam_ark_state_v1', '');
      expect(serializedState.indexOf('password-restart-auth')).assertEqual(-1);
      expect(serializedState.indexOf('pendingAuth') >= 0).assertTrue();

      const secondHost = new FakeStateHost(settingsStore, credentialStore);
      await secondHost.service.initialize();
      for (let tick: number = 0; tick < 16; tick++) {
        await Promise.resolve();
      }
      expect(secondHost.authFactory.createCount).assertEqual(0);
      const restoredSnapshot = secondHost.service.getSelectedAccount();
      expect(restoredSnapshot !== null).assertTrue();
      if (restoredSnapshot !== null) {
        expect(restoredSnapshot.session.state).assertEqual(SteamSessionState.NEEDS_TWO_FACTOR);
        expect(restoredSnapshot.pendingAuth !== null).assertTrue();
      }

      const completed = await secondHost.service.completeAuthChallenge('restart-auth', 'ABCD2');
      expect(completed.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      const restoredAuth = secondHost.authFactory.get('restart-auth');
      expect(restoredAuth !== null).assertTrue();
      if (restoredAuth !== null) {
        expect(restoredAuth.restorePendingCount).assertEqual(1);
        expect(restoredAuth.lastChallengeRequest !== null).assertTrue();
        if (restoredAuth.lastChallengeRequest !== null) {
          expect(restoredAuth.lastChallengeRequest.challengeKind)
            .assertEqual(SteamAuthChallengeKind.TWO_FACTOR);
        }
      }
      const finalSnapshot = secondHost.service.getSelectedAccount();
      expect(finalSnapshot !== null).assertTrue();
      if (finalSnapshot !== null) {
        expect(finalSnapshot.pendingAuth).assertNull();
      }
    });

    it('normalizesLoggedOnStateWithStalePendingAuthDuringRestart', 0, async () => {
      const settingsStore = new FakeSettingsStore();
      const credentialStore = new FakeCredentialStore();
      const accountId: string = 'logged-on-stale-pending';
      const steamId64: string = '76561197960287953';
      const createdAtEpochSeconds: number = Math.floor(Date.now() / 1000);
      const expiresAtEpochSeconds: number = createdAtEpochSeconds + SteamAuthPendingSnapshot.MAX_LIFETIME_SECONDS;
      settingsStore.setString(
        'steam_ark_state_v1',
        '{"version":1,"selectedAccountId":"' + accountId + '","accounts":[{"accountId":"' + accountId +
          '","displayName":"' + accountId + '","steamId64":"' + steamId64 +
          '","sessionState":"logged_on","sessionSteamId64":"' + steamId64 +
          '","autoRestoreEnabled":false,"pendingAuth":{"accountId":"' + accountId +
          '","clientId":"stale-client","requestId":"stale-request","steamId64":"' + steamId64 +
          '","challenge":"two_factor","flow":"password","intervalSeconds":5,"createdAtEpochSeconds":' +
          createdAtEpochSeconds.toString() + ',"expiresAtEpochSeconds":' + expiresAtEpochSeconds.toString() + '}}]}'
      );

      const host = new FakeStateHost(settingsStore, credentialStore);
      await host.service.initialize();

      const restored = host.service.getSelectedAccount();
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.session.state).assertEqual(SteamSessionState.LOGGED_ON);
        expect(restored.pendingAuth).assertNull();
      }
      const persisted = settingsStore.getString('steam_ark_state_v1', '');
      expect(settingsStore.writeCount).assertEqual(1);
      expect(persisted.indexOf('stale-client')).assertEqual(-1);
      expect(persisted.indexOf('"pendingAuth":null') >= 0).assertTrue();
    });

    it('retainsLoggedOnSessionWhenStartupRefreshReturnsNonLoggedOnState', 0, async () => {
      const settingsStore = new FakeSettingsStore();
      const credentialStore = new FakeCredentialStore();
      const firstHost = new FakeStateHost(settingsStore, credentialStore);
      await firstHost.service.initialize();
      await prepareLoggedOnAccount(firstHost, 'restore-guard-account', '76561197960287951');
      await credentialStore.set(
        'restore-guard-account',
        NGFCredentialKind.REFRESH_TOKEN,
        'refresh-restore-guard-account'
      );

      const secondHost = new FakeStateHost(settingsStore, credentialStore);
      secondHost.authFactory.startupRefreshState = SteamSessionState.NEEDS_EMAIL_CODE;
      const refreshGate = new TestAsyncGate();
      secondHost.authFactory.refreshGate = refreshGate;
      await secondHost.service.initialize();
      await refreshGate.entered;
      refreshGate.release();
      await secondHost.service.signIn('restore-guard-account');

      const restored = secondHost.service.getSelectedAccount();
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.session.state).assertEqual(SteamSessionState.LOGGED_ON);
        expect(restored.pendingAuth).assertNull();
      }
      const persisted = settingsStore.getString('steam_ark_state_v1', '');
      expect(persisted.indexOf('"sessionState":"logged_on"') >= 0).assertTrue();
      expect(persisted.indexOf('"sessionState":"needs_email_code"')).assertEqual(-1);
    });

    it('refreshesPersistedProfileAfterStartupSessionRestore', 0, async () => {
      const settingsStore = new FakeSettingsStore();
      const credentialStore = new FakeCredentialStore();
      const firstHost = new FakeStateHost(settingsStore, credentialStore);
      await firstHost.service.initialize();
      await prepareLoggedOnAccount(firstHost, 'restored-profile-account', '76561197960287952');

      const secondHost = new FakeStateHost(settingsStore, credentialStore);
      const resolver = new FakeProfileResolver(
        'Restored Steam Persona',
        'https://avatars.steamstatic.com/restored-persona.jpg'
      );
      const profileGate = new TestAsyncGate();
      resolver.resolveGate = profileGate;
      secondHost.service.setProfileResolver(resolver);
      await secondHost.service.initialize();
      await profileGate.entered;
      profileGate.release();
      await secondHost.service.signIn('restored-profile-account');

      expect(resolver.resolveCount).assertEqual(1);
      const restored = secondHost.service.getSelectedAccount();
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.profile.displayName).assertEqual('Restored Steam Persona');
        expect(restored.profile.avatarUrl).assertEqual('https://avatars.steamstatic.com/restored-persona.jpg');
      }
      const persisted = settingsStore.getString('steam_ark_state_v1', '');
      expect(persisted.indexOf('Restored Steam Persona') >= 0).assertTrue();
      expect(persisted.indexOf('https://avatars.steamstatic.com/restored-persona.jpg') >= 0).assertTrue();
    });

    it('invalidatesMalformedOrExpiredPersistedAuthChallenges', 0, async () => {
      const payloads: Array<string> = [
        '{"version":1,"selectedAccountId":"expired-auth","accounts":[{"accountId":"expired-auth","displayName":"expired-auth","sessionState":"needs_two_factor","pendingAuth":{"accountId":"expired-auth","clientId":"client-expired","requestId":"request-expired","steamId64":"76561197960287930","challenge":"two_factor","intervalSeconds":5,"createdAtEpochSeconds":1699999000,"expiresAtEpochSeconds":1699999900}}]}',
        '{"version":1,"selectedAccountId":"malformed-auth","accounts":[{"accountId":"malformed-auth","displayName":"malformed-auth","sessionState":"needs_two_factor","pendingAuth":{"accountId":"malformed-auth","clientId":"","requestId":"request-malformed","steamId64":"76561197960287930","challenge":"two_factor","intervalSeconds":5,"createdAtEpochSeconds":1700000000,"expiresAtEpochSeconds":1700000900}}]}'
      ];
      for (let index = 0; index < payloads.length; index++) {
        const settingsStore = new FakeSettingsStore();
        settingsStore.setString('steam_ark_state_v1', payloads[index]);
        const host = new FakeStateHost(settingsStore, new FakeCredentialStore());
        await host.service.initialize();
        const snapshot = host.service.getSelectedAccount();
        expect(snapshot !== null).assertTrue();
        if (snapshot !== null) {
          expect(snapshot.session.state).assertEqual(SteamSessionState.EXPIRED);
          expect(snapshot.pendingAuth).assertNull();
        }
      }
    });

    it('exposesQrChallengeOnlyAfterSuccessfulSessionStart', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();

      const result = await host.service.beginQrSignIn();
      expect(result.session.state).assertEqual(SteamSessionState.NEEDS_QR_SCAN);
      expect(result.challenge).assertEqual(SteamAuthChallengeKind.QR_SCAN);
      expect(result.flow).assertEqual(SteamAuthFlowKind.QR);
      expect(result.qrChallengeUrl.length > 0).assertTrue();

      const snapshot = host.service.getSnapshot();
      expect(snapshot.accounts.length).assertEqual(0);
      expect(snapshot.selectedAccountId).assertEqual('');
      expect(snapshot.pendingQrAuthentication !== null).assertTrue();
      if (snapshot.pendingQrAuthentication !== null) {
        expect(snapshot.pendingQrAuthentication.session.accountId).assertEqual('qr-1');
        expect(snapshot.pendingQrAuthentication.session.state).assertEqual(SteamSessionState.NEEDS_QR_SCAN);
        expect(snapshot.pendingQrAuthentication.pendingAuth !== null).assertTrue();
        if (snapshot.pendingQrAuthentication.pendingAuth !== null) {
          expect(snapshot.pendingQrAuthentication.pendingAuth.flow).assertEqual(SteamAuthFlowKind.QR);
          expect(snapshot.pendingQrAuthentication.pendingAuth.challenge).assertEqual(SteamAuthChallengeKind.QR_SCAN);
          expect(snapshot.pendingQrAuthentication.pendingAuth.challengeUrl.length > 0).assertTrue();
        }
      }
      expect(host.service.getSelectedAccount()).assertNull();
    });

    it('cleansPreviousTemporaryQrAccountBeforeStartingNextQr', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();

      await host.service.beginQrSignIn();
      const firstService = host.authFactory.get('qr-1');
      expect(firstService !== null).assertTrue();

      const secondResult = await host.service.beginQrSignIn();
      expect(secondResult.session.accountId).assertEqual('qr-2');
      const snapshot = host.service.getSnapshot();
      expect(snapshot.accounts.length).assertEqual(0);
      expect(snapshot.selectedAccountId).assertEqual('');
      expect(snapshot.pendingQrAuthentication !== null).assertTrue();
      if (snapshot.pendingQrAuthentication !== null) {
        expect(snapshot.pendingQrAuthentication.session.accountId).assertEqual('qr-2');
      }
      expect(host.service.getSelectedAccount()).assertNull();
      expect(host.settingsStore.getString('steam_ark_state_v1', '').indexOf('qr-1')).assertEqual(-1);
      if (firstService !== null) {
        expect(firstService.cancelPendingCount).assertEqual(1);
        expect(firstService.closeCount).assertEqual(1);
      }
    });

    it('cancelsAndRemovesTemporaryQrAccount', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();

      await host.service.beginQrSignIn();
      const qrService = host.authFactory.get('qr-1');
      const removed = await host.service.cancelAuthentication('qr-1');

      expect(removed).assertTrue();
      expect(host.service.getSnapshot().accounts.length).assertEqual(0);
      expect(host.service.getSelectedAccount()).assertNull();
      if (qrService !== null) {
        expect(qrService.cancelPendingCount).assertEqual(1);
        expect(qrService.closeCount).assertEqual(1);
      }
      expect(await host.credentialStore.get('qr-1', NGFCredentialKind.ACCOUNT_NAME)).assertNull();
    });

    it('skipsAStaleQrTimerWithoutPollingOrReplacingTheActiveChallenge', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.beginQrSignIn();
      const active = host.service.getSnapshot().pendingQrAuthentication;
      expect(active !== null).assertTrue();
      if (active === null || active.pendingAuth === null) {
        return;
      }
      const pending: SteamAuthPendingSnapshot = active.pendingAuth;
      const stale = new SteamAuthPendingSnapshot(
        pending.accountId,
        pending.clientId + '-stale',
        pending.requestId,
        pending.steamId64,
        pending.challenge,
        pending.intervalSeconds,
        pending.createdAtEpochSeconds,
        pending.expiresAtEpochSeconds,
        pending.flow,
        pending.challengeUrl
      );
      const authService = host.authFactory.get(pending.accountId);
      expect(authService !== null).assertTrue();

      const skipped: SteamAuthResult | null = await host.service.pollAuthenticationIfCurrent(stale);

      expect(skipped).assertNull();
      if (authService !== null) {
        expect(authService.pollCount).assertEqual(0);
      }
      const after = host.service.getSnapshot().pendingQrAuthentication;
      expect(after !== null).assertTrue();
      if (after !== null && after.pendingAuth !== null) {
        expect(after.pendingAuth.clientId).assertEqual(pending.clientId);
        expect(after.pendingAuth.requestId).assertEqual(pending.requestId);
      }
    });

    it('prunesTerminalQrAccountWhenStartingAnotherQr', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.beginQrSignIn();
      const firstService = host.authFactory.get('qr-1');
      expect(firstService !== null).assertTrue();
      if (firstService === null) {
        return;
      }

      firstService.failQrPollTerminal = true;
      try {
        await host.service.pollAuthentication('qr-1');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }
      const terminal = host.service.getSnapshot().pendingQrAuthentication;
      expect(terminal !== null).assertTrue();
      if (terminal !== null) {
        expect(terminal.pendingAuth).assertNull();
        expect(terminal.session.state).assertEqual(SteamSessionState.ERROR);
        expect(terminal.session.lastErrorType).assertEqual(SteamAuthErrorKind.SERVER);
        expect(terminal.session.lastErrorStage).assertEqual('qr_poll');
        expect(terminal.session.lastErrorCode).assertEqual(65);
        expect(terminal.session.lastErrorMessage).assertEqual('fake QR challenge rejected by server');
      }

      await host.service.beginQrSignIn();
      const snapshot = host.service.getSnapshot();
      expect(snapshot.accounts.length).assertEqual(0);
      expect(snapshot.selectedAccountId).assertEqual('');
      expect(snapshot.pendingQrAuthentication !== null).assertTrue();
      if (snapshot.pendingQrAuthentication !== null) {
        expect(snapshot.pendingQrAuthentication.session.accountId).assertEqual('qr-2');
      }
      expect(firstService.cancelPendingCount).assertEqual(1);
      expect(firstService.closeCount).assertEqual(1);
    });

    it('retainsTerminalQrBeginFailureForCurrentProcessDiagnostics', 0, async () => {
      const host = new FakeStateHost();
      host.authFactory.failQrSignIn = true;
      await host.service.initialize();

      try {
        await host.service.beginQrSignIn();
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }

      const snapshot = host.service.getSnapshot();
      expect(snapshot.accounts.length).assertEqual(0);
      expect(snapshot.selectedAccountId).assertEqual('');
      expect(snapshot.pendingQrAuthentication !== null).assertTrue();
      if (snapshot.pendingQrAuthentication !== null) {
        expect(snapshot.pendingQrAuthentication.pendingAuth).assertNull();
        expect(snapshot.pendingQrAuthentication.session.state).assertEqual(SteamSessionState.ERROR);
        expect(snapshot.pendingQrAuthentication.session.lastErrorType).assertEqual(
          SteamAuthErrorKind.AUTHENTICATION
        );
        expect(snapshot.pendingQrAuthentication.session.lastErrorStage).assertEqual('qr_begin');
        expect(snapshot.pendingQrAuthentication.session.lastErrorMessage).assertEqual(
          'fake QR authentication request failed'
        );
      }
      expect(host.service.getSelectedAccount()).assertNull();
      const persisted = host.settingsStore.getString('steam_ark_state_v1', '');
      expect(persisted.indexOf('qr-1')).assertEqual(-1);
      expect(persisted.indexOf('fake QR authentication request failed')).assertEqual(-1);

      const authService = host.authFactory.get('qr-1');
      expect(authService !== null).assertTrue();
      if (authService !== null) {
        expect(authService.beginQrCount).assertEqual(1);
        expect(authService.cancelPendingCount).assertEqual(1);
      }
    });

    it('stopsQrChallengeAfterTerminalPollFailureButKeepsTransientRetry', 0, async () => {
      const host = new FakeStateHost();
      await host.service.initialize();
      await host.service.beginQrSignIn();
      const authService = host.authFactory.get('qr-1');
      expect(authService !== null).assertTrue();
      if (authService === null) {
        return;
      }

      authService.failQrPollTransport = true;
      try {
        await host.service.pollAuthentication('qr-1');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }
      let pendingQr = host.service.getSnapshot().pendingQrAuthentication;
      expect(pendingQr !== null).assertTrue();
      if (pendingQr !== null) {
        expect(pendingQr.session.state).assertEqual(SteamSessionState.ERROR);
        expect(pendingQr.session.lastErrorType).assertEqual(SteamAuthErrorKind.TRANSPORT);
        expect(pendingQr.pendingAuth !== null).assertTrue();
      }
      expect(host.settingsStore.getString('steam_ark_state_v1', '').indexOf('qr-1')).assertEqual(-1);

      authService.failQrPollTransport = false;
      authService.failQrPollTerminal = true;
      try {
        await host.service.pollAuthentication('qr-1');
        expect(false).assertTrue();
      } catch (error) {
        expect(error instanceof Error).assertTrue();
      }
      pendingQr = host.service.getSnapshot().pendingQrAuthentication;
      expect(pendingQr !== null).assertTrue();
      if (pendingQr !== null) {
        expect(pendingQr.pendingAuth).assertNull();
        expect(pendingQr.session.state).assertEqual(SteamSessionState.ERROR);
        expect(pendingQr.session.lastErrorType).assertEqual(SteamAuthErrorKind.SERVER);
        expect(pendingQr.session.lastErrorStage).assertEqual('qr_poll');
        expect(pendingQr.session.lastErrorCode).assertEqual(65);
        expect(pendingQr.session.lastErrorMessage).assertEqual('fake QR challenge rejected by server');
      }
    });

    it('removesPersistedTemporaryQrStateDuringStartup', 0, async () => {
      const settingsStore = new FakeSettingsStore();
      settingsStore.setString(
        'steam_ark_state_v1',
        '{"version":1,"selectedAccountId":"qr-7","accounts":[{' +
          '"accountId":"qr-7","displayName":"qr-7","sessionState":"error",' +
          '"sessionLastErrorMessage":"old QR failure"}]}'
      );
      const host = new FakeStateHost(settingsStore, new FakeCredentialStore());

      await host.service.initialize();

      const snapshot = host.service.getSnapshot();
      expect(snapshot.accounts.length).assertEqual(0);
      expect(snapshot.pendingQrAuthentication).assertNull();
      expect(snapshot.selectedAccountId).assertEqual('');
      expect(settingsStore.getString('steam_ark_state_v1', '').indexOf('qr-7')).assertEqual(-1);
      expect(settingsStore.getString('steam_ark_state_v1', '').indexOf('old QR failure')).assertEqual(-1);
    });

    it('resolvesAndPersistsProfileAfterSuccessfulQrLogin', 0, async () => {
      const host = new FakeStateHost();
      const resolver = new FakeProfileResolver('Steam Persona', 'https://avatars.steamstatic.com/persona.jpg');
      host.service.setProfileResolver(resolver);
      await host.service.initialize();

      await host.service.beginQrSignIn();
      const result = await host.service.pollAuthentication('qr-1');

      expect(result.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      expect(resolver.resolveCount).assertEqual(1);
      expect(resolver.lastSteamId64).assertEqual('76561197960287932');
      const snapshot = host.service.getSnapshot();
      expect(snapshot.accounts.length).assertEqual(1);
      expect(snapshot.selectedAccountId).assertEqual('qr-1');
      expect(snapshot.pendingQrAuthentication).assertNull();
      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.profile.displayName).assertEqual('Steam Persona');
        expect(account.profile.avatarUrl).assertEqual('https://avatars.steamstatic.com/persona.jpg');
      }
      const persisted = host.settingsStore.getString('steam_ark_state_v1', '');
      expect(persisted.indexOf('Steam Persona') >= 0).assertTrue();
      expect(persisted.indexOf('https://avatars.steamstatic.com/persona.jpg') >= 0).assertTrue();
    });

    it('usesStableAccountForFirstProfileRefreshAfterQrPromotion', 0, async () => {
      const host = new FakeStateHost();
      const resolver = new FakeProfileResolver(
        'Promoted Steam Persona',
        'https://avatars.steamstatic.com/promoted-persona.jpg'
      );
      const profileGate = new TestAsyncGate();
      resolver.resolveGate = profileGate;
      host.authFactory.qrStableAccountName = 'promoted-qr-account';
      host.service.setProfileResolver(resolver);
      await host.service.initialize();

      await host.service.beginQrSignIn();
      const pollTask: Promise<SteamAuthResult> = host.service.pollAuthentication('qr-1');
      await profileGate.entered;

      expect(resolver.lastAccountId).assertEqual('promoted-qr-account');
      const promotedBeforeProfile = host.service.getSelectedAccount();
      expect(promotedBeforeProfile !== null).assertTrue();
      if (promotedBeforeProfile !== null) {
        expect(promotedBeforeProfile.profile.accountId).assertEqual('promoted-qr-account');
        expect(promotedBeforeProfile.profile.avatarUrl).assertEqual('');
      }

      profileGate.release();
      const result = await pollTask;
      expect(result.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      await host.service.refreshProfile('promoted-qr-account');

      const promoted = host.service.getSelectedAccount();
      expect(promoted !== null).assertTrue();
      if (promoted !== null) {
        expect(promoted.profile.accountId).assertEqual('promoted-qr-account');
        expect(promoted.profile.displayName).assertEqual('Promoted Steam Persona');
        expect(promoted.profile.avatarUrl).assertEqual('https://avatars.steamstatic.com/promoted-persona.jpg');
      }
      const persisted = host.settingsStore.getString('steam_ark_state_v1', '');
      expect(persisted.indexOf('promoted-qr-account') >= 0).assertTrue();
      expect(persisted.indexOf('https://avatars.steamstatic.com/promoted-persona.jpg') >= 0).assertTrue();
      expect(persisted.indexOf('qr-1')).assertEqual(-1);
    });

    it('persistsMiniProfileVisualsFromFirstQrProfileLookup', 0, async () => {
      const host = new FakeStateHost();
      const resolver = new FakeProfileResolver(
        'Visual QR Persona',
        'https://avatars.steamstatic.com/visual-persona.jpg',
        'https://avatars.steamstatic.com/visual-frame.png',
        'https://cdn.steamstatic.com/mini-profile.jpg',
        'https://cdn.steamstatic.com/mini-profile.mp4'
      );
      host.authFactory.qrStableAccountName = 'visual-qr-account';
      host.service.setProfileResolver(resolver);
      await host.service.initialize();

      const result = await host.service.beginQrSignIn();
      await host.service.pollAuthentication(result.session.accountId);

      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.profile.accountId).assertEqual('visual-qr-account');
        expect(account.profile.avatarFrameUrl).assertEqual('https://avatars.steamstatic.com/visual-frame.png');
        expect(account.profile.miniProfileBackgroundImageUrl).assertEqual('https://cdn.steamstatic.com/mini-profile.jpg');
        expect(account.profile.miniProfileBackgroundMovieUrl).assertEqual('https://cdn.steamstatic.com/mini-profile.mp4');
      }
      const persisted = host.settingsStore.getString('steam_ark_state_v1', '');
      expect(persisted.indexOf('visual-frame.png') >= 0).assertTrue();
      expect(persisted.indexOf('mini-profile.jpg') >= 0).assertTrue();
      expect(persisted.indexOf('mini-profile.mp4') >= 0).assertTrue();
    });

    it('keepsQrAuthenticationSuccessfulWhenProfileLookupFails', 0, async () => {
      const host = new FakeStateHost();
      const resolver = new FakeProfileResolver();
      resolver.fail = true;
      host.service.setProfileResolver(resolver);
      await host.service.initialize();

      await host.service.beginQrSignIn();
      const result = await host.service.pollAuthentication('qr-1');

      expect(result.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      expect(resolver.resolveCount).assertEqual(1);
      const snapshot = host.service.getSnapshot();
      expect(snapshot.accounts.length).assertEqual(1);
      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.session.state).assertEqual(SteamSessionState.LOGGED_ON);
        expect(account.profile.displayName).assertEqual('76561197960287932');
        expect(account.profile.avatarUrl).assertEqual('');
      }
    });

    it('keepsQrAuthenticationSuccessfulWhenProfileLookupReturnsNoIdentity', 0, async () => {
      const host = new FakeStateHost();
      const resolver = new FakeProfileResolver('', '');
      host.service.setProfileResolver(resolver);
      await host.service.initialize();

      await host.service.beginQrSignIn();
      const result = await host.service.pollAuthentication('qr-1');

      expect(result.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      expect(resolver.resolveCount).assertEqual(1);
      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.session.state).assertEqual(SteamSessionState.LOGGED_ON);
        expect(account.profile.displayName).assertEqual('76561197960287932');
        expect(account.profile.avatarUrl).assertEqual('');
      }
    });

    it('keepsQrAuthenticationSuccessfulWhenProfilePersistenceFails', 0, async () => {
      const host = new FakeStateHost();
      const resolver = new FakeProfileResolver('Persisted Later', 'https://avatars.steamstatic.com/persist-later.jpg');
      resolver.failNextProfilePersistence = host.settingsStore;
      host.service.setProfileResolver(resolver);
      await host.service.initialize();

      await host.service.beginQrSignIn();
      const result = await host.service.pollAuthentication('qr-1');

      expect(result.session.state).assertEqual(SteamSessionState.LOGGED_ON);
      expect(resolver.resolveCount).assertEqual(1);
      const account = host.service.getSelectedAccount();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.session.state).assertEqual(SteamSessionState.LOGGED_ON);
        expect(account.profile.displayName).assertEqual('Persisted Later');
        expect(account.profile.avatarUrl).assertEqual('https://avatars.steamstatic.com/persist-later.jpg');
      }
    });
  });
}
