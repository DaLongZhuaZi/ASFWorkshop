import {
  ISettingsStore,
  ngfSettingsStoreFacade
} from 'ngf_framework';
import {
  SteamJsonParser,
  SteamJsonValue,
  SteamJsonValueKind
} from 'steam_core';
import { SteamArkLog } from './SteamArkLogger';
import { steamArkCoreLogger } from './SteamArkCoreLogger';

const TAG: string = 'SteamArkWidgetStateStore';
const SETTINGS_KEY: string = 'steam_ark_widget_state_v1';

const DEFAULT_SESSION_STATE: string = 'disconnected';
const DEFAULT_FARMING_STATE: string = 'disabled';

function normalizeSessionState(value: string): string {
  switch (value) {
    case 'logged_on':
    case 'connected':
    case 'connecting':
    case 'challenge':
    case 'error':
    case 'disconnected':
      return value;
    default:
      return DEFAULT_SESSION_STATE;
  }
}

function normalizeFarmingState(value: string): string {
  switch (value) {
    case 'running':
    case 'paused':
    case 'idle':
    case 'error':
    case 'disabled':
      return value;
    default:
      return DEFAULT_FARMING_STATE;
  }
}

function normalizeAccountCount(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) {
    return 0;
  }
  return value;
}

function readString(value: SteamJsonValue | null, fallback: string): string {
  if (value === null || value.kind !== SteamJsonValueKind.STRING) {
    return fallback;
  }
  return value.stringValue;
}

function readInteger(value: SteamJsonValue | null, fallback: number): number {
  if (value === null || value.kind !== SteamJsonValueKind.NUMBER) {
    return fallback;
  }
  const parsed: number = Number(value.numberValue);
  return Number.isSafeInteger(parsed) ? parsed : fallback;
}

export class SteamArkWidgetSnapshot {
  readonly sessionState: string;
  readonly farmingState: string;
  readonly accountCount: number;
  readonly updatedAtEpochSeconds: number;

  constructor(
    sessionState: string = DEFAULT_SESSION_STATE,
    farmingState: string = DEFAULT_FARMING_STATE,
    accountCount: number = 0,
    updatedAtEpochSeconds: number = 0
  ) {
    this.sessionState = normalizeSessionState(sessionState);
    this.farmingState = normalizeFarmingState(farmingState);
    this.accountCount = normalizeAccountCount(accountCount);
    this.updatedAtEpochSeconds = Number.isSafeInteger(updatedAtEpochSeconds) && updatedAtEpochSeconds > 0
      ? updatedAtEpochSeconds
      : 0;
  }
}

class SteamArkPersistedWidgetSnapshot {
  sessionState: string = DEFAULT_SESSION_STATE;
  farmingState: string = DEFAULT_FARMING_STATE;
  accountCount: number = 0;
  updatedAtEpochSeconds: number = 0;

  constructor(snapshot: SteamArkWidgetSnapshot) {
    this.sessionState = snapshot.sessionState;
    this.farmingState = snapshot.farmingState;
    this.accountCount = snapshot.accountCount;
    this.updatedAtEpochSeconds = snapshot.updatedAtEpochSeconds;
  }
}

/** Strongly typed payload passed to formBindingData without exposing secrets. */
export class SteamArkWidgetFormPayload {
  steamSessionState: string;
  steamFarmingState: string;
  steamAccountCount: string;
  lastUpdate: string;

  constructor(snapshot: SteamArkWidgetSnapshot) {
    this.steamSessionState = snapshot.sessionState;
    this.steamFarmingState = snapshot.farmingState;
    this.steamAccountCount = snapshot.accountCount.toString();
    this.lastUpdate = snapshot.updatedAtEpochSeconds > 0
      ? new Date(snapshot.updatedAtEpochSeconds * 1000).toLocaleTimeString()
      : '--:--:--';
  }
}

/**
 * Stores only the small, non-sensitive projection needed by the system form.
 * The form extension runs in a separate lifecycle, so it must read this snapshot
 * from Preferences instead of relying on an in-memory Steam service singleton.
 */
export class SteamArkWidgetStateStore {
  private readonly settingsStore: ISettingsStore;
  private snapshot: SteamArkWidgetSnapshot = new SteamArkWidgetSnapshot();
  private initialized: boolean = false;
  private initializationPromise: Promise<boolean> | null = null;
  private updateTail: Promise<void> = Promise.resolve();

  constructor(settingsStore: ISettingsStore = ngfSettingsStoreFacade) {
    this.settingsStore = settingsStore;
  }

  getSnapshot(): SteamArkWidgetSnapshot {
    return new SteamArkWidgetSnapshot(
      this.snapshot.sessionState,
      this.snapshot.farmingState,
      this.snapshot.accountCount,
      this.snapshot.updatedAtEpochSeconds
    );
  }

  async initialize(): Promise<boolean> {
    if (this.initialized) {
      return true;
    }
    if (this.initializationPromise !== null) {
      return await this.initializationPromise;
    }
    const task: Promise<boolean> = this.loadSnapshot();
    this.initializationPromise = task;
    try {
      return await task;
    } finally {
      this.initializationPromise = null;
    }
  }

  async updateAccountState(sessionState: string, accountCount: number): Promise<boolean> {
    const previous: Promise<void> = this.updateTail;
    let saved: boolean = false;
    const current: Promise<void> = previous.then(async (): Promise<void> => {
      if (!(await this.ensureInitialized())) {
        return;
      }
      this.snapshot = new SteamArkWidgetSnapshot(
        sessionState,
        this.snapshot.farmingState,
        accountCount,
        Math.floor(Date.now() / 1000)
      );
      saved = await this.persistSnapshot();
    });
    this.updateTail = current.then((): void => {
      return;
    }, (): void => {
      return;
    });
    await current;
    return saved;
  }

  async updateFarmingState(farmingState: string): Promise<boolean> {
    const previous: Promise<void> = this.updateTail;
    let saved: boolean = false;
    const current: Promise<void> = previous.then(async (): Promise<void> => {
      if (!(await this.ensureInitialized())) {
        return;
      }
      this.snapshot = new SteamArkWidgetSnapshot(
        this.snapshot.sessionState,
        farmingState,
        this.snapshot.accountCount,
        Math.floor(Date.now() / 1000)
      );
      saved = await this.persistSnapshot();
    });
    this.updateTail = current.then((): void => {
      return;
    }, (): void => {
      return;
    });
    await current;
    return saved;
  }

  private async ensureInitialized(): Promise<boolean> {
    if (this.initialized) {
      return true;
    }
    return await this.initialize();
  }

  private async loadSnapshot(): Promise<boolean> {
    const ready: boolean = await this.settingsStore.waitUntilReady();
    if (!ready) {
      SteamArkLog.warn(TAG, 'widget state load skipped; settings store is not ready');
      return false;
    }
    const serialized: string = this.settingsStore.getString(SETTINGS_KEY, '');
    if (serialized.trim().length > 0) {
      try {
        this.snapshot = this.parseSnapshot(serialized);
      } catch (error) {
        this.snapshot = new SteamArkWidgetSnapshot();
        const cleared: boolean = await this.settingsStore.setStringAsync(SETTINGS_KEY, '');
        if (!cleared) {
          SteamArkLog.warn(TAG, 'invalid widget state cleanup was rejected');
        }
        SteamArkLog.warn(TAG, 'widget state ignored; parseErrorType=' +
          (error instanceof Error ? error.name : 'NonError'));
      }
    }
    this.initialized = true;
    SteamArkLog.debug(TAG, 'widget state loaded; accounts=' + this.snapshot.accountCount.toString() +
      ', session=' + this.snapshot.sessionState + ', farming=' + this.snapshot.farmingState);
    return true;
  }

  private parseSnapshot(serialized: string): SteamArkWidgetSnapshot {
    const root: SteamJsonValue = SteamJsonParser.parse(serialized, steamArkCoreLogger);
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('Widget state must be an object');
    }
    const snapshot: SteamArkWidgetSnapshot = new SteamArkWidgetSnapshot(
      readString(root.getProperty('sessionState'), DEFAULT_SESSION_STATE),
      readString(root.getProperty('farmingState'), DEFAULT_FARMING_STATE),
      readInteger(root.getProperty('accountCount'), 0),
      readInteger(root.getProperty('updatedAtEpochSeconds'), 0)
    );
    if (snapshot.updatedAtEpochSeconds <= 0) {
      throw new Error('Widget state timestamp is invalid');
    }
    return snapshot;
  }

  private async persistSnapshot(): Promise<boolean> {
    const serialized: string = JSON.stringify(new SteamArkPersistedWidgetSnapshot(this.snapshot));
    try {
      const saved: boolean = await this.settingsStore.setStringAsync(SETTINGS_KEY, serialized);
      if (!saved) {
        SteamArkLog.warn(TAG, 'widget state persistence rejected');
      }
      return saved;
    } catch (error) {
      SteamArkLog.warn(TAG, 'widget state persistence failed; errorType=' +
        (error instanceof Error ? error.name : 'NonError'));
      return false;
    }
  }
}

export const steamArkWidgetStateStore: SteamArkWidgetStateStore = new SteamArkWidgetStateStore();
