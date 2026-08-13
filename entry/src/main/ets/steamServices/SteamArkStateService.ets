import {
  ISecureCredentialStore,
  ISettingsStore,
  NGFCredentialKind,
  NGFEventPayload,
  ngfContentCacheFacade,
  ngfSecureCredentialStore,
  ngfSettingsStoreFacade,
  ngfStarterKernel
} from 'ngf_framework';
import {
  ISteamAuthService,
  SteamAuthChallengeKind,
  SteamAuthError,
  SteamAuthErrorKind,
  SteamAuthErrorSupport,
  SteamAuthFlowKind,
  SteamAuthPendingSnapshot,
  SteamAuthRequest,
  SteamAuthResult,
  SteamAccountProfile,
  SteamBotConfigImportResult,
  SteamAsfJsonImporter,
  SteamBotConfig,
  SteamCredentialSet,
  SteamFarmingOrder,
  SteamGlobalConfig,
  SteamGlobalConfigImportResult,
  SteamGlobalConfigSecrets,
  SteamInventoryItem,
  SteamInventoryCardDropState,
  SteamInventoryPage,
  SteamInventoryQuery,
  SteamImportReport,
  SteamJsonParser,
  SteamJsonValue,
  SteamJsonValueKind,
  SteamMaFileImporter,
  SteamMaFileImportResult,
  SteamProxyKind,
  SteamProxySettings,
  SteamSessionSnapshot,
  SteamSessionState
} from 'steam_core';
import {
  ISteamArkAuthServiceFactory
} from './SteamArkAuthContracts';
import {
  ISteamArkProfileResolver,
  ISteamArkProfileVisualResolver,
  SteamArkResolvedProfile
} from './SteamArkProfileContracts';
import {
  ISteamArkMessageResolver,
  SteamArkMessageItem,
  SteamArkMessageSyncResult
} from './SteamArkMessageContracts';

import {
  ISteamArkInventoryAdapter,
  ISteamArkInventoryAdapterFactory
} from './SteamArkInventoryContracts';
import { SteamArkLog } from './SteamArkLogger';
import { steamArkCoreLogger } from './SteamArkCoreLogger';
import { SteamArkMarketPriceService } from './SteamArkMarketPriceService';
import { SteamArkMessageCacheStore } from './SteamArkMessageCacheStore';

type SteamArkMessageAction = (resolver: ISteamArkMessageResolver, profile: SteamAccountProfile,
  credentials: SteamCredentialSet, proxyPassword: string) => Promise<void>;

const TAG: string = 'SteamArkStateService';
const SETTINGS_KEY: string = 'steam_ark_state_v1';
const GLOBAL_SETTINGS_KEY: string = 'steam_ark_global_config_v1';
const STATE_EVENT_NAME: string = 'steam_ark.state_changed';
const PERSISTED_VERSION: number = 1;
const GLOBAL_CREDENTIAL_SCOPE: string = 'steam_ark_global';
const GLOBAL_IPC_PASSWORD_NAME: string = 'ipc_password';
const GLOBAL_WEB_PROXY_PASSWORD_NAME: string = 'web_proxy_password';
export const STEAM_ARK_PROFILE_BACKGROUND_STORAGE_KEY: string = 'steam_ark_profile_background_url';
export const STEAM_ARK_PROFILE_BACKGROUND_TILED_STORAGE_KEY: string = 'steam_ark_profile_background_tiled';
const INVENTORY_CACHE_TTL_MS: number = 24 * 60 * 60 * 1000;

class SteamArkCachedInventoryItem {
  assetId: string = '';
  classId: string = '';
  instanceId: string = '';
  appId: string = '';
  contextId: string = '';
  amount: number = 1;
  originalAmount: number = 1;
  name: string = '';
  type: string = '';
  description: string = '';
  iconUrl: string = '';
  iconUrlLarge: string = '';
  marketHashName: string = '';
  marketName: string = '';
  marketable: boolean = false;
  tradable: boolean = false;
  isTradingCard: boolean = false;
  assetStatus: number = 0;
  cardDropState: string = '';
  ownerAppId: string = '';
  ownerAppName: string = '';

  constructor(item: SteamInventoryItem) {
    this.assetId = item.assetId;
    this.classId = item.classId;
    this.instanceId = item.instanceId;
    this.appId = item.appId;
    this.contextId = item.contextId;
    this.amount = item.amount;
    this.originalAmount = item.originalAmount;
    this.name = item.name;
    this.type = item.type;
    this.description = item.description;
    this.iconUrl = item.iconUrl;
    this.iconUrlLarge = item.iconUrlLarge;
    this.marketHashName = item.marketHashName;
    this.marketName = item.marketName;
    this.marketable = item.marketable;
    this.tradable = item.tradable;
    this.isTradingCard = item.isTradingCard;
    this.assetStatus = item.assetStatus;
    this.cardDropState = String(item.cardDropState);
    this.ownerAppId = item.ownerAppId;
    this.ownerAppName = item.ownerAppName;
  }
}

class SteamArkCachedInventoryPage {
  appId: string = '753';
  contextId: string = '6';
  page: number = 1;
  pageSize: number = 100;
  startAssetId: string = '';
  language: string = 'english';
  totalCount: number = 0;
  hasMore: boolean = false;
  nextStartAssetId: string = '';
  syncedAtEpochSeconds: number = 0;
  items: Array<SteamArkCachedInventoryItem> = [];

  constructor(source: SteamInventoryPage) {
    this.appId = source.query.appId;
    this.contextId = source.query.contextId;
    this.page = source.query.page;
    this.pageSize = source.query.pageSize;
    this.startAssetId = source.query.startAssetId;
    this.language = source.query.language;
    this.totalCount = source.totalCount;
    this.hasMore = source.hasMore;
    this.nextStartAssetId = source.nextStartAssetId;
    this.syncedAtEpochSeconds = source.syncedAtEpochSeconds;
    for (let index: number = 0; index < source.items.length; index++) {
      this.items.push(new SteamArkCachedInventoryItem(source.items[index]));
    }
  }
}

class SteamArkCachedInventoryDocument {
  formatVersion: number = 2;
  accountId: string = '';
  syncedAtEpochSeconds: number = 0;
  pages: Array<SteamArkCachedInventoryPage> = [];

  constructor(accountId: string, pages: Array<SteamInventoryPage>) {
    this.accountId = accountId;
    for (let index: number = 0; index < pages.length; index++) {
      this.pages.push(new SteamArkCachedInventoryPage(pages[index]));
    }
    if (pages.length > 0) {
      this.syncedAtEpochSeconds = pages[0].syncedAtEpochSeconds;
    }
  }
}

export class SteamArkStateEventName {
  static readonly STATE_CHANGED: string = STATE_EVENT_NAME;
}

export class SteamArkMigrationReport {
  readonly sourceName: string;
  readonly recognizedFields: Array<string>;
  readonly unknownFields: Array<string>;
  readonly warnings: Array<string>;
  readonly importedAtEpochSeconds: number;

  constructor(
    sourceName: string = '',
    recognizedFields: Array<string> = [],
    unknownFields: Array<string> = [],
    warnings: Array<string> = [],
    importedAtEpochSeconds: number = 0
  ) {
    this.sourceName = sourceName;
    this.recognizedFields = recognizedFields.slice();
    this.unknownFields = unknownFields.slice();
    this.warnings = warnings.slice();
    this.importedAtEpochSeconds = importedAtEpochSeconds;
  }
}

export class SteamArkAccountSnapshot {
  readonly profile: SteamAccountProfile;
  readonly config: SteamBotConfig;
  readonly session: SteamSessionSnapshot;
  readonly pendingAuth: SteamAuthPendingSnapshot | null;
  readonly migrationReport: SteamArkMigrationReport;
  readonly hasCredentialMaterial: boolean;

  constructor(
    profile: SteamAccountProfile,
    config: SteamBotConfig,
    session: SteamSessionSnapshot,
    migrationReport: SteamArkMigrationReport,
    hasCredentialMaterial: boolean,
    pendingAuth: SteamAuthPendingSnapshot | null = null
  ) {
    this.profile = profile;
    this.config = config;
    this.session = session;
    this.pendingAuth = pendingAuth;
    this.migrationReport = migrationReport;
    this.hasCredentialMaterial = hasCredentialMaterial;
  }
}

/** Public snapshot for a QR challenge that is not an account yet. */
export class SteamArkQrAuthenticationSnapshot {
  readonly session: SteamSessionSnapshot;
  readonly pendingAuth: SteamAuthPendingSnapshot | null;

  constructor(session: SteamSessionSnapshot, pendingAuth: SteamAuthPendingSnapshot | null) {
    this.session = new SteamSessionSnapshot(
      session.accountId,
      session.state,
      session.steamId64,
      session.server,
      session.connectedAtEpochSeconds,
      session.expiresAtEpochSeconds,
      session.lastErrorCode,
      session.lastErrorMessage,
      session.lastErrorType,
      session.lastErrorStage,
      session.lastErrorHttpStatusCode,
      session.lastErrorMessageType,
      session.lastErrorHeaderKind,
      session.lastErrorFrameBytes,
      session.lastErrorHeaderBytes,
      session.lastErrorBodyBytes,
      session.lastErrorServerMessage
    );
    this.pendingAuth = pendingAuth === null ? null : new SteamAuthPendingSnapshot(
      pendingAuth.accountId,
      pendingAuth.clientId,
      pendingAuth.requestId,
      pendingAuth.steamId64,
      pendingAuth.challenge,
      pendingAuth.intervalSeconds,
      pendingAuth.createdAtEpochSeconds,
      pendingAuth.expiresAtEpochSeconds,
      pendingAuth.flow,
      pendingAuth.challengeUrl
    );
  }
}

export class SteamArkStateSnapshot {
  readonly accounts: Array<SteamArkAccountSnapshot>;
  readonly selectedAccountId: string;
  readonly initialized: boolean;
  readonly updatedAtEpochSeconds: number;
  readonly globalConfig: SteamGlobalConfig;
  readonly globalMigrationReport: SteamArkMigrationReport;
  readonly hasGlobalCredentialMaterial: boolean;
  readonly pendingQrAuthentication: SteamArkQrAuthenticationSnapshot | null;

  constructor(
    accounts: Array<SteamArkAccountSnapshot>,
    selectedAccountId: string,
    initialized: boolean,
    updatedAtEpochSeconds: number,
    globalConfig: SteamGlobalConfig = new SteamGlobalConfig(),
    globalMigrationReport: SteamArkMigrationReport = new SteamArkMigrationReport(),
    hasGlobalCredentialMaterial: boolean = false,
    pendingQrAuthentication: SteamArkQrAuthenticationSnapshot | null = null
  ) {
    this.accounts = accounts.slice();
    this.selectedAccountId = selectedAccountId;
    this.initialized = initialized;
    this.updatedAtEpochSeconds = updatedAtEpochSeconds;
    this.globalConfig = globalConfig.clone();
    this.globalMigrationReport = globalMigrationReport;
    this.hasGlobalCredentialMaterial = hasGlobalCredentialMaterial;
    this.pendingQrAuthentication = pendingQrAuthentication;
  }
}

export class SteamArkImportSummary {
  readonly account: SteamArkAccountSnapshot;
  readonly sourceName: string;
  readonly mergedExistingAccount: boolean;

  constructor(account: SteamArkAccountSnapshot, sourceName: string, mergedExistingAccount: boolean = false) {
    this.account = account;
    this.sourceName = sourceName;
    this.mergedExistingAccount = mergedExistingAccount;
  }
}

export class SteamArkGlobalConfigSnapshot {
  readonly config: SteamGlobalConfig;
  readonly migrationReport: SteamArkMigrationReport;
  readonly hasCredentialMaterial: boolean;

  constructor(
    config: SteamGlobalConfig,
    migrationReport: SteamArkMigrationReport,
    hasCredentialMaterial: boolean
  ) {
    this.config = config.clone();
    this.migrationReport = migrationReport;
    this.hasCredentialMaterial = hasCredentialMaterial;
  }
}

export class SteamArkGlobalImportSummary {
  readonly globalConfig: SteamArkGlobalConfigSnapshot;
  readonly sourceName: string;

  constructor(globalConfig: SteamArkGlobalConfigSnapshot, sourceName: string) {
    this.globalConfig = globalConfig;
    this.sourceName = sourceName;
  }
}

export class SteamArkInventorySummary {
  readonly totalCount: number;
  readonly loadedItemCount: number;
  readonly cardCount: number;
  readonly hasSnapshot: boolean;
  /** True only when every page reachable from the cached first page is present. */
  readonly isComplete: boolean;
  readonly syncedAtEpochSeconds: number;

  constructor(
    totalCount: number = 0,
    loadedItemCount: number = 0,
    cardCount: number = 0,
    hasSnapshot: boolean = false,
    isComplete: boolean = false,
    syncedAtEpochSeconds: number = 0
  ) {
    this.totalCount = totalCount;
    this.loadedItemCount = loadedItemCount;
    this.cardCount = cardCount;
    this.hasSnapshot = hasSnapshot;
    this.isComplete = isComplete;
    this.syncedAtEpochSeconds = syncedAtEpochSeconds;
  }
}

export type SteamArkStateListener = (snapshot: SteamArkStateSnapshot) => void;

/** Coordinates account-owned runtime cleanup without coupling state to farming implementation. */
export interface ISteamArkAccountLifecycle {
  stop(accountId: string): Promise<void>;
  remove(accountId: string): Promise<void>;
}

class SteamArkAccountRecord {
  profile: SteamAccountProfile;
  config: SteamBotConfig;
  session: SteamSessionSnapshot;
  pendingAuth: SteamAuthPendingSnapshot | null;
  migrationReport: SteamArkMigrationReport;
  hasCredentialMaterial: boolean;
  autoRestoreEnabled: boolean;
  /** Changes only when a completed authenticated identity is committed. */
  profileRefreshGeneration: number;
  /** Limits the post-authentication profile fallback to one retry per identity generation. */
  profileRefreshRetryGeneration: number;
  /** Marks a failed lookup that should dispatch its one retry after the current queue operation releases. */
  profileRefreshRetryPendingGeneration: number;

  constructor(
    profile: SteamAccountProfile,
    config: SteamBotConfig,
    session: SteamSessionSnapshot,
    migrationReport: SteamArkMigrationReport = new SteamArkMigrationReport(),
    hasCredentialMaterial: boolean = false,
    pendingAuth: SteamAuthPendingSnapshot | null = null,
    autoRestoreEnabled: boolean = true,
    profileRefreshGeneration: number = 0,
    profileRefreshRetryGeneration: number = -1,
    profileRefreshRetryPendingGeneration: number = -1
  ) {
    this.profile = profile;
    this.config = config;
    this.session = session;
    this.pendingAuth = pendingAuth;
    this.migrationReport = migrationReport;
    this.hasCredentialMaterial = hasCredentialMaterial;
    this.autoRestoreEnabled = autoRestoreEnabled;
    this.profileRefreshGeneration = profileRefreshGeneration;
    this.profileRefreshRetryGeneration = profileRefreshRetryGeneration;
    this.profileRefreshRetryPendingGeneration = profileRefreshRetryPendingGeneration;
  }
}

/**
 * Persistence DTO. It deliberately contains only non-secret account state.
 * JSON is written from this explicit class and read through SteamJsonParser.
 */
class SteamArkPersistedAuthPending {
  accountId: string = '';
  clientId: string = '';
  requestId: string = '';
  steamId64: string = '';
  challenge: SteamAuthChallengeKind = SteamAuthChallengeKind.NONE;
  flow: SteamAuthFlowKind = SteamAuthFlowKind.PASSWORD;
  challengeUrl: string = '';
  intervalSeconds: number = 0;
  createdAtEpochSeconds: number = 0;
  expiresAtEpochSeconds: number = 0;
}

class SteamArkPersistedAccount {
  accountId: string = '';
  displayName: string = '';
  avatarUrl: string = '';
  profileBackgroundImageUrl: string = '';
  profileBackgroundMovieUrl: string = '';
  profileBackgroundTiled: boolean = false;
  miniProfileBackgroundImageUrl: string = '';
  miniProfileBackgroundMovieUrl: string = '';
  avatarFrameUrl: string = '';
  summary: string = '';
  level: number = 0;
  countryCode: string = '';
  walletBalance: string = '';
  walletCurrency: string = '';
  steamId64: string = '';
  accountEnabled: boolean = true;
  autoRestoreEnabled: boolean = true;
  proxyKind: SteamProxyKind = SteamProxyKind.SYSTEM;
  proxyHost: string = '';
  proxyPort: number = 0;
  proxyUsername: string = '';
  botEnabled: boolean = true;
  hoursUntilCardDrops: number = 3;
  maxGamesPlayedConcurrently: number = 32;
  farmingPreferences: number = 0;
  farmingOrders: Array<string> = [];
  gamesPlayedWhileIdle: Array<string> = [];
  blacklist: Array<string> = [];
  priorityAppIds: Array<string> = [];
  sessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  sessionSteamId64: string = '';
  sessionServer: string = '';
  sessionConnectedAtEpochSeconds: number = 0;
  sessionExpiresAtEpochSeconds: number = 0;
  sessionLastErrorCode: number = 0;
  sessionLastErrorMessage: string = '';
  sessionLastErrorType: string = '';
  sessionLastErrorStage: string = '';
  sessionLastErrorHttpStatusCode: number = 0;
  sessionLastErrorMessageType: number = 0;
  sessionLastErrorHeaderKind: string = '';
  sessionLastErrorFrameBytes: number = 0;
  sessionLastErrorHeaderBytes: number = 0;
  sessionLastErrorBodyBytes: number = 0;
  sessionLastErrorServerMessage: string = '';
  pendingAuth: SteamArkPersistedAuthPending | null = null;
  migrationSourceName: string = '';
  migrationRecognizedFields: Array<string> = [];
  migrationUnknownFields: Array<string> = [];
  migrationWarnings: Array<string> = [];
  migrationImportedAtEpochSeconds: number = 0;
}

class SteamArkPersistedDocument {
  version: number = PERSISTED_VERSION;
  selectedAccountId: string = '';
  accounts: Array<SteamArkPersistedAccount> = [];
}

class SteamArkPersistedGlobalDocument {
  version: number = PERSISTED_VERSION;
  config: SteamGlobalConfig = new SteamGlobalConfig();
  migrationSourceName: string = '';
  migrationRecognizedFields: Array<string> = [];
  migrationUnknownFields: Array<string> = [];
  migrationWarnings: Array<string> = [];
  migrationImportedAtEpochSeconds: number = 0;
}

/** A complete account credential snapshot used to make multi-field updates recoverable. */
class SteamArkCredentialSnapshotEntry {
  readonly kind: NGFCredentialKind;
  readonly present: boolean;
  readonly value: string;

  constructor(kind: NGFCredentialKind, value: string | null) {
    this.kind = kind;
    this.present = value !== null && value.length > 0;
    this.value = value === null ? '' : value;
  }
}

class SteamArkCredentialSnapshot {
  readonly entries: Array<SteamArkCredentialSnapshotEntry>;

  constructor(entries: Array<SteamArkCredentialSnapshotEntry>) {
    this.entries = entries.slice();
  }
}

class SteamArkNamedCredentialSnapshotEntry {
  readonly name: string;
  readonly present: boolean;
  readonly value: string;

  constructor(name: string, value: string | null) {
    this.name = name;
    this.present = value !== null && value.length > 0;
    this.value = value === null ? '' : value;
  }
}

class SteamArkNamedCredentialSnapshot {
  readonly entries: Array<SteamArkNamedCredentialSnapshotEntry>;

  constructor(entries: Array<SteamArkNamedCredentialSnapshotEntry>) {
    this.entries = entries.slice();
  }
}

class SteamArkStateEventEnvelope {
  eventVersion: number = 1;
  accountCount: number = 0;
  selectedAccountId: string = '';
  initialized: boolean = false;
  updatedAtEpochSeconds: number = 0;
}

/** Host dependencies are injectable so fake hosts can verify state transitions without platform storage. */
export class SteamArkStateServiceOptions {
  readonly settingsStore: ISettingsStore;
  readonly credentialStore: ISecureCredentialStore;

  constructor(
    settingsStore: ISettingsStore = ngfSettingsStoreFacade,
    credentialStore: ISecureCredentialStore = ngfSecureCredentialStore
  ) {
    this.settingsStore = settingsStore;
    this.credentialStore = credentialStore;
  }
}

export class SteamArkStateService {
  private readonly records: Map<string, SteamArkAccountRecord> = new Map<string, SteamArkAccountRecord>();
  private readonly listeners: Map<string, SteamArkStateListener> = new Map<string, SteamArkStateListener>();
  private selectedAccountId: string = '';
  /** Last-writer-wins guard for account selection requests from different account queues. */
  private accountSelectionRequestGeneration: number = 0;
  private initialized: boolean = false;
  private globalConfig: SteamGlobalConfig = new SteamGlobalConfig();
  private globalMigrationReport: SteamArkMigrationReport = new SteamArkMigrationReport();
  private hasGlobalCredentialMaterial: boolean = false;
  private initializationPromise: Promise<boolean> | null = null;
  /** Invalidates detached startup refresh work when the ability is destroyed. */
  private sessionRestoreGeneration: number = 0;
  private readonly inventoryAdapters: Map<string, ISteamArkInventoryAdapter> =
    new Map<string, ISteamArkInventoryAdapter>();
  private readonly inventoryPages: Map<string, SteamInventoryPage> =
    new Map<string, SteamInventoryPage>();
  private readonly latestInventoryPages: Map<string, SteamInventoryPage> =
    new Map<string, SteamInventoryPage>();
  private inventoryAdapterFactory: ISteamArkInventoryAdapterFactory | null = null;
  private readonly authServices: Map<string, ISteamAuthService> = new Map<string, ISteamAuthService>();
  /** Coalesces post-authentication profile refreshes without delaying a successful sign-in result. */
  private readonly profileRefreshTasks: Map<string, Promise<boolean>> = new Map<string, Promise<boolean>>();
  /** Associates basic profile work with the authenticated identity generation that requested it. */
  private readonly profileRefreshGenerations: Map<string, number> = new Map<string, number>();
  /** Keeps expensive profile decoration work outside the authentication operation queue. */
  private readonly profileVisualRefreshTasks: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  /** Associates visual work with the authenticated identity generation that requested it. */
  private readonly profileVisualRefreshGenerations: Map<string, number> = new Map<string, number>();
  /** Accounts currently performing an automatic startup session restore. */
  private readonly restoringAccounts: Map<string, boolean> = new Map<string, boolean>();
  private authServiceFactory: ISteamArkAuthServiceFactory | null = null;
  private profileResolver: ISteamArkProfileResolver | null = null;
  private profileVisualResolver: ISteamArkProfileVisualResolver | null = null;
  private messageResolver: ISteamArkMessageResolver | null = null;
  /** Serializes account mutations so a late login cannot race account removal or proxy replacement. */
  private readonly accountOperationTails: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  /** Prevents callbacks from a runtime being stopped from overwriting the settled account state. */
  private readonly sessionUpdateBlockCounts: Map<string, number> = new Map<string, number>();
  private accountLifecycle: ISteamArkAccountLifecycle | null = null;
  private qrAccountSequence: number = 0;
  /** Captures the last explicit selection before each transient QR authentication begins. */
  private readonly qrAuthenticationSelectionGenerations: Map<string, number> = new Map<string, number>();
  private disposalPromise: Promise<void> | null = null;
  private isDisposing: boolean = false;
  /** Prevents an older dispose pass from clearing dependencies configured by a new ability instance. */
  private runtimeDependencyGeneration: number = 0;
  private globalOperationTail: Promise<void> = Promise.resolve();
  private readonly detachedCleanupTasks: Array<Promise<void>> = [];
  /** Serializes account/global preference writes to prevent stale snapshots winning. */
  private persistenceTail: Promise<void> = Promise.resolve();
  private readonly settingsStore: ISettingsStore;
  private readonly credentialStore: ISecureCredentialStore;

  constructor(options: SteamArkStateServiceOptions = new SteamArkStateServiceOptions()) {
    this.settingsStore = options.settingsStore;
    this.credentialStore = options.credentialStore;
    SteamArkLog.debug(TAG, 'state service constructed');
  }

  async initialize(): Promise<boolean> {
    if (this.disposalPromise !== null) {
      await this.disposalPromise;
    }
    if (this.initialized) {
      SteamArkLog.debug(TAG, 'initialize skipped; already initialized');
      return true;
    }
    if (this.initializationPromise !== null) {
      SteamArkLog.debug(TAG, 'initialize joined existing promise');
      return await this.initializationPromise;
    }

    const startedAt: number = Date.now();
    SteamArkLog.startup(TAG, 'state persistence load started');
    const task = this.loadPersistedState();
    this.initializationPromise = task;
    try {
      const initialized: boolean = await task;
      SteamArkLog.startup(TAG, 'state persistence load completed', 'success=' + String(initialized) +
        ', accounts=' + this.records.size.toString());
      SteamArkLog.performance(TAG, 'state initialization', startedAt);
      if (initialized) {
        const generation = this.sessionRestoreGeneration;
        void this.refreshRestoredSessions(generation);
      }
      return initialized;
    } catch (error) {
      SteamArkLog.error(TAG, 'state persistence load failed');
      throw error instanceof Error ? error : new Error('Steam state persistence load failed');
    } finally {
      this.initializationPromise = null;
    }
  }

  /** Closes all host-owned sessions and releases transient state at ability teardown. */
  async dispose(): Promise<void> {
    const existing = this.disposalPromise;
    if (existing !== null) {
      await existing;
      return;
    }
    this.isDisposing = true;
    this.sessionRestoreGeneration++;
    const dependencyGenerationAtStart: number = this.runtimeDependencyGeneration;
    const task = this.disposeRuntimeResources(dependencyGenerationAtStart);
    this.disposalPromise = task;
    try {
      await task;
    } finally {
      if (this.disposalPromise === task) {
        this.disposalPromise = null;
        this.isDisposing = false;
      }
    }
  }

  private async disposeRuntimeResources(dependencyGenerationAtStart: number): Promise<void> {
    SteamArkLog.lifecycle(TAG, 'dispose started', 'authServices=' + this.authServices.size.toString() +
      ', inventoryAdapters=' + this.inventoryAdapters.size.toString());
    let firstFailure: Error | null = null;
    const pendingInitialization = this.initializationPromise;
    if (pendingInitialization !== null) {
      try {
        await pendingInitialization;
      } catch (error) {
        firstFailure = error instanceof Error ? error : new Error('Steam state initialization failed during dispose');
      }
    }

    const pendingAccountOperations: Array<Promise<void>> = [];
    this.accountOperationTails.forEach((operation: Promise<void>): void => {
      pendingAccountOperations.push(operation);
    });
    for (let index = 0; index < pendingAccountOperations.length; index++) {
      await pendingAccountOperations[index];
    }
    await this.globalOperationTail;
    await this.waitForDetachedCleanup();

    const authAccountIds: Array<string> = [];
    const authServices: Array<ISteamAuthService> = [];
    this.authServices.forEach((service: ISteamAuthService, accountId: string): void => {
      authAccountIds.push(accountId);
      authServices.push(service);
    });
    for (let index = 0; index < authServices.length; index++) {
      try {
        await authServices[index].close(authAccountIds[index]);
      } catch (error) {
        if (firstFailure === null) {
          firstFailure = error instanceof Error ? error : new Error('Steam authentication session cleanup failed');
        }
        SteamArkLog.warn(TAG, 'authentication dispose failed; account=' +
          SteamArkLog.accountId(authAccountIds[index]) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }

    const inventoryAccountIds: Array<string> = [];
    const inventoryAdapters: Array<ISteamArkInventoryAdapter> = [];
    this.inventoryAdapters.forEach((adapter: ISteamArkInventoryAdapter, accountId: string): void => {
      inventoryAccountIds.push(accountId);
      inventoryAdapters.push(adapter);
    });
    for (let index = 0; index < inventoryAdapters.length; index++) {
      try {
        await inventoryAdapters[index].close(inventoryAccountIds[index]);
      } catch (error) {
        if (firstFailure === null) {
          firstFailure = error instanceof Error ? error : new Error('Steam inventory session cleanup failed');
        }
        SteamArkLog.warn(TAG, 'inventory dispose failed; account=' +
          SteamArkLog.accountId(inventoryAccountIds[index]) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }

    this.authServices.clear();
    this.profileRefreshTasks.clear();
    this.profileRefreshGenerations.clear();
    this.profileVisualRefreshTasks.clear();
    this.profileVisualRefreshGenerations.clear();
    this.inventoryAdapters.clear();
    this.inventoryPages.clear();
    this.latestInventoryPages.clear();
    this.accountOperationTails.clear();
    this.sessionUpdateBlockCounts.clear();
    this.restoringAccounts.clear();
    this.listeners.clear();
    this.records.clear();
    this.selectedAccountId = '';
    this.accountSelectionRequestGeneration += 1;
    this.initialized = false;
    if (this.runtimeDependencyGeneration === dependencyGenerationAtStart) {
      this.inventoryAdapterFactory = null;
      this.authServiceFactory = null;
      this.profileResolver = null;
      this.profileVisualResolver = null;
      this.messageResolver = null;
      this.accountLifecycle = null;
    } else {
      SteamArkLog.debug(TAG, 'runtime dependencies preserved after disposal reconfiguration; generation=' +
        this.runtimeDependencyGeneration.toString());
    }
    this.qrAccountSequence = 0;
    this.qrAuthenticationSelectionGenerations.clear();
    await this.persistenceTail;
    this.persistenceTail = Promise.resolve();
    this.globalOperationTail = Promise.resolve();
    SteamArkLog.lifecycle(TAG, 'dispose completed', 'failed=' + String(firstFailure !== null));
    if (firstFailure !== null) {
      throw firstFailure;
    }
  }

  getSnapshot(): SteamArkStateSnapshot {
    const snapshots: Array<SteamArkAccountSnapshot> = [];
    let pendingQrAuthentication: SteamArkQrAuthenticationSnapshot | null = null;
    this.records.forEach((record: SteamArkAccountRecord): void => {
      if (this.isTemporaryQrRecord(record)) {
        if (pendingQrAuthentication === null) {
          pendingQrAuthentication = new SteamArkQrAuthenticationSnapshot(
            record.session,
            record.pendingAuth
          );
        }
        return;
      }
      snapshots.push(this.toSnapshot(record));
    });
    const selectedRecord = this.records.get(this.selectedAccountId);
    const visibleSelectedAccountId = selectedRecord !== undefined && this.isTemporaryQrRecord(selectedRecord)
      ? ''
      : this.selectedAccountId;
    return new SteamArkStateSnapshot(
      snapshots,
      visibleSelectedAccountId,
      this.initialized,
      this.nowEpochSeconds(),
      this.globalConfig,
      this.globalMigrationReport,
      this.hasGlobalCredentialMaterial,
      pendingQrAuthentication
    );
  }

  getSelectedAccount(): SteamArkAccountSnapshot | null {
    if (this.selectedAccountId.length <= 0) {
      return null;
    }
    const record = this.records.get(this.selectedAccountId);
    return record === undefined || this.isTemporaryQrRecord(record) ? null : this.toSnapshot(record);
  }

  getGlobalConfig(): SteamGlobalConfig {
    return this.globalConfig.clone();
  }

  getGlobalConfigSnapshot(): SteamArkGlobalConfigSnapshot {
    return new SteamArkGlobalConfigSnapshot(
      this.globalConfig,
      this.globalMigrationReport,
      this.hasGlobalCredentialMaterial
    );
  }

  subscribe(listenerId: string, listener: SteamArkStateListener): boolean {
    const normalizedId = listenerId.trim();
    if (normalizedId.length <= 0) {
      return false;
    }
    if (this.listeners.has(normalizedId)) {
      SteamArkLog.debug(TAG, 'state listener registration skipped; duplicate id=' + normalizedId);
      return false;
    }
    this.listeners.set(normalizedId, listener);
    SteamArkLog.debug(TAG, 'state listener registered; id=' + normalizedId +
      ', count=' + this.listeners.size.toString());
    return true;
  }

  unsubscribe(listenerId: string): boolean {
    const normalizedId: string = listenerId.trim();
    const removed: boolean = this.listeners.delete(normalizedId);
    SteamArkLog.debug(TAG, 'state listener unregistered; id=' + normalizedId +
      ', removed=' + String(removed));
    return removed;
  }

  setInventoryAdapterFactory(factory: ISteamArkInventoryAdapterFactory): void {
    this.runtimeDependencyGeneration++;
    const accountIds: Array<string> = [];
    const adapters: Array<ISteamArkInventoryAdapter> = [];
    this.inventoryAdapters.forEach((_adapter: ISteamArkInventoryAdapter, accountId: string): void => {
      accountIds.push(accountId);
      adapters.push(_adapter);
    });
    this.inventoryAdapterFactory = factory;
    this.inventoryAdapters.clear();
    this.inventoryPages.clear();
    this.latestInventoryPages.clear();
    for (let index = 0; index < accountIds.length; index++) {
      const accountId = accountIds[index];
      this.trackDetachedCleanup(this.closeDetachedInventoryAdapterAfterOperations(accountId, adapters[index]));
    }
    SteamArkLog.info(TAG, 'inventory adapter factory configured; caches cleared');
  }

  isInventoryAdapterReady(): boolean {
    return this.inventoryAdapterFactory !== null;
  }

  setAuthServiceFactory(factory: ISteamArkAuthServiceFactory): void {
    this.runtimeDependencyGeneration++;
    const accountIds: Array<string> = [];
    const services: Array<ISteamAuthService> = [];
    this.authServices.forEach((_service: ISteamAuthService, accountId: string): void => {
      accountIds.push(accountId);
      services.push(_service);
    });
    this.authServiceFactory = factory;
    this.authServices.clear();
    for (let index = 0; index < accountIds.length; index++) {
      this.trackDetachedCleanup(this.closeDetachedAuthServiceAfterOperations(accountIds[index], services[index]));
    }
    SteamArkLog.info(TAG, 'authentication service factory configured; service cache cleared');
  }

  setProfileResolver(resolver: ISteamArkProfileResolver | null): void {
    this.runtimeDependencyGeneration++;
    this.profileResolver = resolver;
    SteamArkLog.info(TAG, 'profile resolver configured; enabled=' + String(resolver !== null));
  }

  setProfileVisualResolver(resolver: ISteamArkProfileVisualResolver | null): void {
    this.runtimeDependencyGeneration++;
    this.profileVisualResolver = resolver;
    SteamArkLog.info(TAG, 'profile visual resolver configured; enabled=' + String(resolver !== null));
  }

  /**
   * Refreshes only non-secret profile metadata for an already authenticated
   * account. Resolver failures are intentionally contained so a public profile
   * outage can never downgrade a valid Steam session.
   */
  async refreshProfile(accountId: string): Promise<boolean> {
    return await this.requestLoggedOnProfileRefresh(accountId);
  }

  private async refreshProfileInternal(accountId: string): Promise<boolean> {
    await this.requireInitialized();
    const normalizedId: string = accountId.trim();
    const record: SteamArkAccountRecord | undefined = this.records.get(normalizedId);
    if (record === undefined) {
      throw new Error('Steam account does not exist');
    }
    if (record.session.state !== SteamSessionState.LOGGED_ON) {
      throw new Error('Steam account must be logged on before profile refresh');
    }
    return await this.resolveLoggedOnProfile(record);
  }

  setMessageResolver(resolver: ISteamArkMessageResolver | null): void {
    this.runtimeDependencyGeneration++;
    this.messageResolver = resolver;
    SteamArkLog.info(TAG, 'message resolver configured; enabled=' + String(resolver !== null));
  }

  async syncMessages(accountId: string): Promise<SteamArkMessageSyncResult> {
    return await this.runAccountOperation<SteamArkMessageSyncResult>(
      accountId,
      async (): Promise<SteamArkMessageSyncResult> => await this.syncMessagesInternal(accountId)
    );
  }

  private async syncMessagesInternal(accountId: string): Promise<SteamArkMessageSyncResult> {
    await this.requireInitialized();
    const normalizedId: string = accountId.trim();
    const record: SteamArkAccountRecord | undefined = this.records.get(normalizedId);
    if (record === undefined) {
      throw new Error('Steam account does not exist');
    }
    if (record.session.state !== SteamSessionState.LOGGED_ON) {
      throw new Error('Steam account must be logged on before message synchronization');
    }
    const resolver: ISteamArkMessageResolver | null = this.messageResolver;
    if (resolver === null) {
      throw new Error('Steam message resolver is not configured');
    }
    const credentials: SteamCredentialSet = await this.getCredentials(normalizedId);
    if (!this.hasUsableAuthenticationCredentials(credentials)) {
      throw new Error('Steam message synchronization requires a persisted access or refresh token. Please sign in again.');
    }
    const proxyPassword: string = await this.readProxyPassword(normalizedId);
    const result: SteamArkMessageSyncResult = await resolver.resolve(
      this.copyProfile(record.profile),
      credentials,
      proxyPassword
    );
    const cacheSaved: boolean = SteamArkMessageCacheStore.writeSyncResult(normalizedId, result);
    if (!cacheSaved && Number.isSafeInteger(result.syncedAtEpochSeconds) && result.syncedAtEpochSeconds > 0) {
      SteamArkLog.debug(TAG, 'message synchronization succeeded but shared cache was not updated; account=' +
        SteamArkLog.accountId(normalizedId));
    }
    return result;
  }

  async markMessageRead(accountId: string, item: SteamArkMessageItem): Promise<void> {
    await this.runMessageAction(accountId, async (resolver: ISteamArkMessageResolver,
      profile: SteamAccountProfile, credentials: SteamCredentialSet, proxyPassword: string): Promise<void> => {
      await resolver.markRead(profile, credentials, proxyPassword, item);
    });
  }

  async markAllMessagesRead(accountId: string): Promise<void> {
    await this.runMessageAction(accountId, async (resolver: ISteamArkMessageResolver,
      profile: SteamAccountProfile, credentials: SteamCredentialSet, proxyPassword: string): Promise<void> => {
      await resolver.markAllRead(profile, credentials, proxyPassword);
    });
  }

  async hideMessage(accountId: string, item: SteamArkMessageItem): Promise<void> {
    await this.runMessageAction(accountId, async (resolver: ISteamArkMessageResolver,
      profile: SteamAccountProfile, credentials: SteamCredentialSet, proxyPassword: string): Promise<void> => {
      await resolver.hide(profile, credentials, proxyPassword, item);
    });
  }

  private async runMessageAction(accountId: string, action: SteamArkMessageAction): Promise<void> {
    await this.runAccountOperation<void>(accountId, async (): Promise<void> => {
      await this.requireInitialized();
      const normalizedId: string = accountId.trim();
      const record: SteamArkAccountRecord | undefined = this.records.get(normalizedId);
      if (record === undefined || record.session.state !== SteamSessionState.LOGGED_ON) {
        throw new Error('Steam account must be logged on before message actions');
      }
      const resolver: ISteamArkMessageResolver | null = this.messageResolver;
      if (resolver === null) {
        throw new Error('Steam message resolver is not configured');
      }
      const credentials: SteamCredentialSet = await this.getCredentials(normalizedId);
      if (!this.hasUsableAuthenticationCredentials(credentials)) {
        throw new Error('Steam message actions require a persisted access or refresh token. Please sign in again.');
      }
      const proxyPassword: string = await this.readProxyPassword(normalizedId);
      await action(resolver, this.copyProfile(record.profile), credentials, proxyPassword);
    });
  }

  isAuthServiceReady(): boolean {
    return this.authServiceFactory !== null;
  }

  setAccountLifecycle(lifecycle: ISteamArkAccountLifecycle | null): void {
    this.runtimeDependencyGeneration++;
    this.accountLifecycle = lifecycle;
    SteamArkLog.info(TAG, 'account lifecycle coordinator configured; enabled=' + String(lifecycle !== null));
  }

  async signIn(accountId: string): Promise<SteamAuthResult> {
    return await this.runAccountOperation<SteamAuthResult>(
      accountId,
      async (): Promise<SteamAuthResult> => await this.signInInternal(accountId)
    );
  }

  private async signInInternal(accountId: string): Promise<SteamAuthResult> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'sign-in started; account=' + SteamArkLog.accountId(normalizedId));
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      throw new Error('Steam account does not exist');
    }
    try {
      const service = await this.getAuthService(record);
      const credentials = await this.getCredentials(normalizedId);
      if (record.session.state === SteamSessionState.LOGGED_ON) {
        return new SteamAuthResult(this.copySession(record.session), credentials);
      }
      const result = credentials.password.length <= 0 && credentials.refreshToken.length > 0
        ? await service.refresh(normalizedId, credentials.refreshToken)
        : await service.signIn(new SteamAuthRequest(normalizedId, credentials));
      await this.applyAuthResult(record, result);
      SteamArkLog.info(TAG, 'sign-in completed; account=' + SteamArkLog.accountId(normalizedId) +
        ', challenge=' + String(result.challenge) + ', state=' + String(result.session.state));
      SteamArkLog.performance(TAG, 'sign-in', startedAt);
      return result;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam sign-in failed');
      const authError = SteamAuthErrorSupport.normalize(
        normalized,
        SteamAuthErrorKind.AUTHENTICATION,
        'sign_in',
        'Steam sign-in failed'
      );
      await this.recordAuthFailure(record, authError);
      SteamArkLog.warn(TAG, 'Steam sign-in failed for account state transition; account=' +
        SteamArkLog.accountId(normalizedId));
      throw authError;
    }
  }

  /** Starts a password flow and creates the local account on first use. */
  async signInWithPassword(accountName: string, password: string): Promise<SteamAuthResult> {
    await this.requireInitialized();
    const operationKey = await this.resolvePasswordSignInOperationKey(accountName);
    return await this.runAccountOperation<SteamAuthResult>(
      operationKey,
      async (): Promise<SteamAuthResult> => await this.signInWithPasswordInternal(accountName, password)
    );
  }

  private async signInWithPasswordInternal(accountName: string, password: string): Promise<SteamAuthResult> {
    await this.requireInitialized();
    const normalizedName = accountName.trim();
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'password sign-in started; account=' + SteamArkLog.accountId(normalizedName));
    if (normalizedName.length <= 0) {
      throw new Error('Steam account name is required');
    }
    if (password.length <= 0) {
      throw new Error('Steam password is required');
    }
    let accountId = normalizedName;
    let record = this.records.get(accountId);
    if (record === undefined) {
      const matchedAccountId: string = await this.findAccountIdByAccountName(normalizedName);
      if (matchedAccountId.length > 0) {
        accountId = matchedAccountId;
        record = this.records.get(accountId);
      }
    }
    if (record === undefined) {
      record = new SteamArkAccountRecord(
        new SteamAccountProfile(accountId, normalizedName),
        new SteamBotConfig(accountId),
        new SteamSessionSnapshot(accountId)
      );
      this.records.set(accountId, record);
    }
    try {
      await this.storeCredential(accountId, NGFCredentialKind.ACCOUNT_NAME, normalizedName);
      record.profile.displayName = normalizedName;
      record.pendingAuth = null;
      this.ensureSelectedAccount(accountId);
      const stored = await this.getCredentials(accountId);
      const credentials = new SteamCredentialSet(
        normalizedName,
        password,
        stored.refreshToken,
        stored.loginKey,
        stored.sharedSecret,
        stored.identitySecret,
        stored.deviceId,
        stored.accessToken,
        stored.oauthToken,
        stored.guardData
      );
      const service = await this.getAuthService(record);
      const result = await service.signIn(new SteamAuthRequest(accountId, credentials));
      await this.applyAuthResult(record, result);
      SteamArkLog.info(TAG, 'password sign-in completed; account=' +
        SteamArkLog.accountId(accountId) + ', challenge=' + String(result.challenge) +
        ', state=' + String(result.session.state));
      SteamArkLog.performance(TAG, 'password sign-in', startedAt);
      return result;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam password sign-in failed');
      const authError = SteamAuthErrorSupport.normalize(
        normalized,
        SteamAuthErrorKind.AUTHENTICATION,
        'password_sign_in',
        'Steam password sign-in failed'
      );
      await this.recordAuthFailure(record, authError);
      SteamArkLog.warn(TAG, 'Steam password sign-in failed for account state transition; account=' +
        SteamArkLog.accountId(accountId));
      throw authError;
    }
  }

  /** Starts a device-local QR flow. The generated account id is non-secret. */
  async beginQrSignIn(): Promise<SteamAuthResult> {
    return await this.runAccountOperation<SteamAuthResult>(
      'qr-authentication',
      async (): Promise<SteamAuthResult> => await this.beginQrSignInInternal()
    );
  }

  private async beginQrSignInInternal(): Promise<SteamAuthResult> {
    await this.requireInitialized();
    try {
      await this.cleanupTemporaryQrAccounts();
    } catch (error) {
      const normalized = error instanceof Error
        ? error
        : new Error('Steam previous QR authentication cleanup failed');
      throw SteamAuthErrorSupport.normalize(
        normalized,
        SteamAuthErrorKind.AUTHENTICATION,
        'qr_cleanup',
        'Steam previous QR authentication cleanup failed'
      );
    }
    const accountId = this.nextQrAccountId();
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'QR sign-in started; temporaryAccount=' + SteamArkLog.accountId(accountId));
    const record = new SteamArkAccountRecord(
      new SteamAccountProfile(accountId, accountId),
      new SteamBotConfig(accountId),
      new SteamSessionSnapshot(accountId)
    );
    this.records.set(accountId, record);
    this.qrAuthenticationSelectionGenerations.set(accountId, this.accountSelectionRequestGeneration);
    // A QR challenge is intentionally hidden from the account list. Keep a
    // previously selected durable account visible while that challenge is pending.
    const selectedRecord = this.records.get(this.selectedAccountId);
    if (selectedRecord === undefined || this.isTemporaryQrRecord(selectedRecord)) {
      this.ensureSelectedAccount(accountId);
    }
    try {
      const service = await this.getAuthService(record);
      const result = await service.beginQr(new SteamAuthRequest(accountId, new SteamCredentialSet()));
      await this.applyAuthResult(record, result);
      SteamArkLog.info(TAG, 'QR sign-in request completed; temporaryAccount=' +
        SteamArkLog.accountId(accountId) + ', challenge=' + String(result.challenge));
      SteamArkLog.performance(TAG, 'QR sign-in request', startedAt);
      return result;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam QR sign-in failed');
      const authError = SteamAuthErrorSupport.normalize(
        normalized,
        SteamAuthErrorKind.AUTHENTICATION,
        'qr_begin',
        'Steam QR sign-in failed'
      );
      const service = this.authServices.get(accountId);
      if (service !== undefined) {
        try {
          await service.cancelPendingAuth(accountId);
        } catch {
          SteamArkLog.warn(TAG, 'Steam QR authentication cleanup failed; temporaryAccount=' +
            SteamArkLog.accountId(accountId));
        }
      }
      await this.recordAuthFailure(record, authError);
      SteamArkLog.warn(TAG, 'Steam QR sign-in failed for account state transition; temporaryAccount=' +
        SteamArkLog.accountId(accountId));
      throw authError;
    }
  }

  /** Stops account-owned sessions while retaining the account and its credentials. */
  async signOut(accountId: string): Promise<boolean> {
    return await this.runAccountOperation<boolean>(
      accountId,
      async (): Promise<boolean> => await this.signOutInternal(accountId),
      true
    );
  }

  private async signOutInternal(accountId: string): Promise<boolean> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      return false;
    }
    SteamArkLog.info(TAG, 'account sign-out started; account=' + SteamArkLog.accountId(normalizedId));
    try {
      await this.stopAccountActivity(normalizedId, false);
      record.pendingAuth = null;
      record.autoRestoreEnabled = false;
      record.session = new SteamSessionSnapshot(
        normalizedId,
        SteamSessionState.DISCONNECTED,
        record.profile.steamId64
      );
      await this.persistState();
      this.notifyListeners();
      SteamArkLog.info(TAG, 'account sign-out completed; account=' + SteamArkLog.accountId(normalizedId));
      return true;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam account sign-out failed');
      await this.recordAccountOperationFailure(record, normalized, 'sign_out');
      SteamArkLog.warn(TAG, 'account sign-out failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  /** Removes an account only after all account-owned runtime and secret state is closed. */
  async removeAccount(accountId: string): Promise<boolean> {
    return await this.runAccountOperation<boolean>(
      accountId,
      async (): Promise<boolean> => await this.removeAccountInternal(accountId),
      true
    );
  }

  private async removeAccountInternal(accountId: string): Promise<boolean> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      return false;
    }
    const credentialSnapshot = await this.captureAccountCredentialSnapshot(normalizedId);
    let credentialCleanupAttempted: boolean = false;
    let stateRemoved: boolean = false;
    let previousSelectedAccountId: string = '';
    let selectedAccountIdAfterRemoval: string = '';
    let selectionRequestGeneration: number = 0;
    SteamArkLog.info(TAG, 'account removal started; account=' + SteamArkLog.accountId(normalizedId));
    try {
      // Remove all account-owned runtimes and their persisted state before the
      // durable account record or secure credentials are touched. If any part of
      // this phase fails, the account record remains available for retry.
      await this.stopAccountActivity(normalizedId, true);
      credentialCleanupAttempted = true;
      const credentialsRemoved = await this.credentialStore.removeAll(normalizedId);
      if (!credentialsRemoved) {
        throw new Error('Steam account secure credential cleanup failed');
      }
      previousSelectedAccountId = this.selectedAccountId;
      selectionRequestGeneration = this.accountSelectionRequestGeneration;
      this.records.delete(normalizedId);
      this.ensureSelectedAccount('');
      selectedAccountIdAfterRemoval = this.selectedAccountId;
      stateRemoved = true;
      await this.persistState();
      // Sign-out retains durable account data; only a fully committed account deletion removes it.
      this.clearPersistedInventoryCache(normalizedId);
      SteamArkMarketPriceService.clearCachedAccount(normalizedId);
      SteamArkMessageCacheStore.clearCachedAccount(normalizedId);
      this.qrAuthenticationSelectionGenerations.delete(normalizedId);
      this.notifyListeners();
      SteamArkLog.info(TAG, 'account removal completed; account=' + SteamArkLog.accountId(normalizedId));
      return true;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam account removal failed');
      if (stateRemoved) {
        this.records.set(normalizedId, record);
        const canRestorePreviousSelection: boolean =
          selectionRequestGeneration === this.accountSelectionRequestGeneration &&
          this.selectedAccountId === selectedAccountIdAfterRemoval;
        if (canRestorePreviousSelection) {
          const selectedBeforeRollback = this.selectedAccountId;
          this.selectedAccountId = previousSelectedAccountId;
          this.logSelectedAccountChange(selectedBeforeRollback);
        } else {
          this.ensureSelectedAccount('');
          SteamArkLog.debug(TAG, 'account removal rollback retained a newer selection; account=' +
            SteamArkLog.accountId(normalizedId));
        }
      }
      if (credentialCleanupAttempted) {
        try {
          await this.restoreAccountCredentialSnapshot(normalizedId, credentialSnapshot);
        } catch (rollbackError) {
          SteamArkLog.error(TAG, 'account credential rollback failed; account=' +
            SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(rollbackError));
        }
      }
      if (stateRemoved) {
        try {
          await this.persistState();
        } catch {
          SteamArkLog.warn(TAG, 'account removal rollback state persistence failed; account=' +
            SteamArkLog.accountId(normalizedId));
        }
      }
      if (this.records.has(normalizedId)) {
        await this.recordAccountOperationFailure(record, normalized, 'remove_account');
      }
      SteamArkLog.warn(TAG, 'account removal failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  async cancelAuthentication(accountId: string): Promise<boolean> {
    return await this.runAccountOperation<boolean>(
      accountId,
      async (): Promise<boolean> => await this.cancelAuthenticationInternal(accountId),
      true
    );
  }

  private async cancelAuthenticationInternal(accountId: string): Promise<boolean> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    SteamArkLog.info(TAG, 'authentication cancellation started; account=' + SteamArkLog.accountId(normalizedId));
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      return false;
    }
    try {
      let firstFailure: Error | null = null;
      const service = this.authServices.get(normalizedId);
      if (service !== undefined) {
        try {
          await service.cancelPendingAuth(normalizedId);
        } catch (error) {
          firstFailure = error instanceof Error
            ? error
            : new Error('Steam authentication cancellation failed');
          SteamArkLog.warn(TAG, 'authentication pending cancellation failed; account=' +
            SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(error));
        }
      }
      try {
        await this.closeAuthService(normalizedId);
      } catch (error) {
        if (firstFailure === null) {
          firstFailure = error instanceof Error
            ? error
            : new Error('Steam authentication service close failed');
        }
        SteamArkLog.warn(TAG, 'authentication service close failed during cancellation; account=' +
          SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
      if (firstFailure !== null) {
        throw firstFailure;
      }
      record.pendingAuth = null;
       const removeTemporaryQrAccount = this.isTemporaryQrRecord(record);
      if (removeTemporaryQrAccount) {
        return await this.removeAccountInternal(normalizedId);
      }
      record.session = new SteamSessionSnapshot(
        normalizedId,
        SteamSessionState.DISCONNECTED,
        record.profile.steamId64,
        record.session.server
      );
      await this.persistState();
      this.notifyListeners();
      SteamArkLog.info(TAG, 'authentication cancellation completed; account=' +
        SteamArkLog.accountId(normalizedId) + ', removedTemporary=' + String(removeTemporaryQrAccount));
      return true;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam authentication cancellation failed');
      await this.recordAccountOperationFailure(record, normalized, 'cancel_authentication');
      SteamArkLog.warn(TAG, 'Steam authentication cancellation failed for account state transition; account=' +
        SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  async completeAuthChallenge(accountId: string, challengeCode: string): Promise<SteamAuthResult> {
    return await this.runAccountOperation<SteamAuthResult>(
      accountId,
      async (): Promise<SteamAuthResult> => await this.completeAuthChallengeInternal(accountId, challengeCode)
    );
  }

  private async completeAuthChallengeInternal(accountId: string, challengeCode: string): Promise<SteamAuthResult> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'authentication challenge completion started; account=' +
      SteamArkLog.accountId(normalizedId) + ', codeProvided=' + String(challengeCode.trim().length > 0));
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      throw new Error('Steam account does not exist');
    }
    try {
      const service = await this.getAuthService(record);
      const credentials = await this.getCredentials(normalizedId);
      const request = new SteamAuthRequest(
        normalizedId,
        credentials,
        challengeCode,
        this.challengeKindForRecord(record)
      );
      await this.restorePendingAuthIfNeeded(record, service, credentials);
      const result = await service.completeChallenge(request);
      await this.applyAuthResult(record, result);
      SteamArkLog.info(TAG, 'authentication challenge completed; account=' +
        SteamArkLog.accountId(normalizedId) + ', challenge=' + String(result.challenge) +
        ', state=' + String(result.session.state));
      SteamArkLog.performance(TAG, 'authentication challenge', startedAt);
      return result;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam Guard challenge failed');
      const authError = SteamAuthErrorSupport.normalize(
        normalized,
        SteamAuthErrorKind.AUTHENTICATION,
        'challenge_completion',
        'Steam Guard challenge failed'
      );
      await this.recordAuthFailure(record, authError);
      SteamArkLog.warn(TAG, 'Steam Guard challenge failed for account state transition; account=' +
        SteamArkLog.accountId(normalizedId));
      throw authError;
    }
  }

  async pollAuthentication(accountId: string): Promise<SteamAuthResult> {
    return await this.runAccountOperation<SteamAuthResult>(
      accountId,
      async (): Promise<SteamAuthResult> => await this.pollAuthenticationInternal(accountId)
    );
  }

  /**
   * Polls only when the caller still represents the exact active challenge.
   * UI timers use this entry so a callback from a rotated or cancelled QR
   * challenge cannot poll, complete, or fail its replacement challenge.
   */
  async pollAuthenticationIfCurrent(
    expected: SteamAuthPendingSnapshot
  ): Promise<SteamAuthResult | null> {
    const accountId: string = expected.accountId.trim();
    return await this.runAccountOperation<SteamAuthResult | null>(
      accountId,
      async (): Promise<SteamAuthResult | null> =>
        await this.pollAuthenticationIfCurrentInternal(expected)
    );
  }

  private async pollAuthenticationIfCurrentInternal(
    expected: SteamAuthPendingSnapshot
  ): Promise<SteamAuthResult | null> {
    await this.requireInitialized();
    const accountId: string = expected.accountId.trim();
    const record = this.records.get(accountId);
    if (record === undefined || record.pendingAuth === null ||
      !this.isSameAuthChallenge(record.pendingAuth, expected)) {
      SteamArkLog.debug(TAG, 'stale authentication poll skipped; account=' +
        SteamArkLog.accountId(accountId));
      return null;
    }
    if (record.pendingAuth.challenge !== SteamAuthChallengeKind.QR_SCAN &&
      record.pendingAuth.challenge !== SteamAuthChallengeKind.MOBILE_CONFIRMATION) {
      SteamArkLog.warn(TAG, 'automatic authentication poll rejected for non-pollable challenge; account=' +
        SteamArkLog.accountId(accountId) + ', challenge=' + String(record.pendingAuth.challenge));
      return null;
    }
    if (!record.pendingAuth.isValidFor(accountId, this.nowEpochSeconds())) {
      await this.expirePendingAuthentication(record);
      return null;
    }
    return await this.pollAuthenticationInternal(accountId);
  }

  private async pollAuthenticationInternal(accountId: string): Promise<SteamAuthResult> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    const startedAt: number = Date.now();
    SteamArkLog.debug(TAG, 'authentication polling started; account=' + SteamArkLog.accountId(normalizedId));
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      throw new Error('Steam account does not exist');
    }
    try {
      const service = await this.getAuthService(record);
      const credentials = await this.getCredentials(normalizedId);
      await this.restorePendingAuthIfNeeded(record, service, credentials);
      const result = await service.poll(normalizedId);
      await this.applyAuthResult(record, result);
      SteamArkLog.debug(TAG, 'authentication polling completed; account=' +
        SteamArkLog.accountId(normalizedId) + ', challenge=' + String(result.challenge) +
        ', state=' + String(result.session.state));
      SteamArkLog.performance(TAG, 'authentication polling', startedAt);
      return result;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam authentication polling failed');
      const authError = SteamAuthErrorSupport.normalize(
        normalized,
        SteamAuthErrorKind.AUTHENTICATION,
        'poll',
        'Steam authentication polling failed'
      );
      await this.recordAuthFailure(record, authError);
      SteamArkLog.warn(TAG, 'Steam authentication polling failed for account state transition; account=' +
        SteamArkLog.accountId(normalizedId));
      throw authError;
    }
  }

  async refreshAuthentication(accountId: string): Promise<SteamAuthResult> {
    return await this.runAccountOperation<SteamAuthResult>(
      accountId,
      async (): Promise<SteamAuthResult> => await this.refreshAuthenticationInternal(accountId)
    );
  }

  private async refreshAuthenticationInternal(accountId: string): Promise<SteamAuthResult> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'authentication refresh started; account=' + SteamArkLog.accountId(normalizedId));
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      throw new Error('Steam account does not exist');
    }
    try {
      const service = await this.getAuthService(record);
      const credentials = await this.getCredentials(normalizedId);
      const result = await service.refresh(normalizedId, credentials.refreshToken);
      await this.applyAuthResult(record, result);
      SteamArkLog.info(TAG, 'authentication refresh completed; account=' +
        SteamArkLog.accountId(normalizedId) + ', state=' + String(result.session.state));
      SteamArkLog.performance(TAG, 'authentication refresh', startedAt);
      return result;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam token refresh failed');
      const authError = SteamAuthErrorSupport.normalize(
        normalized,
        SteamAuthErrorKind.AUTHENTICATION,
        'token_refresh',
        'Steam token refresh failed'
      );
      await this.recordAuthFailure(record, authError);
      SteamArkLog.warn(TAG, 'Steam token refresh failed for account state transition; account=' +
        SteamArkLog.accountId(normalizedId));
      throw authError;
    }
  }

  async syncInventory(accountId: string, query: SteamInventoryQuery): Promise<SteamInventoryPage> {
    return await this.runAccountOperation<SteamInventoryPage>(
      accountId,
      async (): Promise<SteamInventoryPage> => await this.syncInventoryInternal(accountId, query)
    );
  }

  private async syncInventoryInternal(accountId: string, query: SteamInventoryQuery): Promise<SteamInventoryPage> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'read-only inventory sync started; account=' + SteamArkLog.accountId(normalizedId) +
      ', startAssetId=' + SteamArkLog.accountId(query.startAssetId) +
      ', searchLength=' + query.search.length.toString());
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      throw new Error('Steam account does not exist');
    }
    if (record.session.state !== SteamSessionState.LOGGED_ON) {
      throw new Error('Steam account must be logged on before inventory synchronization');
    }
    if (record.profile.steamId64.length <= 0) {
      throw new Error('Steam account SteamID64 is required before inventory synchronization');
    }
    const factory = this.inventoryAdapterFactory;
    if (factory === null) {
      throw new Error('Steam inventory adapter is not configured');
    }

    let adapter = this.inventoryAdapters.get(normalizedId);
    if (adapter === undefined) {
      const profile = this.copyProfile(record.profile);
      const proxyPassword = await this.readProxyPassword(normalizedId);
      adapter = factory.create(profile, proxyPassword);
      this.inventoryAdapters.set(normalizedId, adapter);
    }

    try {
      if (adapter.session.state !== SteamSessionState.LOGGED_ON) {
        const credentials = await this.getCredentials(normalizedId);
        const opened = await adapter.open(normalizedId, credentials);
        if (this.shouldAcceptAdapterSession(record, opened)) {
          this.applySessionToRecord(record, opened);
          await this.persistState();
        }
      }
      const page = await adapter.sync(normalizedId, query);
      if (this.isFirstPersistableInventoryPage(query)) {
        const previousFirstPage: SteamInventoryPage | undefined = this.latestInventoryPages.get(normalizedId);
        if (this.shouldClearPersistableDefaultInventoryContinuationPages(previousFirstPage, page)) {
          this.clearPersistableDefaultInventoryContinuationPages(normalizedId);
        }
      }
      this.inventoryPages.set(this.inventoryCacheKey(normalizedId, query), page);
      if (this.isPersistableDefaultInventoryQuery(query)) {
        if (this.isFirstPersistableInventoryPage(query)) {
          this.latestInventoryPages.set(normalizedId, page);
        }
        this.savePersistedInventoryPages(normalizedId);
      }
      this.notifyListeners();
      SteamArkLog.info(TAG, 'read-only inventory sync completed; account=' +
        SteamArkLog.accountId(normalizedId) + ', items=' + page.items.length.toString() +
        ', total=' + page.totalCount.toString());
      SteamArkLog.performance(TAG, 'inventory synchronization', startedAt);
      return page;
    } catch (error) {
      const normalized = error instanceof Error
        ? error
        : new Error('Steam inventory synchronization failed');
      const session = adapter.session;
      if (session.accountId.length > 0 && this.shouldAcceptAdapterSession(record, session)) {
        this.applySessionToRecord(record, session);
        try {
          await this.persistState();
        } catch {
          SteamArkLog.warn(TAG, 'inventory error state persistence failed');
        }
        this.notifyListeners();
      }
      SteamArkLog.warn(TAG, 'read-only inventory synchronization failed; account=' +
        SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(error));
      throw normalized;
    }
  }

  async getCachedInventory(accountId: string, query: SteamInventoryQuery): Promise<SteamInventoryPage | null> {
    await this.requireInitialized();
    const page = this.inventoryPages.get(this.inventoryCacheKey(accountId.trim(), query));
    SteamArkLog.debug(TAG, 'cached inventory lookup; account=' + SteamArkLog.accountId(accountId) +
      ', hit=' + String(page !== undefined));
    return page === undefined ? null : page;
  }

  getLatestInventoryPage(accountId: string): SteamInventoryPage | null {
    const normalizedId: string = accountId.trim();
    if (normalizedId.length <= 0) {
      return null;
    }
    return this.latestInventoryPages.get(normalizedId) ?? null;
  }

  /** Returns the contiguous cached default Steam inventory pages restored for an account. */
  getCachedDefaultInventoryPages(accountId: string): Array<SteamInventoryPage> {
    const normalizedId: string = accountId.trim();
    if (normalizedId.length <= 0) {
      return [];
    }
    return this.collectPersistableDefaultInventoryPages(normalizedId);
  }

  getInventorySummary(accountId: string): SteamArkInventorySummary {
    const firstPage: SteamInventoryPage | null = this.getLatestInventoryPage(accountId);
    if (firstPage === null) {
      return new SteamArkInventorySummary();
    }
    const normalizedId: string = accountId.trim();
    const seenAssetIds: Map<string, boolean> = new Map<string, boolean>();
    let page: SteamInventoryPage | null = firstPage;
    let loadedItemCount: number = 0;
    let cardCount: number = 0;
    let isComplete: boolean = false;
    while (page !== null) {
      for (let index: number = 0; index < page.items.length; index++) {
        const item: SteamInventoryItem = page.items[index];
        if (seenAssetIds.has(item.assetId)) {
          continue;
        }
        seenAssetIds.set(item.assetId, true);
        loadedItemCount += 1;
        if (item.isTradingCard) {
          cardCount += item.amount;
        }
      }
      if (!page.hasMore) {
        isComplete = true;
        break;
      }
      if (page.nextStartAssetId.length <= 0) {
        break;
      }
      const nextQuery = new SteamInventoryQuery(
        page.query.appId,
        page.query.contextId,
        page.query.page + 1,
        page.query.pageSize,
        page.query.search,
        page.query.marketableOnly,
        page.query.tradableOnly,
        page.nextStartAssetId,
        page.query.language
      );
      const nextPage = this.inventoryPages.get(this.inventoryCacheKey(normalizedId, nextQuery));
      page = nextPage === undefined ? null : nextPage;
    }
    return new SteamArkInventorySummary(
      firstPage.totalCount,
      loadedItemCount,
      cardCount,
      true,
      isComplete,
      firstPage.syncedAtEpochSeconds
    );
  }

  rememberInventoryPage(accountId: string, page: SteamInventoryPage): void {
    const normalizedId: string = accountId.trim();
    if (normalizedId.length <= 0) {
      return;
    }
    if (this.isFirstPersistableInventoryPage(page.query)) {
      const previousFirstPage: SteamInventoryPage | undefined = this.latestInventoryPages.get(normalizedId);
      if (this.shouldClearPersistableDefaultInventoryContinuationPages(previousFirstPage, page)) {
        this.clearPersistableDefaultInventoryContinuationPages(normalizedId);
      }
    }
    this.inventoryPages.set(this.inventoryCacheKey(normalizedId, page.query), page);
    if (this.isPersistableDefaultInventoryQuery(page.query)) {
      if (this.isFirstPersistableInventoryPage(page.query)) {
        this.latestInventoryPages.set(normalizedId, page);
      }
      this.savePersistedInventoryPages(normalizedId);
    }
    this.notifyListeners();
  }

  private persistedInventoryCacheKey(accountId: string): string {
    return 'steam.inventory.' + encodeURIComponent(accountId.trim()) + '.753.6';
  }

  private isPersistableDefaultInventoryQuery(query: SteamInventoryQuery): boolean {
    return query.appId === '753' && query.contextId === '6' && query.search.length === 0 &&
      !query.marketableOnly && !query.tradableOnly;
  }

  private isFirstPersistableInventoryPage(query: SteamInventoryQuery): boolean {
    return this.isPersistableDefaultInventoryQuery(query) && query.page === 1 &&
      query.startAssetId.length <= 0;
  }

  private collectPersistableDefaultInventoryPages(accountId: string): Array<SteamInventoryPage> {
    const pages: Array<SteamInventoryPage> = [];
    const normalizedId: string = accountId.trim();
    const firstPage: SteamInventoryPage | undefined = this.latestInventoryPages.get(normalizedId);
    let page: SteamInventoryPage | null = firstPage === undefined ? null : firstPage;
    let expectedPageNumber: number = 1;
    let expectedStartAssetId: string = '';
    while (page !== null && this.isPersistableDefaultInventoryQuery(page.query) &&
      page.query.page === expectedPageNumber && page.query.startAssetId === expectedStartAssetId) {
      pages.push(page);
      if (!page.hasMore || page.nextStartAssetId.length <= 0) {
        break;
      }
      expectedPageNumber += 1;
      expectedStartAssetId = page.nextStartAssetId;
      const nextQuery = new SteamInventoryQuery(
        page.query.appId,
        page.query.contextId,
        expectedPageNumber,
        page.query.pageSize,
        '',
        false,
        false,
        expectedStartAssetId,
        page.query.language
      );
      const nextPage: SteamInventoryPage | undefined = this.inventoryPages.get(
        this.inventoryCacheKey(normalizedId, nextQuery)
      );
      page = nextPage === undefined ? null : nextPage;
    }
    return pages;
  }

  private clearPersistableDefaultInventoryContinuationPages(accountId: string): void {
    const normalizedId: string = accountId.trim();
    const keys: Array<string> = [];
    this.inventoryPages.forEach((page: SteamInventoryPage, key: string): void => {
      if (key.indexOf(normalizedId + '|') === 0 && this.isPersistableDefaultInventoryQuery(page.query) &&
        !this.isFirstPersistableInventoryPage(page.query)) {
        keys.push(key);
      }
    });
    for (let index: number = 0; index < keys.length; index++) {
      this.inventoryPages.delete(keys[index]);
    }
  }

  private shouldClearPersistableDefaultInventoryContinuationPages(
    previousFirstPage: SteamInventoryPage | undefined,
    refreshedFirstPage: SteamInventoryPage
  ): boolean {
    if (!refreshedFirstPage.hasMore || refreshedFirstPage.nextStartAssetId.length <= 0 ||
      previousFirstPage === undefined || !previousFirstPage.hasMore ||
      previousFirstPage.nextStartAssetId.length <= 0) {
      return true;
    }
    return previousFirstPage.nextStartAssetId !== refreshedFirstPage.nextStartAssetId ||
      previousFirstPage.totalCount !== refreshedFirstPage.totalCount ||
      previousFirstPage.query.pageSize !== refreshedFirstPage.query.pageSize ||
      previousFirstPage.query.language !== refreshedFirstPage.query.language;
  }

  private savePersistedInventoryPages(accountId: string): void {
    try {
      const pages: Array<SteamInventoryPage> = this.collectPersistableDefaultInventoryPages(accountId);
      if (pages.length <= 0) {
        return;
      }
      const document = new SteamArkCachedInventoryDocument(accountId, pages);
      ngfContentCacheFacade.put(
        this.persistedInventoryCacheKey(accountId),
        JSON.stringify(document),
        INVENTORY_CACHE_TTL_MS
      );
    } catch (error) {
      SteamArkLog.warn(TAG, 'inventory cache write failed; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private restorePersistedInventoryPage(accountId: string): void {
    const cacheKey: string = this.persistedInventoryCacheKey(accountId);
    const serialized: string = ngfContentCacheFacade.get(cacheKey);
    if (serialized.trim().length <= 0) {
      return;
    }
    try {
      const root: SteamJsonValue = SteamJsonParser.parse(serialized, steamArkCoreLogger);
      if (root.kind !== SteamJsonValueKind.OBJECT) {
        throw new Error('inventory cache root is not an object');
      }
      const cachedAccountId: string = this.readString(root.getProperty('accountId'), '');
      if (cachedAccountId !== accountId) {
        throw new Error('inventory cache account does not match');
      }
      const pagesValue: SteamJsonValue | null = root.getProperty('pages');
      if (pagesValue !== null && pagesValue.kind === SteamJsonValueKind.ARRAY) {
        this.restorePersistedInventoryPages(accountId, pagesValue);
        return;
      }
      this.restoreLegacyPersistedInventoryPage(accountId, root);
    } catch (error) {
      ngfContentCacheFacade.remove(cacheKey);
      SteamArkLog.warn(TAG, 'inventory cache ignored; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private restorePersistedInventoryPages(accountId: string, pagesValue: SteamJsonValue): void {
    const restoredPages: Array<SteamInventoryPage> = [];
    let expectedPageNumber: number = 1;
    let expectedStartAssetId: string = '';
    for (let index: number = 0; index < pagesValue.items.length; index++) {
      const value: SteamJsonValue = pagesValue.items[index];
      if (value.kind !== SteamJsonValueKind.OBJECT) {
        throw new Error('inventory cache page is not an object');
      }
      const page: SteamInventoryPage | null = this.readCachedInventoryPage(value);
      if (page === null || !this.isPersistableDefaultInventoryQuery(page.query) ||
        page.query.page !== expectedPageNumber || page.query.startAssetId !== expectedStartAssetId) {
        throw new Error('inventory cache pagination chain is invalid');
      }
      restoredPages.push(page);
      if (!page.hasMore || page.nextStartAssetId.length <= 0) {
        if (index + 1 < pagesValue.items.length) {
          throw new Error('inventory cache has unreachable pagination pages');
        }
        break;
      }
      expectedPageNumber += 1;
      expectedStartAssetId = page.nextStartAssetId;
    }
    if (restoredPages.length <= 0) {
      throw new Error('inventory cache pages are missing');
    }
    this.applyRestoredInventoryPages(accountId, restoredPages);
  }

  private restoreLegacyPersistedInventoryPage(accountId: string, root: SteamJsonValue): void {
    const page: SteamInventoryPage | null = this.readCachedInventoryPage(root);
    if (page === null || !this.isFirstPersistableInventoryPage(page.query)) {
      throw new Error('inventory cache is not a valid legacy first page');
    }
    this.applyRestoredInventoryPages(accountId, [page]);
  }

  private readCachedInventoryPage(root: SteamJsonValue): SteamInventoryPage | null {
    const itemsValue: SteamJsonValue | null = root.getProperty('items');
    const syncedAtEpochSeconds: number = this.readInteger(root.getProperty('syncedAtEpochSeconds'), 0);
    if (itemsValue === null || itemsValue.kind !== SteamJsonValueKind.ARRAY || syncedAtEpochSeconds <= 0) {
      return null;
    }
    const items: Array<SteamInventoryItem> = this.readCachedInventoryItems(itemsValue);
    const query = new SteamInventoryQuery(
      this.readString(root.getProperty('appId'), '753'),
      this.readString(root.getProperty('contextId'), '6'),
      this.readInteger(root.getProperty('page'), 1),
      this.readInteger(root.getProperty('pageSize'), 100),
      '',
      false,
      false,
      this.readString(root.getProperty('startAssetId'), ''),
      this.readString(root.getProperty('language'), 'english')
    );
    return new SteamInventoryPage(
      query,
      items,
      this.readInteger(root.getProperty('totalCount'), items.length),
      this.readBoolean(root.getProperty('hasMore'), false),
      syncedAtEpochSeconds,
      this.readString(root.getProperty('nextStartAssetId'), '')
    );
  }

  private readCachedInventoryItems(itemsValue: SteamJsonValue): Array<SteamInventoryItem> {
    const items: Array<SteamInventoryItem> = [];
    for (let index: number = 0; index < itemsValue.items.length; index++) {
      const value: SteamJsonValue = itemsValue.items[index];
      if (value.kind !== SteamJsonValueKind.OBJECT) {
        continue;
      }
      const item = new SteamInventoryItem(
        this.readString(value.getProperty('assetId'), ''),
        this.readString(value.getProperty('classId'), ''),
        this.readString(value.getProperty('instanceId'), '0'),
        this.readString(value.getProperty('appId'), '753'),
        this.readString(value.getProperty('contextId'), '6'),
        this.readInteger(value.getProperty('amount'), 1),
        this.readString(value.getProperty('name'), ''),
        this.readString(value.getProperty('type'), ''),
        this.readBoolean(value.getProperty('marketable'), false),
        this.readBoolean(value.getProperty('tradable'), false),
        this.readInventoryCardDropState(value.getProperty('cardDropState')),
        this.readInteger(value.getProperty('originalAmount'), 1),
        this.readString(value.getProperty('description'), ''),
        this.readString(value.getProperty('iconUrl'), ''),
        this.readString(value.getProperty('iconUrlLarge'), ''),
        this.readString(value.getProperty('marketHashName'), ''),
        this.readString(value.getProperty('marketName'), ''),
        this.readBoolean(value.getProperty('isTradingCard'), false),
        this.readInteger(value.getProperty('assetStatus'), 0),
        this.readString(value.getProperty('ownerAppId'), ''),
        this.readString(value.getProperty('ownerAppName'), '')
      );
      if (item.assetId.length > 0 && item.classId.length > 0) {
        items.push(item);
      }
    }
    return items;
  }

  private applyRestoredInventoryPages(accountId: string, pages: Array<SteamInventoryPage>): void {
    for (let index: number = 0; index < pages.length; index++) {
      this.inventoryPages.set(this.inventoryCacheKey(accountId, pages[index].query), pages[index]);
    }
    this.latestInventoryPages.set(accountId, pages[0]);
    SteamArkLog.info(TAG, 'inventory cache restored; account=' + SteamArkLog.accountId(accountId) +
      ', pages=' + pages.length.toString() + ', items=' + pages[0].items.length.toString());
  }

  private readInventoryCardDropState(value: SteamJsonValue | null): SteamInventoryCardDropState {
    const raw: string = this.readString(value, '');
    if (raw === SteamInventoryCardDropState.AVAILABLE) {
      return SteamInventoryCardDropState.AVAILABLE;
    }
    if (raw === SteamInventoryCardDropState.DROPPED) {
      return SteamInventoryCardDropState.DROPPED;
    }
    if (raw === SteamInventoryCardDropState.NOT_APPLICABLE) {
      return SteamInventoryCardDropState.NOT_APPLICABLE;
    }
    return SteamInventoryCardDropState.UNKNOWN;
  }

  async getInventoryItem(accountId: string, assetId: string): Promise<SteamInventoryItem | null> {
    await this.requireInitialized();
    let found: SteamInventoryItem | null = null;
    const prefix = accountId.trim() + '|';
    this.inventoryPages.forEach((page: SteamInventoryPage, key: string): void => {
      if (found !== null || key.indexOf(prefix) !== 0) {
        return;
      }
      for (let index = 0; index < page.items.length; index++) {
        if (page.items[index].assetId === assetId) {
          found = page.items[index];
          return;
        }
      }
    });
    SteamArkLog.debug(TAG, 'inventory item lookup; account=' + SteamArkLog.accountId(accountId) +
      ', asset=' + SteamArkLog.accountId(assetId) + ', found=' + String(found !== null));
    return found;
  }

  async closeInventory(accountId: string): Promise<void> {
    await this.runAccountOperation<void>(
      accountId,
      async (): Promise<void> => await this.closeInventoryInternal(accountId),
      true
    );
  }

  private async closeInventoryInternal(accountId: string): Promise<void> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    SteamArkLog.debug(TAG, 'inventory session close requested; account=' + SteamArkLog.accountId(normalizedId));
    const adapter = this.inventoryAdapters.get(normalizedId);
    if (adapter === undefined) {
      this.clearInventoryCache(normalizedId);
      return;
    }
    try {
      await adapter.close(normalizedId);
    } finally {
      // A failed close leaves the adapter in an unknown transport state. It must
      // never be handed back to a later request, especially after a proxy change.
      if (this.inventoryAdapters.get(normalizedId) === adapter) {
        this.inventoryAdapters.delete(normalizedId);
      }
      this.clearInventoryCache(normalizedId);
    }
    SteamArkLog.info(TAG, 'inventory session closed; account=' + SteamArkLog.accountId(normalizedId));
  }

  async importAsfBotJson(sourceName: string, json: string): Promise<SteamArkImportSummary> {
    await this.requireInitialized();
    const accountId = this.readAsfAccountName(json);
    const result = SteamAsfJsonImporter.importBotConfig(json, accountId, steamArkCoreLogger);
    return await this.runAccountOperation<SteamArkImportSummary>(
      accountId,
      async (): Promise<SteamArkImportSummary> =>
        await this.importAsfBotJsonInternal(sourceName, json, accountId, result),
      true
    );
  }

  private async importAsfBotJsonInternal(
    sourceName: string,
    json: string,
    accountId: string,
    result: SteamBotConfigImportResult
  ): Promise<SteamArkImportSummary> {
    await this.requireInitialized();
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'ASF bot JSON import started; sourceLength=' + json.length.toString());
    if (accountId.length <= 0) {
      throw new Error('ASF bot JSON SteamLogin is required');
    }
    let record = this.records.get(accountId);
    const previousRecord = record === undefined ? null : this.copyRecord(record);
    const previousSelectedAccountId = this.selectedAccountId;
    const selectionRequestGeneration = this.accountSelectionRequestGeneration;
    const credentialSnapshot = await this.captureAccountCredentialSnapshot(accountId);
    const hadExistingRecord: boolean = record !== undefined;
    let selectedAccountIdAfterImport: string = '';
    let selectionAdjustedByImport: boolean = false;
    if (record !== undefined) {
      await this.stopAccountActivity(accountId, false);
    }
    if (record === undefined) {
      record = new SteamArkAccountRecord(
        new SteamAccountProfile(accountId, accountId),
        new SteamBotConfig(accountId),
        new SteamSessionSnapshot(accountId)
      );
      this.records.set(accountId, record);
    }

    try {
      await this.replaceImportedCredentials(accountId, result.credentials, credentialSnapshot);
      record.config = this.copyBotConfig(result.config, accountId);
      record.profile.displayName = accountId;
      record.profile.enabled = result.config.enabled;
      record.pendingAuth = null;
      record.session = new SteamSessionSnapshot(accountId, SteamSessionState.DISCONNECTED, record.profile.steamId64);
      record.migrationReport = this.toMigrationReport(sourceName, result.report);
      record.hasCredentialMaterial = await this.hasSecureCredentials(accountId);
      if (selectionRequestGeneration === this.accountSelectionRequestGeneration) {
        this.ensureSelectedAccount(accountId);
      } else {
        this.ensureSelectedAccount('');
        SteamArkLog.debug(TAG, 'ASF bot JSON import retained a newer account selection; account=' +
          SteamArkLog.accountId(accountId));
      }
      selectedAccountIdAfterImport = this.selectedAccountId;
      selectionAdjustedByImport = selectedAccountIdAfterImport !== previousSelectedAccountId;
      await this.persistState();
      this.notifyListeners();
      SteamArkLog.info(TAG, 'ASF bot JSON import completed; account=' +
        SteamArkLog.accountId(accountId) + ', unknownFields=' +
        record.migrationReport.unknownFields.length.toString());
      SteamArkLog.performance(TAG, 'ASF bot JSON import', startedAt);
      return new SteamArkImportSummary(this.toSnapshot(record), sourceName);
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('ASF bot JSON import failed');
      if (hadExistingRecord && previousRecord !== null) {
        this.restoreRecord(record, previousRecord);
      } else {
        this.records.delete(accountId);
      }
      const canRestorePreviousSelection: boolean = selectionAdjustedByImport &&
        selectionRequestGeneration === this.accountSelectionRequestGeneration &&
        this.selectedAccountId === selectedAccountIdAfterImport;
      if (canRestorePreviousSelection) {
        const selectedBeforeRollback = this.selectedAccountId;
        this.selectedAccountId = previousSelectedAccountId;
        this.logSelectedAccountChange(selectedBeforeRollback);
      } else {
        this.ensureSelectedAccount('');
        SteamArkLog.debug(TAG, 'ASF bot JSON import rollback retained a newer account selection; account=' +
          SteamArkLog.accountId(accountId));
      }
      try {
        await this.restoreAccountCredentialSnapshot(accountId, credentialSnapshot);
      } catch (rollbackError) {
        SteamArkLog.error(TAG, 'ASF bot JSON credential rollback failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(rollbackError));
      }
      try {
        await this.persistState();
      } catch {
        SteamArkLog.warn(TAG, 'ASF bot JSON import rollback state persistence failed; account=' +
          SteamArkLog.accountId(accountId));
      }
      SteamArkLog.warn(TAG, 'ASF bot JSON import rolled back; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  async importMaFile(sourceName: string, json: string): Promise<SteamArkImportSummary> {
    await this.requireInitialized();
    const parsed = SteamMaFileImporter.importMaFile(json, steamArkCoreLogger);
    const importedAccountId = parsed.credentials.accountName.trim();
    let accountId: string = this.findAccountIdBySteamId64(parsed.steamId64);
    if (accountId.length <= 0 && importedAccountId.length > 0) {
      accountId = await this.findAccountIdByAccountName(importedAccountId);
    }
    if (accountId.length <= 0) {
      accountId = importedAccountId.length > 0 ? importedAccountId : parsed.steamId64;
    }
    return await this.runAccountOperation<SteamArkImportSummary>(
      accountId,
      async (): Promise<SteamArkImportSummary> =>
        await this.importMaFileInternal(sourceName, json, accountId, parsed),
      true
    );
  }

  private async importMaFileInternal(
    sourceName: string,
    json: string,
    accountId: string,
    result: SteamMaFileImportResult
  ): Promise<SteamArkImportSummary> {
    await this.requireInitialized();
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'maFile import started; sourceLength=' + json.length.toString());
    const importedAccountId = result.credentials.accountName.trim();
    let record = this.records.get(accountId);
    const previousRecord = record === undefined ? null : this.copyRecord(record);
    const previousSelectedAccountId = this.selectedAccountId;
    const selectionRequestGeneration = this.accountSelectionRequestGeneration;
    const credentialSnapshot = await this.captureAccountCredentialSnapshot(accountId);
    const hadExistingRecord: boolean = record !== undefined;
    const mergedExistingAccount: boolean = record !== undefined;
    let selectedAccountIdAfterImport: string = '';
    let selectionAdjustedByImport: boolean = false;
    if (record === undefined) {
      record = new SteamArkAccountRecord(
        new SteamAccountProfile(accountId, importedAccountId.length > 0 ? importedAccountId : result.steamId64, result.steamId64),
        new SteamBotConfig(accountId),
        new SteamSessionSnapshot(accountId, SteamSessionState.DISCONNECTED, result.steamId64)
      );
      this.records.set(accountId, record);
    } else {
      if (result.steamId64.length > 0) {
        record.profile.steamId64 = result.steamId64;
      }
      if (importedAccountId.length > 0 && record.profile.displayName.length <= 0) {
        record.profile.displayName = importedAccountId;
      }
    }

    try {
      if (hadExistingRecord) {
        await this.replaceMaFileAuthenticatorCredentials(accountId, result.credentials);
      } else {
        await this.replaceStoredCredentials(accountId, result.credentials);
      }
      record.migrationReport = this.toMigrationReport(sourceName, result.report);
      record.hasCredentialMaterial = await this.hasSecureCredentials(accountId);
      if (selectionRequestGeneration === this.accountSelectionRequestGeneration) {
        this.ensureSelectedAccount(accountId);
      } else {
        this.ensureSelectedAccount('');
        SteamArkLog.debug(TAG, 'maFile import retained a newer account selection; account=' +
          SteamArkLog.accountId(accountId));
      }
      selectedAccountIdAfterImport = this.selectedAccountId;
      selectionAdjustedByImport = selectedAccountIdAfterImport !== previousSelectedAccountId;
      await this.persistState();
      this.notifyListeners();
      SteamArkLog.info(TAG, 'maFile import completed; account=' + SteamArkLog.accountId(accountId) +
        ', steamId64=' + SteamArkLog.steamId64(result.steamId64) + ', unknownFields=' +
        record.migrationReport.unknownFields.length.toString());
      SteamArkLog.performance(TAG, 'maFile import', startedAt);
      SteamArkLog.info(TAG, 'maFile import merge decision; account=' + SteamArkLog.accountId(accountId) +
        ', mergedExistingAccount=' + String(mergedExistingAccount) +
        ', sessionPreserved=' + String(mergedExistingAccount));
      return new SteamArkImportSummary(this.toSnapshot(record), sourceName, mergedExistingAccount);
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('maFile import failed');
      if (hadExistingRecord && previousRecord !== null) {
        this.restoreRecord(record, previousRecord);
      } else {
        this.records.delete(accountId);
      }
      const canRestorePreviousSelection: boolean = selectionAdjustedByImport &&
        selectionRequestGeneration === this.accountSelectionRequestGeneration &&
        this.selectedAccountId === selectedAccountIdAfterImport;
      if (canRestorePreviousSelection) {
        const selectedBeforeRollback = this.selectedAccountId;
        this.selectedAccountId = previousSelectedAccountId;
        this.logSelectedAccountChange(selectedBeforeRollback);
      } else {
        this.ensureSelectedAccount('');
        SteamArkLog.debug(TAG, 'maFile import rollback retained a newer account selection; account=' +
          SteamArkLog.accountId(accountId));
      }
      try {
        await this.restoreAccountCredentialSnapshot(accountId, credentialSnapshot);
      } catch (rollbackError) {
        SteamArkLog.error(TAG, 'maFile credential rollback failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(rollbackError));
      }
      try {
        await this.persistState();
      } catch {
        SteamArkLog.warn(TAG, 'maFile import rollback state persistence failed; account=' +
          SteamArkLog.accountId(accountId));
      }
      SteamArkLog.warn(TAG, 'maFile import rolled back; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  async importAsfGlobalJson(sourceName: string, json: string): Promise<SteamArkGlobalImportSummary> {
    return await this.runGlobalOperation<SteamArkGlobalImportSummary>(
      async (): Promise<SteamArkGlobalImportSummary> =>
        await this.importAsfGlobalJsonInternal(sourceName, json)
    );
  }

  private async importAsfGlobalJsonInternal(
    sourceName: string,
    json: string
  ): Promise<SteamArkGlobalImportSummary> {
    await this.requireInitialized();
    const startedAt: number = Date.now();
    SteamArkLog.info(TAG, 'ASF global JSON import started; sourceLength=' + json.length.toString());
    const result: SteamGlobalConfigImportResult = SteamAsfJsonImporter.importGlobalConfig(json, steamArkCoreLogger);
    const previousConfig = this.globalConfig.clone();
    const previousMigrationReport = this.copyMigrationReport(this.globalMigrationReport);
    const previousHasCredentialMaterial: boolean = this.hasGlobalCredentialMaterial;
    const credentialSnapshot = await this.captureGlobalCredentialSnapshot();
    try {
      this.globalConfig = result.config.clone();
      this.globalMigrationReport = this.toMigrationReport(sourceName, result.report);
      await this.storeGlobalCredentials(result.secrets, credentialSnapshot);
      this.hasGlobalCredentialMaterial = await this.hasGlobalSecureCredentials();
      await this.persistGlobalState();
      this.notifyListeners();
      SteamArkLog.info(TAG, 'ASF global JSON import completed; unknownFields=' +
        this.globalMigrationReport.unknownFields.length.toString());
      SteamArkLog.performance(TAG, 'ASF global JSON import', startedAt);
      return new SteamArkGlobalImportSummary(this.getGlobalConfigSnapshot(), sourceName);
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('ASF global JSON import failed');
      this.globalConfig = previousConfig;
      this.globalMigrationReport = previousMigrationReport;
      this.hasGlobalCredentialMaterial = previousHasCredentialMaterial;
      try {
        await this.restoreGlobalCredentialSnapshot(credentialSnapshot);
      } catch (rollbackError) {
        SteamArkLog.error(TAG, 'ASF global credential rollback failed; errorType=' +
          SteamArkLog.errorKind(rollbackError));
      }
      try {
        await this.persistGlobalState();
      } catch {
        SteamArkLog.warn(TAG, 'ASF global import rollback state persistence failed');
      }
      SteamArkLog.warn(TAG, 'ASF global JSON import rolled back; errorType=' +
        SteamArkLog.errorKind(normalized));
      throw normalized;
    }
  }

  async selectAccount(accountId: string): Promise<boolean> {
    const normalizedId = accountId.trim();
    this.accountSelectionRequestGeneration += 1;
    const requestGeneration: number = this.accountSelectionRequestGeneration;
    return await this.runGlobalOperation<boolean>(
      async (): Promise<boolean> => await this.selectAccountInternal(normalizedId, requestGeneration)
    );
  }

  private async selectAccountInternal(accountId: string, requestGeneration: number): Promise<boolean> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    SteamArkLog.info(TAG, 'account selection requested; account=' + SteamArkLog.accountId(normalizedId));
    if (!this.isCurrentAccountSelectionRequest(requestGeneration)) {
      SteamArkLog.debug(TAG, 'account selection skipped because a newer request exists; account=' +
        SteamArkLog.accountId(normalizedId));
      return false;
    }
    if (!this.records.has(normalizedId)) {
      SteamArkLog.warn(TAG, 'account selection rejected; account not found');
      return false;
    }
    this.selectedAccountId = normalizedId;
    await this.persistState();
    if (!this.isCurrentAccountSelectionRequest(requestGeneration)) {
      SteamArkLog.debug(TAG, 'account selection result suppressed because a newer request exists; account=' +
        SteamArkLog.accountId(normalizedId));
      return false;
    }
    this.notifyListeners();
    SteamArkLog.info(TAG, 'account selected; account=' + SteamArkLog.accountId(normalizedId));
    return true;
  }

  private isCurrentAccountSelectionRequest(requestGeneration: number): boolean {
    return !this.isDisposing && requestGeneration === this.accountSelectionRequestGeneration;
  }

  async saveProxy(
    accountId: string,
    proxy: SteamProxySettings,
    proxyPassword: string | null = null
  ): Promise<boolean> {
    return await this.runAccountOperation<boolean>(
      accountId,
      async (): Promise<boolean> => await this.saveProxyInternal(accountId, proxy, proxyPassword),
      true
    );
  }

  private async saveProxyInternal(
    accountId: string,
    proxy: SteamProxySettings,
    proxyPassword: string | null = null
  ): Promise<boolean> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    SteamArkLog.info(TAG, 'proxy settings save started; account=' + SteamArkLog.accountId(normalizedId) +
      ', kind=' + String(proxy.kind));
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      return false;
    }
    this.validateProxy(proxy);
    const previousRecord: SteamArkAccountRecord = this.copyRecord(record);
    const previousProxy = new SteamProxySettings(
      record.profile.proxy.kind,
      record.profile.proxy.host,
      record.profile.proxy.port,
      record.profile.proxy.username
    );
    const nextProxy = new SteamProxySettings(proxy.kind, proxy.host, proxy.port, proxy.username);
    const previousProxyPassword: string = await this.readProxyPassword(normalizedId);
    let nextProxyPassword: string = previousProxyPassword;
    if (nextProxy.kind === SteamProxyKind.DIRECT || nextProxy.kind === SteamProxyKind.SYSTEM) {
      nextProxyPassword = '';
    } else if (proxyPassword !== null) {
      nextProxyPassword = proxyPassword;
    }
    const proxyChanged: boolean = !this.isSameProxySettings(previousProxy, nextProxy);
    const proxyPasswordChanged: boolean = previousProxyPassword !== nextProxyPassword;
    if (!proxyChanged && !proxyPasswordChanged) {
      SteamArkLog.debug(TAG, 'proxy settings save skipped; no change; account=' +
        SteamArkLog.accountId(normalizedId));
      return true;
    }

    let activityStopCompleted: boolean = false;
    let proxyCredentialMutationAttempted: boolean = false;
    try {
      await this.stopAccountActivity(normalizedId, false);
      activityStopCompleted = true;
      this.resetAccountSessionAfterActivityStop(record);
      if (proxyPasswordChanged) {
        proxyCredentialMutationAttempted = true;
        await this.replaceCredential(normalizedId, NGFCredentialKind.PROXY_PASSWORD, nextProxyPassword);
      }
      record.profile.proxy = nextProxy;
      await this.persistState();
      this.notifyListeners();
      SteamArkLog.info(TAG, 'proxy settings saved; account=' + SteamArkLog.accountId(normalizedId));
      return true;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam proxy settings save failed');
      if (!activityStopCompleted) {
        // Cleanup can fail after only part of the runtime graph has closed. The
        // durable account and credential pair remain unchanged; evicted runtime
        // adapters will be recreated with that previous proxy on next use.
        this.restoreRecord(record, previousRecord);
        SteamArkLog.warn(TAG, 'proxy settings save stopped before mutation; account=' +
          SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(normalized));
        throw normalized;
      }

      let credentialRollbackFailure: Error | null = null;
      if (proxyCredentialMutationAttempted) {
        try {
          await this.restoreProxyPasswordAfterFailedSave(normalizedId, previousProxyPassword);
        } catch (rollbackError) {
          credentialRollbackFailure = rollbackError instanceof Error
            ? rollbackError
            : new Error('Steam proxy credential rollback failed');
          SteamArkLog.error(TAG, 'proxy credential rollback failed after save error; account=' +
            SteamArkLog.accountId(normalizedId) + ', errorType=' +
            SteamArkLog.errorKind(credentialRollbackFailure));
        }
      }
      if (credentialRollbackFailure !== null) {
        let currentProxyPassword: string | null = null;
        try {
          currentProxyPassword = await this.readProxyPassword(normalizedId);
        } catch (readError) {
          SteamArkLog.error(TAG, 'proxy credential recovery verification failed; account=' +
            SteamArkLog.accountId(normalizedId) + ', errorType=' + SteamArkLog.errorKind(readError));
        }
        if (currentProxyPassword === previousProxyPassword) {
          credentialRollbackFailure = null;
        } else if (currentProxyPassword === nextProxyPassword) {
          // If the new secret did commit but the old secret cannot be restored,
          // finish the requested change instead of persisting an old-proxy/new-
          // password pair. Every future runtime will then use a coherent pair.
          record.profile.proxy = nextProxy;
          try {
            await this.persistProxyRollbackState(normalizedId);
            this.notifyListeners();
            SteamArkLog.warn(TAG, 'proxy settings recovered by forward commit; account=' +
              SteamArkLog.accountId(normalizedId));
            return true;
          } catch (forwardPersistenceError) {
            SteamArkLog.error(TAG, 'proxy forward recovery persistence failed; account=' +
              SteamArkLog.accountId(normalizedId) + ', errorType=' +
              SteamArkLog.errorKind(forwardPersistenceError));
            // setStringAsync updates the settings facade's in-memory value before
            // reporting a durable flush failure. Retain the coherent new pair in
            // memory as well; the next successful state write can repair storage.
            this.notifyListeners();
            throw new Error('Steam proxy settings changed, but the recovered state could not be persisted');
          }
        }
        if (credentialRollbackFailure !== null) {
          // The secure store could not prove either known credential state, so
          // committing either proxy would risk a mismatched durable pair.
          record.profile.proxy = nextProxy;
          this.resetAccountSessionAfterActivityStop(record);
          this.notifyListeners();
          throw new Error('Steam proxy settings save failed and secure credential recovery could not be verified');
        }
      }

      record.profile.proxy = previousProxy;
      let rollbackPersistenceFailure: Error | null = null;
      try {
        // Runtime cleanup did complete, so the recovered account must remain
        // disconnected even though its previous proxy configuration is restored.
        await this.persistProxyRollbackState(normalizedId);
      } catch (rollbackError) {
        rollbackPersistenceFailure = rollbackError instanceof Error
          ? rollbackError
          : new Error('Steam proxy rollback state persistence failed');
        SteamArkLog.error(TAG, 'proxy rollback state persistence failed; account=' +
          SteamArkLog.accountId(normalizedId) + ', errorType=' +
          SteamArkLog.errorKind(rollbackPersistenceFailure));
      }
      this.notifyListeners();
      SteamArkLog.warn(TAG, 'proxy settings save failed; account=' + SteamArkLog.accountId(normalizedId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      if (rollbackPersistenceFailure !== null) {
        throw new Error('Steam proxy settings save failed; previous settings were restored but recovery state persistence failed');
      }
      throw normalized;
    }
  }

  async updateSession(session: SteamSessionSnapshot): Promise<boolean> {
    if (this.isDisposing) {
      SteamArkLog.debug(TAG, 'session update ignored while state service is disposing; account=' +
        SteamArkLog.accountId(session.accountId) + ', state=' + String(session.state));
      return false;
    }
    if (this.isSessionUpdateBlocked(session.accountId)) {
      SteamArkLog.debug(TAG, 'session update ignored while account lifecycle is closing; account=' +
        SteamArkLog.accountId(session.accountId) + ', state=' + String(session.state));
      return false;
    }
    return await this.runAccountOperation<boolean>(
      session.accountId,
      async (): Promise<boolean> => await this.updateSessionInternal(session)
    );
  }

  private async updateSessionInternal(session: SteamSessionSnapshot): Promise<boolean> {
    if (this.isDisposing) {
      SteamArkLog.debug(TAG, 'session update ignored while state service is disposing; account=' +
        SteamArkLog.accountId(session.accountId) + ', state=' + String(session.state));
      return false;
    }
    await this.requireInitialized();
    if (this.isSessionUpdateBlocked(session.accountId)) {
      SteamArkLog.debug(TAG, 'session update ignored while account lifecycle is closing; account=' +
        SteamArkLog.accountId(session.accountId) + ', state=' + String(session.state));
      return false;
    }
    SteamArkLog.debug(TAG, 'session update requested; account=' + SteamArkLog.accountId(session.accountId) +
      ', state=' + String(session.state));
    const record = this.records.get(session.accountId);
    if (record === undefined) {
      SteamArkLog.warn(TAG, 'session update rejected; account not found');
      return false;
    }
    // Closing the CM/farming runtime emits DISCONNECTED. That is a transport
    // lifecycle event, not an account sign-out; never persist it over durable
    // credentials for an account configured for automatic restoration.
    if (session.state === SteamSessionState.DISCONNECTED && record.autoRestoreEnabled) {
      SteamArkLog.debug(TAG, 'runtime disconnect ignored; durable account session retained; account=' +
        SteamArkLog.accountId(session.accountId));
      return false;
    }
    record.session = this.copySession(session);
    if (session.steamId64.length > 0) {
      record.profile.steamId64 = session.steamId64;
    }
    await this.persistState();
    this.notifyListeners();
    SteamArkLog.debug(TAG, 'session update persisted; account=' + SteamArkLog.accountId(session.accountId));
    return true;
  }

  async getCredentials(accountId: string): Promise<SteamCredentialSet> {
    await this.requireInitialized();
    SteamArkLog.debug(TAG, 'secure credentials read requested; account=' + SteamArkLog.accountId(accountId));
    const record = this.records.get(accountId.trim());
    if (record === undefined) {
      throw new Error('Steam account does not exist');
    }
    const accountName = await this.readCredential(accountId, NGFCredentialKind.ACCOUNT_NAME);
    const password = await this.readCredential(accountId, NGFCredentialKind.PASSWORD);
    const refreshToken = await this.readCredential(accountId, NGFCredentialKind.REFRESH_TOKEN);
    const loginKey = await this.readCredential(accountId, NGFCredentialKind.LOGIN_KEY);
    const sharedSecret = await this.readCredential(accountId, NGFCredentialKind.SHARED_SECRET);
    const identitySecret = await this.readCredential(accountId, NGFCredentialKind.IDENTITY_SECRET);
    const deviceId = await this.readCredential(accountId, NGFCredentialKind.DEVICE_ID);
    const guardData = await this.readCredential(accountId, NGFCredentialKind.GUARD_DATA);
    const accessToken = await this.readCredential(accountId, NGFCredentialKind.ACCESS_TOKEN);
    const oauthToken = await this.readCredential(accountId, NGFCredentialKind.OAUTH_TOKEN);
    const credentials = new SteamCredentialSet(
      accountName.length > 0
        ? accountName
        : (record.profile.displayName.length > 0 ? record.profile.displayName : record.profile.accountId),
      password,
      refreshToken,
      loginKey,
      sharedSecret,
      identitySecret,
      deviceId,
      accessToken,
      oauthToken,
      guardData
    );
    SteamArkLog.debug(TAG, 'secure credentials read completed; account=' +
      SteamArkLog.accountId(accountId) + ', fieldsPresent=' + this.credentialFieldCount(credentials).toString());
    return credentials;
  }

  /** Exposes only whether device TOTP can be generated; the shared secret never leaves secure storage. */
  async hasSharedSecret(accountId: string): Promise<boolean> {
    await this.requireInitialized();
    const normalizedId = accountId.trim();
    const record = this.records.get(normalizedId);
    if (record === undefined) {
      throw new SteamAuthError(
        'Steam account does not exist',
        SteamAuthErrorKind.VALIDATION,
        'shared_secret_capability'
      );
    }
    const sharedSecret = await this.readCredential(normalizedId, NGFCredentialKind.SHARED_SECRET);
    const available: boolean = sharedSecret.trim().length > 0;
    SteamArkLog.debug(TAG, 'shared secret capability checked; account=' +
      SteamArkLog.accountId(normalizedId) + ', available=' + String(available));
    return available;
  }

  /**
   * Reports the non-secret capability required by Web-backed features.
   * Native/CM authentication remains valid when this returns false.
   */
  async hasWebApiCredentials(accountId: string): Promise<boolean> {
    await this.requireInitialized();
    const normalizedId: string = accountId.trim();
    if (!this.records.has(normalizedId)) {
      throw new SteamAuthError(
        'Steam account does not exist',
        SteamAuthErrorKind.VALIDATION,
        'web_capability'
      );
    }
    const credentials: SteamCredentialSet = await this.getCredentials(normalizedId);
    const available: boolean = this.hasUsableAuthenticationCredentials(credentials);
    SteamArkLog.debug(TAG, 'Web credential capability checked; account=' +
      SteamArkLog.accountId(normalizedId) + ', available=' + String(available));
    return available;
  }

  async getProxyPassword(accountId: string): Promise<string> {
    await this.requireInitialized();
    SteamArkLog.debug(TAG, 'secure proxy password read requested; account=' + SteamArkLog.accountId(accountId));
    const record = this.records.get(accountId.trim());
    if (record === undefined) {
      throw new Error('Steam account does not exist');
    }
    const password = await this.readProxyPassword(record.profile.accountId);
    SteamArkLog.debug(TAG, 'secure proxy password read completed; account=' +
      SteamArkLog.accountId(record.profile.accountId) + ', present=' + String(password.length > 0));
    return password;
  }

  private async loadPersistedState(): Promise<boolean> {
    SteamArkLog.startup(TAG, 'Steam account state load started');
    const ready = await this.settingsStore.waitUntilReady();
    if (!ready) {
      SteamArkLog.warn(TAG, 'settings store is not ready; Steam state load deferred');
      return false;
    }

    await this.loadPersistedGlobalState();
    const serialized = this.settingsStore.getString(SETTINGS_KEY, '');
    this.records.clear();
    this.selectedAccountId = '';
    let restoredStateNeedsCleanup: boolean = false;
    if (serialized.trim().length > 0) {
      SteamArkLog.debug(TAG, 'persisted Steam account state found; serializedLength=' + serialized.length.toString());
      try {
        restoredStateNeedsCleanup = this.restoreDocument(SteamJsonParser.parse(serialized, steamArkCoreLogger));
      } catch (error) {
        SteamArkLog.warn(TAG, 'persisted Steam state ignored; parseErrorType=' +
          (error instanceof Error ? error.name : 'NonError'));
        this.records.clear();
        this.selectedAccountId = '';
      }
    } else {
      SteamArkLog.debug(TAG, 'persisted Steam account state not found; starting empty');
    }

    const accountIds: Array<string> = [];
    this.records.forEach((_record: SteamArkAccountRecord, accountId: string): void => {
      accountIds.push(accountId);
    });
    for (let index = 0; index < accountIds.length; index++) {
      const record = this.records.get(accountIds[index]);
      if (record !== undefined) {
        record.hasCredentialMaterial = await this.hasSecureCredentials(accountIds[index]);
      }
      this.restorePersistedInventoryPage(accountIds[index]);
    }
    this.ensureSelectedAccount('');
    if (restoredStateNeedsCleanup) {
      await this.persistState();
      SteamArkLog.info(TAG, 'persisted Steam authentication state normalized during startup');
    }
    this.initialized = true;
    this.notifyListeners();
    SteamArkLog.startup(TAG, 'Steam account state load completed', 'accounts=' + this.records.size.toString() +
      ', selected=' + SteamArkLog.accountId(this.selectedAccountId));
    return true;
  }

  private async loadPersistedGlobalState(): Promise<void> {
    SteamArkLog.debug(TAG, 'ASF global configuration load started');
    this.globalConfig = new SteamGlobalConfig();
    this.globalMigrationReport = new SteamArkMigrationReport();
    const serialized = this.settingsStore.getString(GLOBAL_SETTINGS_KEY, '');
    if (serialized.trim().length > 0) {
      try {
        this.restoreGlobalDocument(SteamJsonParser.parse(serialized, steamArkCoreLogger));
      } catch (error) {
        SteamArkLog.warn(TAG, 'persisted ASF global configuration ignored; parseErrorType=' +
          (error instanceof Error ? error.name : 'NonError'));
        this.globalConfig = new SteamGlobalConfig();
        this.globalMigrationReport = new SteamArkMigrationReport();
      }
    }
    this.hasGlobalCredentialMaterial = await this.hasGlobalSecureCredentials();
    SteamArkLog.debug(TAG, 'ASF global configuration load completed; unknownFields=' +
      this.globalMigrationReport.unknownFields.length.toString() +
      ', hasCredentialMaterial=' + String(this.hasGlobalCredentialMaterial));
  }

  private async requireInitialized(): Promise<void> {
    if (this.isDisposing) {
      throw new Error('Steam state service is disposing');
    }
    const ready = await this.initialize();
    if (!ready) {
      throw new Error('Steam state service is not initialized');
    }
  }

  private async runAccountOperation<T>(
    accountId: string,
    operation: () => Promise<T>,
    blockSessionUpdates: boolean = false
  ): Promise<T> {
    if (this.isDisposing) {
      throw new Error('Steam state service is disposing');
    }
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
    if (blockSessionUpdates) {
      this.incrementSessionUpdateBlock(normalizedId);
    }
    try {
      if (previous !== undefined) {
        await previous;
      }
      return await operation();
    } finally {
      if (blockSessionUpdates) {
        this.decrementSessionUpdateBlock(normalizedId);
      }
      release();
      if (this.accountOperationTails.get(normalizedId) === chain) {
        this.accountOperationTails.delete(normalizedId);
      }
    }
  }

  private async runGlobalOperation<T>(operation: () => Promise<T>): Promise<T> {
    if (this.isDisposing) {
      throw new Error('Steam state service is disposing');
    }
    const previous = this.globalOperationTail;
    let release: () => void = (): void => {
      return;
    };
    const gate = new Promise<void>((resolve: () => void): void => {
      release = resolve;
    });
    const chain: Promise<void> = previous.then((): Promise<void> => gate);
    this.globalOperationTail = chain;
    try {
      await previous;
      return await operation();
    } finally {
      release();
      if (this.globalOperationTail === chain) {
        this.globalOperationTail = Promise.resolve();
      }
    }
  }

  private incrementSessionUpdateBlock(accountId: string): void {
    const current = this.sessionUpdateBlockCounts.get(accountId);
    this.sessionUpdateBlockCounts.set(accountId, current === undefined ? 1 : current + 1);
  }

  private decrementSessionUpdateBlock(accountId: string): void {
    const current = this.sessionUpdateBlockCounts.get(accountId);
    if (current === undefined || current <= 1) {
      this.sessionUpdateBlockCounts.delete(accountId);
      return;
    }
    this.sessionUpdateBlockCounts.set(accountId, current - 1);
  }

  private isSessionUpdateBlocked(accountId: string): boolean {
    const current = this.sessionUpdateBlockCounts.get(accountId);
    return current !== undefined && current > 0;
  }

  private restoreDocument(root: SteamJsonValue): boolean {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('Steam state must be an object');
    }
    const accountsValue = root.getProperty('accounts');
    if (accountsValue === null || accountsValue.kind !== SteamJsonValueKind.ARRAY) {
      return false;
    }
    const selected = this.readString(root.getProperty('selectedAccountId'), '');
    let ignoredCount: number = 0;
    let normalizedCount: number = 0;
    for (let index = 0; index < accountsValue.items.length; index++) {
      const item = accountsValue.items[index];
      if (item.kind !== SteamJsonValueKind.OBJECT) {
        continue;
      }
      try {
        const record = this.restoreAccount(item);
        const rawPendingAuth = item.getProperty('pendingAuth');
        if (record.session.state === SteamSessionState.LOGGED_ON && rawPendingAuth !== null &&
          rawPendingAuth.kind === SteamJsonValueKind.OBJECT) {
          normalizedCount++;
          SteamArkLog.warn(TAG, 'discarded stale pending authentication state from logged-on account during startup; account=' +
            SteamArkLog.accountId(record.profile.accountId));
        }
        if (this.isTemporaryQrRecord(record)) {
          SteamArkLog.info(TAG, 'ignored stale temporary QR authentication record during startup; account=' +
            SteamArkLog.accountId(record.profile.accountId));
          ignoredCount++;
          continue;
        }
        this.records.set(record.profile.accountId, record);
      } catch {
        SteamArkLog.warn(TAG, 'ignored one malformed persisted Steam account');
        ignoredCount++;
      }
    }
    this.selectedAccountId = selected;
    this.ensureSelectedAccount('');
    SteamArkLog.debug(TAG, 'persisted Steam account document restored; accounts=' + this.records.size.toString() +
      ', ignored=' + ignoredCount.toString() + ', normalized=' + normalizedCount.toString());
    return ignoredCount > 0 || normalizedCount > 0;
  }

  private applySessionToRecord(record: SteamArkAccountRecord, session: SteamSessionSnapshot): void {
    SteamArkLog.state(TAG, String(record.session.state), String(session.state), 'account=' +
      SteamArkLog.accountId(record.profile.accountId));
    record.session = this.copySession(session);
    if (session.steamId64.length > 0) {
      record.profile.steamId64 = session.steamId64;
    }
  }

  private resetAccountSessionAfterActivityStop(record: SteamArkAccountRecord): void {
    SteamArkLog.state(TAG, String(record.session.state), String(SteamSessionState.DISCONNECTED),
      'account activity closed; account=' + SteamArkLog.accountId(record.profile.accountId));
    record.pendingAuth = null;
    record.session = new SteamSessionSnapshot(
      record.profile.accountId,
      SteamSessionState.DISCONNECTED,
      record.profile.steamId64
    );
  }

  private restoreGlobalDocument(root: SteamJsonValue): void {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('ASF global state must be an object');
    }
    const configValue = root.getProperty('config');
    if (configValue !== null && configValue.kind === SteamJsonValueKind.OBJECT) {
      this.globalConfig = this.restoreGlobalConfig(configValue);
    }
    this.globalMigrationReport = new SteamArkMigrationReport(
      this.readString(root.getProperty('migrationSourceName'), ''),
      this.readStringArray(root.getProperty('migrationRecognizedFields')),
      this.readStringArray(root.getProperty('migrationUnknownFields')),
      this.readStringArray(root.getProperty('migrationWarnings')),
      this.readInteger(root.getProperty('migrationImportedAtEpochSeconds'), 0)
    );
  }

  private restoreGlobalConfig(root: SteamJsonValue): SteamGlobalConfig {
    const config = new SteamGlobalConfig();
    config.autoRestart = this.readBoolean(root.getProperty('autoRestart'), config.autoRestart);
    config.blacklist = this.readStringArray(root.getProperty('blacklist'));
    config.commandPrefix = this.readString(root.getProperty('commandPrefix'), config.commandPrefix);
    config.confirmationsLimiterDelay = this.readInteger(root.getProperty('confirmationsLimiterDelay'), config.confirmationsLimiterDelay);
    config.connectionTimeout = this.readInteger(root.getProperty('connectionTimeout'), config.connectionTimeout);
    config.currentCulture = this.readString(root.getProperty('currentCulture'), config.currentCulture);
    config.debug = this.readBoolean(root.getProperty('debug'), config.debug);
    config.defaultBot = this.readString(root.getProperty('defaultBot'), config.defaultBot);
    config.farmingDelay = this.readInteger(root.getProperty('farmingDelay'), config.farmingDelay);
    config.filterBadBots = this.readBoolean(root.getProperty('filterBadBots'), config.filterBadBots);
    config.giftsLimiterDelay = this.readInteger(root.getProperty('giftsLimiterDelay'), config.giftsLimiterDelay);
    config.headless = this.readBoolean(root.getProperty('headless'), config.headless);
    config.idleFarmingPeriod = this.readInteger(root.getProperty('idleFarmingPeriod'), config.idleFarmingPeriod);
    config.inventoryLimiterDelay = this.readInteger(root.getProperty('inventoryLimiterDelay'), config.inventoryLimiterDelay);
    config.ipc = this.readBoolean(root.getProperty('ipc'), config.ipc);
    config.ipcPasswordFormat = this.readString(root.getProperty('ipcPasswordFormat'), config.ipcPasswordFormat);
    config.licenseId = this.readString(root.getProperty('licenseId'), config.licenseId);
    config.loginLimiterDelay = this.readInteger(root.getProperty('loginLimiterDelay'), config.loginLimiterDelay);
    config.maxFarmingTime = this.readInteger(root.getProperty('maxFarmingTime'), config.maxFarmingTime);
    config.maxTradeHoldDuration = this.readInteger(root.getProperty('maxTradeHoldDuration'), config.maxTradeHoldDuration);
    config.minFarmingDelayAfterBlock = this.readInteger(root.getProperty('minFarmingDelayAfterBlock'), config.minFarmingDelayAfterBlock);
    config.optimizationMode = this.readInteger(root.getProperty('optimizationMode'), config.optimizationMode);
    config.pluginsUpdateList = this.readStringArray(root.getProperty('pluginsUpdateList'));
    config.pluginsUpdateMode = this.readString(root.getProperty('pluginsUpdateMode'), config.pluginsUpdateMode);
    config.shutdownIfPossible = this.readBoolean(root.getProperty('shutdownIfPossible'), config.shutdownIfPossible);
    config.steamMessagePrefix = this.readString(root.getProperty('steamMessagePrefix'), config.steamMessagePrefix);
    config.steamOwnerId64 = this.readString(root.getProperty('steamOwnerId64'), config.steamOwnerId64);
    config.steamProtocols = this.readInteger(root.getProperty('steamProtocols'), config.steamProtocols);
    config.updateChannel = this.readString(root.getProperty('updateChannel'), config.updateChannel);
    config.updatePeriod = this.readInteger(root.getProperty('updatePeriod'), config.updatePeriod);
    config.webLimiterDelay = this.readInteger(root.getProperty('webLimiterDelay'), config.webLimiterDelay);
    config.webProxyText = this.readString(root.getProperty('webProxyText'), config.webProxyText);
    config.webProxyUsername = this.readString(root.getProperty('webProxyUsername'), config.webProxyUsername);
    return config;
  }

  private restoreAccount(root: SteamJsonValue): SteamArkAccountRecord {
    const accountId = this.readRequiredString(root.getProperty('accountId'), 'accountId');
    const displayName = this.readString(root.getProperty('displayName'), accountId);
    const avatarUrl = this.readString(root.getProperty('avatarUrl'), '');
    const backgroundImageUrl = this.readString(root.getProperty('profileBackgroundImageUrl'), '');
    const backgroundMovieUrl = this.readString(root.getProperty('profileBackgroundMovieUrl'), '');
    const steamId64 = this.readString(root.getProperty('steamId64'), '');
    const profile = new SteamAccountProfile(
      accountId,
      displayName,
      steamId64,
      this.readBoolean(root.getProperty('accountEnabled'), true),
      new SteamProxySettings(
        this.readProxyKind(root.getProperty('proxyKind')),
        this.readString(root.getProperty('proxyHost'), ''),
        this.readInteger(root.getProperty('proxyPort'), 0),
        this.readString(root.getProperty('proxyUsername'), '')
      ),
      avatarUrl,
      backgroundImageUrl,
      backgroundMovieUrl,
      this.readBoolean(root.getProperty('profileBackgroundTiled'), false),
      this.readString(root.getProperty('avatarFrameUrl'), ''),
      this.readString(root.getProperty('summary'), ''),
      this.readInteger(root.getProperty('level'), 0),
      this.readString(root.getProperty('countryCode'), ''),
      this.readString(root.getProperty('walletBalance'), ''),
      this.readString(root.getProperty('walletCurrency'), ''),
      this.readString(root.getProperty('miniProfileBackgroundImageUrl'), ''),
      this.readString(root.getProperty('miniProfileBackgroundMovieUrl'), '')
    );
    const config = new SteamBotConfig(accountId);
    config.enabled = this.readBoolean(root.getProperty('botEnabled'), true);
    config.hoursUntilCardDrops = this.readInteger(root.getProperty('hoursUntilCardDrops'), 3);
    config.maxGamesPlayedConcurrently = this.readInteger(root.getProperty('maxGamesPlayedConcurrently'), 32);
    config.farmingPreferences = this.readInteger(root.getProperty('farmingPreferences'), 0);
    config.farmingOrders = this.readOrders(root.getProperty('farmingOrders'));
    config.gamesPlayedWhileIdle = this.readStringArray(root.getProperty('gamesPlayedWhileIdle'));
    config.blacklist = this.readStringArray(root.getProperty('blacklist'));
    config.priorityAppIds = this.readStringArray(root.getProperty('priorityAppIds'));
    let session = new SteamSessionSnapshot(
      accountId,
      this.readSessionState(root.getProperty('sessionState')),
      this.readString(root.getProperty('sessionSteamId64'), steamId64),
      this.readString(root.getProperty('sessionServer'), ''),
      this.readInteger(root.getProperty('sessionConnectedAtEpochSeconds'), 0),
      this.readInteger(root.getProperty('sessionExpiresAtEpochSeconds'), 0),
      this.readInteger(root.getProperty('sessionLastErrorCode'), 0),
      this.readString(root.getProperty('sessionLastErrorMessage'), ''),
      this.readString(root.getProperty('sessionLastErrorType'), ''),
      this.readString(root.getProperty('sessionLastErrorStage'), ''),
      this.readInteger(root.getProperty('sessionLastErrorHttpStatusCode'), 0),
      this.readInteger(root.getProperty('sessionLastErrorMessageType'), 0),
      this.readString(root.getProperty('sessionLastErrorHeaderKind'), ''),
      this.readInteger(root.getProperty('sessionLastErrorFrameBytes'), 0),
      this.readInteger(root.getProperty('sessionLastErrorHeaderBytes'), 0),
      this.readInteger(root.getProperty('sessionLastErrorBodyBytes'), 0),
      this.readString(root.getProperty('sessionLastErrorServerMessage'), '')
    );
    const pendingValue = root.getProperty('pendingAuth');
    let pendingAuth = this.restorePendingAuth(pendingValue, accountId);
    const malformedPendingObject = pendingValue !== null && pendingValue.kind === SteamJsonValueKind.OBJECT;
    // A completed authentication cannot legitimately retain an unfinished
    // challenge. Treat this as old interrupted persistence, not a logout.
    if (session.state === SteamSessionState.LOGGED_ON) {
      pendingAuth = null;
    }
    if (session.state !== SteamSessionState.LOGGED_ON &&
      (this.isAuthChallengeState(session.state) || malformedPendingObject) && pendingAuth === null) {
      session = new SteamSessionSnapshot(
        accountId,
        SteamSessionState.EXPIRED,
        session.steamId64,
        session.server,
        session.connectedAtEpochSeconds,
        session.expiresAtEpochSeconds,
        session.lastErrorCode,
        session.lastErrorMessage,
        session.lastErrorType,
        session.lastErrorStage,
        session.lastErrorHttpStatusCode,
        session.lastErrorMessageType,
        session.lastErrorHeaderKind,
        session.lastErrorFrameBytes,
        session.lastErrorHeaderBytes,
        session.lastErrorBodyBytes,
        session.lastErrorServerMessage
      );
    }
    const report = new SteamArkMigrationReport(
      this.readString(root.getProperty('migrationSourceName'), ''),
      this.readStringArray(root.getProperty('migrationRecognizedFields')),
      this.readStringArray(root.getProperty('migrationUnknownFields')),
      this.readStringArray(root.getProperty('migrationWarnings')),
      this.readInteger(root.getProperty('migrationImportedAtEpochSeconds'), 0)
    );
    return new SteamArkAccountRecord(
      profile,
      config,
      session,
      report,
      false,
      pendingAuth,
      this.readBoolean(root.getProperty('autoRestoreEnabled'), true)
    );
  }

  private restorePendingAuth(
    value: SteamJsonValue | null,
    accountId: string
  ): SteamAuthPendingSnapshot | null {
    if (value === null || value.kind !== SteamJsonValueKind.OBJECT) {
      return null;
    }
    const challenge = this.readAuthChallenge(value.getProperty('challenge'));
    if (challenge === null) {
      return null;
    }
    const flow = this.readAuthFlow(value.getProperty('flow'));
    if (flow === null) {
      return null;
    }
    const snapshot = new SteamAuthPendingSnapshot(
      this.readString(value.getProperty('accountId'), ''),
      this.readString(value.getProperty('clientId'), ''),
      this.readString(value.getProperty('requestId'), ''),
      this.readString(value.getProperty('steamId64'), ''),
      challenge,
      this.readInteger(value.getProperty('intervalSeconds'), 0),
      this.readInteger(value.getProperty('createdAtEpochSeconds'), 0),
      this.readInteger(value.getProperty('expiresAtEpochSeconds'), 0),
      flow,
      this.readString(value.getProperty('challengeUrl'), '')
    );
    return snapshot.isValidFor(accountId, this.nowEpochSeconds()) ? snapshot : null;
  }

  private async persistState(): Promise<void> {
    SteamArkLog.debug(TAG, 'Steam account state persistence started; accounts=' + this.records.size.toString());
    const document = new SteamArkPersistedDocument();
    const selectedRecord = this.records.get(this.selectedAccountId);
    document.selectedAccountId = selectedRecord === undefined || this.isTemporaryQrRecord(selectedRecord)
      ? ''
      : this.selectedAccountId;
    this.records.forEach((record: SteamArkAccountRecord): void => {
      if (this.isTemporaryQrRecord(record)) {
        return;
      }
      document.accounts.push(this.toPersistedAccount(record));
    });
    const serialized = JSON.stringify(document);
    const accountCount = document.accounts.length;
    await this.enqueuePersistence(async (): Promise<void> => {
      try {
        const saved = await this.settingsStore.setStringAsync(SETTINGS_KEY, serialized);
        if (!saved) {
          SteamArkLog.error(TAG, 'Steam account state persistence rejected; accounts=' + accountCount.toString());
          throw new Error('Steam state persistence failed');
        }
        SteamArkLog.debug(TAG, 'Steam account state persistence completed; accounts=' + accountCount.toString());
      } catch (error) {
        SteamArkLog.error(TAG, 'Steam account state persistence failed; errorType=' + SteamArkLog.errorKind(error));
        throw error instanceof Error ? error : new Error('Steam state persistence failed');
      }
    });
  }

  private async persistGlobalState(): Promise<void> {
    SteamArkLog.debug(TAG, 'ASF global configuration persistence started');
    const document = new SteamArkPersistedGlobalDocument();
    document.config = this.globalConfig.clone();
    document.migrationSourceName = this.globalMigrationReport.sourceName;
    document.migrationRecognizedFields = this.globalMigrationReport.recognizedFields.slice();
    document.migrationUnknownFields = this.globalMigrationReport.unknownFields.slice();
    document.migrationWarnings = this.globalMigrationReport.warnings.slice();
    document.migrationImportedAtEpochSeconds = this.globalMigrationReport.importedAtEpochSeconds;
    const serialized = JSON.stringify(document);
    await this.enqueuePersistence(async (): Promise<void> => {
      try {
        const saved = await this.settingsStore.setStringAsync(GLOBAL_SETTINGS_KEY, serialized);
        if (!saved) {
          SteamArkLog.error(TAG, 'ASF global configuration persistence rejected');
          throw new Error('ASF global configuration persistence failed');
        }
        SteamArkLog.debug(TAG, 'ASF global configuration persistence completed');
      } catch (error) {
        SteamArkLog.error(TAG, 'ASF global configuration persistence failed; errorType=' +
          SteamArkLog.errorKind(error));
        throw error instanceof Error ? error : new Error('ASF global configuration persistence failed');
      }
    });
  }

  private async enqueuePersistence(task: () => Promise<void>): Promise<void> {
    const previous = this.persistenceTail;
    const current = previous.then((): Promise<void> => task());
    this.persistenceTail = current.then((): void => {
      return;
    }, (): void => {
      return;
    });
    await current;
  }

  private toPersistedAccount(record: SteamArkAccountRecord): SteamArkPersistedAccount {
    const persisted = new SteamArkPersistedAccount();
    persisted.accountId = record.profile.accountId;
    persisted.displayName = record.profile.displayName;
    persisted.avatarUrl = record.profile.avatarUrl;
    persisted.profileBackgroundImageUrl = record.profile.profileBackgroundImageUrl;
    persisted.profileBackgroundMovieUrl = record.profile.profileBackgroundMovieUrl;
    persisted.profileBackgroundTiled = record.profile.profileBackgroundTiled;
    persisted.miniProfileBackgroundImageUrl = record.profile.miniProfileBackgroundImageUrl;
    persisted.miniProfileBackgroundMovieUrl = record.profile.miniProfileBackgroundMovieUrl;
    persisted.avatarFrameUrl = record.profile.avatarFrameUrl;
    persisted.summary = record.profile.summary;
    persisted.level = record.profile.level;
    persisted.countryCode = record.profile.countryCode;
    persisted.walletBalance = record.profile.walletBalance;
    persisted.walletCurrency = record.profile.walletCurrency;
    persisted.steamId64 = record.profile.steamId64;
    persisted.accountEnabled = record.profile.enabled;
    persisted.autoRestoreEnabled = record.autoRestoreEnabled;
    persisted.proxyKind = record.profile.proxy.kind;
    persisted.proxyHost = record.profile.proxy.host;
    persisted.proxyPort = record.profile.proxy.port;
    persisted.proxyUsername = record.profile.proxy.username;
    persisted.botEnabled = record.config.enabled;
    persisted.hoursUntilCardDrops = record.config.hoursUntilCardDrops;
    persisted.maxGamesPlayedConcurrently = record.config.maxGamesPlayedConcurrently;
    persisted.farmingPreferences = record.config.farmingPreferences;
    persisted.farmingOrders = this.copyOrderStrings(record.config.farmingOrders);
    persisted.gamesPlayedWhileIdle = record.config.gamesPlayedWhileIdle.slice();
    persisted.blacklist = record.config.blacklist.slice();
    persisted.priorityAppIds = record.config.priorityAppIds.slice();
    persisted.sessionState = record.session.state;
    persisted.sessionSteamId64 = record.session.steamId64;
    persisted.sessionServer = record.session.server;
    persisted.sessionConnectedAtEpochSeconds = record.session.connectedAtEpochSeconds;
    persisted.sessionExpiresAtEpochSeconds = record.session.expiresAtEpochSeconds;
    persisted.sessionLastErrorCode = record.session.lastErrorCode;
    persisted.sessionLastErrorMessage = record.session.lastErrorMessage;
    persisted.sessionLastErrorType = record.session.lastErrorType;
    persisted.sessionLastErrorStage = record.session.lastErrorStage;
    persisted.sessionLastErrorHttpStatusCode = record.session.lastErrorHttpStatusCode;
    persisted.sessionLastErrorMessageType = record.session.lastErrorMessageType;
    persisted.sessionLastErrorHeaderKind = record.session.lastErrorHeaderKind;
    persisted.sessionLastErrorFrameBytes = record.session.lastErrorFrameBytes;
    persisted.sessionLastErrorHeaderBytes = record.session.lastErrorHeaderBytes;
    persisted.sessionLastErrorBodyBytes = record.session.lastErrorBodyBytes;
    persisted.sessionLastErrorServerMessage = record.session.lastErrorServerMessage;
    persisted.pendingAuth = this.toPersistedPendingAuth(record.pendingAuth);
    persisted.migrationSourceName = record.migrationReport.sourceName;
    persisted.migrationRecognizedFields = record.migrationReport.recognizedFields.slice();
    persisted.migrationUnknownFields = record.migrationReport.unknownFields.slice();
    persisted.migrationWarnings = record.migrationReport.warnings.slice();
    persisted.migrationImportedAtEpochSeconds = record.migrationReport.importedAtEpochSeconds;
    return persisted;
  }

  private toPersistedPendingAuth(
    source: SteamAuthPendingSnapshot | null
  ): SteamArkPersistedAuthPending | null {
    if (source === null) {
      return null;
    }
    const persisted = new SteamArkPersistedAuthPending();
    persisted.accountId = source.accountId;
    persisted.clientId = source.clientId;
    persisted.requestId = source.requestId;
    persisted.steamId64 = source.steamId64;
    persisted.challenge = source.challenge;
    persisted.flow = source.flow;
    persisted.challengeUrl = source.challengeUrl;
    persisted.intervalSeconds = source.intervalSeconds;
    persisted.createdAtEpochSeconds = source.createdAtEpochSeconds;
    persisted.expiresAtEpochSeconds = source.expiresAtEpochSeconds;
    return persisted;
  }

  private copyOrderStrings(orders: Array<SteamFarmingOrder>): Array<string> {
    const result: Array<string> = [];
    for (let index = 0; index < orders.length; index++) {
      result.push(String(orders[index]));
    }
    return result;
  }

  private inventoryCacheKey(accountId: string, query: SteamInventoryQuery): string {
    return accountId + '|' + query.appId + '|' + query.contextId + '|' +
      query.page.toString() + '|' + query.pageSize.toString() + '|' +
      query.startAssetId + '|' + query.search + '|' +
      (query.marketableOnly ? '1' : '0') + '|' +
      (query.tradableOnly ? '1' : '0') + '|' + query.language;
  }

  private copyBotConfig(source: SteamBotConfig, accountId: string): SteamBotConfig {
    const copy = new SteamBotConfig(accountId);
    copy.enabled = source.enabled;
    copy.hoursUntilCardDrops = source.hoursUntilCardDrops;
    copy.maxGamesPlayedConcurrently = source.maxGamesPlayedConcurrently;
    copy.farmingPreferences = source.farmingPreferences;
    copy.farmingOrders = source.farmingOrders.slice();
    copy.gamesPlayedWhileIdle = source.gamesPlayedWhileIdle.slice();
    copy.blacklist = source.blacklist.slice();
    copy.priorityAppIds = source.priorityAppIds.slice();
    return copy;
  }

  private copyProfile(source: SteamAccountProfile): SteamAccountProfile {
    return new SteamAccountProfile(
      source.accountId,
      source.displayName,
      source.steamId64,
      source.enabled,
      new SteamProxySettings(
        source.proxy.kind,
        source.proxy.host,
        source.proxy.port,
        source.proxy.username
      ),
      source.avatarUrl,
      source.profileBackgroundImageUrl,
      source.profileBackgroundMovieUrl,
      source.profileBackgroundTiled,
      source.avatarFrameUrl,
      source.summary,
      source.level,
      source.countryCode,
      source.walletBalance,
      source.walletCurrency,
      source.miniProfileBackgroundImageUrl,
      source.miniProfileBackgroundMovieUrl
    );
  }

  private copyMigrationReport(source: SteamArkMigrationReport): SteamArkMigrationReport {
    return new SteamArkMigrationReport(
      source.sourceName,
      source.recognizedFields,
      source.unknownFields,
      source.warnings,
      source.importedAtEpochSeconds
    );
  }

  private copyRecord(source: SteamArkAccountRecord): SteamArkAccountRecord {
    return new SteamArkAccountRecord(
      this.copyProfile(source.profile),
      this.copyBotConfig(source.config, source.profile.accountId),
      this.copySession(source.session),
      this.copyMigrationReport(source.migrationReport),
      source.hasCredentialMaterial,
      this.copyPendingAuth(source.pendingAuth),
      source.autoRestoreEnabled,
      source.profileRefreshGeneration,
      source.profileRefreshRetryGeneration,
      source.profileRefreshRetryPendingGeneration
    );
  }

  private restoreRecord(target: SteamArkAccountRecord, source: SteamArkAccountRecord): void {
    target.profile = this.copyProfile(source.profile);
    target.config = this.copyBotConfig(source.config, source.profile.accountId);
    target.session = this.copySession(source.session);
    target.pendingAuth = this.copyPendingAuth(source.pendingAuth);
    target.migrationReport = this.copyMigrationReport(source.migrationReport);
    target.hasCredentialMaterial = source.hasCredentialMaterial;
    target.autoRestoreEnabled = source.autoRestoreEnabled;
    target.profileRefreshGeneration = source.profileRefreshGeneration;
    target.profileRefreshRetryGeneration = source.profileRefreshRetryGeneration;
    target.profileRefreshRetryPendingGeneration = source.profileRefreshRetryPendingGeneration;
  }

  private async stopAccountActivity(accountId: string, removeFarming: boolean): Promise<void> {
    let firstFailure: Error | null = null;
    const lifecycle = this.accountLifecycle;
    if (lifecycle !== null) {
      try {
        if (removeFarming) {
          await lifecycle.remove(accountId);
        } else {
          await lifecycle.stop(accountId);
        }
      } catch (error) {
        firstFailure = error instanceof Error ? error : new Error('Steam farming lifecycle cleanup failed');
        SteamArkLog.warn(TAG, 'farming lifecycle cleanup failed; account=' + SteamArkLog.accountId(accountId) +
          ', remove=' + String(removeFarming) + ', errorType=' + SteamArkLog.errorKind(firstFailure));
      }
    }
    try {
      await this.closeInventoryInternal(accountId);
    } catch (error) {
      if (firstFailure === null) {
        firstFailure = error instanceof Error ? error : new Error('Steam inventory session cleanup failed');
      }
      SteamArkLog.warn(TAG, 'inventory lifecycle cleanup failed; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
    try {
      await this.closeAuthService(accountId);
    } catch (error) {
      if (firstFailure === null) {
        firstFailure = error instanceof Error ? error : new Error('Steam authentication session cleanup failed');
      }
      SteamArkLog.warn(TAG, 'authentication lifecycle cleanup failed; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
    if (firstFailure !== null) {
      throw firstFailure;
    }
  }

  private async closeAuthService(accountId: string): Promise<void> {
    const normalizedId = accountId.trim();
    const service = this.authServices.get(normalizedId);
    if (service === undefined) {
      return;
    }
    try {
      await service.close(normalizedId);
    } finally {
      if (this.authServices.get(normalizedId) === service) {
        this.authServices.delete(normalizedId);
      }
    }
    SteamArkLog.info(TAG, 'authentication service closed; account=' + SteamArkLog.accountId(normalizedId));
  }

  private async closeDetachedAuthService(accountId: string, service: ISteamAuthService): Promise<void> {
    try {
      await service.close(accountId);
      SteamArkLog.info(TAG, 'detached authentication service closed; account=' + SteamArkLog.accountId(accountId));
    } catch (error) {
      SteamArkLog.warn(TAG, 'detached authentication service close failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private async closeDetachedAuthServiceAfterOperations(
    accountId: string,
    service: ISteamAuthService
  ): Promise<void> {
    const pending = this.accountOperationTails.get(accountId);
    if (pending !== undefined) {
      await pending;
    }
    await this.closeDetachedAuthService(accountId, service);
  }

  private async closeDetachedInventoryAdapter(
    accountId: string,
    adapter: ISteamArkInventoryAdapter
  ): Promise<void> {
    try {
      await adapter.close(accountId);
      SteamArkLog.info(TAG, 'detached inventory adapter closed; account=' + SteamArkLog.accountId(accountId));
    } catch (error) {
      SteamArkLog.warn(TAG, 'detached inventory adapter close failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private async closeDetachedInventoryAdapterAfterOperations(
    accountId: string,
    adapter: ISteamArkInventoryAdapter
  ): Promise<void> {
    const pending = this.accountOperationTails.get(accountId);
    if (pending !== undefined) {
      await pending;
    }
    await this.closeDetachedInventoryAdapter(accountId, adapter);
  }

  private trackDetachedCleanup(task: Promise<void>): void {
    this.detachedCleanupTasks.push(task);
    void task.then(
      (): void => this.removeDetachedCleanup(task),
      (): void => this.removeDetachedCleanup(task)
    );
  }

  private removeDetachedCleanup(task: Promise<void>): void {
    const index = this.detachedCleanupTasks.indexOf(task);
    if (index >= 0) {
      this.detachedCleanupTasks.splice(index, 1);
    }
  }

  private async waitForDetachedCleanup(): Promise<void> {
    while (this.detachedCleanupTasks.length > 0) {
      const pending: Array<Promise<void>> = this.detachedCleanupTasks.slice();
      for (let index = 0; index < pending.length; index++) {
        await pending[index];
      }
    }
  }

  private clearInventoryCache(accountId: string): void {
    const prefix = accountId.trim() + '|';
    const keys: Array<string> = [];
    this.inventoryPages.forEach((_page: SteamInventoryPage, key: string): void => {
      if (key.indexOf(prefix) === 0) {
        keys.push(key);
      }
    });
    for (let index = 0; index < keys.length; index++) {
      this.inventoryPages.delete(keys[index]);
    }
    this.latestInventoryPages.delete(accountId.trim());
  }

  private clearPersistedInventoryCache(accountId: string): void {
    const normalizedId: string = accountId.trim();
    if (normalizedId.length <= 0) {
      return;
    }
    ngfContentCacheFacade.remove(this.persistedInventoryCacheKey(normalizedId));
    SteamArkLog.debug(TAG, 'persisted inventory cache removed after account deletion; account=' +
      SteamArkLog.accountId(normalizedId));
  }

  private async recordAccountOperationFailure(
    record: SteamArkAccountRecord,
    error: Error,
    stage: string
  ): Promise<void> {
    const authError = error instanceof SteamAuthError ? error : null;
    record.session = new SteamSessionSnapshot(
      record.profile.accountId,
      SteamSessionState.ERROR,
      record.profile.steamId64,
      record.session.server,
      record.session.connectedAtEpochSeconds,
      record.session.expiresAtEpochSeconds,
      authError === null ? 0 : authError.code,
      this.safeAuthErrorMessage(error.message),
      'account_management',
      stage,
      authError === null ? 0 : authError.httpStatusCode,
      authError === null ? 0 : authError.messageType,
      authError === null ? '' : authError.headerKind,
      authError === null ? 0 : authError.frameBytes,
      authError === null ? 0 : authError.headerBytes,
      authError === null ? 0 : authError.bodyBytes,
      authError === null ? '' : this.safeAuthErrorMessage(authError.serverMessage)
    );
    try {
      await this.persistState();
    } catch {
      SteamArkLog.warn(TAG, 'account operation failure state persistence failed; account=' +
        SteamArkLog.accountId(record.profile.accountId) + ', stage=' + stage);
    }
    this.notifyListeners();
  }

  private async getAuthService(record: SteamArkAccountRecord): Promise<ISteamAuthService> {
    const existing = this.authServices.get(record.profile.accountId);
    if (existing !== undefined) {
      SteamArkLog.debug(TAG, 'authentication service cache hit; account=' +
        SteamArkLog.accountId(record.profile.accountId));
      return existing;
    }
    const factory = this.authServiceFactory;
    if (factory === null) {
      SteamArkLog.error(TAG, 'authentication service creation blocked; factory not configured; account=' +
        SteamArkLog.accountId(record.profile.accountId));
      throw new Error('Steam authentication service is not configured');
    }
    SteamArkLog.info(TAG, 'authentication service creation started; account=' +
      SteamArkLog.accountId(record.profile.accountId) + ', proxyKind=' + String(record.profile.proxy.kind));
    const proxyPassword = await this.readProxyPassword(record.profile.accountId);
    const service = factory.create(this.copyProfile(record.profile), proxyPassword);
    this.authServices.set(record.profile.accountId, service);
    SteamArkLog.info(TAG, 'authentication service created; account=' +
      SteamArkLog.accountId(record.profile.accountId));
    return service;
  }

  private async applyAuthResult(
    record: SteamArkAccountRecord,
    result: SteamAuthResult,
    refreshProfile: boolean = true
  ): Promise<void> {
    if (result.session.accountId !== record.profile.accountId) {
      throw new SteamAuthError(
        'Steam authentication result account does not match the requested account',
        SteamAuthErrorKind.RESPONSE,
        'authentication_result'
      );
    }
    const pending = this.validateAuthChallengeResult(record, result);
    const previousState: SteamSessionState = record.session.state;
    SteamArkLog.debug(TAG, 'authentication result application started; account=' +
      SteamArkLog.accountId(record.profile.accountId) + ', from=' + String(previousState) +
      ', to=' + String(result.session.state) + ', flow=' + String(result.flow) +
      ', credentialFieldsPresent=' + this.credentialFieldCount(result.credentials).toString());
    const previousRecord = this.copyRecord(record);
    const credentialSnapshot = await this.captureAccountCredentialSnapshot(record.profile.accountId);
    const isQrAuthentication = result.flow === SteamAuthFlowKind.QR ||
      (record.pendingAuth !== null && record.pendingAuth.flow === SteamAuthFlowKind.QR);
    let settledRecord: SteamArkAccountRecord = record;
    try {
      await this.storeCredentials(record.profile.accountId, result.credentials, credentialSnapshot);
      if (result.credentials.accountName.trim().length > 0 && isQrAuthentication) {
        record.profile.displayName = result.credentials.accountName;
      }
      record.session = this.sessionWithProfileSteamId(record, result.session);
      if (result.session.state === SteamSessionState.LOGGED_ON) {
        record.autoRestoreEnabled = true;
        record.profileRefreshGeneration += 1;
        record.profileRefreshRetryGeneration = -1;
        record.profileRefreshRetryPendingGeneration = -1;
      }
      if (record.session.steamId64.length > 0) {
        record.profile.steamId64 = record.session.steamId64;
      }
      if (result.session.state === SteamSessionState.LOGGED_ON &&
        isQrAuthentication &&
        record.profile.displayName === record.profile.accountId &&
        record.profile.steamId64.length > 0) {
        // Never surface the internal qr-* key as the user-facing account name.
        record.profile.displayName = record.profile.steamId64;
      }
      if (this.isAuthChallengeState(result.session.state)) {
        record.pendingAuth = this.copyPendingAuth(pending);
      } else {
        record.pendingAuth = null;
      }
      record.hasCredentialMaterial = await this.hasSecureCredentials(record.profile.accountId);
      settledRecord = await this.promoteQrAccountIfNeeded(record, result);
      if (settledRecord === record) {
        await this.persistState();
      }
      if (refreshProfile && settledRecord.session.state === SteamSessionState.LOGGED_ON) {
        // Register the deferred task before publishing the logged-on state. State
        // listeners then share this work instead of starting a concurrent profile
        // request while the QR record is still being promoted.
        this.scheduleLoggedOnProfileRefresh(
          settledRecord.profile.accountId,
          record.profile.accountId
        );
      }
      this.notifyListeners();
      SteamArkLog.state(TAG, String(previousState), String(settledRecord.session.state), 'authentication result applied; account=' +
        SteamArkLog.accountId(settledRecord.profile.accountId) + ', hasCredentialMaterial=' +
        String(settledRecord.hasCredentialMaterial));
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam authentication result application failed');
      this.restoreRecord(record, previousRecord);
      try {
        await this.restoreAccountCredentialSnapshot(record.profile.accountId, credentialSnapshot);
      } catch (rollbackError) {
        SteamArkLog.error(TAG, 'authentication credential rollback failed; account=' +
          SteamArkLog.accountId(record.profile.accountId) + ', errorType=' + SteamArkLog.errorKind(rollbackError));
      }
      try {
        await this.persistState();
      } catch {
        SteamArkLog.warn(TAG, 'authentication result rollback state persistence failed; account=' +
          SteamArkLog.accountId(record.profile.accountId));
      }
      throw normalized;
    }
  }

  private scheduleLoggedOnProfileRefresh(accountId: string, authenticationAccountId: string = ''): void {
    void this.requestLoggedOnProfileRefreshAfterAuthentication(accountId, authenticationAccountId).catch((error: Error): void => {
      SteamArkLog.warn(TAG, 'post-authentication profile refresh dispatch failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    });
  }

  private requestLoggedOnProfileRefresh(accountId: string): Promise<boolean> {
    return this.requestLoggedOnProfileRefreshWithBarrier(accountId, undefined);
  }

  /**
   * A QR result can replace its temporary record with a durable account ID while
   * its source authentication operation is still active. Preserve that source
   * operation as a barrier so the first profile request observes the committed
   * durable credentials and identity.
   */
  private requestLoggedOnProfileRefreshAfterAuthentication(
    accountId: string,
    authenticationAccountId: string
  ): Promise<boolean> {
    const sourceId: string = authenticationAccountId.trim();
    const sourceOperation: Promise<void> | undefined = sourceId.length <= 0
      ? undefined
      : this.accountOperationTails.get(sourceId);
    return this.requestLoggedOnProfileRefreshWithBarrier(accountId, sourceOperation);
  }

  private requestLoggedOnProfileRefreshWithBarrier(
    accountId: string,
    completionBarrier: Promise<void> | undefined
  ): Promise<boolean> {
    const normalizedId: string = accountId.trim();
    const record: SteamArkAccountRecord | undefined = this.records.get(normalizedId);
    const existing: Promise<boolean> | undefined = this.profileRefreshTasks.get(normalizedId);
    const existingGeneration: number | undefined = this.profileRefreshGenerations.get(normalizedId);
    if (existing !== undefined && (record === undefined || existingGeneration === record.profileRefreshGeneration)) {
      return existing;
    }
    const task: Promise<boolean> = completionBarrier === undefined
      ? this.runAccountOperation<boolean>(
        normalizedId,
        async (): Promise<boolean> => await this.refreshProfileInternal(normalizedId)
      )
      : this.runLoggedOnProfileRefreshAfterBarrier(completionBarrier, normalizedId);
    this.profileRefreshTasks.set(normalizedId, task);
    if (record === undefined) {
      this.profileRefreshGenerations.delete(normalizedId);
    } else {
      this.profileRefreshGenerations.set(normalizedId, record.profileRefreshGeneration);
    }
    void task.then(
      (): void => this.clearProfileRefreshTask(normalizedId, task),
      (): void => this.clearProfileRefreshTask(normalizedId, task)
    );
    return task;
  }

  private async runLoggedOnProfileRefreshAfterBarrier(
    completionBarrier: Promise<void>,
    accountId: string
  ): Promise<boolean> {
    return await this.runAccountOperation<boolean>(
      accountId,
      async (): Promise<boolean> => {
        // Reserve the durable account queue before state listeners can dispatch
        // inventory, farming, or social work. The source QR operation remains
        // independent, so waiting here cannot block its completion.
        await completionBarrier;
        return await this.refreshProfileInternal(accountId);
      }
    );
  }

  private clearProfileRefreshTask(accountId: string, task: Promise<boolean>): void {
    if (this.profileRefreshTasks.get(accountId) === task) {
      this.profileRefreshTasks.delete(accountId);
      this.profileRefreshGenerations.delete(accountId);
      this.dispatchPendingProfileRefreshRetry(accountId);
    }
  }

  /**
   * A first-login profile request can lose a transient network race while the
   * authenticated runtime finishes connecting. Retry once after its task leaves
   * the account queue; this is event-driven and never delays authentication.
   */
  private scheduleProfileRefreshRetry(record: SteamArkAccountRecord, generation: number): void {
    if (!this.isCurrentLoggedOnProfileRecord(
      record.profile.accountId,
      record,
      generation,
      record.profile.steamId64
    )) {
      return;
    }
    if (record.profileRefreshRetryGeneration === generation ||
      record.profileRefreshRetryPendingGeneration === generation) {
      return;
    }
    record.profileRefreshRetryGeneration = generation;
    record.profileRefreshRetryPendingGeneration = generation;
    SteamArkLog.info(TAG, 'basic profile refresh retry scheduled; account=' +
      SteamArkLog.accountId(record.profile.accountId));
  }

  private dispatchPendingProfileRefreshRetry(accountId: string): void {
    const normalizedId: string = accountId.trim();
    const record: SteamArkAccountRecord | undefined = this.records.get(normalizedId);
    if (record === undefined || record.profileRefreshRetryPendingGeneration !== record.profileRefreshGeneration ||
      record.session.state !== SteamSessionState.LOGGED_ON || this.isDisposing) {
      return;
    }
    record.profileRefreshRetryPendingGeneration = -1;
    this.scheduleLoggedOnProfileRefresh(normalizedId);
  }

  /**
   * Visual profile decoration can require an HTML page request and, for animated
   * backgrounds, a media frame extraction. It must never hold the account
   * operation queue that delivers the basic name and avatar after sign-in.
   */
  private scheduleLoggedOnProfileVisualRefresh(accountId: string, baseline: SteamArkResolvedProfile): void {
    const normalizedId: string = accountId.trim();
    if (normalizedId.length <= 0 || this.profileVisualResolver === null || this.isDisposing) {
      return;
    }
    const record: SteamArkAccountRecord | undefined = this.records.get(normalizedId);
    if (record === undefined || record.session.state !== SteamSessionState.LOGGED_ON) {
      return;
    }
    const generation: number = record.profileRefreshGeneration;
    const existing: Promise<void> | undefined = this.profileVisualRefreshTasks.get(normalizedId);
    const existingGeneration: number | undefined = this.profileVisualRefreshGenerations.get(normalizedId);
    if (existing !== undefined && existingGeneration === generation) {
      return;
    }
    const task: Promise<void> = this.refreshLoggedOnProfileVisuals(record, generation, baseline);
    this.profileVisualRefreshTasks.set(normalizedId, task);
    this.profileVisualRefreshGenerations.set(normalizedId, generation);
    void task.then(
      (): void => this.clearProfileVisualRefreshTask(normalizedId, task),
      (): void => this.clearProfileVisualRefreshTask(normalizedId, task)
    );
  }

  private clearProfileVisualRefreshTask(accountId: string, task: Promise<void>): void {
    if (this.profileVisualRefreshTasks.get(accountId) === task) {
      this.profileVisualRefreshTasks.delete(accountId);
      this.profileVisualRefreshGenerations.delete(accountId);
    }
  }

  /**
   * QR sessions start with an internal key, but that key must never become the
   * persisted account identity. Promote the record and its secure credentials
   * as soon as Steam returns the real account name/SteamID.
   */
  private async promoteQrAccountIfNeeded(
    record: SteamArkAccountRecord,
    result: SteamAuthResult
  ): Promise<SteamArkAccountRecord> {
    if (!this.isQrAuthenticationRecord(record) || result.session.state !== SteamSessionState.LOGGED_ON) {
      return record;
    }
    const credentials = result.credentials;
    let canonicalId = credentials.accountName.trim().length > 0
      ? credentials.accountName.trim()
      : result.session.steamId64.trim();
    if (canonicalId.length <= 0 || canonicalId === record.profile.accountId || canonicalId.indexOf('qr-') === 0) {
      return record;
    }

    const temporaryId = record.profile.accountId;
    const matchingSteamIdAccountId: string = this.findAccountIdBySteamId64(
      result.session.steamId64,
      temporaryId
    );
    if (matchingSteamIdAccountId.length > 0) {
      canonicalId = matchingSteamIdAccountId;
    } else if (credentials.accountName.trim().length > 0) {
      const matchingAccountNameId: string = await this.findAccountIdByAccountName(credentials.accountName);
      if (matchingAccountNameId.length > 0 && matchingAccountNameId !== temporaryId) {
        canonicalId = matchingAccountNameId;
      }
    }
    const existing = this.records.get(canonicalId);
    const existingSnapshot = existing === undefined ? null : this.copyRecord(existing);
    const temporaryCredentialSnapshot = await this.captureAccountCredentialSnapshot(temporaryId);
    const canonicalCredentialSnapshot = await this.captureAccountCredentialSnapshot(canonicalId);
    const temporaryAuthService = this.authServices.get(temporaryId);
    const qrSelectionRequestGeneration = this.qrAuthenticationSelectionGenerations.get(temporaryId);
    let previousSelectedAccountId: string = '';
    let selectedAccountIdAfterPromotion: string = '';
    let selectionRequestGeneration: number = 0;
    let selectionAdjustedByPromotion: boolean = false;
    const target = existing === undefined
      ? new SteamArkAccountRecord(
        new SteamAccountProfile(
          canonicalId,
          record.profile.displayName,
          record.profile.steamId64,
          record.profile.enabled,
          new SteamProxySettings(
            record.profile.proxy.kind,
            record.profile.proxy.host,
            record.profile.proxy.port,
            record.profile.proxy.username
          ),
          record.profile.avatarUrl,
          record.profile.profileBackgroundImageUrl,
          record.profile.profileBackgroundMovieUrl,
          record.profile.profileBackgroundTiled,
          record.profile.avatarFrameUrl,
          record.profile.summary,
          record.profile.level,
          record.profile.countryCode,
          record.profile.walletBalance,
          record.profile.walletCurrency,
          record.profile.miniProfileBackgroundImageUrl,
          record.profile.miniProfileBackgroundMovieUrl
        ),
        this.copyBotConfig(record.config, canonicalId),
        new SteamSessionSnapshot(canonicalId),
        this.copyMigrationReport(record.migrationReport)
      )
      : existing;

    try {
      const temporaryCredentials = await this.getCredentials(temporaryId);
      await this.replaceStoredCredentials(canonicalId, temporaryCredentials);
      const canonicalCredentialMaterialPersisted: boolean = await this.hasSecureCredentials(canonicalId);
      if (!canonicalCredentialMaterialPersisted) {
        throw new Error('QR authentication credential material was not persisted for the stable account');
      }
      const removed = await this.credentialStore.removeAll(temporaryId);
      if (!removed) {
        throw new Error('temporary QR credential cleanup was rejected');
      }
      target.profile.displayName = credentials.accountName.trim().length > 0
        ? credentials.accountName.trim()
        : (target.profile.displayName.length > 0 ? target.profile.displayName : canonicalId);
      target.profile.steamId64 = result.session.steamId64.length > 0
        ? result.session.steamId64
        : record.profile.steamId64;
      target.session = new SteamSessionSnapshot(
        canonicalId,
        result.session.state,
        target.profile.steamId64,
        result.session.server,
        result.session.connectedAtEpochSeconds,
        result.session.expiresAtEpochSeconds,
        result.session.lastErrorCode,
        result.session.lastErrorMessage,
        result.session.lastErrorType,
        result.session.lastErrorStage,
        result.session.lastErrorHttpStatusCode,
        result.session.lastErrorMessageType,
        result.session.lastErrorHeaderKind,
        result.session.lastErrorFrameBytes,
        result.session.lastErrorHeaderBytes,
        result.session.lastErrorBodyBytes,
        result.session.lastErrorServerMessage
      );
      target.pendingAuth = null;
      // The canonical record can have a previous authenticated runtime. Advancing
      // its own generation prevents results from that identity from publishing
      // over the profile just confirmed by this QR sign-in.
      target.profileRefreshGeneration += 1;
      target.profileRefreshRetryGeneration = -1;
      target.profileRefreshRetryPendingGeneration = -1;
      target.hasCredentialMaterial = await this.hasSecureCredentials(canonicalId);
      previousSelectedAccountId = this.selectedAccountId;
      selectionRequestGeneration = this.accountSelectionRequestGeneration;
      this.records.set(canonicalId, target);
      this.records.delete(temporaryId);
      const shouldSelectPromotedAccount: boolean =
        qrSelectionRequestGeneration === undefined
          ? previousSelectedAccountId === temporaryId
          : qrSelectionRequestGeneration === this.accountSelectionRequestGeneration;
      if (shouldSelectPromotedAccount) {
        this.selectedAccountId = canonicalId;
        this.logSelectedAccountChange(previousSelectedAccountId);
      } else {
        this.ensureSelectedAccount('');
      }
      selectedAccountIdAfterPromotion = this.selectedAccountId;
      selectionAdjustedByPromotion = selectedAccountIdAfterPromotion !== previousSelectedAccountId;
      this.authServices.delete(temporaryId);
      await this.persistState();
      this.qrAuthenticationSelectionGenerations.delete(temporaryId);
    } catch (error) {
      this.records.delete(canonicalId);
      if (existing !== undefined && existingSnapshot !== null) {
        this.restoreRecord(existing, existingSnapshot);
        this.records.set(canonicalId, existing);
      }
      this.records.set(temporaryId, record);
      const canRestorePreviousSelection: boolean = selectionAdjustedByPromotion &&
        selectionRequestGeneration === this.accountSelectionRequestGeneration &&
        this.selectedAccountId === selectedAccountIdAfterPromotion;
      if (canRestorePreviousSelection) {
        const selectedBeforeRollback = this.selectedAccountId;
        this.selectedAccountId = previousSelectedAccountId;
        this.logSelectedAccountChange(selectedBeforeRollback);
      } else {
        this.ensureSelectedAccount('');
      }
      if (temporaryAuthService !== undefined) {
        this.authServices.set(temporaryId, temporaryAuthService);
      }
      await this.restoreAccountCredentialSnapshot(temporaryId, temporaryCredentialSnapshot);
      await this.restoreAccountCredentialSnapshot(canonicalId, canonicalCredentialSnapshot);
      throw error instanceof Error ? error : new Error('QR account promotion failed');
    }
    if (temporaryAuthService !== undefined) {
      try {
        await temporaryAuthService.close(temporaryId);
      } catch (error) {
        SteamArkLog.warn(TAG, 'promoted QR authentication service cleanup failed; account=' +
          SteamArkLog.accountId(canonicalId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
    SteamArkLog.info(TAG, 'QR account promoted to stable identity; temporary=' +
      SteamArkLog.accountId(temporaryId) + ', account=' + SteamArkLog.accountId(canonicalId));
    return target;
  }

  private isQrAuthenticationRecord(record: SteamArkAccountRecord): boolean {
    return record.profile.accountId.indexOf('qr-') === 0;
  }

  private async replaceStoredCredentials(
    accountId: string,
    credentials: SteamCredentialSet
  ): Promise<void> {
    // QR authentication does not return authenticator secrets. Do not erase a
    // previously imported maFile secret while promoting the QR account.
    await this.mergeStoredCredential(accountId, NGFCredentialKind.ACCOUNT_NAME, credentials.accountName);
    await this.mergeStoredCredential(accountId, NGFCredentialKind.PASSWORD, credentials.password);
    await this.mergeStoredCredential(accountId, NGFCredentialKind.REFRESH_TOKEN, credentials.refreshToken);
    await this.mergeStoredCredential(accountId, NGFCredentialKind.LOGIN_KEY, credentials.loginKey);
    await this.mergeStoredCredential(accountId, NGFCredentialKind.SHARED_SECRET, credentials.sharedSecret);
    await this.mergeStoredCredential(accountId, NGFCredentialKind.IDENTITY_SECRET, credentials.identitySecret);
    await this.mergeStoredCredential(accountId, NGFCredentialKind.DEVICE_ID, credentials.deviceId);
    await this.mergeStoredCredential(accountId, NGFCredentialKind.GUARD_DATA, credentials.guardData);
    await this.mergeStoredCredential(accountId, NGFCredentialKind.ACCESS_TOKEN, credentials.accessToken);
    await this.mergeStoredCredential(accountId, NGFCredentialKind.OAUTH_TOKEN, credentials.oauthToken);
  }

  /**
   * A maFile is authoritative only for its authenticator material. Optional
   * authenticator fields therefore use replacement semantics, while login and
   * web-session credentials remain owned by the active authentication flow.
   */
  private async replaceMaFileAuthenticatorCredentials(
    accountId: string,
    credentials: SteamCredentialSet
  ): Promise<void> {
    await this.mergeStoredCredential(accountId, NGFCredentialKind.ACCOUNT_NAME, credentials.accountName);
    await this.replaceCredential(accountId, NGFCredentialKind.SHARED_SECRET, credentials.sharedSecret);
    await this.replaceCredential(accountId, NGFCredentialKind.IDENTITY_SECRET, credentials.identitySecret);
    await this.replaceCredential(accountId, NGFCredentialKind.DEVICE_ID, credentials.deviceId);
    await this.mergeStoredCredentialIfMissing(accountId, NGFCredentialKind.ACCESS_TOKEN, credentials.accessToken);
    await this.mergeStoredCredentialIfMissing(accountId, NGFCredentialKind.OAUTH_TOKEN, credentials.oauthToken);
  }

  private async mergeStoredCredentialIfMissing(
    accountId: string,
    kind: NGFCredentialKind,
    value: string
  ): Promise<void> {
    if (value.trim().length <= 0) {
      return;
    }
    const existing: string | null = await this.credentialStore.get(accountId, kind);
    if (existing === null || existing.trim().length <= 0) {
      await this.replaceCredential(accountId, kind, value);
    }
  }

  private async mergeStoredCredential(
    accountId: string,
    kind: NGFCredentialKind,
    value: string
  ): Promise<void> {
    if (value.trim().length > 0) {
      await this.replaceCredential(accountId, kind, value);
    }
  }

  /**
   * The basic mini-profile is deliberately post-commit. A public-profile
   * outage must not turn a completed Steam authentication back into a failed
   * login, and an empty field must never erase a previously cached value.
   */
  private async resolveLoggedOnProfile(record: SteamArkAccountRecord): Promise<boolean> {
    const resolver: ISteamArkProfileResolver | null = this.profileResolver;
    if (resolver === null || record.session.state !== SteamSessionState.LOGGED_ON) {
      return false;
    }
    const accountId: string = record.profile.accountId;
    const generation: number = record.profileRefreshGeneration;
    const steamId64: string = record.profile.steamId64;
    try {
      const credentials: SteamCredentialSet = await this.getCredentials(accountId);
      const proxyPassword: string = await this.readProxyPassword(accountId);
      const resolved: SteamArkResolvedProfile = await resolver.resolve(
        this.copyProfile(record.profile),
        credentials,
        proxyPassword
      );
      if (!this.hasUsableBasicResolvedIdentity(resolved)) {
        SteamArkLog.warn(TAG, 'basic profile lookup returned no usable identity; authentication remains completed; account=' +
          SteamArkLog.accountId(accountId));
        this.scheduleProfileRefreshRetry(record, generation);
        return false;
      }
      if (!this.isCurrentLoggedOnProfileRecord(accountId, record, generation, steamId64)) {
        SteamArkLog.debug(TAG, 'basic profile result ignored because account authentication changed; account=' +
          SteamArkLog.accountId(accountId));
        return false;
      }
      const changed: boolean = this.mergeBasicResolvedProfile(record.profile, resolved);
      if (changed) {
        try {
          await this.persistState();
        } catch (error) {
          SteamArkLog.warn(TAG, 'basic profile persistence failed; authentication remains completed; account=' +
            SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
        }
      }
      if (!this.isCurrentLoggedOnProfileRecord(accountId, record, generation, steamId64)) {
        SteamArkLog.debug(TAG, 'basic profile publication ignored because account authentication changed; account=' +
          SteamArkLog.accountId(accountId));
        return false;
      }
      // Always publish a settled snapshot. This releases first-login placeholders
      // even when Steam returns the same name/avatar already stored by auth.
      this.notifyListeners();
      SteamArkLog.info(TAG, 'basic authenticated profile refreshed; account=' +
        SteamArkLog.accountId(accountId) + ', changed=' + String(changed) +
        ', displayNamePresent=' + String(record.profile.displayName.length > 0) +
        ', avatarPresent=' + String(record.profile.avatarUrl.length > 0));
      this.scheduleLoggedOnProfileVisualRefresh(accountId, resolved);
      return true;
    } catch (error) {
      SteamArkLog.warn(TAG, 'basic authenticated profile lookup failed; authentication remains completed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      this.scheduleProfileRefreshRetry(record, generation);
      return false;
    }
  }

  /** Basic resolvers must return identity data; decoration is handled by the visual resolver. */
  private hasUsableBasicResolvedIdentity(resolved: SteamArkResolvedProfile): boolean {
    return resolved.displayName.trim().length > 0 || resolved.avatarUrl.trim().length > 0;
  }

  /** Resolves non-essential decoration after basic identity is already visible. */
  private async refreshLoggedOnProfileVisuals(
    record: SteamArkAccountRecord,
    generation: number,
    baseline: SteamArkResolvedProfile
  ): Promise<void> {
    const resolver: ISteamArkProfileVisualResolver | null = this.profileVisualResolver;
    if (resolver === null) {
      return;
    }
    const accountId: string = record.profile.accountId;
    const steamId64: string = record.profile.steamId64;
    try {
      const credentials: SteamCredentialSet = await this.getCredentials(accountId);
      const proxyPassword: string = await this.readProxyPassword(accountId);
      const resolved: SteamArkResolvedProfile = await resolver.resolveVisuals(
        this.copyProfile(record.profile),
        credentials,
        baseline,
        proxyPassword
      );
      if (!this.isCurrentLoggedOnProfileRecord(accountId, record, generation, steamId64)) {
        SteamArkLog.debug(TAG, 'profile visual result ignored because account authentication changed; account=' +
          SteamArkLog.accountId(accountId));
        return;
      }
      const changed: boolean = this.mergeVisualResolvedProfile(record.profile, resolved);
      if (changed) {
        try {
          await this.persistState();
        } catch (error) {
          SteamArkLog.warn(TAG, 'profile visual persistence failed; account=' +
            SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
        }
      }
      if (!this.isCurrentLoggedOnProfileRecord(accountId, record, generation, steamId64)) {
        SteamArkLog.debug(TAG, 'profile visual publication ignored because account authentication changed; account=' +
          SteamArkLog.accountId(accountId));
        return;
      }
      if (changed) {
        this.notifyListeners();
      }
      SteamArkLog.info(TAG, 'profile visual refresh completed; account=' +
        SteamArkLog.accountId(accountId) + ', changed=' + String(changed) +
        ', framePresent=' + String(record.profile.avatarFrameUrl.length > 0) +
        ', backgroundPresent=' + String(record.profile.profileBackgroundImageUrl.length > 0));
    } catch (error) {
      SteamArkLog.warn(TAG, 'profile visual lookup failed; basic identity retained; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private mergeBasicResolvedProfile(profile: SteamAccountProfile, resolved: SteamArkResolvedProfile): boolean {
    let changed: boolean = false;
    const displayName: string = resolved.displayName.trim();
    if (displayName.length > 0 && displayName !== profile.displayName) {
      profile.displayName = displayName;
      changed = true;
    }
    const avatarUrl: string = resolved.avatarUrl.trim();
    if (avatarUrl.length > 0 && avatarUrl !== profile.avatarUrl) {
      profile.avatarUrl = avatarUrl;
      changed = true;
    }
    const summary: string = resolved.summary.trim();
    if (summary.length > 0 && summary !== profile.summary) {
      profile.summary = summary;
      changed = true;
    }
    if (resolved.level > 0 && resolved.level !== profile.level) {
      profile.level = resolved.level;
      changed = true;
    }
    const countryCode: string = resolved.countryCode.trim();
    if (countryCode.length > 0 && countryCode !== profile.countryCode) {
      profile.countryCode = countryCode;
      changed = true;
    }
    const walletBalance: string = resolved.walletBalance.trim();
    if (walletBalance.length > 0 && walletBalance !== profile.walletBalance) {
      profile.walletBalance = walletBalance;
      changed = true;
    }
    const walletCurrency: string = resolved.walletCurrency.trim();
    if (walletCurrency.length > 0 && walletCurrency !== profile.walletCurrency) {
      profile.walletCurrency = walletCurrency;
      changed = true;
    }
    // The mini-profile endpoint already supplies these lightweight decorations.
    // Persist them with the first identity response so a later full profile-page
    // request cannot leave a newly logged-in account without its frame or card background.
    const avatarFrameUrl: string = resolved.avatarFrameUrl.trim();
    if (avatarFrameUrl.length > 0 && avatarFrameUrl !== profile.avatarFrameUrl) {
      profile.avatarFrameUrl = avatarFrameUrl;
      changed = true;
    }
    const miniBackgroundImageUrl: string = resolved.miniProfileBackgroundImageUrl.trim();
    if (miniBackgroundImageUrl.length > 0 && miniBackgroundImageUrl !== profile.miniProfileBackgroundImageUrl) {
      profile.miniProfileBackgroundImageUrl = miniBackgroundImageUrl;
      changed = true;
    }
    const miniBackgroundMovieUrl: string = resolved.miniProfileBackgroundMovieUrl.trim();
    if (miniBackgroundMovieUrl.length > 0 && miniBackgroundMovieUrl !== profile.miniProfileBackgroundMovieUrl) {
      profile.miniProfileBackgroundMovieUrl = miniBackgroundMovieUrl;
      changed = true;
    }
    return changed;
  }

  private mergeVisualResolvedProfile(profile: SteamAccountProfile, resolved: SteamArkResolvedProfile): boolean {
    let changed: boolean = false;
    const backgroundImageUrl: string = resolved.backgroundImageUrl.trim();
    if (backgroundImageUrl.length > 0 && backgroundImageUrl !== profile.profileBackgroundImageUrl) {
      profile.profileBackgroundImageUrl = backgroundImageUrl;
      changed = true;
    }
    const backgroundMovieUrl: string = resolved.backgroundMovieUrl.trim();
    if (backgroundMovieUrl.length > 0 && backgroundMovieUrl !== profile.profileBackgroundMovieUrl) {
      profile.profileBackgroundMovieUrl = backgroundMovieUrl;
      changed = true;
    }
    if ((backgroundImageUrl.length > 0 || backgroundMovieUrl.length > 0) &&
      resolved.backgroundTiled !== profile.profileBackgroundTiled) {
      profile.profileBackgroundTiled = resolved.backgroundTiled;
      changed = true;
    }
    const miniBackgroundImageUrl: string = resolved.miniProfileBackgroundImageUrl.trim();
    if (miniBackgroundImageUrl.length > 0 && miniBackgroundImageUrl !== profile.miniProfileBackgroundImageUrl) {
      profile.miniProfileBackgroundImageUrl = miniBackgroundImageUrl;
      changed = true;
    }
    const miniBackgroundMovieUrl: string = resolved.miniProfileBackgroundMovieUrl.trim();
    if (miniBackgroundMovieUrl.length > 0 && miniBackgroundMovieUrl !== profile.miniProfileBackgroundMovieUrl) {
      profile.miniProfileBackgroundMovieUrl = miniBackgroundMovieUrl;
      changed = true;
    }
    const avatarFrameUrl: string = resolved.avatarFrameUrl.trim();
    if (avatarFrameUrl.length > 0 && avatarFrameUrl !== profile.avatarFrameUrl) {
      profile.avatarFrameUrl = avatarFrameUrl;
      changed = true;
    }
    return changed;
  }

  private isCurrentLoggedOnProfileRecord(
    accountId: string,
    record: SteamArkAccountRecord,
    generation: number,
    steamId64: string
  ): boolean {
    const current: SteamArkAccountRecord | undefined = this.records.get(accountId);
    return !this.isDisposing && current !== undefined && current === record &&
      current.profileRefreshGeneration === generation && current.session.state === SteamSessionState.LOGGED_ON &&
      current.profile.steamId64 === steamId64;
  }

  /** Re-establishes every stored account independently after an ability restart. */
  private async refreshRestoredSessions(generation: number): Promise<void> {
    if (!this.initialized || this.isDisposing || this.authServiceFactory === null) {
      return;
    }
    const records: Array<SteamArkAccountRecord> = [];
    this.records.forEach((record: SteamArkAccountRecord): void => {
      if (record.autoRestoreEnabled && record.session.state === SteamSessionState.LOGGED_ON &&
        record.pendingAuth === null && record.profile.steamId64.length > 0) {
        records.push(record);
        this.restoringAccounts.set(record.profile.accountId, true);
      }
    });
    this.notifyListeners();
    for (let index = 0; index < records.length; index++) {
      const record = records[index];
      if (generation !== this.sessionRestoreGeneration || this.isDisposing) {
        SteamArkLog.debug(TAG, 'stored session restore cancelled during lifecycle teardown');
        return;
      }
      try {
        await this.runAccountOperation<void>(
          record.profile.accountId,
          async (): Promise<void> => {
            const current = this.records.get(record.profile.accountId);
            if (current === undefined) {
              return;
            }
            const credentials = await this.getCredentials(current.profile.accountId);
            if (!this.hasUsableAuthenticationCredentials(credentials)) {
              // A missing Web token only limits Web-backed features. It is not
              // evidence that the native/CM session or imported maFile is invalid.
              this.notifyListeners();
              SteamArkLog.info(TAG, 'stored native session retained without Web credentials; account=' +
                SteamArkLog.accountId(current.profile.accountId));
              return;
            }
            const service = await this.getAuthService(current);
            // QR authentication already returns a usable access token. Reusing it
            // avoids an unnecessary GenerateAccessTokenForApp call during startup;
            // Steam can reject that call even while the stored token is valid.
            const result = credentials.accessToken.trim().length > 0
              ? new SteamAuthResult(
                new SteamSessionSnapshot(
                  current.profile.accountId,
                  SteamSessionState.LOGGED_ON,
                  current.profile.steamId64,
                  current.session.server,
                  this.nowEpochSeconds(),
                  0,
                  0
                ),
                credentials
              )
              : await service.refresh(current.profile.accountId, credentials.refreshToken);
            if (generation !== this.sessionRestoreGeneration || this.isDisposing) {
              SteamArkLog.debug(TAG, 'stored session restore result ignored after lifecycle teardown; account=' +
                SteamArkLog.accountId(current.profile.accountId));
              return;
            }
            // Startup recovery is advisory. A challenge or other non-logged-on
            // response does not prove that the persisted account session was
            // revoked, so it must not replace a previously usable session. The
            // user can still explicitly refresh or sign in to handle a real
            // challenge through the normal authentication flow.
            if (current.session.state === SteamSessionState.LOGGED_ON &&
              result.session.state !== SteamSessionState.LOGGED_ON) {
              SteamArkLog.warn(TAG, 'stored session restore returned non-logged-on state; last known session retained; account=' +
                SteamArkLog.accountId(current.profile.accountId) + ', resultState=' + String(result.session.state));
              return;
            }
            await this.applyAuthResult(current, result, false);
          }
        );
        SteamArkLog.info(TAG, 'stored session restored; account=' +
          SteamArkLog.accountId(record.profile.accountId));
      } catch (error) {
        if (generation !== this.sessionRestoreGeneration || this.isDisposing) {
          SteamArkLog.debug(TAG, 'stored session restore failure ignored after lifecycle teardown; account=' +
            SteamArkLog.accountId(record.profile.accountId));
          return;
        }
        // A refresh failure is not proof that Steam revoked the credentials. Keep
        // the last known authenticated snapshot so a transient CM/network issue
        // cannot force a re-login or overwrite durable state with disconnected.
        this.notifyListeners();
        SteamArkLog.warn(TAG, 'stored session restore failed; last known session retained; account=' +
          SteamArkLog.accountId(record.profile.accountId) + ', state=' + String(record.session.state) +
          ', errorType=' + SteamArkLog.errorKind(error));
      }
      this.restoringAccounts.delete(record.profile.accountId);
      this.notifyListeners();
    }
    if (generation === this.sessionRestoreGeneration && !this.isDisposing) {
      await this.refreshRestoredProfiles(generation);
    }
  }

  private isAccountBeingRestored(accountId: string): boolean {
    return this.restoringAccounts.has(accountId.trim());
  }

  private async refreshRestoredProfiles(generation: number): Promise<void> {
    const resolver = this.profileResolver;
    if (resolver === null || !this.initialized || this.isDisposing) {
      return;
    }
    const records: Array<SteamArkAccountRecord> = [];
    this.records.forEach((record: SteamArkAccountRecord): void => {
      if (!this.isTemporaryQrRecord(record) && record.session.state === SteamSessionState.LOGGED_ON &&
        record.profile.steamId64.length > 0) {
        records.push(record);
      }
    });
    for (let index: number = 0; index < records.length; index++) {
      const record: SteamArkAccountRecord = records[index];
      if (generation !== this.sessionRestoreGeneration || this.isDisposing) {
        return;
      }
      await this.runAccountOperation<void>(record.profile.accountId, async (): Promise<void> => {
        if (generation !== this.sessionRestoreGeneration || this.isDisposing) {
          return;
        }
        const current: SteamArkAccountRecord | undefined = this.records.get(record.profile.accountId);
        if (current === undefined || current !== record || current.session.state !== SteamSessionState.LOGGED_ON) {
          SteamArkLog.debug(TAG, 'stored profile refresh ignored because account state changed; account=' +
            SteamArkLog.accountId(record.profile.accountId));
          return;
        }
        await this.resolveLoggedOnProfile(current);
      });
    }
  }

  private async recordAuthFailure(record: SteamArkAccountRecord, error: SteamAuthError): Promise<void> {
    SteamArkLog.warn(TAG, 'authentication failure state transition started; account=' +
      SteamArkLog.accountId(record.profile.accountId) + ', kind=' + String(error.kind) +
      ', stage=' + error.stage + ', code=' + error.code.toString());
    const service = this.authServices.get(record.profile.accountId);
    const pending = service === undefined
      ? null
      : service.getPendingAuthSnapshot(record.profile.accountId);
    const canResumeAfterFailure = pending !== null &&
      ((error.kind === SteamAuthErrorKind.TRANSPORT || error.kind === SteamAuthErrorKind.TIMEOUT) ||
        (error.kind === SteamAuthErrorKind.VALIDATION && error.stage === 'challenge_completion'));
    if (pending !== null && !canResumeAfterFailure && service !== undefined) {
      try {
        await service.cancelPendingAuth(record.profile.accountId);
      } catch {
        SteamArkLog.warn(TAG, 'terminal authentication failure pending cleanup failed; account=' +
          SteamArkLog.accountId(record.profile.accountId) + ', stage=' + error.stage);
      }
    }
    const failureState: SteamSessionState = error.stage === 'pending_auth_restore' ||
      error.stage === 'pending_auth_expired'
      ? SteamSessionState.EXPIRED
      : SteamSessionState.ERROR;
    record.pendingAuth = canResumeAfterFailure
      ? this.copyPendingAuth(pending)
      : null;
    record.session = new SteamSessionSnapshot(
      record.profile.accountId,
      failureState,
      record.profile.steamId64,
      record.session.server,
      record.session.connectedAtEpochSeconds,
      record.session.expiresAtEpochSeconds,
      error.code,
      this.safeAuthErrorMessage(error.message),
      String(error.kind),
      error.stage,
      error.httpStatusCode,
      error.messageType,
      error.headerKind,
      error.frameBytes,
      error.headerBytes,
      error.bodyBytes,
      this.safeAuthErrorMessage(error.serverMessage)
    );
    try {
      record.hasCredentialMaterial = await this.hasSecureCredentials(record.profile.accountId);
    } catch {
      SteamArkLog.warn(TAG, 'authentication credential presence refresh failed; account=' +
        SteamArkLog.accountId(record.profile.accountId));
    }
    try {
      await this.persistState();
    } catch {
      SteamArkLog.warn(TAG, 'Steam authentication error state persistence failed');
    }
    this.notifyListeners();
    SteamArkLog.warn(TAG, 'authentication failure state persisted; account=' +
      SteamArkLog.accountId(record.profile.accountId) + ', pending=' + String(record.pendingAuth !== null) +
      ', detailLength=' + error.message.length.toString());
  }

  private validateAuthChallengeResult(
    record: SteamArkAccountRecord,
    result: SteamAuthResult
  ): SteamAuthPendingSnapshot | null {
    if (!this.isAuthChallengeState(result.session.state)) {
      return null;
    }
    const service = this.authServices.get(record.profile.accountId);
    const pending = service === undefined
      ? null
      : service.getPendingAuthSnapshot(record.profile.accountId);
    const expectedChallenge = this.challengeKindForState(result.session.state);
    if (pending === null) {
      throw new SteamAuthError(
        'Steam authentication challenge response has no pending session snapshot',
        SteamAuthErrorKind.RESPONSE,
        'challenge_snapshot'
      );
    }
    if (pending.accountId !== record.profile.accountId ||
      pending.challenge !== expectedChallenge ||
      result.challenge !== expectedChallenge ||
      pending.flow !== result.flow ||
      (result.flow === SteamAuthFlowKind.QR && pending.challengeUrl !== result.qrChallengeUrl) ||
      !pending.isValidFor(record.profile.accountId, Math.floor(Date.now() / 1000))) {
      throw new SteamAuthError(
        'Steam authentication challenge response does not match its pending session snapshot',
        SteamAuthErrorKind.RESPONSE,
        'challenge_snapshot'
      );
    }
    return pending;
  }

  private isSameAuthChallenge(
    current: SteamAuthPendingSnapshot,
    expected: SteamAuthPendingSnapshot
  ): boolean {
    return current.accountId === expected.accountId &&
      current.clientId === expected.clientId &&
      current.requestId === expected.requestId &&
      current.challenge === expected.challenge &&
      current.flow === expected.flow &&
      current.createdAtEpochSeconds === expected.createdAtEpochSeconds &&
      current.expiresAtEpochSeconds === expected.expiresAtEpochSeconds &&
      current.challengeUrl === expected.challengeUrl;
  }

  private async expirePendingAuthentication(record: SteamArkAccountRecord): Promise<void> {
    const accountId: string = record.profile.accountId;
    const service = this.authServices.get(accountId);
    if (service !== undefined) {
      try {
        await service.cancelPendingAuth(accountId);
      } catch (error) {
        SteamArkLog.warn(TAG, 'expired authentication pending cleanup failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
    await this.recordAuthFailure(
      record,
      new SteamAuthError(
        'Steam authentication challenge expired; sign in again',
        SteamAuthErrorKind.AUTHENTICATION,
        'pending_auth_expired'
      )
    );
  }

  private safeAuthErrorMessage(message: string): string {
    const normalized = message.replace(/\r/g, ' ').replace(/\n/g, ' ').trim();
    if (normalized.length <= 512) {
      return normalized;
    }
    return normalized.substring(0, 512);
  }

  private sessionWithProfileSteamId(
    record: SteamArkAccountRecord,
    session: SteamSessionSnapshot
  ): SteamSessionSnapshot {
    const steamId64 = session.steamId64.length > 0 ? session.steamId64 : record.profile.steamId64;
    return new SteamSessionSnapshot(
      record.profile.accountId,
      session.state,
      steamId64,
      session.server,
      session.connectedAtEpochSeconds,
      session.expiresAtEpochSeconds,
      session.lastErrorCode,
      session.lastErrorMessage,
      session.lastErrorType,
      session.lastErrorStage,
      session.lastErrorHttpStatusCode,
      session.lastErrorMessageType,
      session.lastErrorHeaderKind,
      session.lastErrorFrameBytes,
      session.lastErrorHeaderBytes,
      session.lastErrorBodyBytes,
      session.lastErrorServerMessage
    );
  }

  private challengeKindForState(state: SteamSessionState): SteamAuthChallengeKind {
    if (state === SteamSessionState.NEEDS_QR_SCAN) {
      return SteamAuthChallengeKind.QR_SCAN;
    }
    if (state === SteamSessionState.NEEDS_EMAIL_CODE) {
      return SteamAuthChallengeKind.EMAIL_CODE;
    }
    if (state === SteamSessionState.NEEDS_TWO_FACTOR) {
      return SteamAuthChallengeKind.TWO_FACTOR;
    }
    if (state === SteamSessionState.NEEDS_MOBILE_CONFIRMATION) {
      return SteamAuthChallengeKind.MOBILE_CONFIRMATION;
    }
    return SteamAuthChallengeKind.NONE;
  }

  private isAuthChallengeState(state: SteamSessionState): boolean {
    return state === SteamSessionState.NEEDS_QR_SCAN ||
      state === SteamSessionState.NEEDS_EMAIL_CODE ||
      state === SteamSessionState.NEEDS_TWO_FACTOR ||
      state === SteamSessionState.NEEDS_MOBILE_CONFIRMATION;
  }

  private challengeKindForRecord(record: SteamArkAccountRecord): SteamAuthChallengeKind {
    if (record.pendingAuth !== null) {
      return record.pendingAuth.challenge;
    }
    return this.challengeKindForState(record.session.state);
  }

  private async restorePendingAuthIfNeeded(
    record: SteamArkAccountRecord,
    service: ISteamAuthService,
    credentials: SteamCredentialSet
  ): Promise<void> {
    const pending = record.pendingAuth;
    if (pending === null) {
      SteamArkLog.warn(TAG, 'pending authentication restore requested but no snapshot exists; account=' +
        SteamArkLog.accountId(record.profile.accountId));
      throw new SteamAuthError(
        'No pending Steam authentication session to restore',
        SteamAuthErrorKind.AUTHENTICATION,
        'pending_auth_restore'
      );
    }
    SteamArkLog.debug(TAG, 'pending authentication restore started; account=' +
      SteamArkLog.accountId(record.profile.accountId) + ', challenge=' + String(pending.challenge));
    const current = service.getPendingAuthSnapshot(record.profile.accountId);
    if (current !== null) {
      SteamArkLog.debug(TAG, 'pending authentication restore skipped; service already has snapshot; account=' +
        SteamArkLog.accountId(record.profile.accountId));
      return;
    }
    if (service.restorePendingAuthSnapshot(pending, credentials)) {
      SteamArkLog.info(TAG, 'pending authentication restored; account=' +
        SteamArkLog.accountId(record.profile.accountId));
      return;
    }
    record.pendingAuth = null;
      record.session = new SteamSessionSnapshot(
      record.profile.accountId,
      SteamSessionState.EXPIRED,
      record.profile.steamId64,
      record.session.server,
      record.session.connectedAtEpochSeconds,
      record.session.expiresAtEpochSeconds,
      record.session.lastErrorCode,
      record.session.lastErrorMessage,
      record.session.lastErrorType,
      record.session.lastErrorStage,
      record.session.lastErrorHttpStatusCode,
      record.session.lastErrorMessageType,
      record.session.lastErrorHeaderKind,
      record.session.lastErrorFrameBytes,
      record.session.lastErrorHeaderBytes,
      record.session.lastErrorBodyBytes,
      record.session.lastErrorServerMessage
    );
    try {
      await this.persistState();
    } catch {
      SteamArkLog.warn(TAG, 'expired Steam authentication state persistence failed');
    }
    this.notifyListeners();
    SteamArkLog.warn(TAG, 'pending authentication expired and was cleared; account=' +
      SteamArkLog.accountId(record.profile.accountId));
    throw new SteamAuthError(
      'Steam authentication challenge expired; sign in again',
      SteamAuthErrorKind.AUTHENTICATION,
      'pending_auth_restore'
    );
  }

  private copySession(source: SteamSessionSnapshot): SteamSessionSnapshot {
    return new SteamSessionSnapshot(
      source.accountId,
      source.state,
      source.steamId64,
      source.server,
      source.connectedAtEpochSeconds,
      source.expiresAtEpochSeconds,
      source.lastErrorCode,
      source.lastErrorMessage,
      source.lastErrorType,
      source.lastErrorStage,
      source.lastErrorHttpStatusCode,
      source.lastErrorMessageType,
      source.lastErrorHeaderKind,
      source.lastErrorFrameBytes,
      source.lastErrorHeaderBytes,
      source.lastErrorBodyBytes,
      source.lastErrorServerMessage
    );
  }

  private copyPendingAuth(source: SteamAuthPendingSnapshot | null): SteamAuthPendingSnapshot | null {
    if (source === null) {
      return null;
    }
    return new SteamAuthPendingSnapshot(
      source.accountId,
      source.clientId,
      source.requestId,
      source.steamId64,
      source.challenge,
      source.intervalSeconds,
      source.createdAtEpochSeconds,
      source.expiresAtEpochSeconds,
      source.flow,
      source.challengeUrl
    );
  }

  private toSnapshot(record: SteamArkAccountRecord): SteamArkAccountSnapshot {
    const profile = new SteamAccountProfile(
      record.profile.accountId,
      record.profile.displayName,
      record.profile.steamId64,
      record.profile.enabled,
      new SteamProxySettings(
        record.profile.proxy.kind,
        record.profile.proxy.host,
        record.profile.proxy.port,
        record.profile.proxy.username
      ),
      record.profile.avatarUrl,
      record.profile.profileBackgroundImageUrl,
      record.profile.profileBackgroundMovieUrl,
      record.profile.profileBackgroundTiled,
      record.profile.avatarFrameUrl,
      record.profile.summary,
      record.profile.level,
      record.profile.countryCode,
      record.profile.walletBalance,
      record.profile.walletCurrency,
      record.profile.miniProfileBackgroundImageUrl,
      record.profile.miniProfileBackgroundMovieUrl
    );
    const session = this.isAccountBeingRestored(record.profile.accountId) &&
      record.session.state !== SteamSessionState.LOGGED_ON &&
      record.pendingAuth === null && !this.isAuthChallengeState(record.session.state)
      ? this.copySessionWithState(record.session, SteamSessionState.RECONNECTING)
      : this.copySession(record.session);
    return new SteamArkAccountSnapshot(
      profile,
      this.copyBotConfig(record.config, record.config.accountId),
      session,
      new SteamArkMigrationReport(
        record.migrationReport.sourceName,
        record.migrationReport.recognizedFields,
        record.migrationReport.unknownFields,
        record.migrationReport.warnings,
        record.migrationReport.importedAtEpochSeconds
      ),
      record.hasCredentialMaterial,
      this.copyPendingAuth(record.pendingAuth)
    );
  }

  private copySessionWithState(source: SteamSessionSnapshot, state: SteamSessionState): SteamSessionSnapshot {
    return new SteamSessionSnapshot(
      source.accountId,
      state,
      source.steamId64,
      source.server,
      source.connectedAtEpochSeconds,
      source.expiresAtEpochSeconds,
      source.lastErrorCode,
      source.lastErrorMessage,
      source.lastErrorType,
      source.lastErrorStage,
      source.lastErrorHttpStatusCode,
      source.lastErrorMessageType,
      source.lastErrorHeaderKind,
      source.lastErrorFrameBytes,
      source.lastErrorHeaderBytes,
      source.lastErrorBodyBytes,
      source.lastErrorServerMessage
    );
  }

  private toMigrationReport(sourceName: string, report: SteamImportReport): SteamArkMigrationReport {
    return new SteamArkMigrationReport(
      sourceName,
      report.recognizedFields,
      report.unknownFields,
      report.warnings,
      this.nowEpochSeconds()
    );
  }

  private ensureSelectedAccount(preferredAccountId: string): void {
    const previousAccountId: string = this.selectedAccountId;
    if (preferredAccountId.length > 0 && this.records.has(preferredAccountId)) {
      this.selectedAccountId = preferredAccountId;
      this.logSelectedAccountChange(previousAccountId);
      return;
    }
    if (this.selectedAccountId.length > 0 && this.records.has(this.selectedAccountId)) {
      return;
    }
    this.selectedAccountId = '';
    this.records.forEach((_record: SteamArkAccountRecord, accountId: string): void => {
      if (this.selectedAccountId.length <= 0) {
        this.selectedAccountId = accountId;
      }
    });
    this.logSelectedAccountChange(previousAccountId);
  }

  private logSelectedAccountChange(previousAccountId: string): void {
    if (previousAccountId === this.selectedAccountId) {
      return;
    }
    SteamArkLog.state(TAG, SteamArkLog.accountId(previousAccountId),
      SteamArkLog.accountId(this.selectedAccountId), 'selected account changed');
  }

  private accountCredentialKinds(): Array<NGFCredentialKind> {
    return [
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
  }

  private async captureAccountCredentialSnapshot(accountId: string): Promise<SteamArkCredentialSnapshot> {
    const entries: Array<SteamArkCredentialSnapshotEntry> = [];
    const kinds = this.accountCredentialKinds();
    for (let index = 0; index < kinds.length; index++) {
      const value = await this.credentialStore.get(accountId, kinds[index]);
      entries.push(new SteamArkCredentialSnapshotEntry(kinds[index], value));
    }
    return new SteamArkCredentialSnapshot(entries);
  }

  private async restoreAccountCredentialSnapshot(
    accountId: string,
    snapshot: SteamArkCredentialSnapshot
  ): Promise<void> {
    let firstFailure: Error | null = null;
    for (let index = 0; index < snapshot.entries.length; index++) {
      const entry = snapshot.entries[index];
      try {
        await this.replaceCredential(accountId, entry.kind, entry.present ? entry.value : '');
      } catch (error) {
        if (firstFailure === null) {
          firstFailure = error instanceof Error ? error : new Error('Steam account credential rollback failed');
        }
        SteamArkLog.warn(TAG, 'one account credential rollback failed; account=' +
          SteamArkLog.accountId(accountId) + ', kind=' + String(entry.kind));
      }
    }
    if (firstFailure !== null) {
      throw firstFailure;
    }
  }

  private async storeCredentials(
    accountId: string,
    credentials: SteamCredentialSet,
    rollbackSnapshot: SteamArkCredentialSnapshot | null = null
  ): Promise<void> {
    SteamArkLog.debug(TAG, 'secure account credential write started; account=' +
      SteamArkLog.accountId(accountId) + ', fieldsPresent=' + this.credentialFieldCount(credentials).toString());
    const snapshot = rollbackSnapshot === null
      ? await this.captureAccountCredentialSnapshot(accountId)
      : rollbackSnapshot;
    try {
      await this.storeCredential(accountId, NGFCredentialKind.ACCOUNT_NAME, credentials.accountName);
      await this.storeCredential(accountId, NGFCredentialKind.PASSWORD, credentials.password);
      await this.storeCredential(accountId, NGFCredentialKind.REFRESH_TOKEN, credentials.refreshToken);
      await this.storeCredential(accountId, NGFCredentialKind.LOGIN_KEY, credentials.loginKey);
      await this.storeCredential(accountId, NGFCredentialKind.SHARED_SECRET, credentials.sharedSecret);
      await this.storeCredential(accountId, NGFCredentialKind.IDENTITY_SECRET, credentials.identitySecret);
      await this.storeCredential(accountId, NGFCredentialKind.DEVICE_ID, credentials.deviceId);
      await this.storeCredential(accountId, NGFCredentialKind.GUARD_DATA, credentials.guardData);
      await this.storeCredential(accountId, NGFCredentialKind.ACCESS_TOKEN, credentials.accessToken);
      await this.storeCredential(accountId, NGFCredentialKind.OAUTH_TOKEN, credentials.oauthToken);
      SteamArkLog.debug(TAG, 'secure account credential write completed; account=' +
        SteamArkLog.accountId(accountId));
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('secure credential write failed');
      try {
        await this.restoreAccountCredentialSnapshot(accountId, snapshot);
      } catch (rollbackError) {
        SteamArkLog.error(TAG, 'secure account credential write rollback failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(rollbackError));
      }
      throw normalized;
    }
  }

  private async replaceImportedCredentials(
    accountId: string,
    credentials: SteamCredentialSet,
    rollbackSnapshot: SteamArkCredentialSnapshot | null = null
  ): Promise<void> {
    SteamArkLog.debug(TAG, 'secure imported credential replacement started; account=' +
      SteamArkLog.accountId(accountId) + ', fieldsPresent=' + this.credentialFieldCount(credentials).toString());
    const snapshot = rollbackSnapshot === null
      ? await this.captureAccountCredentialSnapshot(accountId)
      : rollbackSnapshot;
    try {
      await this.replaceCredential(accountId, NGFCredentialKind.ACCOUNT_NAME, credentials.accountName);
      await this.replaceCredential(accountId, NGFCredentialKind.PASSWORD, credentials.password);
      await this.replaceCredential(accountId, NGFCredentialKind.REFRESH_TOKEN, credentials.refreshToken);
      await this.replaceCredential(accountId, NGFCredentialKind.LOGIN_KEY, credentials.loginKey);
      await this.replaceCredential(accountId, NGFCredentialKind.SHARED_SECRET, credentials.sharedSecret);
      await this.replaceCredential(accountId, NGFCredentialKind.IDENTITY_SECRET, credentials.identitySecret);
      await this.replaceCredential(accountId, NGFCredentialKind.DEVICE_ID, credentials.deviceId);
      await this.replaceCredential(accountId, NGFCredentialKind.GUARD_DATA, credentials.guardData);
      await this.replaceCredential(accountId, NGFCredentialKind.ACCESS_TOKEN, credentials.accessToken);
      await this.replaceCredential(accountId, NGFCredentialKind.OAUTH_TOKEN, credentials.oauthToken);
      await this.replaceCredential(accountId, NGFCredentialKind.COOKIE_JAR, '');
      await this.replaceCredential(accountId, NGFCredentialKind.CSRF_TOKEN, '');
      SteamArkLog.debug(TAG, 'secure imported credential replacement completed; account=' +
        SteamArkLog.accountId(accountId));
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('secure imported credential replacement failed');
      try {
        await this.restoreAccountCredentialSnapshot(accountId, snapshot);
      } catch (rollbackError) {
        SteamArkLog.error(TAG, 'secure imported credential rollback failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(rollbackError));
      }
      throw normalized;
    }
  }

  private credentialFieldCount(credentials: SteamCredentialSet): number {
    let count: number = 0;
    if (credentials.accountName.length > 0) {
      count++;
    }
    if (credentials.password.length > 0) {
      count++;
    }
    if (credentials.refreshToken.length > 0) {
      count++;
    }
    if (credentials.loginKey.length > 0) {
      count++;
    }
    if (credentials.sharedSecret.length > 0) {
      count++;
    }
    if (credentials.identitySecret.length > 0) {
      count++;
    }
    if (credentials.deviceId.length > 0) {
      count++;
    }
    if (credentials.guardData.length > 0) {
      count++;
    }
    if (credentials.accessToken.length > 0) {
      count++;
    }
    if (credentials.oauthToken.length > 0) {
      count++;
    }
    return count;
  }

  private hasUsableAuthenticationCredentials(credentials: SteamCredentialSet): boolean {
    return credentials.accessToken.trim().length > 0 || credentials.refreshToken.trim().length > 0;
  }

  private shouldAcceptAdapterSession(
    record: SteamArkAccountRecord,
    candidate: SteamSessionSnapshot
  ): boolean {
    if (candidate.state === SteamSessionState.LOGGED_ON ||
      record.session.state !== SteamSessionState.LOGGED_ON) {
      return true;
    }
    SteamArkLog.debug(TAG, 'inventory adapter session downgrade ignored; account=' +
      SteamArkLog.accountId(record.profile.accountId) + ', candidate=' + String(candidate.state));
    return false;
  }

  private async captureGlobalCredentialSnapshot(): Promise<SteamArkNamedCredentialSnapshot> {
    const names: Array<string> = [GLOBAL_IPC_PASSWORD_NAME, GLOBAL_WEB_PROXY_PASSWORD_NAME];
    const entries: Array<SteamArkNamedCredentialSnapshotEntry> = [];
    for (let index = 0; index < names.length; index++) {
      const value = await this.credentialStore.getNamed(GLOBAL_CREDENTIAL_SCOPE, names[index]);
      entries.push(new SteamArkNamedCredentialSnapshotEntry(names[index], value));
    }
    return new SteamArkNamedCredentialSnapshot(entries);
  }

  private async restoreGlobalCredentialSnapshot(
    snapshot: SteamArkNamedCredentialSnapshot
  ): Promise<void> {
    let firstFailure: Error | null = null;
    for (let index = 0; index < snapshot.entries.length; index++) {
      const entry = snapshot.entries[index];
      try {
        await this.storeNamedCredential(entry.name, entry.present ? entry.value : '');
      } catch (error) {
        if (firstFailure === null) {
          firstFailure = error instanceof Error ? error : new Error('ASF global credential rollback failed');
        }
        SteamArkLog.warn(TAG, 'one ASF global credential rollback failed; name=' + entry.name);
      }
    }
    if (firstFailure !== null) {
      throw firstFailure;
    }
  }

  private async storeGlobalCredentials(
    secrets: SteamGlobalConfigSecrets,
    rollbackSnapshot: SteamArkNamedCredentialSnapshot | null = null
  ): Promise<void> {
    SteamArkLog.debug(TAG, 'secure global credential write started; fieldsPresent=' +
      String((secrets.ipcPassword.trim().length > 0 ? 1 : 0) +
        (secrets.webProxyPassword.trim().length > 0 ? 1 : 0)));
    const snapshot = rollbackSnapshot === null
      ? await this.captureGlobalCredentialSnapshot()
      : rollbackSnapshot;
    try {
      await this.storeNamedCredential(GLOBAL_IPC_PASSWORD_NAME, secrets.ipcPassword);
      await this.storeNamedCredential(GLOBAL_WEB_PROXY_PASSWORD_NAME, secrets.webProxyPassword);
      SteamArkLog.debug(TAG, 'secure global credential write completed');
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('secure global credential write failed');
      try {
        await this.restoreGlobalCredentialSnapshot(snapshot);
      } catch (rollbackError) {
        SteamArkLog.error(TAG, 'secure global credential write rollback failed; errorType=' +
          SteamArkLog.errorKind(rollbackError));
      }
      throw normalized;
    }
  }

  private async storeNamedCredential(name: string, value: string): Promise<void> {
    if (value.trim().length <= 0) {
      const existing = await this.credentialStore.getNamed(GLOBAL_CREDENTIAL_SCOPE, name);
      if (existing === null || existing.length <= 0) {
        SteamArkLog.debug(TAG, 'secure global credential removal skipped; name=' + name + ', present=false');
        return;
      }
      const removed = await this.credentialStore.removeNamed(GLOBAL_CREDENTIAL_SCOPE, name);
      if (!removed) {
        SteamArkLog.error(TAG, 'secure global credential removal failed; name=' + name);
        throw new Error('secure global credential cleanup rejected one field');
      }
      SteamArkLog.debug(TAG, 'secure global credential removed; name=' + name);
      return;
    }
    const saved = await this.credentialStore.setNamed(GLOBAL_CREDENTIAL_SCOPE, name, value);
    if (!saved) {
      SteamArkLog.error(TAG, 'secure global credential write failed; name=' + name);
      throw new Error('secure global credential store rejected one field');
    }
    SteamArkLog.debug(TAG, 'secure global credential write succeeded; name=' + name);
  }

  private async storeCredential(accountId: string, kind: NGFCredentialKind, value: string): Promise<void> {
    if (value.trim().length <= 0) {
      SteamArkLog.debug(TAG, 'secure account credential write skipped; account=' +
        SteamArkLog.accountId(accountId) + ', kind=' + String(kind) + ', empty=true');
      return;
    }
    const saved = await this.credentialStore.set(accountId, kind, value);
    if (!saved) {
      SteamArkLog.error(TAG, 'secure account credential write failed; account=' +
        SteamArkLog.accountId(accountId) + ', kind=' + String(kind));
      throw new Error('secure credential store rejected one field');
    }
    SteamArkLog.debug(TAG, 'secure account credential write succeeded; account=' +
      SteamArkLog.accountId(accountId) + ', kind=' + String(kind));
  }

  private async replaceCredential(accountId: string, kind: NGFCredentialKind, value: string): Promise<void> {
    if (value.length <= 0) {
      const existing = await this.credentialStore.get(accountId, kind);
      if (existing === null || existing.length <= 0) {
        SteamArkLog.debug(TAG, 'secure account credential removal skipped; account=' +
          SteamArkLog.accountId(accountId) + ', kind=' + String(kind) + ', present=false');
        return;
      }
      const removed = await this.credentialStore.remove(accountId, kind);
      if (!removed) {
        SteamArkLog.error(TAG, 'secure account credential removal failed; account=' +
          SteamArkLog.accountId(accountId) + ', kind=' + String(kind));
        throw new Error('secure credential cleanup rejected one field');
      }
      SteamArkLog.debug(TAG, 'secure account credential removed; account=' +
        SteamArkLog.accountId(accountId) + ', kind=' + String(kind));
      return;
    }
    const saved = await this.credentialStore.set(accountId, kind, value);
    if (!saved) {
      SteamArkLog.error(TAG, 'secure account credential replacement failed; account=' +
        SteamArkLog.accountId(accountId) + ', kind=' + String(kind));
      throw new Error('secure credential store rejected one field');
    }
    SteamArkLog.debug(TAG, 'secure account credential replaced; account=' +
      SteamArkLog.accountId(accountId) + ', kind=' + String(kind));
  }

  private async hasSecureCredentials(accountId: string): Promise<boolean> {
    const kinds: Array<NGFCredentialKind> = [
      NGFCredentialKind.ACCOUNT_NAME,
      NGFCredentialKind.PASSWORD,
      NGFCredentialKind.REFRESH_TOKEN,
      NGFCredentialKind.LOGIN_KEY,
      NGFCredentialKind.SHARED_SECRET,
      NGFCredentialKind.IDENTITY_SECRET,
      NGFCredentialKind.DEVICE_ID,
      NGFCredentialKind.GUARD_DATA,
      NGFCredentialKind.ACCESS_TOKEN,
      NGFCredentialKind.OAUTH_TOKEN,
      NGFCredentialKind.COOKIE_JAR
    ];
    for (let index = 0; index < kinds.length; index++) {
      const value = await this.credentialStore.get(accountId, kinds[index]);
      if (value !== null && value.length > 0) {
        SteamArkLog.debug(TAG, 'secure account credential presence detected; account=' +
          SteamArkLog.accountId(accountId) + ', kind=' + String(kinds[index]));
        return true;
      }
    }
    SteamArkLog.debug(TAG, 'secure account credential presence not detected; account=' +
      SteamArkLog.accountId(accountId));
    return false;
  }

  private async hasGlobalSecureCredentials(): Promise<boolean> {
    const ipcPassword = await this.credentialStore.getNamed(
      GLOBAL_CREDENTIAL_SCOPE,
      GLOBAL_IPC_PASSWORD_NAME
    );
    if (ipcPassword !== null && ipcPassword.length > 0) {
      SteamArkLog.debug(TAG, 'secure global credential presence detected; name=' + GLOBAL_IPC_PASSWORD_NAME);
      return true;
    }
    const webProxyPassword = await this.credentialStore.getNamed(
      GLOBAL_CREDENTIAL_SCOPE,
      GLOBAL_WEB_PROXY_PASSWORD_NAME
    );
    const hasWebProxyPassword: boolean = webProxyPassword !== null && webProxyPassword.length > 0;
    SteamArkLog.debug(TAG, 'secure global credential presence checked; name=' + GLOBAL_WEB_PROXY_PASSWORD_NAME +
      ', present=' + String(hasWebProxyPassword));
    return hasWebProxyPassword;
  }

  private async readCredential(accountId: string, kind: NGFCredentialKind): Promise<string> {
    const value = await this.credentialStore.get(accountId.trim(), kind);
    const normalized: string = value === null ? '' : value;
    SteamArkLog.debug(TAG, 'secure account credential read completed; account=' +
      SteamArkLog.accountId(accountId) + ', kind=' + String(kind) +
      ', present=' + String(normalized.length > 0));
    return normalized;
  }

  private async readProxyPassword(accountId: string): Promise<string> {
    return await this.readCredential(accountId, NGFCredentialKind.PROXY_PASSWORD);
  }

  private async findAccountIdByAccountName(accountName: string): Promise<string> {
    SteamArkLog.debug(TAG, 'account name lookup started; candidateLength=' + accountName.length.toString());
    const normalizedAccountName: string = accountName.trim().toLowerCase();
    if (normalizedAccountName.length <= 0) {
      return '';
    }
    const accountIds: Array<string> = [];
    this.records.forEach((_record: SteamArkAccountRecord, accountId: string): void => {
      accountIds.push(accountId);
    });
    for (let index = 0; index < accountIds.length; index++) {
      const candidate = await this.readCredential(accountIds[index], NGFCredentialKind.ACCOUNT_NAME);
      if (candidate.trim().toLowerCase() === normalizedAccountName ||
        accountIds[index].trim().toLowerCase() === normalizedAccountName) {
        SteamArkLog.debug(TAG, 'account name lookup matched; account=' +
          SteamArkLog.accountId(accountIds[index]));
        return accountIds[index];
      }
    }
    SteamArkLog.debug(TAG, 'account name lookup did not match; accountCount=' + accountIds.length.toString());
    return '';
  }

  private findAccountIdBySteamId64(steamId64: string, excludedAccountId: string = ''): string {
    const normalizedSteamId64: string = steamId64.trim();
    if (normalizedSteamId64.length <= 0 || normalizedSteamId64 === '0') {
      return '';
    }
    let matchedAccountId: string = '';
    this.records.forEach((record: SteamArkAccountRecord, accountId: string): void => {
      if (matchedAccountId.length <= 0 && accountId !== excludedAccountId &&
        record.profile.steamId64.trim() === normalizedSteamId64) {
        matchedAccountId = accountId;
      }
    });
    return matchedAccountId;
  }

  /** Resolves the durable account key before serializing a password login. */
  private async resolvePasswordSignInOperationKey(accountName: string): Promise<string> {
    const normalizedName = accountName.trim();
    if (this.records.has(normalizedName)) {
      return normalizedName;
    }
    const existingAccountId = await this.findAccountIdByAccountName(normalizedName);
    return existingAccountId.length > 0 ? existingAccountId : normalizedName;
  }

  private nextQrAccountId(): string {
    while (this.qrAccountSequence < Number.MAX_SAFE_INTEGER) {
      this.qrAccountSequence++;
      const candidate = 'qr-' + this.qrAccountSequence.toString();
      if (!this.records.has(candidate)) {
        return candidate;
      }
    }
    throw new Error('Steam QR account identifier space is exhausted');
  }

  /** Only one device-local QR challenge may remain active at a time. */
  private async cleanupTemporaryQrAccounts(): Promise<void> {
    const accountIds: Array<string> = [];
    this.records.forEach((record: SteamArkAccountRecord, accountId: string): void => {
      if (this.isTemporaryQrRecord(record)) {
        accountIds.push(accountId);
      }
    });

    for (let index = 0; index < accountIds.length; index++) {
      const accountId = accountIds[index];
      const pendingOperation = this.accountOperationTails.get(accountId);
      if (pendingOperation !== undefined) {
        await pendingOperation;
      }
      const record = this.records.get(accountId);
      if (record === undefined || !this.isTemporaryQrRecord(record)) {
        continue;
      }

      SteamArkLog.info(TAG, 'temporary QR account cleanup started; account=' +
        SteamArkLog.accountId(accountId) + ', pending=' + String(record.pendingAuth !== null));
      try {
        const service = this.authServices.get(accountId);
        if (service !== undefined) {
          await service.cancelPendingAuth(accountId);
        }
        await this.removeAccountInternal(accountId);
        SteamArkLog.info(TAG, 'temporary QR account cleanup completed; account=' +
          SteamArkLog.accountId(accountId));
      } catch (error) {
        const normalized = error instanceof Error
          ? error
          : new Error('Steam previous QR authentication cleanup failed');
        if (this.records.has(accountId)) {
          await this.recordAccountOperationFailure(record, normalized, 'qr_cleanup');
        }
        SteamArkLog.warn(TAG, 'temporary QR account cleanup failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(normalized));
        throw normalized;
      }
    }
  }

  private isTemporaryQrRecord(record: SteamArkAccountRecord): boolean {
    return record.profile.accountId.indexOf('qr-') === 0 &&
      record.profile.displayName === record.profile.accountId &&
      record.session.state !== SteamSessionState.LOGGED_ON;
  }

  private isSameProxySettings(left: SteamProxySettings, right: SteamProxySettings): boolean {
    return left.kind === right.kind && left.host === right.host && left.port === right.port &&
      left.username === right.username;
  }

  private async restoreProxyPasswordAfterFailedSave(accountId: string, previousPassword: string): Promise<void> {
    const maximumAttempts: number = 3;
    let lastFailure: Error | null = null;
    for (let attempt: number = 1; attempt <= maximumAttempts; attempt++) {
      try {
        await this.replaceCredential(accountId, NGFCredentialKind.PROXY_PASSWORD, previousPassword);
        const restoredPassword: string = await this.readProxyPassword(accountId);
        if (restoredPassword !== previousPassword) {
          throw new Error('Steam proxy credential rollback verification failed');
        }
        SteamArkLog.debug(TAG, 'proxy credential rollback verified; account=' +
          SteamArkLog.accountId(accountId) + ', attempt=' + attempt.toString());
        return;
      } catch (error) {
        lastFailure = error instanceof Error ? error : new Error('Steam proxy credential rollback failed');
        try {
          const observedPassword: string = await this.readProxyPassword(accountId);
          if (observedPassword === previousPassword) {
            SteamArkLog.debug(TAG, 'proxy credential rollback verified after a rejected write; account=' +
              SteamArkLog.accountId(accountId) + ', attempt=' + attempt.toString());
            return;
          }
        } catch (verificationError) {
          lastFailure = verificationError instanceof Error
            ? verificationError
            : new Error('Steam proxy credential rollback verification failed');
        }
        SteamArkLog.warn(TAG, 'proxy credential rollback attempt failed; account=' +
          SteamArkLog.accountId(accountId) + ', attempt=' + attempt.toString() +
          ', errorType=' + SteamArkLog.errorKind(lastFailure));
      }
    }
    if (lastFailure !== null) {
      throw lastFailure;
    }
    throw new Error('Steam proxy credential rollback failed');
  }

  private async persistProxyRollbackState(accountId: string): Promise<void> {
    const maximumAttempts: number = 3;
    let lastFailure: Error | null = null;
    for (let attempt: number = 1; attempt <= maximumAttempts; attempt++) {
      try {
        await this.persistState();
        SteamArkLog.debug(TAG, 'proxy rollback state persisted; account=' +
          SteamArkLog.accountId(accountId) + ', attempt=' + attempt.toString());
        return;
      } catch (error) {
        lastFailure = error instanceof Error ? error : new Error('Steam proxy rollback state persistence failed');
        SteamArkLog.warn(TAG, 'proxy rollback state persistence attempt failed; account=' +
          SteamArkLog.accountId(accountId) + ', attempt=' + attempt.toString() +
          ', errorType=' + SteamArkLog.errorKind(lastFailure));
      }
    }
    if (lastFailure !== null) {
      throw lastFailure;
    }
    throw new Error('Steam proxy rollback state persistence failed');
  }

  private validateProxy(proxy: SteamProxySettings): void {
    if (proxy.kind === SteamProxyKind.DIRECT || proxy.kind === SteamProxyKind.SYSTEM) {
      return;
    }
    if (proxy.host.trim().length <= 0) {
      throw new Error('proxy host is required');
    }
    if (!Number.isSafeInteger(proxy.port) || proxy.port < 1 || proxy.port > 65535) {
      throw new Error('proxy port is invalid');
    }
  }

  private readAsfAccountName(json: string): string {
    const root = SteamJsonParser.parse(json, steamArkCoreLogger);
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('ASF bot JSON must be an object');
    }
    return this.readString(root.getProperty('SteamLogin'), '').trim();
  }

  private readString(value: SteamJsonValue | null, defaultValue: string): string {
    if (value === null || value.kind === SteamJsonValueKind.NULL) {
      return defaultValue;
    }
    return value.kind === SteamJsonValueKind.STRING ? value.stringValue : defaultValue;
  }

  private readRequiredString(value: SteamJsonValue | null, field: string): string {
    const result = this.readString(value, '').trim();
    if (result.length <= 0) {
      throw new Error('persisted Steam field is missing: ' + field);
    }
    return result;
  }

  private readBoolean(value: SteamJsonValue | null, defaultValue: boolean): boolean {
    if (value === null || value.kind !== SteamJsonValueKind.BOOLEAN) {
      return defaultValue;
    }
    return value.booleanValue;
  }

  private readInteger(value: SteamJsonValue | null, defaultValue: number): number {
    if (value === null || value.kind !== SteamJsonValueKind.NUMBER) {
      return defaultValue;
    }
    const result = Number(value.numberValue);
    return Number.isSafeInteger(result) ? result : defaultValue;
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

  private readOrders(value: SteamJsonValue | null): Array<SteamFarmingOrder> {
    const result: Array<SteamFarmingOrder> = [];
    const values = this.readStringArray(value);
    for (let index = 0; index < values.length; index++) {
      const order = this.readOrder(values[index]);
      if (order !== null) {
        result.push(order);
      }
    }
    return result;
  }

  private readOrder(value: string): SteamFarmingOrder | null {
    switch (value) {
      case SteamFarmingOrder.UNORDERED:
        return SteamFarmingOrder.UNORDERED;
      case SteamFarmingOrder.APP_IDS_ASCENDING:
        return SteamFarmingOrder.APP_IDS_ASCENDING;
      case SteamFarmingOrder.APP_IDS_DESCENDING:
        return SteamFarmingOrder.APP_IDS_DESCENDING;
      case SteamFarmingOrder.CARD_DROPS_ASCENDING:
        return SteamFarmingOrder.CARD_DROPS_ASCENDING;
      case SteamFarmingOrder.CARD_DROPS_DESCENDING:
        return SteamFarmingOrder.CARD_DROPS_DESCENDING;
      case SteamFarmingOrder.HOURS_ASCENDING:
        return SteamFarmingOrder.HOURS_ASCENDING;
      case SteamFarmingOrder.HOURS_DESCENDING:
        return SteamFarmingOrder.HOURS_DESCENDING;
      case SteamFarmingOrder.NAMES_ASCENDING:
        return SteamFarmingOrder.NAMES_ASCENDING;
      case SteamFarmingOrder.NAMES_DESCENDING:
        return SteamFarmingOrder.NAMES_DESCENDING;
      case SteamFarmingOrder.RANDOM:
        return SteamFarmingOrder.RANDOM;
      case SteamFarmingOrder.BADGE_LEVELS_ASCENDING:
        return SteamFarmingOrder.BADGE_LEVELS_ASCENDING;
      case SteamFarmingOrder.BADGE_LEVELS_DESCENDING:
        return SteamFarmingOrder.BADGE_LEVELS_DESCENDING;
      case SteamFarmingOrder.MARKETABLE_ASCENDING:
        return SteamFarmingOrder.MARKETABLE_ASCENDING;
      case SteamFarmingOrder.MARKETABLE_DESCENDING:
        return SteamFarmingOrder.MARKETABLE_DESCENDING;
      default:
        return null;
    }
  }

  private readProxyKind(value: SteamJsonValue | null): SteamProxyKind {
    const raw = this.readString(value, '');
    if (raw === SteamProxyKind.DIRECT) {
      return SteamProxyKind.DIRECT;
    }
    if (raw === SteamProxyKind.HTTP) {
      return SteamProxyKind.HTTP;
    }
    if (raw === SteamProxyKind.SOCKS5) {
      return SteamProxyKind.SOCKS5;
    }
    return SteamProxyKind.SYSTEM;
  }

  private readSessionState(value: SteamJsonValue | null): SteamSessionState {
    const raw = this.readString(value, '');
    switch (raw) {
      case SteamSessionState.CONNECTING:
        return SteamSessionState.CONNECTING;
      case SteamSessionState.CONNECTED:
        return SteamSessionState.CONNECTED;
      case SteamSessionState.LOGGED_ON:
        return SteamSessionState.LOGGED_ON;
      case SteamSessionState.NEEDS_QR_SCAN:
        return SteamSessionState.NEEDS_QR_SCAN;
      case SteamSessionState.NEEDS_EMAIL_CODE:
        return SteamSessionState.NEEDS_EMAIL_CODE;
      case SteamSessionState.NEEDS_TWO_FACTOR:
        return SteamSessionState.NEEDS_TWO_FACTOR;
      case SteamSessionState.NEEDS_MOBILE_CONFIRMATION:
        return SteamSessionState.NEEDS_MOBILE_CONFIRMATION;
      case SteamSessionState.EXPIRED:
        return SteamSessionState.EXPIRED;
      case SteamSessionState.RECONNECTING:
        return SteamSessionState.RECONNECTING;
      case SteamSessionState.ERROR:
        return SteamSessionState.ERROR;
      case SteamSessionState.DISCONNECTED:
      default:
        return SteamSessionState.DISCONNECTED;
    }
  }

  private readAuthChallenge(value: SteamJsonValue | null): SteamAuthChallengeKind | null {
    const raw = this.readString(value, '');
    switch (raw) {
      case SteamAuthChallengeKind.NONE:
        return SteamAuthChallengeKind.NONE;
      case SteamAuthChallengeKind.QR_SCAN:
        return SteamAuthChallengeKind.QR_SCAN;
      case SteamAuthChallengeKind.EMAIL_CODE:
        return SteamAuthChallengeKind.EMAIL_CODE;
      case SteamAuthChallengeKind.TWO_FACTOR:
        return SteamAuthChallengeKind.TWO_FACTOR;
      case SteamAuthChallengeKind.MOBILE_CONFIRMATION:
        return SteamAuthChallengeKind.MOBILE_CONFIRMATION;
      default:
        return null;
    }
  }

  private readAuthFlow(value: SteamJsonValue | null): SteamAuthFlowKind | null {
    const raw = this.readString(value, '');
    if (raw.length <= 0) {
      return SteamAuthFlowKind.PASSWORD;
    }
    switch (raw) {
      case SteamAuthFlowKind.PASSWORD:
        return SteamAuthFlowKind.PASSWORD;
      case SteamAuthFlowKind.QR:
        return SteamAuthFlowKind.QR;
      default:
        return null;
    }
  }

  private notifyListeners(): void {
    const snapshot = this.getSnapshot();
    const selected = this.records.get(snapshot.selectedAccountId);
    const shouldShowSelectedBackground: boolean = selected !== undefined &&
      selected.session.state === SteamSessionState.LOGGED_ON;
    AppStorage.setOrCreate<string>(
      STEAM_ARK_PROFILE_BACKGROUND_STORAGE_KEY,
      shouldShowSelectedBackground && selected !== undefined
        ? selected.profile.profileBackgroundImageUrl
        : ''
    );
    AppStorage.setOrCreate<boolean>(
      STEAM_ARK_PROFILE_BACKGROUND_TILED_STORAGE_KEY,
      shouldShowSelectedBackground && selected !== undefined
        ? selected.profile.profileBackgroundTiled
        : false
    );
    SteamArkLog.debug(TAG, 'state notification dispatch started; accounts=' + snapshot.accounts.length.toString() +
      ', selected=' + SteamArkLog.accountId(snapshot.selectedAccountId) +
      ', listeners=' + this.listeners.size.toString());
    this.publishEvent(snapshot);
    const currentListeners: Array<SteamArkStateListener> = [];
    this.listeners.forEach((listener: SteamArkStateListener): void => {
      currentListeners.push(listener);
    });
    for (let index = 0; index < currentListeners.length; index++) {
      try {
        currentListeners[index](snapshot);
      } catch (error) {
        SteamArkLog.warn(TAG, 'Steam state listener failed; errorType=' + SteamArkLog.errorKind(error));
      }
    }
    SteamArkLog.debug(TAG, 'state notification dispatch completed; accounts=' + snapshot.accounts.length.toString());
  }

  private publishEvent(snapshot: SteamArkStateSnapshot): void {
    const envelope = new SteamArkStateEventEnvelope();
    envelope.accountCount = snapshot.accounts.length;
    envelope.selectedAccountId = snapshot.selectedAccountId;
    envelope.initialized = snapshot.initialized;
    envelope.updatedAtEpochSeconds = snapshot.updatedAtEpochSeconds;
    const payload = new NGFEventPayload(
      'steam_ark_state_changed',
      JSON.stringify(envelope),
      Date.now()
    );
    ngfStarterKernel.eventBus.publish(STATE_EVENT_NAME, payload);
    SteamArkLog.debug(TAG, 'state event published; accounts=' + snapshot.accounts.length.toString() +
      ', selected=' + SteamArkLog.accountId(snapshot.selectedAccountId));
  }

  private nowEpochSeconds(): number {
    return Math.floor(Date.now() / 1000);
  }
}

export const steamArkStateService: SteamArkStateService = new SteamArkStateService();
