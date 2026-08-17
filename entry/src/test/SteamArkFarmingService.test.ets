import { describe, expect, it } from '@ohos/hypium';
import {
  ISecureCredentialStore,
  ISettingsStore,
  NGFCredentialKind,
  NGFTaskExecutor
} from 'ngf_framework';
import {
  ISteamArkBackgroundTaskHost,
  ISteamArkAccountLifecycle,
  ISteamArkFarmingRuntime,
  ISteamArkFarmingRuntimeFactory,
  SteamArkFarmingService,
  SteamArkFarmingServiceOptions,
  SteamArkFarmingEvent,
  SteamArkFarmingEventType,
  SteamArkFarmingStateStore,
  SteamArkStateService,
  SteamArkStateServiceOptions,
  SteamFarmEventListener,
  SteamSessionEventListener
} from '../main/ets/steamServices';
import {
  IStateStore,
  SteamAccountProfile,
  SteamBadgeSyncReport,
  SteamBotConfig,
  SteamCredentialSet,
  SteamFarmEvent,
  SteamFarmEventType,
  SteamFarmPauseMode,
  SteamFarmStateRecord,
  SteamFarmState,
  SteamFarmSnapshot,
  SteamCommunityBadge,
  SteamGameDrop,
  SteamSessionSnapshot,
  SteamSessionState
} from 'steam_core';

class FakeSettingsStore implements ISettingsStore {
  private readonly values: Map<string, string> = new Map<string, string>();
  failNextAsyncWrite: boolean = false;

  getString(key: string, defaultValue: string): string {
    const value = this.values.get(key);
    return value === undefined ? defaultValue : value;
  }

  getNumber(_key: string, defaultValue: number): number {
    return defaultValue;
  }

  getBoolean(_key: string, defaultValue: boolean): boolean {
    return defaultValue;
  }

  setString(key: string, value: string): void {
    this.values.set(key, value);
  }

  async setStringAsync(key: string, value: string): Promise<boolean> {
    if (this.failNextAsyncWrite) {
      this.failNextAsyncWrite = false;
      return false;
    }
    this.values.set(key, value);
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

class FakeCredentialStore implements ISecureCredentialStore {
  private readonly values: Map<string, string> = new Map<string, string>();

  async set(accountId: string, kind: NGFCredentialKind, value: string): Promise<boolean> {
    this.values.set(this.key(accountId, kind), value);
    return true;
  }

  async get(accountId: string, kind: NGFCredentialKind): Promise<string | null> {
    const value = this.values.get(this.key(accountId, kind));
    return value === undefined ? null : value;
  }

  async remove(accountId: string, kind: NGFCredentialKind): Promise<boolean> {
    return this.values.delete(this.key(accountId, kind));
  }

  async removeAll(accountId: string): Promise<boolean> {
    const kinds: Array<NGFCredentialKind> = [
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
      NGFCredentialKind.CSRF_TOKEN
    ];
    for (let index = 0; index < kinds.length; index++) {
      this.values.delete(this.key(accountId, kinds[index]));
    }
    return true;
  }

  async setNamed(scope: string, name: string, value: string): Promise<boolean> {
    this.values.set('named|' + scope + '|' + name, value);
    return true;
  }

  async getNamed(scope: string, name: string): Promise<string | null> {
    const value = this.values.get('named|' + scope + '|' + name);
    return value === undefined ? null : value;
  }

  async removeNamed(scope: string, name: string): Promise<boolean> {
    return this.values.delete('named|' + scope + '|' + name);
  }

  private key(accountId: string, kind: NGFCredentialKind): string {
    return accountId + '|' + kind;
  }
}

class FakeBackgroundTaskHost implements ISteamArkBackgroundTaskHost {
  readonly taskNames: Array<string> = [];
  readonly executors: Array<NGFTaskExecutor> = [];
  submitError: Error | null = null;
  stoppedExecutorCount: number = 0;
  executorStartedCount: number = 0;
  lastExecutor: NGFTaskExecutor | null = null;
  submitGate: Promise<void> | null = null;
  private submitRelease: (() => void) | null = null;
  private submitStartedWaiters: Array<() => void> = [];
  submitStarted: boolean = false;
  skipNextExecutor: boolean = false;
  private nextExecutorGate: Promise<void> | null = null;
  private nextExecutorRelease: (() => void) | null = null;

  async submit(name: string, executor: NGFTaskExecutor): Promise<string> {
    this.submitStarted = true;
    const startedWaiters: Array<() => void> = this.submitStartedWaiters;
    this.submitStartedWaiters = [];
    for (let index = 0; index < startedWaiters.length; index++) {
      startedWaiters[index]();
    }
    if (this.submitGate !== null) {
      await this.submitGate;
    }
    if (this.submitError !== null) {
      throw this.submitError;
    }
    this.taskNames.push(name);
    this.executors.push(executor);
    this.lastExecutor = executor;
    const shouldSkipExecutor = this.skipNextExecutor;
    this.skipNextExecutor = false;
    if (!shouldSkipExecutor) {
      void this.run(this.executors.length - 1);
    }
    return 'fake_task_' + this.taskNames.length.toString();
  }

  blockNextSubmit(): void {
    this.submitGate = new Promise<void>((resolve: () => void): void => {
      this.submitRelease = resolve;
    });
  }

  async waitForSubmitStarted(): Promise<void> {
    if (this.submitStarted) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      this.submitStartedWaiters.push(resolve);
    });
  }

  releaseSubmit(): void {
    const release = this.submitRelease;
    this.submitRelease = null;
    this.submitGate = null;
    if (release !== null) {
      release();
    }
  }

  blockNextExecutor(): void {
    this.nextExecutorGate = new Promise<void>((resolve: () => void): void => {
      this.nextExecutorRelease = resolve;
    });
  }

  releaseNextExecutor(): void {
    const release = this.nextExecutorRelease;
    this.nextExecutorRelease = null;
    this.nextExecutorGate = null;
    if (release !== null) {
      release();
    }
  }

  async run(index: number): Promise<void> {
    const executor: NGFTaskExecutor | undefined = this.executors[index];
    if (executor === undefined) {
      throw new Error('Fake background executor does not exist');
    }
    this.executorStartedCount++;
    const gate = this.nextExecutorGate;
    if (gate !== null) {
      this.nextExecutorGate = null;
      await gate;
    }
    await executor('fake_executor_' + index.toString(), (_progress: number, _total: number, message: string): void => {
      if (message === 'Steam farming runtime stopped') {
        this.stoppedExecutorCount++;
      }
    });
  }
}

class FakeFarmingRuntime implements ISteamArkFarmingRuntime {
  readonly accountId: string;
  private currentSession: SteamSessionSnapshot;
  private currentSnapshot: SteamFarmSnapshot;
  private readonly listeners: Array<SteamFarmEventListener> = [];
  loadCount: number = 0;
  startCount: number = 0;
  stopCount: number = 0;
  disposeCount: number = 0;
  stopError: Error | null = null;
  disposeError: Error | null = null;
  startGate: Promise<void> | null = null;
  private startRelease: (() => void) | null = null;

  constructor(profile: SteamAccountProfile) {
    this.accountId = profile.accountId;
    this.currentSession = new SteamSessionSnapshot(
      profile.accountId,
      SteamSessionState.LOGGED_ON,
      profile.steamId64,
      'fake-cm',
      1700000000
    );
    this.currentSnapshot = this.snapshotFor(SteamFarmState.IDLE, false, false);
  }

  get session(): SteamSessionSnapshot {
    return this.currentSession;
  }

  get snapshot(): SteamFarmSnapshot {
    return this.currentSnapshot;
  }

  async load(): Promise<SteamFarmSnapshot> {
    this.loadCount++;
    return this.currentSnapshot;
  }

  async start(): Promise<SteamFarmSnapshot> {
    this.startCount++;
    if (this.startGate !== null) {
      await this.startGate;
    }
    this.currentSnapshot = this.snapshotFor(SteamFarmState.FARMING, false, true);
    this.emitSnapshot();
    return this.currentSnapshot;
  }

  async pause(): Promise<SteamFarmSnapshot> {
    this.currentSnapshot = this.snapshotFor(SteamFarmState.PAUSED, true, false);
    this.emitSnapshot();
    return this.currentSnapshot;
  }

  async pauseFor(_pauseMode: SteamFarmPauseMode, _seconds: number): Promise<SteamFarmSnapshot> {
    return await this.pause();
  }

  async resume(): Promise<SteamFarmSnapshot> {
    return await this.start();
  }

  async stop(): Promise<SteamFarmSnapshot> {
    this.stopCount++;
    if (this.stopError !== null) {
      throw this.stopError;
    }
    this.currentSnapshot = this.snapshotFor(SteamFarmState.IDLE, false, false);
    this.emitSnapshot();
    return this.currentSnapshot;
  }

  async playManual(appIds: Array<string>, gameName: string): Promise<SteamFarmSnapshot> {
    this.currentSnapshot = new SteamFarmSnapshot(
      this.accountId,
      SteamFarmState.FARMING,
      false,
      true,
      appIds,
      [new SteamGameDrop('10', gameName, 0, 1, 0, false, '10')],
      3600,
      1700000010,
      '',
      true,
      appIds,
      gameName
    );
    this.emitSnapshot();
    return this.currentSnapshot;
  }

  async resetManual(): Promise<SteamFarmSnapshot> {
    this.currentSnapshot = this.snapshotFor(SteamFarmState.IDLE, false, false);
    this.emitSnapshot();
    return this.currentSnapshot;
  }

  addEventListener(listener: SteamFarmEventListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeEventListener(listener: SteamFarmEventListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  addSessionListener(_listener: SteamSessionEventListener): void {
    return;
  }

  removeSessionListener(_listener: SteamSessionEventListener): void {
    return;
  }

  async dispose(): Promise<void> {
    this.disposeCount++;
    if (this.disposeError !== null) {
      throw this.disposeError;
    }
  }

  blockNextStart(): void {
    this.startGate = new Promise<void>((resolve: () => void): void => {
      this.startRelease = resolve;
    });
  }

  releaseStart(): void {
    const release = this.startRelease;
    this.startRelease = null;
    this.startGate = null;
    if (release !== null) {
      release();
    }
  }

  completeWithoutStopping(): void {
    this.currentSnapshot = this.snapshotFor(SteamFarmState.COMPLETED, false, false);
    this.emitSnapshot();
  }

  emitBadgeReport(report: SteamBadgeSyncReport): void {
    const event = new SteamFarmEvent(
      SteamFarmEventType.BADGE_SYNCED,
      this.currentSnapshot,
      null,
      'fake badge report',
      report
    );
    for (let index = 0; index < this.listeners.length; index++) {
      this.listeners[index](event);
    }
  }

  private snapshotFor(state: SteamFarmState, paused: boolean, nowFarming: boolean): SteamFarmSnapshot {
    const currentAppIds: Array<string> = [];
    if (nowFarming) {
      currentAppIds.push('10');
    }
    const games: Array<SteamGameDrop> = [
      new SteamGameDrop('10', this.accountId + ' game', 0, 1, 0, false, '10')
    ];
    return new SteamFarmSnapshot(
      this.accountId,
      state,
      paused,
      nowFarming,
      currentAppIds,
      games,
      3600,
      1700000010
    );
  }

  private emitSnapshot(): void {
    const event = new SteamFarmEvent(
      SteamFarmEventType.STATE_CHANGED,
      this.currentSnapshot,
      null,
      'fake runtime state changed'
    );
    for (let index = 0; index < this.listeners.length; index++) {
      this.listeners[index](event);
    }
  }
}

class FakeFarmingRuntimeFactory implements ISteamArkFarmingRuntimeFactory {
  readonly runtimes: Map<string, FakeFarmingRuntime> = new Map<string, FakeFarmingRuntime>();
  createCount: number = 0;
  readonly isEnabled: boolean = true;
  readonly unavailableReason: string = '';

  create(
    profile: SteamAccountProfile,
    _config: SteamBotConfig,
    _credentials: SteamCredentialSet,
    _stateStore: IStateStore
  ): ISteamArkFarmingRuntime {
    this.createCount++;
    const runtime = new FakeFarmingRuntime(profile);
    this.runtimes.set(profile.accountId, runtime);
    return runtime;
  }

  get(accountId: string): FakeFarmingRuntime | null {
    const runtime = this.runtimes.get(accountId);
    return runtime === undefined ? null : runtime;
  }
}

class FakeFarmingHost {
  readonly settingsStore: FakeSettingsStore = new FakeSettingsStore();
  readonly credentialStore: FakeCredentialStore = new FakeCredentialStore();
  readonly stateService: SteamArkStateService;
  readonly runtimeFactory: FakeFarmingRuntimeFactory = new FakeFarmingRuntimeFactory();
  readonly taskHost: FakeBackgroundTaskHost = new FakeBackgroundTaskHost();
  readonly service: SteamArkFarmingService;

  constructor() {
    this.stateService = new SteamArkStateService(
      new SteamArkStateServiceOptions(this.settingsStore, this.credentialStore)
    );
    this.service = new SteamArkFarmingService(
      new SteamArkFarmingServiceOptions(
        this.stateService,
        this.settingsStore,
        this.runtimeFactory,
        'Fake Steam Farming',
        this.taskHost,
        1
      )
    );
  }

  async initialize(): Promise<void> {
    await this.stateService.initialize();
  }

  async addLoggedOnAccount(accountId: string, steamId64: string): Promise<void> {
    await this.stateService.importAsfBotJson(
      'fake-' + accountId + '.json',
      '{"SteamLogin":"' + accountId + '","SteamPassword":"password-' + accountId + '"}'
    );
    await this.stateService.updateSession(
      new SteamSessionSnapshot(accountId, SteamSessionState.LOGGED_ON, steamId64, 'fake-cm', 1700000000)
    );
  }
}

class FakeFarmingHostWithExistingStorage {
  readonly stateService: SteamArkStateService;
  readonly runtimeFactory: FakeFarmingRuntimeFactory = new FakeFarmingRuntimeFactory();
  readonly taskHost: FakeBackgroundTaskHost = new FakeBackgroundTaskHost();
  readonly service: SteamArkFarmingService;

  constructor(settingsStore: FakeSettingsStore, credentialStore: FakeCredentialStore) {
    this.stateService = new SteamArkStateService(
      new SteamArkStateServiceOptions(settingsStore, credentialStore)
    );
    this.service = new SteamArkFarmingService(
      new SteamArkFarmingServiceOptions(
        this.stateService,
        settingsStore,
        this.runtimeFactory,
        'Fake Steam Farming',
        this.taskHost,
        1
      )
    );
  }

  async initialize(): Promise<void> {
    await this.stateService.initialize();
  }
}

class FakeAccountLifecycle implements ISteamArkAccountLifecycle {
  private readonly farmingService: SteamArkFarmingService;

  constructor(farmingService: SteamArkFarmingService) {
    this.farmingService = farmingService;
  }

  async stop(accountId: string): Promise<void> {
    await this.farmingService.stop(accountId);
  }

  async remove(accountId: string): Promise<void> {
    await this.farmingService.removeAccount(accountId);
  }
}

export default function steamArkFarmingServiceTest(): void {
  describe('SteamArkFarmingService', () => {
    it('isolatesAccountsAndStopsBackgroundTaskAfterLastRuntime', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('alice', '76561197960287930');
      await host.addLoggedOnAccount('bob', '76561197960287931');

      const aliceSnapshot = await host.service.start('alice');
      const bobSnapshot = await host.service.start('bob');
      expect(aliceSnapshot.accountId).assertEqual('alice');
      expect(bobSnapshot.accountId).assertEqual('bob');
      expect(aliceSnapshot.nowFarming).assertTrue();
      expect(bobSnapshot.nowFarming).assertTrue();
      expect(host.runtimeFactory.createCount).assertEqual(2);
      expect(host.taskHost.taskNames.length).assertEqual(1);
      expect(host.service.isBackgroundTaskRunning()).assertTrue();

      const aliceRuntime = host.runtimeFactory.get('alice');
      const bobRuntime = host.runtimeFactory.get('bob');
      expect(aliceRuntime !== null).assertTrue();
      expect(bobRuntime !== null).assertTrue();
      if (aliceRuntime !== null && bobRuntime !== null) {
        expect(aliceRuntime.startCount).assertEqual(1);
        expect(bobRuntime.startCount).assertEqual(1);
      }

      await host.service.stop('alice');
      expect(host.service.isBackgroundTaskRunning()).assertTrue();
      if (aliceRuntime !== null && bobRuntime !== null) {
        expect(aliceRuntime.disposeCount).assertEqual(1);
        expect(bobRuntime.disposeCount).assertEqual(0);
      }

      await host.service.stop('bob');
      expect(host.service.isBackgroundTaskRunning()).assertFalse();
      expect(host.service.getBackgroundTaskId()).assertEqual('');
      if (bobRuntime !== null) {
        expect(bobRuntime.disposeCount).assertEqual(1);
      }
      expect(host.service.getSnapshot('alice') !== null).assertTrue();
      expect(host.service.getSnapshot('bob') !== null).assertTrue();
    });

    it('continuesRuntimeCleanupWhenStopFails', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('stop-cleanup', '76561197960287940');
      await host.service.start('stop-cleanup');
      const runtime = host.runtimeFactory.get('stop-cleanup');
      expect(runtime !== null).assertTrue();
      if (runtime === null) {
        return;
      }

      runtime.stopError = new Error('runtime stop rejected');
      runtime.disposeError = new Error('runtime dispose rejected');
      let failureMessage: string = '';
      try {
        await host.service.stop('stop-cleanup');
      } catch (error) {
        failureMessage = error instanceof Error ? error.message : 'unexpected failure';
      }

      expect(failureMessage).assertEqual('runtime stop rejected');
      expect(runtime.stopCount).assertEqual(1);
      expect(runtime.disposeCount).assertEqual(1);
      expect(host.service.hasRuntime('stop-cleanup')).assertFalse();
    });

    it('continuesRuntimeCleanupWhenSessionPersistenceFails', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('session-cleanup', '76561197960287941');
      await host.service.start('session-cleanup');
      const runtime = host.runtimeFactory.get('session-cleanup');
      expect(runtime !== null).assertTrue();
      if (runtime === null) {
        return;
      }

      host.settingsStore.failNextAsyncWrite = true;
      let failureMessage: string = '';
      try {
        await host.service.stop('session-cleanup');
      } catch (error) {
        failureMessage = error instanceof Error ? error.message : 'unexpected failure';
      }

      expect(failureMessage).assertEqual('Steam state persistence failed');
      expect(runtime.disposeCount).assertEqual(1);
      expect(host.service.hasRuntime('session-cleanup')).assertFalse();
    });

    it('serializesStartBeforeStopAndDetachesLateRuntimeEvents', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('serialized', '76561197960287942');
      await host.service.start('serialized');
      const runtime = host.runtimeFactory.get('serialized');
      expect(runtime !== null).assertTrue();
      if (runtime === null) {
        return;
      }

      let eventCount: number = 0;
      host.service.subscribe('serialized-test', (_event: SteamArkFarmingEvent): void => {
        eventCount++;
      });
      runtime.blockNextStart();
      const restarting = host.service.start('serialized');
      const stopping = host.service.stop('serialized');
      await Promise.resolve();
      await Promise.resolve();
      expect(runtime.stopCount).assertEqual(0);
      runtime.releaseStart();
      await restarting;
      await stopping;

      const eventsBeforeLateEvent = eventCount;
      runtime.completeWithoutStopping();
      expect(eventCount).assertEqual(eventsBeforeLateEvent);
      expect(host.service.hasRuntime('serialized')).assertFalse();
      host.service.unsubscribe('serialized-test');
    });

    it('retainsAccountWhenRuntimeDisposeFailsDuringRemoval', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('dispose-failure', '76561197960287943');
      await host.service.start('dispose-failure');
      const runtime = host.runtimeFactory.get('dispose-failure');
      expect(runtime !== null).assertTrue();
      if (runtime === null) {
        return;
      }

      host.stateService.setAccountLifecycle(new FakeAccountLifecycle(host.service));
      runtime.disposeError = new Error('runtime dispose rejected');
      let failureMessage: string = '';
      try {
        await host.stateService.removeAccount('dispose-failure');
      } catch (error) {
        failureMessage = error instanceof Error ? error.message : 'unexpected failure';
      }

      expect(failureMessage).assertEqual('runtime dispose rejected');
      expect(host.service.hasRuntime('dispose-failure')).assertFalse();
      expect(host.stateService.getSelectedAccount() !== null).assertTrue();
      const credentials = await host.stateService.getCredentials('dispose-failure');
      expect(credentials.password).assertEqual('password-dispose-failure');
    });

    it('stopsBackgroundTaskWhenRuntimeCompletesByEvent', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('completed', '76561197960287932');
      await host.service.start('completed');
      expect(host.service.isBackgroundTaskRunning()).assertTrue();

      const runtime = host.runtimeFactory.get('completed');
      expect(runtime !== null).assertTrue();
      if (runtime !== null) {
        runtime.completeWithoutStopping();
      }
      expect(host.service.isBackgroundTaskRunning()).assertFalse();
      await host.service.dispose();
    });

    it('waitsForOnePendingBackgroundSubmissionAcrossAccounts', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('pending-alice', '76561197960287950');
      await host.addLoggedOnAccount('pending-bob', '76561197960287951');
      host.taskHost.blockNextSubmit();

      const firstStart = host.service.start('pending-alice');
      await host.taskHost.waitForSubmitStarted();
      expect(host.taskHost.submitStarted).assertTrue();

      let secondCompleted: boolean = false;
      const secondStart = host.service.start('pending-bob');
      void secondStart.then((): void => {
        secondCompleted = true;
      });
      await Promise.resolve();
      await Promise.resolve();
      expect(secondCompleted).assertFalse();

      host.taskHost.releaseSubmit();
      await Promise.all([firstStart, secondStart]);
      expect(host.taskHost.taskNames.length).assertEqual(1);
      expect(host.service.isBackgroundTaskRunning()).assertTrue();
      await host.service.dispose();
    });

    it('doesNotWaitForeverWhenAcceptedTaskExecutorIsNeverScheduled', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('unscheduled-task', '76561197960287953');
      host.taskHost.skipNextExecutor = true;

      const starting = host.service.start('unscheduled-task');
      await host.taskHost.waitForSubmitStarted();
      expect(host.taskHost.submitStarted).assertTrue();
      await starting;

      expect(host.service.isBackgroundTaskRunning()).assertTrue();
      await host.service.stop('unscheduled-task');
      expect(host.service.isBackgroundTaskRunning()).assertFalse();
      expect(host.service.getBackgroundTaskId()).assertEqual('');
      await host.service.dispose();
    });

    it('stopsAllRuntimesAndContinuesWhenOneDisposeFails', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('dispose-one', '76561197960287954');
      await host.addLoggedOnAccount('dispose-two', '76561197960287955');
      await host.service.start('dispose-one');
      await host.service.start('dispose-two');
      const first = host.runtimeFactory.get('dispose-one');
      const second = host.runtimeFactory.get('dispose-two');
      expect(first !== null).assertTrue();
      expect(second !== null).assertTrue();
      if (first === null || second === null) {
        return;
      }
      first.disposeError = new Error('first runtime dispose rejected');

      let failureMessage: string = '';
      try {
        await host.service.dispose();
      } catch (error) {
        failureMessage = error instanceof Error ? error.message : 'unexpected failure';
      }

      expect(failureMessage).assertEqual('first runtime dispose rejected');
      expect(first.stopCount).assertEqual(1);
      expect(second.stopCount).assertEqual(1);
      expect(first.disposeCount).assertEqual(1);
      expect(second.disposeCount).assertEqual(1);
      expect(host.service.isBackgroundTaskRunning()).assertFalse();
    });

    it('clearsSnapshotsWhenDisposed', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('dispose-snapshot', '76561197960287952');
      await host.service.start('dispose-snapshot');
      expect(host.service.getSnapshot('dispose-snapshot') !== null).assertTrue();

      await host.service.dispose();
      expect(host.service.getSnapshot('dispose-snapshot') === null).assertTrue();
      expect(host.service.isBackgroundTaskRunning()).assertFalse();
      expect(host.service.getBackgroundTaskId()).assertEqual('');
    });

    it('marksRuntimeErrorWhenBackgroundTaskSubmissionFails', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('background-failure', '76561197960287935');
      host.taskHost.submitError = new Error('background task unavailable');

      let failureMessage: string = '';
      try {
        await host.service.start('background-failure');
      } catch (error) {
        failureMessage = error instanceof Error ? error.message : 'unexpected failure';
      }

      expect(failureMessage).assertEqual('background task unavailable');
      expect(host.service.isBackgroundTaskRunning()).assertFalse();
      expect(host.service.getBackgroundTaskId()).assertEqual('');
      const snapshot = host.service.getSnapshot('background-failure');
      expect(snapshot !== null).assertTrue();
      if (snapshot !== null) {
        expect(snapshot.state).assertEqual(SteamFarmState.ERROR);
        expect(snapshot.nowFarming).assertFalse();
        expect(snapshot.lastError).assertEqual('background task unavailable');
      }
      const runtime = host.runtimeFactory.get('background-failure');
      expect(runtime !== null).assertTrue();
      if (runtime !== null) {
        expect(runtime.disposeCount).assertEqual(1);
      }
      await host.service.dispose();
    });

    it('finishesOldBackgroundExecutorAfterFarmingRestarts', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('background-restart', '76561197960287936');

      host.taskHost.blockNextExecutor();
      await host.service.start('background-restart');
      const firstStop = host.service.stop('background-restart');
      await Promise.resolve();
      await Promise.resolve();
      expect(host.taskHost.executorStartedCount).assertEqual(1);
      expect(host.taskHost.stoppedExecutorCount).assertEqual(0);
      expect(host.taskHost.taskNames.length).assertEqual(1);
      host.taskHost.releaseNextExecutor();
      await firstStop;

      await host.service.start('background-restart');
      await host.service.stop('background-restart');

      expect(host.taskHost.executorStartedCount).assertEqual(2);
      expect(host.taskHost.stoppedExecutorCount).assertEqual(2);
      expect(host.service.isBackgroundTaskRunning()).assertFalse();
      await host.service.dispose();
    });

    it('routesCoreCommandsThroughSelectedAccountService', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('command-account', '76561197960287934');
      await host.service.start('command-account');

      const manual = await host.service.executeCommand(
        'play 480,730 Manual Game',
        'command-account',
        ['command-account']
      );
      expect(manual.success).assertTrue();
      expect(manual.request !== null).assertTrue();
      expect(manual.snapshot !== null).assertTrue();
      if (manual.request !== null) {
        expect(manual.request.accountId).assertEqual('command-account');
        expect(manual.request.appIds.length).assertEqual(2);
      }
      if (manual.snapshot !== null) {
        expect(manual.snapshot.manualMode).assertTrue();
        expect(manual.snapshot.manualGameName).assertEqual('Manual Game');
      }

      const status = await host.service.executeCommand('status', 'command-account');
      expect(status.success).assertTrue();
      const reset = await host.service.executeCommand('reset', 'command-account');
      expect(reset.success).assertTrue();
      if (reset.snapshot !== null) {
        expect(reset.snapshot.manualMode).assertFalse();
      }
      await host.service.stop('command-account');
    });

    it('roundTripsManualFarmStateWithoutCredentialFields', 0, async () => {
      const settings = new FakeSettingsStore();
      const store = new SteamArkFarmingStateStore(settings);
      const record = new SteamFarmStateRecord(
        'persisted-manual',
        SteamFarmState.FARMING,
        false,
        ['480'],
        [new SteamGameDrop('480', 'Manual Game', 0, 1)],
        1700000020,
        true,
        ['480', '730'],
        'Manual Game',
        SteamFarmState.FARMING,
        false,
        ['10']
      );
      expect(await store.save(record)).assertTrue();
      const restored = await store.load('persisted-manual');
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.manualMode).assertTrue();
        expect(restored.manualAppIds[1]).assertEqual('730');
        expect(restored.manualPreviousAppIds[0]).assertEqual('10');
        expect(restored.manualGameName).assertEqual('Manual Game');
      }
    });

    it('publishesAndRetainsBadgeSyncDiagnosticsPerAccount', 0, async () => {
      const host = new FakeFarmingHost();
      await host.initialize();
      await host.addLoggedOnAccount('diagnostic', '76561197960287933');
      await host.service.start('diagnostic');
      const runtime = host.runtimeFactory.get('diagnostic');
      expect(runtime !== null).assertTrue();

      const eventTypes: Array<SteamArkFarmingEventType> = [];
      host.service.subscribe('badge-diagnostic-test', (event: SteamArkFarmingEvent): void => {
        eventTypes.push(event.type);
      });
      if (runtime !== null) {
        runtime.emitBadgeReport(new SteamBadgeSyncReport(
          [new SteamGameDrop('10', 'Diagnostic Game', 0, 1)],
          2,
          2,
          1,
          [],
          ['page 2: duplicate game']
        ));
      }

      const report = host.service.getBadgeSyncReport('diagnostic');
      expect(report !== null).assertTrue();
      expect(eventTypes.includes(SteamArkFarmingEventType.BADGE_SYNCED)).assertTrue();
      if (report !== null) {
        expect(report.requestedPageCount).assertEqual(2);
        expect(report.duplicateGameCount).assertEqual(1);
      }
      host.service.unsubscribe('badge-diagnostic-test');
      await host.service.stop('diagnostic');
      expect(host.service.getBadgeSyncReport('diagnostic') !== null).assertTrue();
    });

    it('restoresPublicBadgeReportAfterServiceRecreation', 0, async () => {
      const first = new FakeFarmingHost();
      await first.initialize();
      await first.addLoggedOnAccount('cached-badges', '76561197960287944');
      await first.service.start('cached-badges');
      const runtime = first.runtimeFactory.get('cached-badges');
      expect(runtime !== null).assertTrue();
      if (runtime === null) {
        return;
      }
      runtime.emitBadgeReport(new SteamBadgeSyncReport(
        [new SteamGameDrop(
          '440',
          'Cached Badge Game',
          12.5,
          3,
          5,
          true,
          '440',
          'https://cdn.example.invalid/game.jpg',
          'https://store.steampowered.com/app/440/',
          'https://cdn.example.invalid/badge.jpg',
          'https://steamcommunity.com/my/gamecards/440/'
        )],
        3,
        3,
        1,
        [],
        ['duplicate game was skipped'],
        [new SteamCommunityBadge(
          'steam-years',
          'Years of Service',
          100,
          'https://cdn.example.invalid/community-badge.jpg',
          'https://steamcommunity.com/my/badges/'
        )]
      ));
      await first.service.dispose();

      const second = new FakeFarmingHostWithExistingStorage(first.settingsStore, first.credentialStore);
      await second.initialize();
      const restored = second.service.getBadgeSyncReport('cached-badges');
      expect(restored !== null).assertTrue();
      if (restored === null) {
        return;
      }
      expect(restored.games.length).assertEqual(1);
      expect(restored.games[0].badgeImageUrl).assertEqual('https://cdn.example.invalid/badge.jpg');
      expect(restored.communityBadges.length).assertEqual(1);
      expect(restored.communityBadges[0].name).assertEqual('Years of Service');
      expect(restored.requestedPageCount).assertEqual(3);
      expect(restored.warnings[0]).assertEqual('duplicate game was skipped');
    });

    it('clearsPersistedBadgeReportWhenAccountIsRemoved', 0, async () => {
      const first = new FakeFarmingHost();
      await first.initialize();
      await first.addLoggedOnAccount('removed-badges', '76561197960287945');
      await first.service.start('removed-badges');
      const runtime = first.runtimeFactory.get('removed-badges');
      expect(runtime !== null).assertTrue();
      if (runtime === null) {
        return;
      }
      runtime.emitBadgeReport(new SteamBadgeSyncReport(
        [new SteamGameDrop('570', 'Removed Badge Game', 0, 1, 1)],
        1,
        1
      ));
      await first.service.removeAccount('removed-badges');
      await first.service.dispose();

      const second = new FakeFarmingHostWithExistingStorage(first.settingsStore, first.credentialStore);
      await second.initialize();
      expect(second.service.getBadgeSyncReport('removed-badges') === null).assertTrue();
    });
  });
}
