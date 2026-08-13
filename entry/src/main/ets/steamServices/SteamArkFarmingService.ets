import {
  ISettingsStore,
  NGFTaskExecutor,
  ngfSettingsStoreFacade,
  ngfSystem
} from 'ngf_framework';
import {
  IStateStore,
  ISteamCommandExecutor,
  SteamAccountProfile,
  SteamBadgeSyncReport,
  SteamBotConfig,
  SteamFarmEvent,
  SteamFarmEventType,
  SteamFarmSnapshot,
  SteamFarmState,
  SteamFarmStateRecord,
  SteamCommunityBadge,
  SteamGameDrop,
  SteamJsonParser,
  SteamJsonValue,
  SteamJsonValueKind,
  SteamProxySettings,
  SteamSessionSnapshot,
  SteamSessionState,
  SteamCommandName,
  SteamCommandParserOptions,
  SteamCommandReadOnlyPayload,
  SteamCommandRequest,
  SteamCommandResult,
  SteamCommandRouter,
  ISteamReadOnlyCommandExecutor,
  SteamInventoryQuery
} from 'steam_core';
import {
  ISteamArkFarmingRuntime,
  ISteamArkFarmingRuntimeFactory,
  SteamArkFarmingEvent,
  SteamArkFarmingEventListener,
  SteamArkFarmingEventType,
  SteamFarmEventListener,
  SteamSessionEventListener
} from './SteamArkFarmingContracts';
import {
  SteamArkAccountSnapshot,
  SteamArkStateService,
  SteamArkStateSnapshot,
  steamArkStateService
} from './SteamArkStateService';
import { ASFWorkshopProductIdentity } from './ASFWorkshopProductIdentity';
import { SteamArkLog } from './SteamArkLogger';
import { steamArkCoreLogger } from './SteamArkCoreLogger';

const TAG: string = 'SteamArkFarmingService';
const FARM_STATE_KEY_PREFIX: string = 'steam_ark_farm_v1_';
const BADGE_REPORT_KEY_PREFIX: string = 'steam_ark_badge_report_v1_';
const BADGE_REPORT_CACHE_VERSION: number = 1;
const BACKGROUND_TASK_NAME: string = ASFWorkshopProductIdentity.BACKGROUND_TASK_FARMING;
const BACKGROUND_UPDATE_INTERVAL_MS: number = 30000;

/** Completes when the submitted executor has actually returned. */
class SteamArkBackgroundTaskCompletion {
  readonly promise: Promise<void>;
  private resolver: (() => void) | null = null;
  private executorStarted: boolean = false;

  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => {
      this.resolver = resolve;
    });
  }

  complete(): void {
    const resolve = this.resolver;
    this.resolver = null;
    if (resolve !== null) {
      resolve();
    }
  }

  markExecutorStarted(): void {
    this.executorStarted = true;
  }

  hasExecutorStarted(): boolean {
    return this.executorStarted;
  }
}

/** Host boundary keeps the service testable without starting a system task. */
export interface ISteamArkBackgroundTaskHost {
  submit(name: string, executor: NGFTaskExecutor): Promise<string>;
}

/** Production host delegates task lifecycle to the NGF system facade. */
export class NGFSteamArkBackgroundTaskHost implements ISteamArkBackgroundTaskHost {
  submit(name: string, executor: NGFTaskExecutor): Promise<string> {
    return ngfSystem.submitTask(name, executor);
  }
}

/** Explicit non-secret persistence DTO for one account's farming state. */
class SteamArkPersistedFarmGame {
  appId: string = '';
  name: string = '';
  hoursPlayed: number = 0;
  cardsRemaining: number = 0;
  badgeLevel: number = 0;
  marketable: boolean = false;
  playableAppId: string = '';
  imageUrl: string = '';
  storeUrl: string = '';

  constructor(game: SteamGameDrop) {
    this.appId = game.appId;
    this.name = game.name;
    this.hoursPlayed = game.hoursPlayed;
    this.cardsRemaining = game.cardsRemaining;
    this.badgeLevel = game.badgeLevel;
    this.marketable = game.marketable;
    this.playableAppId = game.playableAppId;
    this.imageUrl = game.imageUrl;
    this.storeUrl = game.storeUrl;
  }
}

class SteamArkPersistedFarmRecord {
  accountId: string = '';
  state: SteamFarmState = SteamFarmState.IDLE;
  paused: boolean = false;
  manualMode: boolean = false;
  manualAppIds: Array<string> = [];
  manualGameName: string = '';
  manualPreviousState: SteamFarmState = SteamFarmState.IDLE;
  manualPreviousPaused: boolean = false;
  manualPreviousAppIds: Array<string> = [];
  currentAppIds: Array<string> = [];
  games: Array<SteamArkPersistedFarmGame> = [];
  updatedAtEpochSeconds: number = 0;

  constructor(record: SteamFarmStateRecord) {
    this.accountId = record.accountId;
    this.state = record.state;
    this.paused = record.paused;
    this.manualMode = record.manualMode;
    this.manualAppIds = record.manualAppIds.slice();
    this.manualGameName = record.manualGameName;
    this.manualPreviousState = record.manualPreviousState;
    this.manualPreviousPaused = record.manualPreviousPaused;
    this.manualPreviousAppIds = record.manualPreviousAppIds.slice();
    this.currentAppIds = record.currentAppIds.slice();
    for (let index = 0; index < record.games.length; index++) {
      this.games.push(new SteamArkPersistedFarmGame(record.games[index]));
    }
    this.updatedAtEpochSeconds = record.updatedAtEpochSeconds;
  }
}

/** Public badge data only. This document must never include Steam HTML or session material. */
class SteamArkPersistedBadgeGame {
  appId: string = '';
  name: string = '';
  hoursPlayed: number = 0;
  cardsRemaining: number = 0;
  badgeLevel: number = 0;
  marketable: boolean = false;
  playableAppId: string = '';
  imageUrl: string = '';
  storeUrl: string = '';
  badgeImageUrl: string = '';
  badgeUrl: string = '';

  constructor(game: SteamGameDrop) {
    this.appId = game.appId;
    this.name = game.name;
    this.hoursPlayed = game.hoursPlayed;
    this.cardsRemaining = game.cardsRemaining;
    this.badgeLevel = game.badgeLevel;
    this.marketable = game.marketable;
    this.playableAppId = game.playableAppId;
    this.imageUrl = game.imageUrl;
    this.storeUrl = game.storeUrl;
    this.badgeImageUrl = game.badgeImageUrl;
    this.badgeUrl = game.badgeUrl;
  }
}

class SteamArkPersistedCommunityBadge {
  badgeId: string = '';
  name: string = '';
  experience: number = 0;
  imageUrl: string = '';
  badgeUrl: string = '';

  constructor(badge: SteamCommunityBadge) {
    this.badgeId = badge.badgeId;
    this.name = badge.name;
    this.experience = badge.experience;
    this.imageUrl = badge.imageUrl;
    this.badgeUrl = badge.badgeUrl;
  }
}

class SteamArkPersistedBadgeReport {
  version: number = BADGE_REPORT_CACHE_VERSION;
  accountId: string = '';
  updatedAtEpochSeconds: number = 0;
  requestedPageCount: number = 0;
  fetchedPageCount: number = 0;
  duplicateGameCount: number = 0;
  warnings: Array<string> = [];
  games: Array<SteamArkPersistedBadgeGame> = [];
  communityBadges: Array<SteamArkPersistedCommunityBadge> = [];

  constructor(accountId: string, report: SteamBadgeSyncReport, updatedAtEpochSeconds: number) {
    this.accountId = accountId;
    this.updatedAtEpochSeconds = updatedAtEpochSeconds;
    this.requestedPageCount = report.requestedPageCount;
    this.fetchedPageCount = report.fetchedPageCount;
    this.duplicateGameCount = report.duplicateGameCount;
    this.warnings = report.warnings.slice();
    for (let index = 0; index < report.games.length; index++) {
      this.games.push(new SteamArkPersistedBadgeGame(report.games[index]));
    }
    for (let index = 0; index < report.communityBadges.length; index++) {
      this.communityBadges.push(new SteamArkPersistedCommunityBadge(report.communityBadges[index]));
    }
  }
}

/** NGF-backed state store for the platform-independent coordinator. */
export class SteamArkFarmingStateStore implements IStateStore {
  private readonly settingsStore: ISettingsStore;

  constructor(settingsStore: ISettingsStore = ngfSettingsStoreFacade) {
    this.settingsStore = settingsStore;
  }

  async load(accountId: string): Promise<SteamFarmStateRecord | null> {
    SteamArkLog.debug(TAG, 'farming state load started; account=' + SteamArkLog.accountId(accountId));
    const serialized = this.settingsStore.getString(this.key(accountId), '');
    if (serialized.trim().length <= 0) {
      SteamArkLog.debug(TAG, 'farming state load skipped; account=' + SteamArkLog.accountId(accountId) +
        ', reason=empty');
      return null;
    }
    try {
      const root = SteamJsonParser.parse(serialized, steamArkCoreLogger);
      const record = this.readRecord(root, accountId);
      SteamArkLog.debug(TAG, 'farming state load completed; account=' + SteamArkLog.accountId(accountId) +
        ', found=' + String(record !== null));
      return record;
    } catch (error) {
      const normalized: Error = error instanceof Error ? error : new Error(String(error));
      SteamArkLog.warn(TAG, 'farming state ignored; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      return null;
    }
  }

  async save(record: SteamFarmStateRecord): Promise<boolean> {
    SteamArkLog.debug(TAG, 'farming state save started; account=' + SteamArkLog.accountId(record.accountId) +
      ', state=' + String(record.state) + ', games=' + record.games.length.toString());
    const ready = await this.settingsStore.waitUntilReady();
    if (!ready) {
      SteamArkLog.warn(TAG, 'farming state save skipped; settings store not ready; account=' +
        SteamArkLog.accountId(record.accountId));
      return false;
    }
    const persisted = new SteamArkPersistedFarmRecord(record);
    const saved = await this.settingsStore.setStringAsync(this.key(record.accountId), JSON.stringify(persisted));
    SteamArkLog.debug(TAG, 'farming state save completed; account=' + SteamArkLog.accountId(record.accountId) +
      ', success=' + String(saved));
    return saved;
  }

  async clear(accountId: string): Promise<boolean> {
    const normalizedId = accountId.trim();
    if (normalizedId.length <= 0) {
      return false;
    }
    const ready = await this.settingsStore.waitUntilReady();
    if (!ready) {
      SteamArkLog.warn(TAG, 'farming state clear skipped; settings store not ready; account=' +
        SteamArkLog.accountId(normalizedId));
      return false;
    }
    const cleared = await this.settingsStore.setStringAsync(this.key(normalizedId), '');
    SteamArkLog.debug(TAG, 'farming state clear completed; account=' + SteamArkLog.accountId(normalizedId) +
      ', success=' + String(cleared));
    return cleared;
  }

  private key(accountId: string): string {
    return FARM_STATE_KEY_PREFIX + encodeURIComponent(accountId.trim());
  }

  private readRecord(root: SteamJsonValue, accountId: string): SteamFarmStateRecord | null {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('farming state must be an object');
    }
    const storedAccountId = this.readString(root.getProperty('accountId'), '');
    if (storedAccountId !== accountId) {
      return null;
    }
    const games: Array<SteamGameDrop> = this.readGames(root.getProperty('games'));
    return new SteamFarmStateRecord(
      accountId,
      this.readFarmState(root.getProperty('state')),
      this.readBoolean(root.getProperty('paused'), false),
      this.readStringArray(root.getProperty('currentAppIds')),
      games,
      this.readNumber(root.getProperty('updatedAtEpochSeconds'), 0),
      this.readBoolean(root.getProperty('manualMode'), false),
      this.readStringArray(root.getProperty('manualAppIds')),
      this.readString(root.getProperty('manualGameName'), ''),
      this.readFarmState(root.getProperty('manualPreviousState')),
      this.readBoolean(root.getProperty('manualPreviousPaused'), false),
      this.readStringArray(root.getProperty('manualPreviousAppIds'))
    );
  }

  private readGames(value: SteamJsonValue | null): Array<SteamGameDrop> {
    const games: Array<SteamGameDrop> = [];
    if (value === null || value.kind !== SteamJsonValueKind.ARRAY) {
      return games;
    }
    for (let index = 0; index < value.items.length; index++) {
      const item = value.items[index];
      if (item.kind !== SteamJsonValueKind.OBJECT) {
        continue;
      }
      const appId = this.readString(item.getProperty('appId'), '');
      if (appId.length <= 0) {
        continue;
      }
      games.push(new SteamGameDrop(
        appId,
        this.readString(item.getProperty('name'), ''),
        this.readNumber(item.getProperty('hoursPlayed'), 0),
        this.readInteger(item.getProperty('cardsRemaining'), 0),
        this.readInteger(item.getProperty('badgeLevel'), 0),
        this.readBoolean(item.getProperty('marketable'), false),
        this.readString(item.getProperty('playableAppId'), appId),
        this.readString(item.getProperty('imageUrl'), ''),
        this.readString(item.getProperty('storeUrl'), '')
      ));
    }
    return games;
  }

  private readFarmState(value: SteamJsonValue | null): SteamFarmState {
    const raw = this.readString(value, '');
    switch (raw) {
      case SteamFarmState.STARTING:
        return SteamFarmState.STARTING;
      case SteamFarmState.FARMING:
        return SteamFarmState.FARMING;
      case SteamFarmState.PAUSED:
        return SteamFarmState.PAUSED;
      case SteamFarmState.RECONNECTING:
        return SteamFarmState.RECONNECTING;
      case SteamFarmState.COMPLETED:
        return SteamFarmState.COMPLETED;
      case SteamFarmState.ERROR:
        return SteamFarmState.ERROR;
      case SteamFarmState.IDLE:
      default:
        return SteamFarmState.IDLE;
    }
  }

  private readString(value: SteamJsonValue | null, defaultValue: string): string {
    if (value === null || value.kind !== SteamJsonValueKind.STRING) {
      return defaultValue;
    }
    return value.stringValue;
  }

  private readBoolean(value: SteamJsonValue | null, defaultValue: boolean): boolean {
    if (value === null || value.kind !== SteamJsonValueKind.BOOLEAN) {
      return defaultValue;
    }
    return value.booleanValue;
  }

  private readNumber(value: SteamJsonValue | null, defaultValue: number): number {
    if (value === null || value.kind !== SteamJsonValueKind.NUMBER) {
      return defaultValue;
    }
    const parsed = Number(value.numberValue);
    return Number.isNaN(parsed) ? defaultValue : parsed;
  }

  private readInteger(value: SteamJsonValue | null, defaultValue: number): number {
    const parsed = this.readNumber(value, defaultValue);
    return Number.isSafeInteger(parsed) ? parsed : defaultValue;
  }

  private readStringArray(value: SteamJsonValue | null): Array<string> {
    const result: Array<string> = [];
    if (value === null || value.kind !== SteamJsonValueKind.ARRAY) {
      return result;
    }
    for (let index = 0; index < value.items.length; index++) {
      const item = value.items[index];
      if (item.kind === SteamJsonValueKind.STRING && item.stringValue.length > 0 && !result.includes(item.stringValue)) {
        result.push(item.stringValue);
      }
    }
    return result;
  }
}

export class SteamArkFarmingServiceOptions {
  readonly stateService: SteamArkStateService;
  readonly settingsStore: ISettingsStore;
  readonly runtimeFactory: ISteamArkFarmingRuntimeFactory | null;
  readonly taskName: string;
  readonly backgroundTaskHost: ISteamArkBackgroundTaskHost;
  readonly backgroundUpdateIntervalMs: number;

  constructor(
    stateService: SteamArkStateService = steamArkStateService,
    settingsStore: ISettingsStore = ngfSettingsStoreFacade,
    runtimeFactory: ISteamArkFarmingRuntimeFactory | null = null,
    taskName: string = BACKGROUND_TASK_NAME,
    backgroundTaskHost: ISteamArkBackgroundTaskHost = new NGFSteamArkBackgroundTaskHost(),
    backgroundUpdateIntervalMs: number = BACKGROUND_UPDATE_INTERVAL_MS
  ) {
    if (backgroundUpdateIntervalMs <= 0 || Math.floor(backgroundUpdateIntervalMs) !== backgroundUpdateIntervalMs) {
      throw new Error('Steam farming background update interval must be a positive integer');
    }
    this.stateService = stateService;
    this.settingsStore = settingsStore;
    this.runtimeFactory = runtimeFactory;
    this.taskName = taskName;
    this.backgroundTaskHost = backgroundTaskHost;
    this.backgroundUpdateIntervalMs = backgroundUpdateIntervalMs;
  }
}

class SteamArkFarmingRuntimeBinding {
  readonly runtime: ISteamArkFarmingRuntime;
  readonly snapshotListener: SteamFarmEventListener;
  readonly sessionListener: SteamSessionEventListener;
  readonly configurationGeneration: number;

  constructor(
    runtime: ISteamArkFarmingRuntime,
    snapshotListener: SteamFarmEventListener,
    sessionListener: SteamSessionEventListener,
    configurationGeneration: number
  ) {
    this.runtime = runtime;
    this.snapshotListener = snapshotListener;
    this.sessionListener = sessionListener;
    this.configurationGeneration = configurationGeneration;
  }
}

/** Captures a pending runtime creation so an old ability can cancel only its own work. */
class SteamArkFarmingRuntimeCreationHandle {
  readonly accountId: string;
  readonly generation: number;
  readonly configurationGeneration: number;
  readonly creation: Promise<ISteamArkFarmingRuntime>;

  constructor(
    accountId: string,
    generation: number,
    configurationGeneration: number,
    creation: Promise<ISteamArkFarmingRuntime>
  ) {
    this.accountId = accountId;
    this.generation = generation;
    this.configurationGeneration = configurationGeneration;
    this.creation = creation;
  }
}

/**
 * Application host for account-isolated farming runtimes. It owns no Steam
 * protocol implementation; that logic stays in steam_core and its adapters.
 */
export class SteamArkFarmingService implements ISteamCommandExecutor, ISteamReadOnlyCommandExecutor {
  private readonly stateService: SteamArkStateService;
  private readonly settingsStore: ISettingsStore;
  private readonly runtimes: Map<string, ISteamArkFarmingRuntime> =
    new Map<string, ISteamArkFarmingRuntime>();
  /** Serializes account actions so removal cannot race a late start or stop. */
  private readonly accountOperationTails: Map<string, Promise<void>> =
    new Map<string, Promise<void>>();
  private readonly runtimeCreationPromises: Map<string, Promise<ISteamArkFarmingRuntime>> =
    new Map<string, Promise<ISteamArkFarmingRuntime>>();
  private readonly runtimeCreationConfigurationGenerations: Map<string, number> =
    new Map<string, number>();
  private readonly runtimeGenerations: Map<string, number> = new Map<string, number>();
  private readonly runtimeConfigurationGenerations: Map<string, number> =
    new Map<string, number>();
  private readonly runtimeBindings: Map<string, SteamArkFarmingRuntimeBinding> =
    new Map<string, SteamArkFarmingRuntimeBinding>();
  private readonly snapshots: Map<string, SteamFarmSnapshot> =
    new Map<string, SteamFarmSnapshot>();
  private readonly badgeReports: Map<string, SteamBadgeSyncReport> =
    new Map<string, SteamBadgeSyncReport>();
  private readonly badgeReportUpdatedAtEpochSeconds: Map<string, number> =
    new Map<string, number>();
  /** Serializes public badge-cache writes so removal cannot be overwritten by a late event. */
  private readonly badgeReportPersistenceTails: Map<string, Promise<void>> =
    new Map<string, Promise<void>>();
  private readonly listeners: Map<string, SteamArkFarmingEventListener> =
    new Map<string, SteamArkFarmingEventListener>();
  private readonly taskName: string;
  private readonly backgroundTaskHost: ISteamArkBackgroundTaskHost;
  private readonly backgroundUpdateIntervalMs: number;
  private readonly commandRouter: SteamCommandRouter = new SteamCommandRouter(steamArkCoreLogger);
  private runtimeFactory: ISteamArkFarmingRuntimeFactory | null;
  private backgroundTaskRunning: boolean = false;
  private backgroundTaskId: string = '';
  private backgroundTaskGeneration: number = 0;
  private backgroundTaskConfigurationGeneration: number = 0;
  private backgroundTaskSubmissionPromise: Promise<void> | null = null;
  private backgroundTaskExecutorCompletion: SteamArkBackgroundTaskCompletion | null = null;
  /** Serializes start/stop transitions across accounts. */
  private backgroundTaskTransitionTail: Promise<void> = Promise.resolve();
  private disposed: boolean = false;
  private runtimeConfigurationGeneration: number = 0;
  private disposePromise: Promise<void> | null = null;
  private disposeConfigurationGeneration: number = -1;

  constructor(options: SteamArkFarmingServiceOptions = new SteamArkFarmingServiceOptions()) {
    this.stateService = options.stateService;
    this.settingsStore = options.settingsStore;
    this.runtimeFactory = options.runtimeFactory;
    this.taskName = options.taskName;
    this.backgroundTaskHost = options.backgroundTaskHost;
    this.backgroundUpdateIntervalMs = options.backgroundUpdateIntervalMs;
    SteamArkLog.debug(TAG, 'farming service constructed; runtimeConfigured=' +
      String(this.runtimeFactory !== null) + ', taskNameConfigured=' + String(this.taskName.length > 0));
  }

  setRuntimeFactory(factory: ISteamArkFarmingRuntimeFactory): void {
    this.runtimeConfigurationGeneration += 1;
    this.runtimeFactory = factory;
    this.disposed = false;
    SteamArkLog.info(TAG, 'farming runtime factory configured; enabled=' + String(factory.isEnabled));
    this.emit(new SteamArkFarmingEvent('', SteamArkFarmingEventType.BACKGROUND_TASK_CHANGED, null, null, this.availabilityMessage()));
  }

  isFarmingReady(): boolean {
    return this.runtimeFactory !== null && this.runtimeFactory.isEnabled;
  }

  availabilityMessage(): string {
    if (this.runtimeFactory === null) {
      return 'Farming runtime factory is not configured';
    }
    return this.runtimeFactory.isEnabled
      ? 'Farming runtime is enabled'
      : this.runtimeFactory.unavailableReason;
  }

  isBackgroundTaskRunning(): boolean {
    return !this.disposed && this.backgroundTaskRunning &&
      this.backgroundTaskConfigurationGeneration === this.runtimeConfigurationGeneration;
  }

  getBackgroundTaskId(): string {
    return this.isBackgroundTaskRunning() ? this.backgroundTaskId : '';
  }

  getSnapshot(accountId: string): SteamFarmSnapshot | null {
    const snapshot = this.snapshots.get(accountId.trim());
    return snapshot === undefined ? null : snapshot;
  }

  hasRuntime(accountId: string): boolean {
    const normalizedId = accountId.trim();
    return !this.disposed && this.runtimes.has(normalizedId) &&
      this.runtimeConfigurationGenerations.get(normalizedId) === this.runtimeConfigurationGeneration;
  }

  getBadgeSyncReport(accountId: string): SteamBadgeSyncReport | null {
    const normalizedId = accountId.trim();
    if (normalizedId.length <= 0) {
      return null;
    }
    const report = this.badgeReports.get(normalizedId);
    if (report === undefined) {
      this.restoreBadgeReport(normalizedId);
    }
    const restored = this.badgeReports.get(normalizedId);
    return restored === undefined ? null : restored;
  }

  getBadgeSyncReportUpdatedAtEpochSeconds(accountId: string): number {
    const normalizedId = accountId.trim();
    if (normalizedId.length <= 0 || this.getBadgeSyncReport(normalizedId) === null) {
      return 0;
    }
    const updatedAtEpochSeconds = this.badgeReportUpdatedAtEpochSeconds.get(normalizedId);
    return updatedAtEpochSeconds === undefined ? 0 : updatedAtEpochSeconds;
  }

  subscribe(listenerId: string, listener: SteamArkFarmingEventListener): boolean {
    const normalizedId = listenerId.trim();
    if (normalizedId.length <= 0 || this.listeners.has(normalizedId)) {
      SteamArkLog.debug(TAG, 'farming listener registration skipped; id=' + normalizedId);
      return false;
    }
    this.listeners.set(normalizedId, listener);
    SteamArkLog.debug(TAG, 'farming listener registered; id=' + normalizedId +
      ', count=' + this.listeners.size.toString());
    return true;
  }

  unsubscribe(listenerId: string): boolean {
    const normalizedId = listenerId.trim();
    const removed = this.listeners.delete(normalizedId);
    SteamArkLog.debug(TAG, 'farming listener unregistered; id=' + normalizedId +
      ', removed=' + String(removed));
    return removed;
  }

  async startSelected(): Promise<SteamFarmSnapshot> {
    const selected = this.stateService.getSelectedAccount();
    if (selected === null) {
      SteamArkLog.warn(TAG, 'selected farming start rejected; no account selected');
      throw new Error('A Steam account must be selected before farming starts');
    }
    SteamArkLog.info(TAG, 'selected farming start requested; account=' +
      SteamArkLog.accountId(selected.profile.accountId));
    return await this.start(selected.profile.accountId);
  }

  async refreshSelectedGames(): Promise<SteamFarmSnapshot> {
    const selected = this.stateService.getSelectedAccount();
    if (selected === null) {
      throw new Error('A Steam account must be selected before refreshing farming games');
    }
    return await this.refreshGames(selected.profile.accountId);
  }

  async refreshGames(accountId: string): Promise<SteamFarmSnapshot> {
    const normalizedId = accountId.trim();
    return await this.runAccountOperation<SteamFarmSnapshot>(
      normalizedId,
      async (): Promise<SteamFarmSnapshot> => {
        const configurationGeneration = this.runtimeConfigurationGeneration;
        await this.requireReadyState();
        this.requireCurrentRuntimeConfiguration(configurationGeneration);
        const account = this.findAccount(normalizedId);
        if (account === null) {
          throw new Error('Steam account does not exist');
        }
        if (account.session.state !== SteamSessionState.LOGGED_ON) {
          throw new Error('Steam account must be logged on before refreshing farming games');
        }
        const runtime = await this.getOrCreateRuntime(account);
        const snapshot = await runtime.refreshGames();
        this.requireCurrentRuntimeConfiguration(configurationGeneration);
        this.snapshots.set(normalizedId, snapshot);
        this.emitSnapshot(snapshot);
        return snapshot;
      }
    );
  }

  async start(accountId: string): Promise<SteamFarmSnapshot> {
    const normalizedId = accountId.trim();
    return await this.runAccountOperation<SteamFarmSnapshot>(
      normalizedId,
      async (): Promise<SteamFarmSnapshot> => await this.startInternal(normalizedId)
    );
  }

  private async startInternal(accountId: string): Promise<SteamFarmSnapshot> {
    const normalizedId = accountId.trim();
    const configurationGeneration = this.runtimeConfigurationGeneration;
    await this.requireReadyState();
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'farming start requested; account=' + SteamArkLog.accountId(normalizedId));
    const account = this.findAccount(normalizedId);
    if (account === null) {
      throw new Error('Steam account does not exist');
    }
    if (!account.profile.enabled || !account.config.enabled) {
      throw new Error('Steam account farming is disabled');
    }
    if (account.session.state !== SteamSessionState.LOGGED_ON) {
      throw new Error('Steam account must be logged on before farming starts');
    }
    const factory = this.runtimeFactory;
    if (factory === null || !factory.isEnabled) {
      throw new Error(this.availabilityMessage());
    }

    const runtime = await this.getOrCreateRuntime(account);
    try {
      const snapshot = await runtime.start();
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.snapshots.set(normalizedId, snapshot);
      await this.stateService.updateSession(runtime.session);
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      if (snapshot.nowFarming) {
        await this.ensureBackgroundTask();
      } else {
        await this.stopBackgroundTaskIfIdle();
      }
      this.emitSnapshot(snapshot);
      SteamArkLog.info(TAG, 'farming start completed; account=' + SteamArkLog.accountId(normalizedId) +
        ', state=' + String(snapshot.state) + ', active=' + String(snapshot.nowFarming));
      SteamArkLog.performance(TAG, 'farming start', startedAt);
      return snapshot;
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming start failed');
      SteamArkLog.error(TAG, 'farming start failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      if (this.isCurrentRuntimeConfiguration(configurationGeneration)) {
        await this.removeRuntimeForConfiguration(normalizedId, configurationGeneration);
        this.markSnapshotError(normalizedId, normalized.message);
        await this.stopBackgroundTaskIfIdle();
      }
      throw normalized;
    }
  }

  async pause(accountId: string): Promise<SteamFarmSnapshot | null> {
    const normalizedId = accountId.trim();
    return await this.runAccountOperation<SteamFarmSnapshot | null>(
      normalizedId,
      async (): Promise<SteamFarmSnapshot | null> => await this.pauseInternal(normalizedId)
    );
  }

  private async pauseInternal(accountId: string): Promise<SteamFarmSnapshot | null> {
    const normalizedId = accountId.trim();
    const configurationGeneration = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    SteamArkLog.info(TAG, 'farming pause requested; account=' + SteamArkLog.accountId(normalizedId));
    const runtime = this.runtimes.get(normalizedId);
    if (runtime === undefined ||
      this.runtimeConfigurationGenerations.get(normalizedId) !== configurationGeneration) {
      SteamArkLog.debug(TAG, 'farming pause skipped; runtime not found; account=' +
        SteamArkLog.accountId(normalizedId));
      return null;
    }
    try {
      const snapshot = await runtime.pause();
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.snapshots.set(runtime.accountId, snapshot);
      this.emitSnapshot(snapshot);
      await this.stopBackgroundTaskIfIdle();
      SteamArkLog.info(TAG, 'farming pause completed; account=' + SteamArkLog.accountId(normalizedId) +
        ', state=' + String(snapshot.state));
      return snapshot;
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming pause failed');
      SteamArkLog.error(TAG, 'farming pause failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  async resume(accountId: string): Promise<SteamFarmSnapshot> {
    const normalizedId = accountId.trim();
    return await this.runAccountOperation<SteamFarmSnapshot>(
      normalizedId,
      async (): Promise<SteamFarmSnapshot> => await this.resumeInternal(normalizedId)
    );
  }

  private async resumeInternal(accountId: string): Promise<SteamFarmSnapshot> {
    const normalizedId = accountId.trim();
    const configurationGeneration = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    SteamArkLog.info(TAG, 'farming resume requested; account=' + SteamArkLog.accountId(normalizedId));
    const runtime = this.runtimes.get(normalizedId);
    if (runtime === undefined ||
      this.runtimeConfigurationGenerations.get(normalizedId) !== configurationGeneration) {
      SteamArkLog.debug(TAG, 'farming resume creating runtime; account=' + SteamArkLog.accountId(normalizedId));
      return await this.startInternal(normalizedId);
    }
    try {
      const snapshot = await runtime.resume();
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.snapshots.set(normalizedId, snapshot);
      if (snapshot.nowFarming) {
        await this.ensureBackgroundTask();
      } else {
        await this.stopBackgroundTaskIfIdle();
      }
      this.emitSnapshot(snapshot);
      SteamArkLog.info(TAG, 'farming resume completed; account=' + SteamArkLog.accountId(normalizedId) +
        ', state=' + String(snapshot.state) + ', active=' + String(snapshot.nowFarming));
      return snapshot;
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming resume failed');
      SteamArkLog.error(TAG, 'farming resume failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  async play(accountId: string, appIds: Array<string>, gameName: string = ''): Promise<SteamFarmSnapshot> {
    const normalizedId = accountId.trim();
    return await this.runAccountOperation<SteamFarmSnapshot>(
      normalizedId,
      async (): Promise<SteamFarmSnapshot> => await this.playInternal(normalizedId, appIds, gameName)
    );
  }

  private async playInternal(
    accountId: string,
    appIds: Array<string>,
    gameName: string
  ): Promise<SteamFarmSnapshot> {
    const normalizedId = accountId.trim();
    const configurationGeneration = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    SteamArkLog.info(TAG, 'manual farming requested; account=' + SteamArkLog.accountId(normalizedId) +
      ', appCount=' + appIds.length.toString() + ', customName=' + String(gameName.trim().length > 0));
    const runtime = this.runtimes.get(normalizedId);
    if (runtime === undefined ||
      this.runtimeConfigurationGenerations.get(normalizedId) !== configurationGeneration) {
      throw new Error('Steam account must be started before manual farming');
    }
    try {
      const snapshot = await runtime.playManual(appIds, gameName);
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.snapshots.set(normalizedId, snapshot);
      if (snapshot.nowFarming) {
        await this.ensureBackgroundTask();
      }
      this.emitSnapshot(snapshot);
      SteamArkLog.info(TAG, 'manual farming completed; account=' + SteamArkLog.accountId(normalizedId) +
        ', state=' + String(snapshot.state) + ', active=' + String(snapshot.nowFarming));
      return snapshot;
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam manual farming failed');
      SteamArkLog.error(TAG, 'manual farming failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  async reset(accountId: string): Promise<SteamFarmSnapshot | null> {
    const normalizedId = accountId.trim();
    return await this.runAccountOperation<SteamFarmSnapshot | null>(
      normalizedId,
      async (): Promise<SteamFarmSnapshot | null> => await this.resetInternal(normalizedId)
    );
  }

  private async resetInternal(accountId: string): Promise<SteamFarmSnapshot | null> {
    const normalizedId = accountId.trim();
    const configurationGeneration = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    SteamArkLog.info(TAG, 'manual farming reset requested; account=' + SteamArkLog.accountId(normalizedId));
    const runtime = this.runtimes.get(normalizedId);
    if (runtime === undefined ||
      this.runtimeConfigurationGenerations.get(normalizedId) !== configurationGeneration) {
      SteamArkLog.debug(TAG, 'manual farming reset skipped; runtime not found; account=' +
        SteamArkLog.accountId(normalizedId));
      return null;
    }
    try {
      const snapshot = await runtime.resetManual();
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.snapshots.set(normalizedId, snapshot);
      if (snapshot.nowFarming) {
        await this.ensureBackgroundTask();
      } else {
        await this.stopBackgroundTaskIfIdle();
      }
      this.emitSnapshot(snapshot);
      SteamArkLog.info(TAG, 'manual farming reset completed; account=' + SteamArkLog.accountId(normalizedId) +
        ', state=' + String(snapshot.state));
      return snapshot;
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam manual farming reset failed');
      SteamArkLog.error(TAG, 'manual farming reset failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  async execute(request: SteamCommandRequest): Promise<SteamFarmSnapshot> {
    const accountId = request.accountId.trim();
    SteamArkLog.info(TAG, 'farming command requested; account=' + SteamArkLog.accountId(accountId) +
      ', command=' + String(request.name) + ', appCount=' + request.appIds.length.toString());
    if (accountId.length <= 0) {
      throw new Error('Steam account is required');
    }
    switch (request.name) {
      case SteamCommandName.START:
        return await this.start(accountId);
      case SteamCommandName.STOP: {
        const stopped = await this.stop(accountId);
        if (stopped === null) {
          throw new Error('Steam farming runtime is not active');
        }
        return stopped;
      }
      case SteamCommandName.PAUSE: {
        const paused = await this.pause(accountId);
        if (paused === null) {
          throw new Error('Steam farming runtime is not active');
        }
        return paused;
      }
      case SteamCommandName.RESUME:
        return await this.resume(accountId);
      case SteamCommandName.STATUS: {
        const status = this.getSnapshot(accountId);
        if (status === null) {
          throw new Error('Steam farming status is not available');
        }
        return status;
      }
      case SteamCommandName.PLAY:
        return await this.play(accountId, request.appIds, request.gameName);
      case SteamCommandName.RESET: {
        const resetSnapshot = await this.reset(accountId);
        if (resetSnapshot === null) {
          throw new Error('Steam farming runtime is not active');
        }
        return resetSnapshot;
      }
    }
    throw new Error('Unsupported Steam command');
  }

  async executeReadOnly(request: SteamCommandRequest): Promise<SteamCommandReadOnlyPayload> {
    const accountId = request.accountId.trim();
    SteamArkLog.info(TAG, 'read-only command requested; account=' + SteamArkLog.accountId(accountId) +
      ', command=' + String(request.name));
    if (accountId.length <= 0) {
      throw new Error('Steam account is required');
    }
    if (request.name === SteamCommandName.INVENTORY) {
      const page = await this.stateService.syncInventory(accountId, new SteamInventoryQuery());
      return new SteamCommandReadOnlyPayload(
        this.getSnapshot(accountId),
        page,
        null,
        'Read-only inventory synchronized'
      );
    }
    if (request.name === SteamCommandName.TWO_FACTOR) {
      const account = this.findAccount(accountId);
      if (account === null) {
        throw new Error('Steam account does not exist');
      }
      const pendingAuth = account.pendingAuth;
      const message = pendingAuth === null
        ? 'No pending Steam Guard challenge'
        : 'Steam Guard challenge status read';
      return new SteamCommandReadOnlyPayload(
        this.getSnapshot(accountId),
        null,
        pendingAuth,
        message
      );
    }
    throw new Error('Unsupported read-only Steam command');
  }

  async executeCommand(
    message: string,
    defaultAccountId: string = '',
    knownAccountIds: Array<string> = [],
    commandPrefix: string = '',
    requirePrefix: boolean = false
  ): Promise<SteamCommandResult> {
    SteamArkLog.debug(TAG, 'command message received; messageLength=' + message.length.toString() +
      ', defaultAccount=' + SteamArkLog.accountId(defaultAccountId) +
      ', knownAccounts=' + knownAccountIds.length.toString() +
      ', prefixRequired=' + String(requirePrefix));
    const options = new SteamCommandParserOptions(
      commandPrefix,
      requirePrefix,
      defaultAccountId,
      knownAccountIds
    );
    const parsed = this.commandRouter.parse(message, options);
    SteamArkLog.debug(TAG, 'command message parsed; valid=' + String(parsed.isValid()) +
      ', hasRequest=' + String(parsed.request !== null));
    if (parsed.isValid() && parsed.request !== null && this.commandRouter.isReadOnlyCommand(parsed.request.name)) {
      return await this.commandRouter.executeReadOnly(message, this, options);
    }
    return await this.commandRouter.execute(message, this, options);
  }

  async stop(accountId: string): Promise<SteamFarmSnapshot | null> {
    const normalizedId = accountId.trim();
    return await this.runAccountOperation<SteamFarmSnapshot | null>(
      normalizedId,
      async (): Promise<SteamFarmSnapshot | null> => await this.stopInternal(normalizedId)
    );
  }

  private async stopInternal(accountId: string): Promise<SteamFarmSnapshot | null> {
    const normalizedId = accountId.trim();
    const configurationGeneration = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    SteamArkLog.info(TAG, 'farming stop requested; account=' + SteamArkLog.accountId(normalizedId));
    const runtime = this.runtimes.get(normalizedId);
    if (runtime === undefined ||
      this.runtimeConfigurationGenerations.get(normalizedId) !== configurationGeneration) {
      SteamArkLog.debug(TAG, 'farming stop cancelling pending runtime; account=' +
        SteamArkLog.accountId(normalizedId));
      await this.removeRuntimeForConfiguration(normalizedId, configurationGeneration);
      await this.stopBackgroundTaskIfIdleForConfiguration(configurationGeneration);
      return null;
    }
    let snapshot: SteamFarmSnapshot | null = null;
    let failure: Error | null = null;
    try {
      snapshot = await runtime.stop();
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.snapshots.set(normalizedId, snapshot);
      this.emitSnapshot(snapshot);
    } catch (error) {
      failure = this.normalizeError(error, 'Steam farming stop failed');
      SteamArkLog.error(TAG, 'farming stop failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(failure));
    }
    try {
      const session = runtime.session;
      await this.stateService.updateSession(session);
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming session cleanup failed');
      if (failure === null) {
        failure = normalized;
      }
      SteamArkLog.warn(TAG, 'farming session cleanup failed; account=' +
        SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(normalized));
    }
    try {
      await this.removeRuntimeForConfiguration(normalizedId, configurationGeneration);
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming runtime cleanup failed');
      if (failure === null) {
        failure = normalized;
      }
      SteamArkLog.error(TAG, 'farming runtime cleanup failed; account=' +
        SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(normalized));
    }
    try {
      await this.stopBackgroundTaskIfIdleForConfiguration(configurationGeneration);
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming background cleanup failed');
      if (failure === null) {
        failure = normalized;
      }
      SteamArkLog.error(TAG, 'farming background cleanup failed; errorType=' +
        SteamArkLog.errorKind(normalized));
    }
    if (failure !== null) {
      throw failure;
    }
    SteamArkLog.info(TAG, 'farming stop completed; account=' + SteamArkLog.accountId(normalizedId) +
      ', hadSnapshot=' + String(snapshot !== null));
    return snapshot;
  }

  async removeAccount(accountId: string): Promise<void> {
    const normalizedId = accountId.trim();
    await this.runAccountOperation<void>(
      normalizedId,
      async (): Promise<void> => await this.removeAccountInternal(normalizedId)
    );
  }

  private async removeAccountInternal(accountId: string): Promise<void> {
    const normalizedId = accountId.trim();
    const configurationGeneration = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    SteamArkLog.info(TAG, 'farming account removal started; account=' + SteamArkLog.accountId(normalizedId));
    await this.stopInternal(normalizedId);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    const stateStore = new SteamArkFarmingStateStore(this.settingsStore);
    const cleared = await stateStore.clear(normalizedId);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    if (!cleared) {
      throw new Error('Steam farming state cleanup failed');
    }
    const badgeReportCleared = await this.clearBadgeReport(normalizedId);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    if (!badgeReportCleared) {
      throw new Error('Steam badge cache cleanup failed');
    }
    this.snapshots.delete(normalizedId);
    this.badgeReports.delete(normalizedId);
    SteamArkLog.info(TAG, 'farming account removal completed; account=' + SteamArkLog.accountId(normalizedId));
  }

  async stopSelected(): Promise<SteamFarmSnapshot | null> {
    const selected = this.stateService.getSelectedAccount();
    SteamArkLog.debug(TAG, 'selected farming stop requested; hasAccount=' + String(selected !== null));
    return selected === null ? null : await this.stop(selected.profile.accountId);
  }

  async pauseSelected(): Promise<SteamFarmSnapshot | null> {
    const selected = this.stateService.getSelectedAccount();
    SteamArkLog.debug(TAG, 'selected farming pause requested; hasAccount=' + String(selected !== null));
    return selected === null ? null : await this.pause(selected.profile.accountId);
  }

  async resumeSelected(): Promise<SteamFarmSnapshot | null> {
    const selected = this.stateService.getSelectedAccount();
    SteamArkLog.debug(TAG, 'selected farming resume requested; hasAccount=' + String(selected !== null));
    return selected === null ? null : await this.resume(selected.profile.accountId);
  }

  async dispose(): Promise<void> {
    const existingDispose: Promise<void> | null = this.disposePromise;
    if (existingDispose !== null && this.disposeConfigurationGeneration === this.runtimeConfigurationGeneration) {
      await existingDispose;
      return;
    }
    const disposedConfigurationGeneration: number = this.runtimeConfigurationGeneration;
    this.disposed = true;
    const runtimeBindings: Array<SteamArkFarmingRuntimeBinding> = this.captureRuntimeBindings();
    const creationHandles: Array<SteamArkFarmingRuntimeCreationHandle> = this.captureRuntimeCreationHandles();
    const disposePromise: Promise<void> = this.disposeRuntimeGeneration(
      disposedConfigurationGeneration,
      runtimeBindings,
      creationHandles
    );
    this.disposePromise = disposePromise;
    this.disposeConfigurationGeneration = disposedConfigurationGeneration;
    try {
      await disposePromise;
    } finally {
      if (this.disposePromise === disposePromise &&
        this.disposeConfigurationGeneration === disposedConfigurationGeneration) {
        this.disposePromise = null;
        this.disposeConfigurationGeneration = -1;
      }
    }
  }

  private async disposeRuntimeGeneration(
    disposedConfigurationGeneration: number,
    runtimeBindings: Array<SteamArkFarmingRuntimeBinding>,
    creationHandles: Array<SteamArkFarmingRuntimeCreationHandle>
  ): Promise<void> {
    SteamArkLog.lifecycle(TAG, 'dispose started', 'runtimeCount=' + runtimeBindings.length.toString() +
      ', configurationGeneration=' + disposedConfigurationGeneration.toString());
    let firstFailure: Error | null = null;
    const pendingOperations: Array<Promise<void>> = [];
    this.accountOperationTails.forEach((operation: Promise<void>): void => {
      pendingOperations.push(operation);
    });
    for (let index = 0; index < pendingOperations.length; index++) {
      try {
        await pendingOperations[index];
      } catch (error) {
        const normalized = this.normalizeError(error, 'Steam farming account operation failed during dispose');
        if (firstFailure === null) {
          firstFailure = normalized;
        }
        SteamArkLog.warn(TAG, 'farming account operation failed during dispose; errorType=' +
          SteamArkLog.errorKind(normalized));
      }
    }
    for (let index = 0; index < runtimeBindings.length; index++) {
      try {
        await this.closeRuntimeBinding(runtimeBindings[index]);
      } catch (error) {
        const normalized = this.normalizeError(error, 'Steam farming runtime cleanup failed during dispose');
        if (firstFailure === null) {
          firstFailure = normalized;
        }
        SteamArkLog.warn(TAG, 'farming runtime cleanup failed during dispose; account=' +
          SteamArkLog.accountId(runtimeBindings[index].runtime.accountId) + ', errorType=' +
          SteamArkLog.errorKind(normalized));
      }
    }
    for (let index = 0; index < creationHandles.length; index++) {
      try {
        await this.cancelRuntimeCreationHandle(creationHandles[index]);
      } catch (error) {
        const normalized = this.normalizeError(error, 'Steam farming runtime creation cleanup failed during dispose');
        if (firstFailure === null) {
          firstFailure = normalized;
        }
        SteamArkLog.warn(TAG, 'farming runtime creation cleanup failed during dispose; account=' +
          SteamArkLog.accountId(creationHandles[index].accountId) + ', errorType=' +
          SteamArkLog.errorKind(normalized));
      }
    }
    try {
      await this.stopBackgroundTaskForConfiguration(disposedConfigurationGeneration);
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming background cleanup failed during dispose');
      if (firstFailure === null) {
        firstFailure = normalized;
      }
      SteamArkLog.warn(TAG, 'farming background cleanup failed during dispose; errorType=' +
        SteamArkLog.errorKind(normalized));
    }
    if (this.runtimeConfigurationGeneration !== disposedConfigurationGeneration || !this.disposed) {
      SteamArkLog.debug(TAG, 'stale farming dispose cleanup skipped; disposedConfiguration=' +
        disposedConfigurationGeneration.toString() + ', currentConfiguration=' +
        this.runtimeConfigurationGeneration.toString());
      if (firstFailure !== null) {
        throw firstFailure;
      }
      return;
    }
    this.badgeReports.clear();
    this.badgeReportUpdatedAtEpochSeconds.clear();
    await this.waitForBadgeReportPersistence();
    if (this.runtimeConfigurationGeneration !== disposedConfigurationGeneration || !this.disposed) {
      SteamArkLog.debug(TAG, 'stale farming dispose persistence cleanup skipped; disposedConfiguration=' +
        disposedConfigurationGeneration.toString() + ', currentConfiguration=' +
        this.runtimeConfigurationGeneration.toString());
      if (firstFailure !== null) {
        throw firstFailure;
      }
      return;
    }
    this.badgeReportPersistenceTails.clear();
    this.snapshots.clear();
    this.accountOperationTails.clear();
    this.runtimeCreationPromises.clear();
    this.runtimeCreationConfigurationGenerations.clear();
    this.runtimeGenerations.clear();
    this.runtimeConfigurationGenerations.clear();
    this.runtimeBindings.clear();
    this.backgroundTaskId = '';
    this.backgroundTaskRunning = false;
    this.backgroundTaskConfigurationGeneration = 0;
    this.backgroundTaskSubmissionPromise = null;
    this.backgroundTaskExecutorCompletion = null;
    SteamArkLog.lifecycle(TAG, 'dispose completed', 'failed=' + String(firstFailure !== null));
    if (firstFailure !== null) {
      throw firstFailure;
    }
  }

  private async requireReadyState(): Promise<void> {
    this.requireCurrentRuntimeConfiguration(this.runtimeConfigurationGeneration);
    SteamArkLog.debug(TAG, 'farming readiness check started');
    const initialized = await this.stateService.initialize();
    this.requireCurrentRuntimeConfiguration(this.runtimeConfigurationGeneration);
    if (!initialized) {
      SteamArkLog.warn(TAG, 'farming readiness check failed; state service not initialized');
      throw new Error('Steam state service is not initialized');
    }
    SteamArkLog.debug(TAG, 'farming readiness check completed');
  }

  private async getOrCreateRuntime(account: SteamArkAccountSnapshot): Promise<ISteamArkFarmingRuntime> {
    const accountId = account.profile.accountId;
    const configurationGeneration = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    const existing = this.runtimes.get(accountId);
    if (existing !== undefined && this.runtimeConfigurationGenerations.get(accountId) === configurationGeneration) {
      SteamArkLog.debug(TAG, 'farming runtime cache hit; account=' +
        SteamArkLog.accountId(accountId));
      return existing;
    }
    if (existing !== undefined) {
      const existingConfigurationGeneration = this.runtimeConfigurationGenerations.get(accountId);
      if (existingConfigurationGeneration !== undefined) {
        this.detachRuntimeBinding(accountId, existing, existingConfigurationGeneration);
      }
      SteamArkLog.debug(TAG, 'stale farming runtime detached; account=' +
        SteamArkLog.accountId(accountId));
    }
    const pendingCreation = this.runtimeCreationPromises.get(accountId);
    if (pendingCreation !== undefined &&
      this.runtimeCreationConfigurationGenerations.get(accountId) === configurationGeneration) {
      SteamArkLog.debug(TAG, 'farming runtime creation joined; account=' +
        SteamArkLog.accountId(accountId));
      return await pendingCreation;
    }
    const generation = this.runtimeGenerationFor(accountId);
    const creation = this.createRuntime(account, generation, configurationGeneration);
    this.runtimeCreationPromises.set(accountId, creation);
    this.runtimeCreationConfigurationGenerations.set(accountId, configurationGeneration);
    try {
      return await creation;
    } finally {
      if (this.runtimeCreationPromises.get(accountId) === creation &&
        this.runtimeCreationConfigurationGenerations.get(accountId) === configurationGeneration) {
        this.runtimeCreationPromises.delete(accountId);
        this.runtimeCreationConfigurationGenerations.delete(accountId);
      }
    }
  }

  private async createRuntime(
    account: SteamArkAccountSnapshot,
    generation: number,
    configurationGeneration: number
  ): Promise<ISteamArkFarmingRuntime> {
    const accountId = account.profile.accountId;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    const factory = this.runtimeFactory;
    if (factory === null || !factory.isEnabled) {
      SteamArkLog.warn(TAG, 'farming runtime creation blocked; account=' +
        SteamArkLog.accountId(accountId));
      throw new Error(this.availabilityMessage());
    }
    SteamArkLog.info(TAG, 'farming runtime creation started; account=' +
      SteamArkLog.accountId(accountId) + ', generation=' + generation.toString() +
      ', configurationGeneration=' + configurationGeneration.toString());
    const credentials = await this.stateService.getCredentials(accountId);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    const proxyPassword = await this.stateService.getProxyPassword(accountId);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    const stateStore: IStateStore = new SteamArkFarmingStateStore(this.settingsStore);
    const runtime = factory.create(
      this.copyProfile(account.profile),
      this.copyConfig(account.config),
      credentials,
      stateStore,
      proxyPassword
    );
    if (this.runtimeGenerationFor(accountId) !== generation ||
      !this.isCurrentRuntimeConfiguration(configurationGeneration)) {
      try {
        await runtime.dispose();
      } catch (error) {
        const normalized = this.normalizeError(error, 'Steam farming runtime cancellation cleanup failed');
        SteamArkLog.error(TAG, 'cancelled farming runtime dispose failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(normalized));
        throw normalized;
      }
      throw new Error('Steam farming runtime creation was cancelled');
    }
    const snapshotListener: SteamFarmEventListener = (event: SteamFarmEvent): void => {
      this.handleRuntimeFarmEvent(runtime, event, configurationGeneration);
    };
    const sessionListener: SteamSessionEventListener = (session: SteamSessionSnapshot): void => {
      this.handleRuntimeSession(runtime, session, configurationGeneration);
    };
    const binding = new SteamArkFarmingRuntimeBinding(
      runtime,
      snapshotListener,
      sessionListener,
      configurationGeneration
    );
    runtime.addEventListener(snapshotListener);
    runtime.addSessionListener(sessionListener);
    this.runtimes.set(accountId, runtime);
    this.runtimeConfigurationGenerations.set(accountId, configurationGeneration);
    this.runtimeBindings.set(accountId, binding);
    try {
      const loaded = await runtime.load();
      if (this.runtimeGenerationFor(accountId) !== generation || this.runtimes.get(accountId) !== runtime ||
        this.runtimeConfigurationGenerations.get(accountId) !== configurationGeneration ||
        !this.isCurrentRuntimeConfiguration(configurationGeneration)) {
        if (this.runtimes.get(accountId) === runtime &&
          this.runtimeConfigurationGenerations.get(accountId) === configurationGeneration) {
          this.detachRuntimeBinding(accountId, runtime, configurationGeneration);
          await runtime.dispose();
        }
        throw new Error('Steam farming runtime load became stale');
      }
      this.snapshots.set(accountId, loaded);
      this.emitSnapshot(loaded);
      SteamArkLog.info(TAG, 'farming runtime state restored; account=' +
        SteamArkLog.accountId(accountId) + ', state=' + String(loaded.state));
      return runtime;
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming state restore failed');
      SteamArkLog.error(TAG, 'farming runtime state restore failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(normalized));
      let cleanupFailure: Error | null = null;
      if (this.runtimes.get(accountId) === runtime &&
        this.runtimeConfigurationGenerations.get(accountId) === configurationGeneration) {
        this.detachRuntimeBinding(accountId, runtime, configurationGeneration);
        try {
          await runtime.dispose();
        } catch (disposeError) {
          cleanupFailure = this.normalizeError(disposeError, 'Steam farming runtime dispose failed');
          SteamArkLog.warn(TAG, 'stale farming runtime dispose failed; account=' +
            SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(cleanupFailure));
        }
      }
      if (cleanupFailure !== null) {
        throw cleanupFailure;
      }
      throw normalized;
    }
  }

  private captureRuntimeBindings(): Array<SteamArkFarmingRuntimeBinding> {
    const bindings: Array<SteamArkFarmingRuntimeBinding> = [];
    this.runtimeBindings.forEach((binding: SteamArkFarmingRuntimeBinding): void => {
      bindings.push(binding);
    });
    return bindings;
  }

  private captureRuntimeCreationHandles(): Array<SteamArkFarmingRuntimeCreationHandle> {
    const handles: Array<SteamArkFarmingRuntimeCreationHandle> = [];
    this.runtimeCreationPromises.forEach((creation: Promise<ISteamArkFarmingRuntime>, accountId: string): void => {
      const configuredGeneration = this.runtimeCreationConfigurationGenerations.get(accountId);
      const configurationGeneration = configuredGeneration === undefined
        ? this.runtimeConfigurationGeneration
        : configuredGeneration;
      handles.push(new SteamArkFarmingRuntimeCreationHandle(
        accountId,
        this.runtimeGenerationFor(accountId),
        configurationGeneration,
        creation
      ));
    });
    return handles;
  }

  private async cancelRuntimeCreationHandle(handle: SteamArkFarmingRuntimeCreationHandle): Promise<void> {
    if (this.runtimeCreationPromises.get(handle.accountId) === handle.creation &&
      this.runtimeCreationConfigurationGenerations.get(handle.accountId) === handle.configurationGeneration) {
      this.bumpRuntimeGeneration(handle.accountId);
    }
    try {
      await handle.creation;
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming runtime creation failed during disposal');
      if (!this.isExpectedRuntimeCancellation(normalized)) {
        throw normalized;
      }
    }
  }

  private async closeRuntimeBinding(binding: SteamArkFarmingRuntimeBinding): Promise<void> {
    const accountId = binding.runtime.accountId;
    if (this.runtimes.get(accountId) === binding.runtime &&
      this.runtimeConfigurationGenerations.get(accountId) === binding.configurationGeneration) {
      this.bumpRuntimeGeneration(accountId);
      this.detachRuntimeBinding(accountId, binding.runtime, binding.configurationGeneration);
    }
    let firstFailure: Error | null = null;
    try {
      await binding.runtime.stop();
    } catch (error) {
      firstFailure = this.normalizeError(error, 'Steam farming runtime stop failed during disposal');
      SteamArkLog.warn(TAG, 'farming runtime stop failed during dispose; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(firstFailure));
    }
    try {
      await binding.runtime.dispose();
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming runtime dispose failed during disposal');
      if (firstFailure === null) {
        firstFailure = normalized;
      }
      SteamArkLog.warn(TAG, 'farming runtime dispose failed during dispose; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(normalized));
    }
    if (firstFailure !== null) {
      throw firstFailure;
    }
  }

  private async removeRuntimeForConfiguration(
    accountId: string,
    configurationGeneration: number
  ): Promise<void> {
    const normalizedId = accountId.trim();
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration)) {
      return;
    }
    this.bumpRuntimeGeneration(normalizedId);
    let failure: Error | null = null;
    const pendingCreation = this.runtimeCreationPromises.get(normalizedId);
    if (pendingCreation !== undefined &&
      this.runtimeCreationConfigurationGenerations.get(normalizedId) === configurationGeneration) {
      try {
        await pendingCreation;
      } catch (error) {
        const normalized = this.normalizeError(error, 'Steam farming runtime creation failed during removal');
        SteamArkLog.debug(TAG, 'farming runtime creation cancelled during removal; account=' +
          SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(normalized));
        if (!this.isExpectedRuntimeCancellation(normalized)) {
          failure = normalized;
        }
      }
    }
    const runtime = this.runtimes.get(normalizedId);
    if (runtime === undefined || this.runtimeConfigurationGenerations.get(normalizedId) !== configurationGeneration) {
      if (failure !== null) {
        throw failure;
      }
      return;
    }
    this.detachRuntimeBinding(normalizedId, runtime, configurationGeneration);
    SteamArkLog.info(TAG, 'farming runtime removal started; account=' + SteamArkLog.accountId(normalizedId));
    try {
      await runtime.dispose();
      SteamArkLog.info(TAG, 'farming runtime removed; account=' + SteamArkLog.accountId(normalizedId));
    } catch (error) {
      const normalized = this.normalizeError(error, 'dispose');
      if (failure === null) {
        failure = normalized;
      }
      SteamArkLog.warn(TAG, 'farming runtime dispose failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
    }
    if (failure !== null) {
      throw failure;
    }
  }

  private detachRuntimeBinding(
    accountId: string,
    runtime: ISteamArkFarmingRuntime,
    configurationGeneration: number = this.runtimeConfigurationGeneration
  ): void {
    const binding = this.runtimeBindings.get(accountId);
    if (binding !== undefined && binding.runtime === runtime &&
      binding.configurationGeneration === configurationGeneration) {
      runtime.removeEventListener(binding.snapshotListener);
      runtime.removeSessionListener(binding.sessionListener);
      this.runtimeBindings.delete(accountId);
    }
    if (this.runtimes.get(accountId) === runtime &&
      this.runtimeConfigurationGenerations.get(accountId) === configurationGeneration) {
      this.runtimes.delete(accountId);
      this.runtimeConfigurationGenerations.delete(accountId);
    }
  }

  private handleRuntimeFarmEvent(
    runtime: ISteamArkFarmingRuntime,
    event: SteamFarmEvent,
    configurationGeneration: number
  ): void {
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      runtime.accountId !== event.snapshot.accountId || this.runtimes.get(event.snapshot.accountId) !== runtime ||
      this.runtimeConfigurationGenerations.get(event.snapshot.accountId) !== configurationGeneration) {
      SteamArkLog.debug(TAG, 'stale farming runtime event ignored; account=' +
        SteamArkLog.accountId(event.snapshot.accountId));
      return;
    }
    SteamArkLog.debug(TAG, 'farming runtime event received; account=' +
      SteamArkLog.accountId(event.snapshot.accountId) + ', type=' + String(event.type) +
      ', state=' + String(event.snapshot.state) + ', active=' + String(event.snapshot.nowFarming));
    this.snapshots.set(event.snapshot.accountId, event.snapshot);
    this.emitSnapshot(event.snapshot);
    if (event.type === SteamFarmEventType.BADGE_SYNCED && event.badgeReport !== null) {
      const updatedAtEpochSeconds = Math.floor(Date.now() / 1000);
      this.badgeReports.set(event.snapshot.accountId, event.badgeReport);
      this.badgeReportUpdatedAtEpochSeconds.set(event.snapshot.accountId, updatedAtEpochSeconds);
      this.persistBadgeReport(event.snapshot.accountId, event.badgeReport, updatedAtEpochSeconds);
      this.emit(new SteamArkFarmingEvent(
        event.snapshot.accountId,
        SteamArkFarmingEventType.BADGE_SYNCED,
        event.snapshot,
        null,
        event.message,
        event.badgeReport
      ));
      SteamArkLog.info(TAG, 'badge synchronization event handled; account=' +
        SteamArkLog.accountId(event.snapshot.accountId) + ', pages=' + event.badgeReport.pages.length.toString() +
        ', games=' + event.badgeReport.games.length.toString());
    }
    if (!event.snapshot.nowFarming) {
      this.markBackgroundTaskStoppedIfIdle();
      void this.stopBackgroundTaskIfIdle();
    }
  }

  private handleRuntimeSession(
    runtime: ISteamArkFarmingRuntime,
    session: SteamSessionSnapshot,
    configurationGeneration: number
  ): void {
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      runtime.accountId !== session.accountId || this.runtimes.get(session.accountId) !== runtime ||
      this.runtimeConfigurationGenerations.get(session.accountId) !== configurationGeneration) {
      SteamArkLog.debug(TAG, 'stale farming runtime session ignored; account=' +
        SteamArkLog.accountId(session.accountId));
      return;
    }
    SteamArkLog.state(TAG, 'runtime', String(session.state), 'account=' +
      SteamArkLog.accountId(session.accountId) + ', steamId64=' + SteamArkLog.steamId64(session.steamId64));
    void this.stateService.updateSession(session).catch((error: Error): void => {
      SteamArkLog.warn(TAG, 'farming session state update failed; account=' +
        SteamArkLog.accountId(session.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    });
    this.emit(new SteamArkFarmingEvent(
      session.accountId,
      SteamArkFarmingEventType.SESSION_CHANGED,
      this.getSnapshot(session.accountId),
      session
    ));
  }

  private emitSnapshot(snapshot: SteamFarmSnapshot): void {
    SteamArkLog.debug(TAG, 'farming snapshot emitted; account=' + SteamArkLog.accountId(snapshot.accountId) +
      ', state=' + String(snapshot.state) + ', games=' + snapshot.games.length.toString());
    this.emit(new SteamArkFarmingEvent(
      snapshot.accountId,
      SteamArkFarmingEventType.SNAPSHOT_CHANGED,
      snapshot,
      null
    ));
  }

  private emit(event: SteamArkFarmingEvent): void {
    SteamArkLog.debug(TAG, 'farming event dispatch started; type=' + String(event.type) +
      ', account=' + SteamArkLog.accountId(event.accountId) + ', listeners=' + this.listeners.size.toString());
    const currentListeners: Array<SteamArkFarmingEventListener> = [];
    this.listeners.forEach((listener: SteamArkFarmingEventListener): void => {
      currentListeners.push(listener);
    });
    for (let index = 0; index < currentListeners.length; index++) {
      try {
        currentListeners[index](event);
      } catch (error) {
        const normalized = this.normalizeError(error, 'listener');
        SteamArkLog.warn(TAG, 'farming event listener failed; errorType=' + SteamArkLog.errorKind(normalized));
      }
    }
  }

  private async ensureBackgroundTask(): Promise<void> {
    const configurationGeneration = this.runtimeConfigurationGeneration;
    await this.runBackgroundTaskTransition(
      async (): Promise<void> => await this.ensureBackgroundTaskInternal(configurationGeneration)
    );
  }

  private async ensureBackgroundTaskInternal(configurationGeneration: number): Promise<void> {
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    while (true) {
      const pendingSubmission = this.backgroundTaskSubmissionPromise;
      if (pendingSubmission !== null) {
        SteamArkLog.debug(TAG, 'background farming task submission already pending');
        await pendingSubmission;
        if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
          this.activeRuntimeCountForConfiguration(configurationGeneration) <= 0) {
          return;
        }
        if (this.backgroundTaskRunning &&
          this.backgroundTaskConfigurationGeneration !== configurationGeneration) {
          await this.stopBackgroundTaskForConfigurationInternal(this.backgroundTaskConfigurationGeneration);
          continue;
        }
        if (this.backgroundTaskRunning) {
          return;
        }
        continue;
      }
      // A live executor belongs to the current task generation and is reused.
      if (this.backgroundTaskRunning) {
        if (this.backgroundTaskConfigurationGeneration !== configurationGeneration) {
          await this.stopBackgroundTaskForConfigurationInternal(this.backgroundTaskConfigurationGeneration);
          continue;
        }
        SteamArkLog.debug(TAG, 'background farming task already running; taskId=' +
          SteamArkLog.accountId(this.backgroundTaskId));
        return;
      }
      const pendingCompletion = this.backgroundTaskExecutorCompletion;
      if (pendingCompletion !== null) {
        SteamArkLog.debug(TAG, 'waiting for previous background farming executor to finish');
        await pendingCompletion.promise;
        if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
          this.activeRuntimeCountForConfiguration(configurationGeneration) <= 0) {
          return;
        }
        if (this.backgroundTaskRunning &&
          this.backgroundTaskConfigurationGeneration !== configurationGeneration) {
          await this.stopBackgroundTaskForConfigurationInternal(this.backgroundTaskConfigurationGeneration);
          continue;
        }
        if (this.backgroundTaskRunning) {
          return;
        }
        continue;
      }
      this.backgroundTaskGeneration++;
      const generation = this.backgroundTaskGeneration;
      this.backgroundTaskRunning = true;
      this.backgroundTaskConfigurationGeneration = configurationGeneration;
      const completion = new SteamArkBackgroundTaskCompletion();
      this.backgroundTaskExecutorCompletion = completion;
      SteamArkLog.info(TAG, 'background farming task starting; generation=' + generation.toString() +
        ', activeAccounts=' + this.activeRuntimeCountForConfiguration(configurationGeneration).toString());
      const executor: NGFTaskExecutor = async (
        _taskId: string,
        updateCallback: (progress: number, total: number, message: string) => void
      ): Promise<void> => {
        completion.markExecutorStarted();
        try {
          updateCallback(0, 0, 'Steam farming runtime is running');
          while (this.backgroundTaskRunning && this.backgroundTaskGeneration === generation &&
            this.backgroundTaskConfigurationGeneration === configurationGeneration &&
            this.isCurrentRuntimeConfiguration(configurationGeneration)) {
            await this.waitForBackgroundUpdate();
            if (this.backgroundTaskRunning && this.backgroundTaskGeneration === generation &&
              this.backgroundTaskConfigurationGeneration === configurationGeneration &&
              this.isCurrentRuntimeConfiguration(configurationGeneration)) {
              updateCallback(0, 0, 'Active farming accounts: ' +
                this.activeRuntimeCountForConfiguration(configurationGeneration).toString());
            }
          }
          updateCallback(0, 0, 'Steam farming runtime stopped');
        } finally {
          completion.complete();
          this.clearBackgroundTaskCompletion(completion);
        }
      };
      const submission = this.submitBackgroundTask(generation, configurationGeneration, executor, completion);
      this.backgroundTaskSubmissionPromise = submission;
      try {
        await submission;
      } finally {
        if (this.backgroundTaskSubmissionPromise === submission) {
          this.backgroundTaskSubmissionPromise = null;
        }
      }
      return;
    }
  }

  private async submitBackgroundTask(
    generation: number,
    configurationGeneration: number,
    executor: NGFTaskExecutor,
    completion: SteamArkBackgroundTaskCompletion
  ): Promise<void> {
    try {
       const submittedTaskId: string = await this.backgroundTaskHost.submit(this.taskName, executor);
       if (!this.backgroundTaskRunning || this.backgroundTaskGeneration !== generation ||
         this.backgroundTaskConfigurationGeneration !== configurationGeneration ||
         !this.isCurrentRuntimeConfiguration(configurationGeneration)) {
         SteamArkLog.debug(TAG, 'background task submission became stale; generation=' + generation.toString());
         completion.complete();
         this.clearBackgroundTaskCompletion(completion);
         return;
       }
      this.backgroundTaskId = submittedTaskId;
      SteamArkLog.info(TAG, 'background farming task submitted; generation=' + generation.toString());
      this.emit(new SteamArkFarmingEvent('', SteamArkFarmingEventType.BACKGROUND_TASK_CHANGED, null, null, this.backgroundTaskId));
    } catch (error) {
      if (this.backgroundTaskGeneration !== generation ||
        this.backgroundTaskConfigurationGeneration !== configurationGeneration ||
        !this.isCurrentRuntimeConfiguration(configurationGeneration)) {
        completion.complete();
        this.clearBackgroundTaskCompletion(completion);
        return;
      }
      this.backgroundTaskRunning = false;
      this.backgroundTaskId = '';
      completion.complete();
      this.clearBackgroundTaskCompletion(completion);
      const normalized = this.normalizeError(error, 'background task submission failed');
      SteamArkLog.error(TAG, 'background farming task submission failed; errorType=' +
        SteamArkLog.errorKind(normalized));
      this.emit(new SteamArkFarmingEvent('', SteamArkFarmingEventType.ERROR, null, null, normalized.message));
      throw normalized;
    }
  }

  private async stopBackgroundTaskIfIdle(): Promise<void> {
    const configurationGeneration = this.runtimeConfigurationGeneration;
    await this.stopBackgroundTaskIfIdleForConfiguration(configurationGeneration);
  }

  private async stopBackgroundTaskIfIdleForConfiguration(configurationGeneration: number): Promise<void> {
    await this.runBackgroundTaskTransition(
      async (): Promise<void> => await this.stopBackgroundTaskIfIdleInternal(configurationGeneration)
    );
  }

  private async stopBackgroundTaskForConfiguration(configurationGeneration: number): Promise<void> {
    await this.runBackgroundTaskTransition(
      async (): Promise<void> => await this.stopBackgroundTaskForConfigurationInternal(configurationGeneration)
    );
  }

  private async stopBackgroundTaskIfIdleInternal(configurationGeneration: number): Promise<void> {
    if (this.backgroundTaskConfigurationGeneration !== configurationGeneration ||
      (this.runtimeConfigurationGeneration !== configurationGeneration && !this.disposed)) {
      return;
    }
    if (this.activeRuntimeCountForConfiguration(configurationGeneration) > 0) {
      return;
    }
    const pendingSubmission = this.backgroundTaskSubmissionPromise;
    const pendingCompletion = this.backgroundTaskExecutorCompletion;
    if (!this.backgroundTaskRunning && pendingSubmission === null && pendingCompletion === null) {
      return;
    }
    this.markBackgroundTaskStoppedForConfiguration(configurationGeneration);
    if (pendingSubmission !== null) {
      try {
        await pendingSubmission;
      } catch (error) {
        SteamArkLog.debug(TAG, 'background task submission settled during stop; errorType=' +
          SteamArkLog.errorKind(error));
      }
    }
    if (pendingCompletion !== null) {
      if (pendingCompletion.hasExecutorStarted()) {
        SteamArkLog.debug(TAG, 'waiting for background farming executor to finish');
        await pendingCompletion.promise;
      } else {
        // A host may accept a task before scheduling its executor. Once the
        // generation is stopped, there is no work to wait for; a late executor
        // observes the stopped generation and exits immediately.
        pendingCompletion.complete();
        this.clearBackgroundTaskCompletion(pendingCompletion);
      }
    }
    this.clearBackgroundTaskCompletion(pendingCompletion);
  }

  private async stopBackgroundTaskForConfigurationInternal(configurationGeneration: number): Promise<void> {
    if (this.backgroundTaskConfigurationGeneration !== configurationGeneration) {
      return;
    }
    const pendingSubmission = this.backgroundTaskSubmissionPromise;
    const pendingCompletion = this.backgroundTaskExecutorCompletion;
    if (!this.backgroundTaskRunning && pendingSubmission === null && pendingCompletion === null) {
      return;
    }
    this.markBackgroundTaskStoppedForConfiguration(configurationGeneration);
    if (pendingSubmission !== null) {
      try {
        await pendingSubmission;
      } catch (error) {
        SteamArkLog.debug(TAG, 'background task submission settled during configuration stop; errorType=' +
          SteamArkLog.errorKind(error));
      }
    }
    if (pendingCompletion !== null) {
      if (pendingCompletion.hasExecutorStarted()) {
        await pendingCompletion.promise;
      } else {
        pendingCompletion.complete();
        this.clearBackgroundTaskCompletion(pendingCompletion);
      }
    }
    this.clearBackgroundTaskCompletion(pendingCompletion);
  }

  /** Publishes the stopped state before asynchronous task cleanup completes. */
  private markBackgroundTaskStoppedIfIdle(): boolean {
    const configurationGeneration = this.backgroundTaskConfigurationGeneration;
    if (this.activeRuntimeCountForConfiguration(configurationGeneration) > 0 || !this.backgroundTaskRunning) {
      return false;
    }
    return this.markBackgroundTaskStoppedForConfiguration(configurationGeneration);
  }

  private markBackgroundTaskStoppedForConfiguration(configurationGeneration: number): boolean {
    if (this.backgroundTaskConfigurationGeneration !== configurationGeneration || !this.backgroundTaskRunning) {
      return false;
    }
    this.backgroundTaskRunning = false;
    this.backgroundTaskGeneration++;
    this.backgroundTaskId = '';
    this.backgroundTaskConfigurationGeneration = 0;
    SteamArkLog.info(TAG, 'background farming task stopping for disposed configuration; configurationGeneration=' +
      configurationGeneration.toString());
    this.emit(new SteamArkFarmingEvent('', SteamArkFarmingEventType.BACKGROUND_TASK_CHANGED));
    return true;
  }

  private async runBackgroundTaskTransition(action: () => Promise<void>): Promise<void> {
    const previous = this.backgroundTaskTransitionTail;
    const transition = new SteamArkBackgroundTaskCompletion();
    this.backgroundTaskTransitionTail = transition.promise;
    await previous;
    try {
      await action();
    } finally {
      transition.complete();
    }
  }

  private clearBackgroundTaskCompletion(
    completion: SteamArkBackgroundTaskCompletion | null
  ): void {
    if (completion !== null && this.backgroundTaskExecutorCompletion === completion) {
      this.backgroundTaskExecutorCompletion = null;
    }
  }

  private activeRuntimeCount(): number {
    if (this.disposed) {
      return 0;
    }
    return this.activeRuntimeCountForConfiguration(this.runtimeConfigurationGeneration);
  }

  private activeRuntimeCountForConfiguration(configurationGeneration: number): number {
    let count = 0;
    this.runtimes.forEach((_runtime: ISteamArkFarmingRuntime, accountId: string): void => {
      if (this.runtimeConfigurationGenerations.get(accountId) !== configurationGeneration) {
        return;
      }
      const snapshot = this.snapshots.get(accountId);
      if (snapshot !== undefined && snapshot.nowFarming) {
        count++;
      }
    });
    return count;
  }

  private async waitForBackgroundUpdate(): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, this.backgroundUpdateIntervalMs);
    });
  }

  private badgeReportKey(accountId: string): string {
    return BADGE_REPORT_KEY_PREFIX + encodeURIComponent(accountId.trim());
  }

  private persistBadgeReport(
    accountId: string,
    report: SteamBadgeSyncReport,
    updatedAtEpochSeconds: number
  ): void {
    const normalizedId = accountId.trim();
    if (normalizedId.length <= 0) {
      return;
    }
    const document = new SteamArkPersistedBadgeReport(
      normalizedId,
      report,
      updatedAtEpochSeconds
    );
    const serialized = JSON.stringify(document);
    const persistence = this.enqueueBadgeReportPersistence(
      normalizedId,
      async (): Promise<void> => {
        const ready = await this.settingsStore.waitUntilReady();
        if (!ready) {
          SteamArkLog.warn(TAG, 'badge cache write skipped; settings store not ready; account=' +
            SteamArkLog.accountId(normalizedId));
          return;
        }
        const saved = await this.settingsStore.setStringAsync(this.badgeReportKey(normalizedId), serialized);
        if (!saved) {
          SteamArkLog.warn(TAG, 'badge cache write rejected; account=' + SteamArkLog.accountId(normalizedId));
          return;
        }
        SteamArkLog.debug(TAG, 'badge cache saved; account=' + SteamArkLog.accountId(normalizedId) +
          ', games=' + report.games.length.toString() + ', communityBadges=' +
          report.communityBadges.length.toString());
      }
    );
    void persistence.catch((error: Error): void => {
      SteamArkLog.warn(TAG, 'badge cache write failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    });
  }

  private restoreBadgeReport(accountId: string): void {
    const normalizedId = accountId.trim();
    if (normalizedId.length <= 0 || this.badgeReports.has(normalizedId)) {
      return;
    }
    const serialized = this.settingsStore.getString(this.badgeReportKey(normalizedId), '');
    if (serialized.trim().length <= 0) {
      return;
    }
    try {
      const root = SteamJsonParser.parse(serialized, steamArkCoreLogger);
      const updatedAtEpochSeconds = this.readInteger(root.getProperty('updatedAtEpochSeconds'), 0);
      if (updatedAtEpochSeconds <= 0) {
        throw new Error('badge cache sync timestamp is invalid');
      }
      const report = this.readBadgeReport(root, normalizedId);
      if (report === null) {
        throw new Error('badge cache is invalid');
      }
      this.badgeReports.set(normalizedId, report);
      this.badgeReportUpdatedAtEpochSeconds.set(normalizedId, updatedAtEpochSeconds);
      SteamArkLog.info(TAG, 'badge cache restored; account=' + SteamArkLog.accountId(normalizedId) +
        ', games=' + report.games.length.toString() + ', communityBadges=' +
        report.communityBadges.length.toString());
    } catch (error) {
      const removal = this.enqueueBadgeReportPersistence(
        normalizedId,
        async (): Promise<void> => {
          const ready = await this.settingsStore.waitUntilReady();
          if (ready) {
            await this.settingsStore.setStringAsync(this.badgeReportKey(normalizedId), '');
          }
        }
      );
      void removal.catch((removalError: Error): void => {
        SteamArkLog.warn(TAG, 'invalid badge cache cleanup failed; account=' +
          SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(removalError));
      });
      SteamArkLog.warn(TAG, 'badge cache ignored; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private readBadgeReport(root: SteamJsonValue, accountId: string): SteamBadgeSyncReport | null {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      return null;
    }
    if (this.readInteger(root.getProperty('version'), 0) !== BADGE_REPORT_CACHE_VERSION ||
      this.readString(root.getProperty('accountId'), '') !== accountId) {
      return null;
    }
    const games = this.readBadgeGames(root.getProperty('games'));
    const communityBadges = this.readCommunityBadges(root.getProperty('communityBadges'));
    return new SteamBadgeSyncReport(
      games,
      this.readInteger(root.getProperty('requestedPageCount'), 0),
      this.readInteger(root.getProperty('fetchedPageCount'), 0),
      this.readInteger(root.getProperty('duplicateGameCount'), 0),
      [],
      this.readStringArray(root.getProperty('warnings')),
      communityBadges
    );
  }

  private readBadgeGames(value: SteamJsonValue | null): Array<SteamGameDrop> {
    const games: Array<SteamGameDrop> = [];
    if (value === null || value.kind !== SteamJsonValueKind.ARRAY) {
      return games;
    }
    for (let index = 0; index < value.items.length; index++) {
      const item = value.items[index];
      if (item.kind !== SteamJsonValueKind.OBJECT) {
        continue;
      }
      const appId = this.readString(item.getProperty('appId'), '');
      if (appId.length <= 0) {
        continue;
      }
      games.push(new SteamGameDrop(
        appId,
        this.readString(item.getProperty('name'), ''),
        this.readNumber(item.getProperty('hoursPlayed'), 0),
        this.readInteger(item.getProperty('cardsRemaining'), 0),
        this.readInteger(item.getProperty('badgeLevel'), 0),
        this.readBoolean(item.getProperty('marketable'), false),
        this.readString(item.getProperty('playableAppId'), appId),
        this.readString(item.getProperty('imageUrl'), ''),
        this.readString(item.getProperty('storeUrl'), ''),
        this.readString(item.getProperty('badgeImageUrl'), ''),
        this.readString(item.getProperty('badgeUrl'), '')
      ));
    }
    return games;
  }

  private readCommunityBadges(value: SteamJsonValue | null): Array<SteamCommunityBadge> {
    const badges: Array<SteamCommunityBadge> = [];
    if (value === null || value.kind !== SteamJsonValueKind.ARRAY) {
      return badges;
    }
    for (let index = 0; index < value.items.length; index++) {
      const item = value.items[index];
      if (item.kind !== SteamJsonValueKind.OBJECT) {
        continue;
      }
      const badgeId = this.readString(item.getProperty('badgeId'), '');
      if (badgeId.length <= 0) {
        continue;
      }
      badges.push(new SteamCommunityBadge(
        badgeId,
        this.readString(item.getProperty('name'), ''),
        this.readNumber(item.getProperty('experience'), 0),
        this.readString(item.getProperty('imageUrl'), ''),
        this.readString(item.getProperty('badgeUrl'), '')
      ));
    }
    return badges;
  }

  private async clearBadgeReport(accountId: string): Promise<boolean> {
    const normalizedId = accountId.trim();
    if (normalizedId.length <= 0) {
      return false;
    }
    this.badgeReports.delete(normalizedId);
    this.badgeReportUpdatedAtEpochSeconds.delete(normalizedId);
    let cleared: boolean = false;
    await this.enqueueBadgeReportPersistence(
      normalizedId,
      async (): Promise<void> => {
        const ready = await this.settingsStore.waitUntilReady();
        if (!ready) {
          return;
        }
        cleared = await this.settingsStore.setStringAsync(this.badgeReportKey(normalizedId), '');
      }
    );
    SteamArkLog.debug(TAG, 'badge cache clear completed; account=' + SteamArkLog.accountId(normalizedId) +
      ', success=' + String(cleared));
    return cleared;
  }

  private async waitForBadgeReportPersistence(): Promise<void> {
    const pending: Array<Promise<void>> = [];
    this.badgeReportPersistenceTails.forEach((tail: Promise<void>): void => {
      pending.push(tail);
    });
    for (let index = 0; index < pending.length; index++) {
      try {
        await pending[index];
      } catch (error) {
        SteamArkLog.warn(TAG, 'badge cache persistence settled with failure; errorType=' +
          SteamArkLog.errorKind(error));
      }
    }
  }

  private async enqueueBadgeReportPersistence(
    accountId: string,
    action: () => Promise<void>
  ): Promise<void> {
    const previous = this.badgeReportPersistenceTails.get(accountId);
    const operation: Promise<void> = previous === undefined
      ? action()
      : previous.catch((error: Error): void => {
        SteamArkLog.warn(TAG, 'previous badge cache persistence failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }).then((): Promise<void> => action());
    this.badgeReportPersistenceTails.set(accountId, operation);
    try {
      await operation;
    } finally {
      if (this.badgeReportPersistenceTails.get(accountId) === operation) {
        this.badgeReportPersistenceTails.delete(accountId);
      }
    }
  }

  private readString(value: SteamJsonValue | null, defaultValue: string): string {
    if (value === null || value.kind !== SteamJsonValueKind.STRING) {
      return defaultValue;
    }
    return value.stringValue;
  }

  private readBoolean(value: SteamJsonValue | null, defaultValue: boolean): boolean {
    if (value === null || value.kind !== SteamJsonValueKind.BOOLEAN) {
      return defaultValue;
    }
    return value.booleanValue;
  }

  private readNumber(value: SteamJsonValue | null, defaultValue: number): number {
    if (value === null || value.kind !== SteamJsonValueKind.NUMBER) {
      return defaultValue;
    }
    const parsed = Number(value.numberValue);
    return Number.isNaN(parsed) ? defaultValue : parsed;
  }

  private readInteger(value: SteamJsonValue | null, defaultValue: number): number {
    const parsed = this.readNumber(value, defaultValue);
    return Number.isSafeInteger(parsed) ? parsed : defaultValue;
  }

  private readStringArray(value: SteamJsonValue | null): Array<string> {
    const result: Array<string> = [];
    if (value === null || value.kind !== SteamJsonValueKind.ARRAY) {
      return result;
    }
    for (let index = 0; index < value.items.length; index++) {
      const item = value.items[index];
      if (item.kind === SteamJsonValueKind.STRING && item.stringValue.length > 0) {
        result.push(item.stringValue);
      }
    }
    return result;
  }

  private markSnapshotError(accountId: string, message: string): void {
    const existing = this.snapshots.get(accountId);
    if (existing === undefined) {
      return;
    }
    const failed = new SteamFarmSnapshot(
      existing.accountId,
      SteamFarmState.ERROR,
      false,
      false,
      [],
      existing.games,
      existing.estimatedSeconds,
      existing.updatedAtEpochSeconds,
      message,
      existing.manualMode,
      existing.manualAppIds,
      existing.manualGameName
    );
    this.snapshots.set(accountId, failed);
    this.emitSnapshot(failed);
  }

  private findAccount(accountId: string): SteamArkAccountSnapshot | null {
    const snapshot: SteamArkStateSnapshot = this.stateService.getSnapshot();
    for (let index = 0; index < snapshot.accounts.length; index++) {
      if (snapshot.accounts[index].profile.accountId === accountId) {
        return snapshot.accounts[index];
      }
    }
    return null;
  }

  private copyProfile(profile: SteamAccountProfile): SteamAccountProfile {
    return new SteamAccountProfile(
      profile.accountId,
      profile.displayName,
      profile.steamId64,
      profile.enabled,
      new SteamProxySettings(profile.proxy.kind, profile.proxy.host, profile.proxy.port, profile.proxy.username),
      profile.avatarUrl,
      profile.profileBackgroundImageUrl,
      profile.profileBackgroundMovieUrl,
      profile.profileBackgroundTiled,
      profile.avatarFrameUrl,
      profile.summary,
      profile.level,
      profile.countryCode,
      profile.walletBalance,
      profile.walletCurrency,
      profile.miniProfileBackgroundImageUrl,
      profile.miniProfileBackgroundMovieUrl
    );
  }

  private copyConfig(config: SteamBotConfig): SteamBotConfig {
    const copy = new SteamBotConfig(config.accountId);
    copy.enabled = config.enabled;
    copy.hoursUntilCardDrops = config.hoursUntilCardDrops;
    copy.maxGamesPlayedConcurrently = config.maxGamesPlayedConcurrently;
    copy.farmingPreferences = config.farmingPreferences;
    copy.farmingOrders = config.farmingOrders.slice();
    copy.gamesPlayedWhileIdle = config.gamesPlayedWhileIdle.slice();
    copy.blacklist = config.blacklist.slice();
    copy.priorityAppIds = config.priorityAppIds.slice();
    return copy;
  }

  private runtimeGenerationFor(accountId: string): number {
    const current = this.runtimeGenerations.get(accountId);
    return current === undefined ? 0 : current;
  }

  private bumpRuntimeGeneration(accountId: string): number {
    const next = this.runtimeGenerationFor(accountId) + 1;
    this.runtimeGenerations.set(accountId, next);
    return next;
  }

  private isCurrentRuntimeConfiguration(configurationGeneration: number): boolean {
    return !this.disposed && configurationGeneration === this.runtimeConfigurationGeneration;
  }

  private requireCurrentRuntimeConfiguration(configurationGeneration: number): void {
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration)) {
      throw new Error('Steam farming runtime configuration changed before the operation completed');
    }
  }

  private isExpectedRuntimeCancellation(error: Error): boolean {
    return error.message === 'Steam farming runtime creation was cancelled' ||
      error.message === 'Steam farming runtime load became stale';
  }

  private async runAccountOperation<T>(
    accountId: string,
    operation: () => Promise<T>
  ): Promise<T> {
    const normalizedId = accountId.trim();
    if (normalizedId.length <= 0) {
      return await operation();
    }
    const previous = this.accountOperationTails.get(normalizedId);
    let release: () => void = (): void => {
      return;
    };
    const gate = new Promise<void>((resolve: () => void): void => {
      release = resolve;
    });
    const chain: Promise<void> = previous === undefined
      ? gate
      : previous.then((): Promise<void> => gate);
    this.accountOperationTails.set(normalizedId, chain);
    try {
      if (previous !== undefined) {
        await previous;
      }
      return await operation();
    } finally {
      release();
      if (this.accountOperationTails.get(normalizedId) === chain) {
        this.accountOperationTails.delete(normalizedId);
      }
    }
  }

  private normalizeError(error: Error | Object, fallback: string): Error {
    return error instanceof Error ? error : new Error(fallback);
  }
}

export const steamArkFarmingService: SteamArkFarmingService = new SteamArkFarmingService();
