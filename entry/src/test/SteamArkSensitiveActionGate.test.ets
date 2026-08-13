import { Permissions } from '@kit.AbilityKit';
import { userAuth } from '@kit.UserAuthenticationKit';
import { describe, expect, it } from '@ohos/hypium';
import {
  ISettingsStore,
  IPermissionManager,
  IUserAuthentication
} from 'ngf_framework';
import {
  ISteamArkChallengeGenerator,
  ISteamArkSensitiveActionAuditEventPublisher,
  ISteamArkSensitiveActionAuditStore,
  SteamArkAssetConfirmationItem,
  SteamArkAssetConfirmationSnapshot,
  SteamArkSensitiveAction,
  SteamArkSensitiveActionAuditEntry,
  SteamArkSensitiveActionAuditStore,
  SteamArkSensitiveActionContext,
  SteamArkSensitiveActionGate,
  SteamArkSensitiveActionGateOptions,
  SteamArkSensitiveActionOutcome,
  SteamArkSensitiveActionResult
} from '../main/ets/steamServices';

class FakePermissionManager implements IPermissionManager {
  granted: boolean = false;
  requestResult: boolean = false;
  checkCount: number = 0;
  requestCount: number = 0;

  checkPermission(_permission: Permissions): boolean {
    this.checkCount++;
    return this.granted;
  }

  async requestPermissions(_permissions: Permissions[]): Promise<boolean> {
    this.requestCount++;
    this.granted = this.requestResult;
    return this.requestResult;
  }
}

class FakeUserAuthentication implements IUserAuthentication {
  supportPin: boolean = true;
  supportFingerprint: boolean = false;
  supportFace: boolean = false;
  authenticated: boolean = true;
  blockAuthenticate: boolean = false;
  authenticateCount: number = 0;
  private pendingResolver: ((value: boolean) => void) | null = null;

  async authenticate(_challenge: Uint8Array, _title: string): Promise<boolean> {
    this.authenticateCount++;
    if (!this.blockAuthenticate) {
      return this.authenticated;
    }
    return await new Promise<boolean>((resolve: (value: boolean) => void): void => {
      this.pendingResolver = resolve;
    });
  }

  checkSupport(authType: userAuth.UserAuthType): boolean {
    if (authType === userAuth.UserAuthType.PIN) {
      return this.supportPin;
    }
    if (authType === userAuth.UserAuthType.FINGERPRINT) {
      return this.supportFingerprint;
    }
    if (authType === userAuth.UserAuthType.FACE) {
      return this.supportFace;
    }
    return false;
  }

  release(result: boolean): void {
    const resolver = this.pendingResolver;
    this.pendingResolver = null;
    if (resolver !== null) {
      resolver(result);
    }
  }
}

class FakeChallengeGenerator implements ISteamArkChallengeGenerator {
  requestedLength: number = 0;
  generatedLength: number = 32;

  generate(length: number): Uint8Array {
    this.requestedLength = length;
    return new Uint8Array(this.generatedLength);
  }
}

class FakeAuditStore implements ISteamArkSensitiveActionAuditStore {
  readonly entries: Array<SteamArkSensitiveActionAuditEntry> = [];
  appendResult: boolean = true;
  appendCount: number = 0;

  async append(entry: SteamArkSensitiveActionAuditEntry): Promise<boolean> {
    this.appendCount++;
    if (!this.appendResult) {
      return false;
    }
    this.entries.push(entry);
    return true;
  }

  async listRecent(_limit: number): Promise<Array<SteamArkSensitiveActionAuditEntry>> {
    return this.entries.slice();
  }

  async clear(): Promise<boolean> {
    this.entries.splice(0, this.entries.length);
    return true;
  }
}

class FakeAuditEventPublisher implements ISteamArkSensitiveActionAuditEventPublisher {
  readonly entries: Array<SteamArkSensitiveActionAuditEntry> = [];
  throwOnPublish: boolean = false;

  publish(entry: SteamArkSensitiveActionAuditEntry): void {
    if (this.throwOnPublish) {
      throw new Error('publisher failure');
    }
    this.entries.push(entry);
  }
}

class FakeSettingsStore implements ISettingsStore {
  private readonly stringValues: Map<string, string> = new Map<string, string>();
  private readonly numberValues: Map<string, number> = new Map<string, number>();
  private readonly booleanValues: Map<string, boolean> = new Map<string, boolean>();

  getString(key: string, defaultValue: string): string {
    const value = this.stringValues.get(key);
    return value === undefined ? defaultValue : value;
  }

  getNumber(key: string, defaultValue: number): number {
    const value = this.numberValues.get(key);
    return value === undefined ? defaultValue : value;
  }

  getBoolean(key: string, defaultValue: boolean): boolean {
    const value = this.booleanValues.get(key);
    return value === undefined ? defaultValue : value;
  }

  setString(key: string, value: string): void {
    this.stringValues.set(key, value);
  }

  async setStringAsync(key: string, value: string): Promise<boolean> {
    this.stringValues.set(key, value);
    return true;
  }

  setNumber(key: string, value: number): void {
    this.numberValues.set(key, value);
  }

  setBoolean(key: string, value: boolean): void {
    this.booleanValues.set(key, value);
  }

  async waitUntilReady(): Promise<boolean> {
    return true;
  }

  readStoredString(key: string): string {
    return this.getString(key, '');
  }
}

function createGate(
  permissionManager: FakePermissionManager,
  userAuthentication: FakeUserAuthentication,
  challengeGenerator: FakeChallengeGenerator,
  auditStore: ISteamArkSensitiveActionAuditStore = new FakeAuditStore(),
  auditEventPublisher: ISteamArkSensitiveActionAuditEventPublisher = new FakeAuditEventPublisher()
): SteamArkSensitiveActionGate {
  return new SteamArkSensitiveActionGate(new SteamArkSensitiveActionGateOptions(
    permissionManager,
    userAuthentication,
    challengeGenerator,
    auditStore,
    auditEventPublisher
  ));
}

function createAuditEntry(eventId: string, outcome: SteamArkSensitiveActionOutcome): SteamArkSensitiveActionAuditEntry {
  return new SteamArkSensitiveActionAuditEntry(
    eventId,
    SteamArkSensitiveAction.INVENTORY_WRITE,
    outcome,
    'account-audit',
    '76561197960287930',
    1700000000,
    'confirmation-persisted',
    2
  );
}

function createConfirmation(
  action: SteamArkSensitiveAction,
  accountId: string = 'account-confirmation'
): SteamArkAssetConfirmationSnapshot {
  const nowEpochSeconds: number = Math.floor(Date.now() / 1000);
  return new SteamArkAssetConfirmationSnapshot(
    'confirmation-' + accountId,
    action,
    new SteamArkSensitiveActionContext(accountId, '76561197960287930'),
    [new SteamArkAssetConfirmationItem('10000000000000001', '753', '6', 1, 'Trading Card', 'Trading Card')],
    nowEpochSeconds,
    nowEpochSeconds + 60
  );
}

export default function steamArkSensitiveActionGateTest(): void {
  describe('SteamArkSensitiveActionGate', () => {
    it('requestsPermissionAndGrantsFreshVerification', 0, async () => {
      const permissions = new FakePermissionManager();
      permissions.requestResult = true;
      const authentication = new FakeUserAuthentication();
      const challenge = new FakeChallengeGenerator();
      const auditStore = new FakeAuditStore();
      const publisher = new FakeAuditEventPublisher();
      const gate = createGate(permissions, authentication, challenge, auditStore, publisher);

      const result: SteamArkSensitiveActionResult = await gate.verify(
        SteamArkSensitiveAction.INVENTORY_WRITE,
        'Verify inventory operation',
        new SteamArkSensitiveActionContext('account-main', '76561197960287930'),
        createConfirmation(SteamArkSensitiveAction.INVENTORY_WRITE, 'account-main')
      );

      expect(result.granted).assertTrue();
      expect(result.outcome).assertEqual(SteamArkSensitiveActionOutcome.GRANTED);
      expect(result.verificationOutcome).assertEqual(SteamArkSensitiveActionOutcome.GRANTED);
      expect(result.auditPersisted).assertTrue();
      expect(result.auditEventId.length > 0).assertTrue();
      expect(permissions.requestCount).assertEqual(1);
      expect(authentication.authenticateCount).assertEqual(1);
      expect(challenge.requestedLength).assertEqual(32);
      expect(auditStore.entries.length).assertEqual(1);
      expect(auditStore.entries[0].accountId).assertEqual('account-main');
      expect(auditStore.entries[0].steamId64).assertEqual('76561197960287930');
      expect(auditStore.entries[0].confirmationId).assertEqual('confirmation-account-main');
      expect(auditStore.entries[0].assetCount).assertEqual(1);
      expect(result.confirmationId).assertEqual('confirmation-account-main');
      expect(result.assetCount).assertEqual(1);
      expect(publisher.entries.length).assertEqual(1);
    });

    it('rejectsPermissionDenialBeforeAuthenticationAndAuditsIt', 0, async () => {
      const permissions = new FakePermissionManager();
      permissions.requestResult = false;
      const authentication = new FakeUserAuthentication();
      const auditStore = new FakeAuditStore();
      const gate = createGate(
        permissions,
        authentication,
        new FakeChallengeGenerator(),
        auditStore
      );

      const result: SteamArkSensitiveActionResult = await gate.verify(
        SteamArkSensitiveAction.TRADE_ACCEPT,
        'Verify trade operation',
        new SteamArkSensitiveActionContext('account-confirmation', '76561197960287930'),
        createConfirmation(SteamArkSensitiveAction.TRADE_ACCEPT)
      );

      expect(result.granted).assertFalse();
      expect(result.outcome).assertEqual(SteamArkSensitiveActionOutcome.PERMISSION_DENIED);
      expect(authentication.authenticateCount).assertEqual(0);
      expect(auditStore.entries.length).assertEqual(1);
      expect(auditStore.entries[0].outcome).assertEqual(SteamArkSensitiveActionOutcome.PERMISSION_DENIED);
    });

    it('reportsAuthenticationFailureAndAuditsIt', 0, async () => {
      const permissions = new FakePermissionManager();
      permissions.granted = true;
      const authentication = new FakeUserAuthentication();
      authentication.authenticated = false;
      const auditStore = new FakeAuditStore();
      const gate = createGate(
        permissions,
        authentication,
        new FakeChallengeGenerator(),
        auditStore
      );

      const result: SteamArkSensitiveActionResult = await gate.verify(
        SteamArkSensitiveAction.REDEEM,
        'Verify redeem operation',
        new SteamArkSensitiveActionContext('account-confirmation', '76561197960287930'),
        createConfirmation(SteamArkSensitiveAction.REDEEM)
      );

      expect(result.granted).assertFalse();
      expect(result.outcome).assertEqual(SteamArkSensitiveActionOutcome.AUTHENTICATION_FAILED);
      expect(result.verificationOutcome).assertEqual(SteamArkSensitiveActionOutcome.AUTHENTICATION_FAILED);
      expect(auditStore.entries.length).assertEqual(1);
    });

    it('rejectsWhenDeviceHasNoSupportedAuthenticatorAndAuditsIt', 0, async () => {
      const permissions = new FakePermissionManager();
      const authentication = new FakeUserAuthentication();
      authentication.supportPin = false;
      authentication.supportFingerprint = false;
      authentication.supportFace = false;
      const auditStore = new FakeAuditStore();
      const gate = createGate(
        permissions,
        authentication,
        new FakeChallengeGenerator(),
        auditStore
      );

      const result: SteamArkSensitiveActionResult = await gate.verify(
        SteamArkSensitiveAction.PRIVACY_VERIFICATION,
        'Verify privacy operation'
      );

      expect(result.outcome).assertEqual(SteamArkSensitiveActionOutcome.UNSUPPORTED);
      expect(permissions.requestCount).assertEqual(0);
      expect(authentication.authenticateCount).assertEqual(0);
      expect(auditStore.entries.length).assertEqual(1);
    });

    it('auditsInvalidPromptTitle', 0, async () => {
      const auditStore = new FakeAuditStore();
      const gate = createGate(
        new FakePermissionManager(),
        new FakeUserAuthentication(),
        new FakeChallengeGenerator(),
        auditStore
      );

      const result: SteamArkSensitiveActionResult = await gate.verify(
        SteamArkSensitiveAction.INVENTORY_WRITE,
        '   '
      );

      expect(result.outcome).assertEqual(SteamArkSensitiveActionOutcome.INVALID_REQUEST);
      expect(result.auditPersisted).assertTrue();
      expect(auditStore.entries.length).assertEqual(1);
    });

    it('requiresAssetConfirmationBeforeSensitiveActionVerification', 0, async () => {
      const permissions = new FakePermissionManager();
      permissions.granted = true;
      const authentication = new FakeUserAuthentication();
      const auditStore = new FakeAuditStore();
      const gate = createGate(
        permissions,
        authentication,
        new FakeChallengeGenerator(),
        auditStore
      );

      const result: SteamArkSensitiveActionResult = await gate.verify(
        SteamArkSensitiveAction.INVENTORY_WRITE,
        'Verify inventory operation',
        new SteamArkSensitiveActionContext('account-confirmation', '76561197960287930')
      );

      expect(result.granted).assertFalse();
      expect(result.outcome).assertEqual(SteamArkSensitiveActionOutcome.INVALID_REQUEST);
      expect(authentication.authenticateCount).assertEqual(0);
      expect(auditStore.entries.length).assertEqual(1);
      expect(auditStore.entries[0].confirmationId).assertEqual('');
      expect(auditStore.entries[0].assetCount).assertEqual(0);
    });

    it('rejectsConcurrentVerificationAndAuditsBusyState', 0, async () => {
      const permissions = new FakePermissionManager();
      permissions.granted = true;
      const authentication = new FakeUserAuthentication();
      authentication.blockAuthenticate = true;
      const auditStore = new FakeAuditStore();
      const gate = createGate(
        permissions,
        authentication,
        new FakeChallengeGenerator(),
        auditStore
      );

      const firstPromise: Promise<SteamArkSensitiveActionResult> = gate.verify(
        SteamArkSensitiveAction.INVENTORY_WRITE,
        'Verify first operation',
        new SteamArkSensitiveActionContext('account-confirmation', '76561197960287930'),
        createConfirmation(SteamArkSensitiveAction.INVENTORY_WRITE)
      );
      const second: SteamArkSensitiveActionResult = await gate.verify(
        SteamArkSensitiveAction.INVENTORY_WRITE,
        'Verify second operation',
        new SteamArkSensitiveActionContext('account-confirmation', '76561197960287930'),
        createConfirmation(SteamArkSensitiveAction.INVENTORY_WRITE)
      );
      expect(second.outcome).assertEqual(SteamArkSensitiveActionOutcome.BUSY);
      expect(second.auditPersisted).assertTrue();
      expect(auditStore.entries.length).assertEqual(1);
      authentication.release(true);
      const first: SteamArkSensitiveActionResult = await firstPromise;
      expect(first.granted).assertTrue();
      expect(auditStore.entries.length).assertEqual(2);

      authentication.blockAuthenticate = false;
      const third: SteamArkSensitiveActionResult = await gate.verify(
        SteamArkSensitiveAction.INVENTORY_WRITE,
        'Verify third operation',
        new SteamArkSensitiveActionContext('account-confirmation', '76561197960287930'),
        createConfirmation(SteamArkSensitiveAction.INVENTORY_WRITE)
      );
      expect(third.outcome).assertEqual(SteamArkSensitiveActionOutcome.GRANTED);
      expect(authentication.authenticateCount).assertEqual(2);
    });

    it('closesGateWhenAuditPersistenceFails', 0, async () => {
      const permissions = new FakePermissionManager();
      permissions.granted = true;
      const auditStore = new FakeAuditStore();
      auditStore.appendResult = false;
      const gate = createGate(
        permissions,
        new FakeUserAuthentication(),
        new FakeChallengeGenerator(),
        auditStore
      );

      const result: SteamArkSensitiveActionResult = await gate.verify(
        SteamArkSensitiveAction.INVENTORY_WRITE,
        'Verify inventory operation',
        new SteamArkSensitiveActionContext('account-confirmation', '76561197960287930'),
        createConfirmation(SteamArkSensitiveAction.INVENTORY_WRITE)
      );

      expect(result.granted).assertFalse();
      expect(result.outcome).assertEqual(SteamArkSensitiveActionOutcome.AUDIT_FAILED);
      expect(result.verificationOutcome).assertEqual(SteamArkSensitiveActionOutcome.GRANTED);
      expect(result.auditPersisted).assertFalse();
      expect(result.auditEventId.length).assertEqual(0);
    });

    it('restoresAuditAfterSettingsStoreRestart', 0, async () => {
      const settings = new FakeSettingsStore();
      const firstStore = new SteamArkSensitiveActionAuditStore(settings);
      const entry = createAuditEntry('event-persisted', SteamArkSensitiveActionOutcome.PERMISSION_DENIED);

      expect(await firstStore.append(entry)).assertTrue();

      const restartedStore = new SteamArkSensitiveActionAuditStore(settings);
      const restored: Array<SteamArkSensitiveActionAuditEntry> = await restartedStore.listRecent(10);
      expect(restored.length).assertEqual(1);
      expect(restored[0].eventId).assertEqual('event-persisted');
      expect(restored[0].outcome).assertEqual(SteamArkSensitiveActionOutcome.PERMISSION_DENIED);
      expect(restored[0].confirmationId).assertEqual('confirmation-persisted');
      expect(restored[0].assetCount).assertEqual(2);
    });

    it('boundsAuditStoreToOneHundredEntries', 0, async () => {
      const settings = new FakeSettingsStore();
      const store = new SteamArkSensitiveActionAuditStore(settings);

      for (let index = 0; index < 101; index++) {
        const outcome: SteamArkSensitiveActionOutcome = index % 2 === 0
          ? SteamArkSensitiveActionOutcome.PERMISSION_DENIED
          : SteamArkSensitiveActionOutcome.AUTHENTICATION_FAILED;
        const entry = createAuditEntry('event-' + index.toString(), outcome);
        expect(await store.append(entry)).assertTrue();
      }

      const recent: Array<SteamArkSensitiveActionAuditEntry> = await store.listRecent(200);
      expect(recent.length).assertEqual(SteamArkSensitiveActionAuditStore.MAX_ENTRIES);
      expect(recent[0].eventId).assertEqual('event-100');
      expect(recent[99].eventId).assertEqual('event-1');
    });

    it('ignoresCorruptAuditSnapshotAndDoesNotExposeSecrets', 0, async () => {
      const settings = new FakeSettingsStore();
      settings.setString('steam_ark_sensitive_action_audit_v1', '{corrupt');
      const store = new SteamArkSensitiveActionAuditStore(settings);

      const restored: Array<SteamArkSensitiveActionAuditEntry> = await store.listRecent(10);
      expect(restored.length).assertEqual(0);

      const validSettings = new FakeSettingsStore();
      const validStore = new SteamArkSensitiveActionAuditStore(validSettings);
      const entry = createAuditEntry('event-safe', SteamArkSensitiveActionOutcome.GRANTED);
      expect(await validStore.append(entry)).assertTrue();
      const serialized: string = validSettings.readStoredString('steam_ark_sensitive_action_audit_v1');
      expect(serialized.includes('password')).assertFalse();
      expect(serialized.includes('token')).assertFalse();
      expect(serialized.includes('cookie')).assertFalse();
      expect(serialized.includes('assetList')).assertFalse();
      expect(serialized.includes('promptTitle')).assertFalse();
    });
  });
}

