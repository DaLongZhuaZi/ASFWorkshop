import { SteamSessionState } from 'steam_core';

/** Non-secret capabilities that pages may safely render for one account. */
export class SteamArkCapabilitySnapshot {
  readonly accountId: string;
  readonly sessionState: SteamSessionState;
  readonly authenticated: boolean;
  readonly webApiCredentialsAvailable: boolean;
  readonly sharedSecretAvailable: boolean;
  readonly socialConnected: boolean;
  readonly credentialsAvailable: boolean;

  constructor(
    accountId: string,
    sessionState: SteamSessionState,
    authenticated: boolean,
    webApiCredentialsAvailable: boolean,
    sharedSecretAvailable: boolean,
    socialConnected: boolean,
    credentialsAvailable: boolean
  ) {
    this.accountId = accountId;
    this.sessionState = sessionState;
    this.authenticated = authenticated;
    this.webApiCredentialsAvailable = webApiCredentialsAvailable;
    this.sharedSecretAvailable = sharedSecretAvailable;
    this.socialConnected = socialConnected;
    this.credentialsAvailable = credentialsAvailable;
  }
}

export enum SteamArkSyncStage {
  IDLE = 'idle',
  PROFILE = 'profile',
  INVENTORY = 'inventory',
  LIBRARY = 'library',
  FARMING = 'farming',
  SOCIAL = 'social',
  MESSAGES = 'messages',
  COMPLETE = 'complete',
  FAILED = 'failed'
}

export enum SteamArkSyncFailureKind {
  NONE = 'none',
  AUTHENTICATION = 'authentication',
  NETWORK = 'network',
  CONFIGURATION = 'configuration',
  DATA = 'data',
  CANCELLED = 'cancelled'
}

/** A single structured, redacted failure for UI and diagnostics. */
export class SteamArkSyncFailure {
  readonly kind: SteamArkSyncFailureKind;
  readonly stage: SteamArkSyncStage;
  readonly message: string;
  readonly occurredAtEpochSeconds: number;

  constructor(
    kind: SteamArkSyncFailureKind = SteamArkSyncFailureKind.NONE,
    stage: SteamArkSyncStage = SteamArkSyncStage.IDLE,
    message: string = '',
    occurredAtEpochSeconds: number = 0
  ) {
    this.kind = kind;
    this.stage = stage;
    this.message = message;
    this.occurredAtEpochSeconds = occurredAtEpochSeconds;
  }
}

/** Cache freshness is explicit so unknown data is never rendered as a zero. */
export class SteamArkCacheFreshnessSnapshot {
  readonly profileUpdatedAtEpochSeconds: number;
  readonly inventoryUpdatedAtEpochSeconds: number;
  readonly farmingUpdatedAtEpochSeconds: number;
  readonly socialUpdatedAtEpochSeconds: number;
  readonly messagesUpdatedAtEpochSeconds: number;
  readonly libraryUpdatedAtEpochSeconds: number;

  constructor(
    profileUpdatedAtEpochSeconds: number = 0,
    inventoryUpdatedAtEpochSeconds: number = 0,
    farmingUpdatedAtEpochSeconds: number = 0,
    socialUpdatedAtEpochSeconds: number = 0,
    messagesUpdatedAtEpochSeconds: number = 0,
    libraryUpdatedAtEpochSeconds: number = 0
  ) {
    this.profileUpdatedAtEpochSeconds = profileUpdatedAtEpochSeconds;
    this.inventoryUpdatedAtEpochSeconds = inventoryUpdatedAtEpochSeconds;
    this.farmingUpdatedAtEpochSeconds = farmingUpdatedAtEpochSeconds;
    this.socialUpdatedAtEpochSeconds = socialUpdatedAtEpochSeconds;
    this.messagesUpdatedAtEpochSeconds = messagesUpdatedAtEpochSeconds;
    this.libraryUpdatedAtEpochSeconds = libraryUpdatedAtEpochSeconds;
  }
}

export class SteamArkAccountSyncSnapshot {
  readonly accountId: string;
  readonly stage: SteamArkSyncStage;
  readonly running: boolean;
  readonly lastCompletedAtEpochSeconds: number;
  readonly capability: SteamArkCapabilitySnapshot;
  readonly freshness: SteamArkCacheFreshnessSnapshot;
  readonly failure: SteamArkSyncFailure;
  readonly stageFailures: Array<SteamArkSyncFailure>;

  constructor(
    accountId: string,
    stage: SteamArkSyncStage,
    running: boolean,
    lastCompletedAtEpochSeconds: number,
    capability: SteamArkCapabilitySnapshot,
    freshness: SteamArkCacheFreshnessSnapshot,
    failure: SteamArkSyncFailure = new SteamArkSyncFailure(),
    stageFailures: Array<SteamArkSyncFailure> = []
  ) {
    this.accountId = accountId;
    this.stage = stage;
    this.running = running;
    this.lastCompletedAtEpochSeconds = lastCompletedAtEpochSeconds;
    this.capability = capability;
    this.freshness = freshness;
    this.failure = failure;
    this.stageFailures = stageFailures.slice();
  }
}

export class SteamArkSyncSnapshot {
  readonly initialized: boolean;
  readonly updatedAtEpochSeconds: number;
  readonly accounts: Array<SteamArkAccountSyncSnapshot>;

  constructor(
    initialized: boolean = false,
    updatedAtEpochSeconds: number = 0,
    accounts: Array<SteamArkAccountSyncSnapshot> = []
  ) {
    this.initialized = initialized;
    this.updatedAtEpochSeconds = updatedAtEpochSeconds;
    this.accounts = accounts.slice();
  }
}

export type SteamArkSyncSnapshotListener = (snapshot: SteamArkSyncSnapshot) => void;
