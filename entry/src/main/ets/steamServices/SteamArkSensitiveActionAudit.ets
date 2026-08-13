import {
  ISettingsStore,
  NGFEventPayload,
  ngfSettingsStoreFacade,
  ngfStarterKernel
} from 'ngf_framework';
import {
  SteamJsonParser,
  SteamJsonValue,
  SteamJsonValueKind
} from 'steam_core';
import { SteamArkLog } from './SteamArkLogger';
import { steamArkCoreLogger } from './SteamArkCoreLogger';

const TAG: string = 'SteamArkSensitiveActionAudit';
const SETTINGS_KEY: string = 'steam_ark_sensitive_action_audit_v1';
const STORAGE_VERSION: number = 1;
const MAX_AUDIT_ASSET_COUNT: number = 500;

/** Operations that require a fresh device identity check immediately before execution. */
export enum SteamArkSensitiveAction {
  PRIVACY_VERIFICATION = 'privacy_verification',
  INVENTORY_WRITE = 'inventory_write',
  BADGE_CRAFT = 'badge_craft',
  TRADE_PREVIEW = 'trade_preview',
  TRADE_ACCEPT = 'trade_accept',
  TRADE_DECLINE = 'trade_decline',
  TRADE_CANCEL = 'trade_cancel',
  MOBILE_CONFIRM = 'mobile_confirm',
  REDEEM = 'redeem',
  ASSET_TRANSFER = 'asset_transfer'
}

export enum SteamArkSensitiveActionOutcome {
  GRANTED = 'granted',
  PERMISSION_DENIED = 'permission_denied',
  UNSUPPORTED = 'unsupported',
  AUTHENTICATION_FAILED = 'authentication_failed',
  BUSY = 'busy',
  INVALID_REQUEST = 'invalid_request',
  ERROR = 'error',
  AUDIT_FAILED = 'audit_failed'
}

/** Only non-secret account identifiers may cross the sensitive-action boundary. */
export class SteamArkSensitiveActionContext {
  readonly accountId: string;
  readonly steamId64: string;

  constructor(accountId: string = '', steamId64: string = '') {
    this.accountId = SteamArkSensitiveActionAuditEntry.normalizeIdentifier(accountId, 128);
    this.steamId64 = SteamArkSensitiveActionAuditEntry.normalizeSteamId64(steamId64);
  }
}

/** Durable audit DTO. It deliberately has no prompt text, asset list, credential, or token field. */
export class SteamArkSensitiveActionAuditEntry {
  readonly eventId: string;
  readonly action: SteamArkSensitiveAction;
  readonly outcome: SteamArkSensitiveActionOutcome;
  readonly accountId: string;
  readonly steamId64: string;
  readonly createdAtEpochSeconds: number;
  /** Only a reference to the in-memory review snapshot is durable. */
  readonly confirmationId: string;
  readonly assetCount: number;

  constructor(
    eventId: string,
    action: SteamArkSensitiveAction,
    outcome: SteamArkSensitiveActionOutcome,
    accountId: string = '',
    steamId64: string = '',
    createdAtEpochSeconds: number = 0,
    confirmationId: string = '',
    assetCount: number = 0
  ) {
    this.eventId = SteamArkSensitiveActionAuditEntry.normalizeIdentifier(eventId, 96);
    this.action = action;
    this.outcome = outcome;
    this.accountId = SteamArkSensitiveActionAuditEntry.normalizeIdentifier(accountId, 128);
    this.steamId64 = SteamArkSensitiveActionAuditEntry.normalizeSteamId64(steamId64);
    this.createdAtEpochSeconds = Number.isSafeInteger(createdAtEpochSeconds) && createdAtEpochSeconds > 0
      ? createdAtEpochSeconds
      : 0;
    this.confirmationId = SteamArkSensitiveActionAuditEntry.normalizeIdentifier(confirmationId, 96);
    this.assetCount = Number.isSafeInteger(assetCount) && assetCount >= 0 && assetCount <= MAX_AUDIT_ASSET_COUNT
      ? assetCount
      : -1;
  }

  isValid(): boolean {
    return this.eventId.length > 0 &&
      this.isKnownAction() &&
      this.isKnownOutcome() &&
      this.createdAtEpochSeconds > 0 &&
      this.assetCount >= 0 &&
      (this.confirmationId.length > 0 ? this.assetCount > 0 : this.assetCount === 0);
  }

  static normalizeIdentifier(value: string, maxLength: number): string {
    const trimmed = value.trim();
    if (trimmed.length <= 0 || trimmed.length > maxLength) {
      return trimmed.length <= maxLength ? trimmed : '';
    }
    for (let index = 0; index < trimmed.length; index++) {
      if (trimmed.charCodeAt(index) < 32) {
        return '';
      }
    }
    return trimmed;
  }

  static normalizeSteamId64(value: string): string {
    const trimmed = value.trim();
    if (trimmed.length <= 0 || trimmed.length > 20) {
      return '';
    }
    for (let index = 0; index < trimmed.length; index++) {
      const code = trimmed.charCodeAt(index);
      if (code < 48 || code > 57) {
        return '';
      }
    }
    return trimmed;
  }

  private isKnownAction(): boolean {
    switch (this.action) {
      case SteamArkSensitiveAction.PRIVACY_VERIFICATION:
      case SteamArkSensitiveAction.INVENTORY_WRITE:
      case SteamArkSensitiveAction.BADGE_CRAFT:
      case SteamArkSensitiveAction.TRADE_PREVIEW:
      case SteamArkSensitiveAction.TRADE_ACCEPT:
      case SteamArkSensitiveAction.TRADE_DECLINE:
      case SteamArkSensitiveAction.TRADE_CANCEL:
      case SteamArkSensitiveAction.MOBILE_CONFIRM:
      case SteamArkSensitiveAction.REDEEM:
      case SteamArkSensitiveAction.ASSET_TRANSFER:
        return true;
      default:
        return false;
    }
  }

  private isKnownOutcome(): boolean {
    switch (this.outcome) {
      case SteamArkSensitiveActionOutcome.GRANTED:
      case SteamArkSensitiveActionOutcome.PERMISSION_DENIED:
      case SteamArkSensitiveActionOutcome.UNSUPPORTED:
      case SteamArkSensitiveActionOutcome.AUTHENTICATION_FAILED:
      case SteamArkSensitiveActionOutcome.BUSY:
      case SteamArkSensitiveActionOutcome.INVALID_REQUEST:
      case SteamArkSensitiveActionOutcome.ERROR:
      case SteamArkSensitiveActionOutcome.AUDIT_FAILED:
        return true;
      default:
        return false;
    }
  }
}

export interface ISteamArkSensitiveActionAuditStore {
  append(entry: SteamArkSensitiveActionAuditEntry): Promise<boolean>;
  listRecent(limit: number): Promise<Array<SteamArkSensitiveActionAuditEntry>>;
  clear(): Promise<boolean>;
}

class SteamArkSensitiveActionAuditDocument {
  readonly version: number;
  readonly entries: Array<SteamArkSensitiveActionAuditEntry>;

  constructor(entries: Array<SteamArkSensitiveActionAuditEntry> = []) {
    this.version = STORAGE_VERSION;
    this.entries = entries.slice();
  }
}

/** Settings-backed, bounded audit store. Secrets never enter this store. */
export class SteamArkSensitiveActionAuditStore implements ISteamArkSensitiveActionAuditStore {
  static readonly MAX_ENTRIES: number = 100;
  private readonly settingsStore: ISettingsStore;
  private entries: Array<SteamArkSensitiveActionAuditEntry> = [];
  private initialized: boolean = false;
  private operation: Promise<boolean> = Promise.resolve(true);

  constructor(settingsStore: ISettingsStore = ngfSettingsStoreFacade) {
    this.settingsStore = settingsStore;
    SteamArkLog.debug(TAG, 'sensitive action audit store constructed');
  }

  append(entry: SteamArkSensitiveActionAuditEntry): Promise<boolean> {
    SteamArkLog.debug(TAG, 'audit append queued; action=' + String(entry.action) +
      ', outcome=' + String(entry.outcome) + ', assetCount=' + entry.assetCount.toString());
    const task: Promise<boolean> = this.operation
      .then((_previous: boolean): Promise<boolean> => this.appendInternal(entry))
      .catch((error: Error): boolean => {
        SteamArkLog.warn(TAG, 'audit append operation failed; errorType=' + SteamArkLog.errorKind(error));
        return false;
      });
    this.operation = task;
    return task;
  }

  async listRecent(limit: number): Promise<Array<SteamArkSensitiveActionAuditEntry>> {
    await this.operation;
    if (!await this.ensureLoaded()) {
      return [];
    }
    const safeLimit: number = this.normalizeLimit(limit);
    const result: Array<SteamArkSensitiveActionAuditEntry> = [];
    const startIndex: number = Math.max(0, this.entries.length - safeLimit);
    for (let index = this.entries.length - 1; index >= startIndex; index--) {
      result.push(this.entries[index]);
    }
    SteamArkLog.debug(TAG, 'audit recent list loaded; requested=' + limit.toString() +
      ', returned=' + result.length.toString());
    return result;
  }

  clear(): Promise<boolean> {
    SteamArkLog.info(TAG, 'audit clear requested; currentCount=' + this.entries.length.toString());
    const task: Promise<boolean> = this.operation
      .then((_previous: boolean): Promise<boolean> => this.clearInternal())
      .catch((error: Error): boolean => {
        SteamArkLog.warn(TAG, 'audit clear operation failed; errorType=' + SteamArkLog.errorKind(error));
        return false;
      });
    this.operation = task;
    return task;
  }

  private async appendInternal(entry: SteamArkSensitiveActionAuditEntry): Promise<boolean> {
    if (!await this.ensureLoaded()) {
      SteamArkLog.warn(TAG, 'audit append rejected; store unavailable');
      return false;
    }
    if (!entry.isValid()) {
      SteamArkLog.warn(TAG, 'audit append rejected; invalid entry; action=' + String(entry.action) +
        ', outcome=' + String(entry.outcome));
      return false;
    }
    const previous: Array<SteamArkSensitiveActionAuditEntry> = this.entries.slice();
    this.entries.push(entry);
    while (this.entries.length > SteamArkSensitiveActionAuditStore.MAX_ENTRIES) {
      this.entries.shift();
    }
    const saved: boolean = await this.persist();
    if (!saved) {
      this.entries = previous;
    }
    SteamArkLog.info(TAG, 'audit append completed; success=' + String(saved) +
      ', count=' + this.entries.length.toString() + ', account=' +
      SteamArkLog.accountId(entry.accountId));
    return saved;
  }

  private async clearInternal(): Promise<boolean> {
    if (!await this.ensureLoaded()) {
      SteamArkLog.warn(TAG, 'audit clear rejected; store unavailable');
      return false;
    }
    const previous: Array<SteamArkSensitiveActionAuditEntry> = this.entries.slice();
    this.entries = [];
    const saved: boolean = await this.persist();
    if (!saved) {
      this.entries = previous;
    }
    SteamArkLog.info(TAG, 'audit clear completed; success=' + String(saved) +
      ', count=' + this.entries.length.toString());
    return saved;
  }

  private async ensureLoaded(): Promise<boolean> {
    if (this.initialized) {
      return true;
    }
    try {
      if (!await this.settingsStore.waitUntilReady()) {
        return false;
      }
      const serialized: string = this.settingsStore.getString(SETTINGS_KEY, '');
      this.entries = this.readEntries(serialized);
      this.initialized = true;
      SteamArkLog.info(TAG, 'audit store initialized; count=' + this.entries.length.toString());
      return true;
    } catch (error) {
      SteamArkLog.warn(TAG, 'audit store initialization failed; errorType=' + SteamArkLog.errorKind(error));
      return false;
    }
  }

  private async persist(): Promise<boolean> {
    try {
      const document = new SteamArkSensitiveActionAuditDocument(this.entries);
      const saved = await this.settingsStore.setStringAsync(SETTINGS_KEY, JSON.stringify(document));
      SteamArkLog.debug(TAG, 'audit store persisted; success=' + String(saved) +
        ', count=' + this.entries.length.toString());
      return saved;
    } catch (error) {
      SteamArkLog.warn(TAG, 'audit store persistence failed; errorType=' + SteamArkLog.errorKind(error));
      return false;
    }
  }

  private readEntries(serialized: string): Array<SteamArkSensitiveActionAuditEntry> {
    if (serialized.trim().length <= 0) {
      return [];
    }
    try {
      const root: SteamJsonValue = SteamJsonParser.parse(serialized, steamArkCoreLogger);
      if (root.kind !== SteamJsonValueKind.OBJECT) {
        return [];
      }
      const version: number = this.readInteger(root.getProperty('version'), 0);
      if (version !== STORAGE_VERSION) {
        return [];
      }
      const value: SteamJsonValue | null = root.getProperty('entries');
      if (value === null || value.kind !== SteamJsonValueKind.ARRAY) {
        return [];
      }
      const result: Array<SteamArkSensitiveActionAuditEntry> = [];
      for (let index = 0; index < value.items.length; index++) {
        const entry: SteamArkSensitiveActionAuditEntry | null = this.readEntry(value.items[index]);
        if (entry !== null) {
          result.push(entry);
        }
      }
      if (result.length > SteamArkSensitiveActionAuditStore.MAX_ENTRIES) {
        return result.slice(result.length - SteamArkSensitiveActionAuditStore.MAX_ENTRIES);
      }
      return result;
    } catch (error) {
      SteamArkLog.warn(TAG, 'audit store snapshot invalid; corrupted snapshot ignored; errorType=' +
        SteamArkLog.errorKind(error));
      return [];
    }
  }

  private readEntry(value: SteamJsonValue): SteamArkSensitiveActionAuditEntry | null {
    if (value.kind !== SteamJsonValueKind.OBJECT) {
      return null;
    }
    const action: SteamArkSensitiveAction | null = this.readAction(value.getProperty('action'));
    const outcome: SteamArkSensitiveActionOutcome | null = this.readOutcome(value.getProperty('outcome'));
    if (action === null || outcome === null) {
      return null;
    }
    const entry = new SteamArkSensitiveActionAuditEntry(
      this.readString(value.getProperty('eventId'), ''),
      action,
      outcome,
      this.readString(value.getProperty('accountId'), ''),
      this.readString(value.getProperty('steamId64'), ''),
      this.readInteger(value.getProperty('createdAtEpochSeconds'), 0),
      this.readString(value.getProperty('confirmationId'), ''),
      this.readAuditAssetCount(value.getProperty('assetCount'))
    );
    return entry.isValid() ? entry : null;
  }

  private readAction(value: SteamJsonValue | null): SteamArkSensitiveAction | null {
    if (value === null || value.kind !== SteamJsonValueKind.STRING) {
      return null;
    }
    switch (value.stringValue) {
      case SteamArkSensitiveAction.PRIVACY_VERIFICATION:
        return SteamArkSensitiveAction.PRIVACY_VERIFICATION;
      case SteamArkSensitiveAction.INVENTORY_WRITE:
        return SteamArkSensitiveAction.INVENTORY_WRITE;
      case SteamArkSensitiveAction.BADGE_CRAFT:
        return SteamArkSensitiveAction.BADGE_CRAFT;
      case SteamArkSensitiveAction.TRADE_PREVIEW:
        return SteamArkSensitiveAction.TRADE_PREVIEW;
      case SteamArkSensitiveAction.TRADE_ACCEPT:
        return SteamArkSensitiveAction.TRADE_ACCEPT;
      case SteamArkSensitiveAction.TRADE_DECLINE:
        return SteamArkSensitiveAction.TRADE_DECLINE;
      case SteamArkSensitiveAction.TRADE_CANCEL:
        return SteamArkSensitiveAction.TRADE_CANCEL;
      case SteamArkSensitiveAction.MOBILE_CONFIRM:
        return SteamArkSensitiveAction.MOBILE_CONFIRM;
      case SteamArkSensitiveAction.REDEEM:
        return SteamArkSensitiveAction.REDEEM;
      case SteamArkSensitiveAction.ASSET_TRANSFER:
        return SteamArkSensitiveAction.ASSET_TRANSFER;
      default:
        return null;
    }
  }

  private readOutcome(value: SteamJsonValue | null): SteamArkSensitiveActionOutcome | null {
    if (value === null || value.kind !== SteamJsonValueKind.STRING) {
      return null;
    }
    switch (value.stringValue) {
      case SteamArkSensitiveActionOutcome.GRANTED:
        return SteamArkSensitiveActionOutcome.GRANTED;
      case SteamArkSensitiveActionOutcome.PERMISSION_DENIED:
        return SteamArkSensitiveActionOutcome.PERMISSION_DENIED;
      case SteamArkSensitiveActionOutcome.UNSUPPORTED:
        return SteamArkSensitiveActionOutcome.UNSUPPORTED;
      case SteamArkSensitiveActionOutcome.AUTHENTICATION_FAILED:
        return SteamArkSensitiveActionOutcome.AUTHENTICATION_FAILED;
      case SteamArkSensitiveActionOutcome.BUSY:
        return SteamArkSensitiveActionOutcome.BUSY;
      case SteamArkSensitiveActionOutcome.INVALID_REQUEST:
        return SteamArkSensitiveActionOutcome.INVALID_REQUEST;
      case SteamArkSensitiveActionOutcome.ERROR:
        return SteamArkSensitiveActionOutcome.ERROR;
      case SteamArkSensitiveActionOutcome.AUDIT_FAILED:
        return SteamArkSensitiveActionOutcome.AUDIT_FAILED;
      default:
        return null;
    }
  }

  private readString(value: SteamJsonValue | null, defaultValue: string): string {
    if (value === null || value.kind !== SteamJsonValueKind.STRING) {
      return defaultValue;
    }
    return value.stringValue;
  }

  private readInteger(value: SteamJsonValue | null, defaultValue: number): number {
    if (value === null || value.kind !== SteamJsonValueKind.NUMBER) {
      return defaultValue;
    }
    const parsed: number = Number(value.numberValue);
    return Number.isSafeInteger(parsed) ? parsed : defaultValue;
  }

  private readAuditAssetCount(value: SteamJsonValue | null): number {
    if (value === null) {
      return 0;
    }
    return this.readInteger(value, -1);
  }

  private normalizeLimit(limit: number): number {
    if (!Number.isSafeInteger(limit) || limit <= 0) {
      return 0;
    }
    return Math.min(limit, SteamArkSensitiveActionAuditStore.MAX_ENTRIES);
  }
}

export const STEAM_ARK_SENSITIVE_ACTION_AUDIT_EVENT: string =
  'steam_ark.sensitive_action_audit_recorded';

export interface ISteamArkSensitiveActionAuditEventPublisher {
  publish(entry: SteamArkSensitiveActionAuditEntry): void;
}

/** Publishes only the same non-secret DTO that has already passed audit validation. */
export class SteamArkSensitiveActionAuditEventPublisher implements ISteamArkSensitiveActionAuditEventPublisher {
  publish(entry: SteamArkSensitiveActionAuditEntry): void {
    SteamArkLog.debug(TAG, 'audit event publish started; action=' + String(entry.action) +
      ', outcome=' + String(entry.outcome) + ', account=' + SteamArkLog.accountId(entry.accountId));
    try {
      const payload = new NGFEventPayload(
        'steam_ark.sensitive_action_audit',
        JSON.stringify(entry),
        Date.now()
      );
      ngfStarterKernel.eventBus.publish(STEAM_ARK_SENSITIVE_ACTION_AUDIT_EVENT, payload);
      SteamArkLog.debug(TAG, 'audit event publish completed; action=' + String(entry.action));
    } catch (error) {
      SteamArkLog.warn(TAG, 'audit event publish failed; errorType=' + SteamArkLog.errorKind(error));
    }
  }
}

export const steamArkSensitiveActionAuditStore: ISteamArkSensitiveActionAuditStore =
  new SteamArkSensitiveActionAuditStore();

export const steamArkSensitiveActionAuditEventPublisher: ISteamArkSensitiveActionAuditEventPublisher =
  new SteamArkSensitiveActionAuditEventPublisher();
