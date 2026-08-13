import { ngfContentCacheFacade } from 'ngf_framework';
import { SteamJsonParser, SteamJsonValue, SteamJsonValueKind } from 'steam_core';
import { SteamArkLog } from './SteamArkLogger';
import { steamArkCoreLogger } from './SteamArkCoreLogger';
import { SteamArkMessageCategory } from './SteamArkMessageContracts';
import { SteamArkMessageItem, SteamArkMessageSyncResult } from './SteamArkMessageContracts';

const TAG: string = 'SteamArkMessageCacheStore';
const CACHE_NAMESPACE: string = 'steam.messages.v2';
const LEGACY_CACHE_PREFIX: string = 'steam-ark-messages:';
const DEFAULT_CACHE_GENERATION: number = 1;
const DEFAULT_MESSAGE_CACHE_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
const MAX_NOTIFICATION_LEDGER_SIZE: number = 500;

/** Serialized form intentionally remains compatible with the existing message page cache reader. */
class SteamArkPersistedMessageItem {
  readonly id: string;
  readonly category: string;
  readonly title: string;
  readonly body: string;
  readonly url: string;
  readonly source: string;
  readonly imageUrl: string;
  readonly createdAtEpochSeconds: number;
  readonly unread: boolean;
  readonly remoteId: string;
  readonly notificationType: number;
  readonly tradeOfferId: string;
  readonly tradeOfferSent: boolean;

  constructor(item: SteamArkMessageItem) {
    this.id = item.id;
    this.category = String(item.category);
    this.title = item.title;
    this.body = item.body;
    this.url = item.url;
    this.source = item.source;
    this.imageUrl = item.imageUrl;
    this.createdAtEpochSeconds = item.createdAtEpochSeconds;
    this.unread = item.unread;
    this.remoteId = item.remoteId;
    this.notificationType = item.notificationType;
    this.tradeOfferId = item.tradeOfferId;
    this.tradeOfferSent = item.tradeOfferSent;
  }
}

class SteamArkPersistedMessageDocument {
  readonly accountId: string;
  readonly syncedAtEpochSeconds: number;
  readonly items: Array<SteamArkPersistedMessageItem>;

  constructor(accountId: string, result: SteamArkMessageSyncResult) {
    this.accountId = accountId;
    this.syncedAtEpochSeconds = result.syncedAtEpochSeconds;
    this.items = [];
    for (let index: number = 0; index < result.items.length; index++) {
      this.items.push(new SteamArkPersistedMessageItem(result.items[index]));
    }
  }
}

/** Immutable cache read result that keeps a page write bound to the generation it read. */
export class SteamArkMessageCacheSnapshot {
  readonly accountId: string;
  readonly generation: number;
  readonly serialized: string;

  constructor(accountId: string, generation: number, serialized: string) {
    this.accountId = accountId;
    this.generation = generation;
    this.serialized = serialized;
  }
}

/** Typed message cache content shared by pages that need a subset of notifications. */
export class SteamArkMessageCacheReadResult {
  readonly accountId: string;
  readonly generation: number;
  readonly syncedAtEpochSeconds: number;
  readonly items: Array<SteamArkMessageItem>;
  readonly valid: boolean;

  constructor(
    accountId: string,
    generation: number,
    syncedAtEpochSeconds: number = 0,
    items: Array<SteamArkMessageItem> = [],
    valid: boolean = false
  ) {
    this.accountId = accountId;
    this.generation = generation;
    this.syncedAtEpochSeconds = syncedAtEpochSeconds;
    this.items = items.slice();
    this.valid = valid;
  }
}

/**
 * Owns message-center cache names and account-scoped invalidation. Generations prevent a refresh
 * that started before account deletion from writing its result after the account has been removed.
 */
export class SteamArkMessageCacheStore {
  private static readonly accountGenerations: Map<string, number> = new Map<string, number>();

  static read(accountId: string): SteamArkMessageCacheSnapshot {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0) {
      return new SteamArkMessageCacheSnapshot('', 0, '');
    }
    const generation: number = SteamArkMessageCacheStore.captureGeneration(normalizedAccountId);
    const serialized: string = ngfContentCacheFacade.get(
      SteamArkMessageCacheStore.cacheKey(normalizedAccountId, generation)
    );
    if (serialized.length > 0) {
      return new SteamArkMessageCacheSnapshot(normalizedAccountId, generation, serialized);
    }
    // Preserve pre-v2 messages until the next successful write migrates them into the isolated key.
    return new SteamArkMessageCacheSnapshot(
      normalizedAccountId,
      generation,
      ngfContentCacheFacade.get(SteamArkMessageCacheStore.legacyCacheKey(normalizedAccountId))
    );
  }

  /** Reads and validates the account-scoped message document without exposing JSON parsing to pages. */
  static readMessages(accountId: string): SteamArkMessageCacheReadResult {
    const snapshot: SteamArkMessageCacheSnapshot = SteamArkMessageCacheStore.read(accountId);
    if (snapshot.accountId.length <= 0 || snapshot.serialized.trim().length <= 0) {
      return new SteamArkMessageCacheReadResult(snapshot.accountId, snapshot.generation);
    }
    try {
      const root: SteamJsonValue = SteamJsonParser.parse(snapshot.serialized, steamArkCoreLogger);
      if (root.kind !== SteamJsonValueKind.OBJECT) {
        throw new Error('message cache root is not an object');
      }
      const cachedAccountId: string = SteamArkMessageCacheStore.readString(root, 'accountId');
      const syncedAtEpochSeconds: number = SteamArkMessageCacheStore.readNumber(
        root, 'syncedAtEpochSeconds'
      );
      const itemValue: SteamJsonValue | null = root.getProperty('items');
      if (cachedAccountId !== snapshot.accountId || !Number.isSafeInteger(syncedAtEpochSeconds) ||
        syncedAtEpochSeconds <= 0 || itemValue === null || itemValue.kind !== SteamJsonValueKind.ARRAY) {
        throw new Error('message cache metadata is invalid');
      }
      const items: Array<SteamArkMessageItem> = [];
      for (let index: number = 0; index < itemValue.items.length; index++) {
        const item: SteamArkMessageItem | null = SteamArkMessageCacheStore.readMessageItem(itemValue.items[index]);
        if (item !== null) {
          items.push(item);
        }
      }
      return new SteamArkMessageCacheReadResult(
        snapshot.accountId,
        snapshot.generation,
        syncedAtEpochSeconds,
        items,
        true
      );
    } catch (error) {
      SteamArkMessageCacheStore.remove(snapshot.accountId, snapshot.generation);
      SteamArkLog.warn(TAG, 'invalid typed message cache removed; account=' +
        SteamArkLog.accountId(snapshot.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      return new SteamArkMessageCacheReadResult(snapshot.accountId, snapshot.generation);
    }
  }

  static captureGeneration(accountId: string): number {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0) {
      return 0;
    }
    return SteamArkMessageCacheStore.accountGeneration(normalizedAccountId);
  }

  static write(accountId: string, generation: number, serialized: string, ttlMs: number): boolean {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0 || generation < DEFAULT_CACHE_GENERATION || serialized.length <= 0) {
      return false;
    }
    if (!SteamArkMessageCacheStore.isGenerationCurrent(normalizedAccountId, generation)) {
      return false;
    }
    const cacheKey: string = SteamArkMessageCacheStore.cacheKey(normalizedAccountId, generation);
    ngfContentCacheFacade.put(cacheKey, serialized, ttlMs);
    if (!SteamArkMessageCacheStore.isGenerationCurrent(normalizedAccountId, generation)) {
      ngfContentCacheFacade.remove(cacheKey);
      return false;
    }
    ngfContentCacheFacade.remove(SteamArkMessageCacheStore.legacyCacheKey(normalizedAccountId));
    return true;
  }

  /**
   * Persists a successful remote synchronization so coordinator-triggered refreshes update the
   * same account-scoped cache consumed by the message page. Cache failures are deliberately
   * contained here: callers can keep the successful remote result even when local persistence is
   * unavailable.
   */
  static writeSyncResult(
    accountId: string,
    result: SteamArkMessageSyncResult,
    ttlMs: number = DEFAULT_MESSAGE_CACHE_TTL_MS
  ): boolean {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0 || !Number.isSafeInteger(result.syncedAtEpochSeconds) ||
      result.syncedAtEpochSeconds <= 0 || !Number.isSafeInteger(ttlMs) || ttlMs < 0) {
      return false;
    }
    const generation: number = SteamArkMessageCacheStore.captureGeneration(normalizedAccountId);
    try {
      const document: SteamArkPersistedMessageDocument = new SteamArkPersistedMessageDocument(
        normalizedAccountId,
        result
      );
      const saved: boolean = SteamArkMessageCacheStore.write(
        normalizedAccountId,
        generation,
        JSON.stringify(document),
        ttlMs
      );
      if (!saved) {
        return false;
      }
      const remoteSyncSaved: boolean = SteamArkMessageCacheStore.writeRemoteSyncAtEpochSeconds(
        normalizedAccountId,
        generation,
        result.syncedAtEpochSeconds
      );
      if (!remoteSyncSaved) {
        SteamArkLog.debug(TAG, 'message remote sync timestamp write ignored; account=' +
          SteamArkLog.accountId(normalizedAccountId));
      }
      return remoteSyncSaved;
    } catch (error) {
      SteamArkLog.warn(TAG, 'message sync result cache write failed; account=' +
        SteamArkLog.accountId(normalizedAccountId) + ', errorType=' + SteamArkLog.errorKind(error));
      return false;
    }
  }

  /** Records the last completed remote refresh independently from local read-state edits. */
  static writeRemoteSyncAtEpochSeconds(accountId: string, generation: number, syncedAtEpochSeconds: number): boolean {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0 || generation < DEFAULT_CACHE_GENERATION ||
      !Number.isSafeInteger(syncedAtEpochSeconds) || syncedAtEpochSeconds <= 0 ||
      !SteamArkMessageCacheStore.isGenerationCurrent(normalizedAccountId, generation)) {
      return false;
    }
    ngfContentCacheFacade.put(
      SteamArkMessageCacheStore.remoteSyncCacheKey(normalizedAccountId, generation),
      syncedAtEpochSeconds.toString(),
      0
    );
    return SteamArkMessageCacheStore.isGenerationCurrent(normalizedAccountId, generation);
  }

  static readRemoteSyncAtEpochSeconds(accountId: string): number {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0) {
      return 0;
    }
    const generation: number = SteamArkMessageCacheStore.captureGeneration(normalizedAccountId);
    const value: number = Number(ngfContentCacheFacade.get(
      SteamArkMessageCacheStore.remoteSyncCacheKey(normalizedAccountId, generation)
    ).trim());
    return Number.isSafeInteger(value) && value > 0 ? value : 0;
  }

  /** Reads message IDs that have already been delivered to the system notification channel. */
  static readNotificationMessageIds(accountId: string): Array<string> {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0) {
      return [];
    }
    const generation: number = SteamArkMessageCacheStore.captureGeneration(normalizedAccountId);
    const serialized: string = ngfContentCacheFacade.get(
      SteamArkMessageCacheStore.notificationLedgerKey(normalizedAccountId, generation)
    ).trim();
    if (serialized.length <= 0) {
      return [];
    }
    try {
      const root: SteamJsonValue = SteamJsonParser.parse(serialized, steamArkCoreLogger);
      if (root.kind !== SteamJsonValueKind.ARRAY) {
        throw new Error('message notification ledger is not an array');
      }
      const ids: Array<string> = [];
      for (let index: number = 0; index < root.items.length; index++) {
        const value: SteamJsonValue = root.items[index];
        if (value.kind !== SteamJsonValueKind.STRING) {
          continue;
        }
        const id: string = value.stringValue.trim();
        if (id.length > 0 && !ids.includes(id)) {
          ids.push(id);
        }
      }
      return ids;
    } catch (error) {
      ngfContentCacheFacade.remove(
        SteamArkMessageCacheStore.notificationLedgerKey(normalizedAccountId, generation)
      );
      SteamArkLog.warn(TAG, 'invalid message notification ledger removed; account=' +
        SteamArkLog.accountId(normalizedAccountId) + ', errorType=' + SteamArkLog.errorKind(error));
      return [];
    }
  }

  static hasNotificationMessageLedger(accountId: string): boolean {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0) {
      return false;
    }
    const generation: number = SteamArkMessageCacheStore.captureGeneration(normalizedAccountId);
    return ngfContentCacheFacade.get(
      SteamArkMessageCacheStore.notificationLedgerKey(normalizedAccountId, generation)
    ).trim().length > 0;
  }

  /** True only after a complete message snapshot has established the notification baseline. */
  static hasNotificationMessageBaseline(accountId: string): boolean {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0) {
      return false;
    }
    const generation: number = SteamArkMessageCacheStore.captureGeneration(normalizedAccountId);
    const key: string = SteamArkMessageCacheStore.notificationBaselineKey(normalizedAccountId, generation);
    const value: string = ngfContentCacheFacade.get(key).trim();
    if (value === '1') {
      return true;
    }
    if (value.length > 0) {
      ngfContentCacheFacade.remove(key);
    }
    return false;
  }

  /** Persists the bounded notification ledger only for the current account generation. */
  static writeNotificationMessageIds(
    accountId: string,
    generation: number,
    messageIds: Array<string>
  ): boolean {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0 || generation < DEFAULT_CACHE_GENERATION ||
      !SteamArkMessageCacheStore.isGenerationCurrent(normalizedAccountId, generation)) {
      return false;
    }
    const values: Array<string> = [];
    for (let index: number = 0; index < messageIds.length; index++) {
      const id: string = messageIds[index].trim();
      if (id.length > 0 && !values.includes(id)) {
        values.push(id);
      }
    }
    const bounded: Array<string> = values.length > MAX_NOTIFICATION_LEDGER_SIZE
      ? values.slice(values.length - MAX_NOTIFICATION_LEDGER_SIZE)
      : values;
    const key: string = SteamArkMessageCacheStore.notificationLedgerKey(normalizedAccountId, generation);
    ngfContentCacheFacade.put(key, JSON.stringify(bounded), 0);
    if (!SteamArkMessageCacheStore.isGenerationCurrent(normalizedAccountId, generation)) {
      ngfContentCacheFacade.remove(key);
      return false;
    }
    return true;
  }

  /** Writes the baseline marker only after its corresponding ID ledger has been persisted. */
  static writeNotificationMessageBaseline(accountId: string, generation: number): boolean {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0 || generation < DEFAULT_CACHE_GENERATION ||
      !SteamArkMessageCacheStore.isGenerationCurrent(normalizedAccountId, generation)) {
      return false;
    }
    const key: string = SteamArkMessageCacheStore.notificationBaselineKey(normalizedAccountId, generation);
    ngfContentCacheFacade.put(key, '1', 0);
    if (!SteamArkMessageCacheStore.isGenerationCurrent(normalizedAccountId, generation)) {
      ngfContentCacheFacade.remove(key);
      return false;
    }
    return true;
  }

  static remove(accountId: string, generation: number): void {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0 || generation < DEFAULT_CACHE_GENERATION ||
      !SteamArkMessageCacheStore.isGenerationCurrent(normalizedAccountId, generation)) {
      return;
    }
    ngfContentCacheFacade.remove(SteamArkMessageCacheStore.cacheKey(normalizedAccountId, generation));
    ngfContentCacheFacade.remove(SteamArkMessageCacheStore.remoteSyncCacheKey(normalizedAccountId, generation));
    ngfContentCacheFacade.remove(
      SteamArkMessageCacheStore.notificationLedgerKey(normalizedAccountId, generation)
    );
    ngfContentCacheFacade.remove(
      SteamArkMessageCacheStore.notificationBaselineKey(normalizedAccountId, generation)
    );
    ngfContentCacheFacade.remove(SteamArkMessageCacheStore.legacyCacheKey(normalizedAccountId));
  }

  /** Invalidates both v2 and legacy message caches only after account deletion has committed. */
  static clearCachedAccount(accountId: string): void {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0) {
      return;
    }
    const previousGeneration: number = SteamArkMessageCacheStore.captureGeneration(normalizedAccountId);
    const nextGeneration: number = previousGeneration + 1;
    SteamArkMessageCacheStore.accountGenerations.set(normalizedAccountId, nextGeneration);
    ngfContentCacheFacade.put(
      SteamArkMessageCacheStore.generationCacheKey(normalizedAccountId),
      nextGeneration.toString(),
      0
    );
    ngfContentCacheFacade.remove(SteamArkMessageCacheStore.cacheKey(normalizedAccountId, previousGeneration));
    ngfContentCacheFacade.remove(SteamArkMessageCacheStore.remoteSyncCacheKey(
      normalizedAccountId, previousGeneration
    ));
    ngfContentCacheFacade.remove(
      SteamArkMessageCacheStore.notificationLedgerKey(normalizedAccountId, previousGeneration)
    );
    ngfContentCacheFacade.remove(
      SteamArkMessageCacheStore.notificationBaselineKey(normalizedAccountId, previousGeneration)
    );
    ngfContentCacheFacade.remove(SteamArkMessageCacheStore.legacyCacheKey(normalizedAccountId));
    SteamArkLog.debug(TAG, 'message cache invalidated after account deletion; account=' +
      SteamArkLog.accountId(normalizedAccountId));
  }

  private static readMessageItem(value: SteamJsonValue): SteamArkMessageItem | null {
    if (value.kind !== SteamJsonValueKind.OBJECT) {
      return null;
    }
    const id: string = SteamArkMessageCacheStore.readString(value, 'id');
    const category: SteamArkMessageCategory = SteamArkMessageCacheStore.readCategory(value);
    const createdAtEpochSeconds: number = SteamArkMessageCacheStore.readNumber(
      value, 'createdAtEpochSeconds'
    );
    if (id.length <= 0 || !Number.isSafeInteger(createdAtEpochSeconds) || createdAtEpochSeconds <= 0) {
      return null;
    }
    return new SteamArkMessageItem(
      id,
      category,
      SteamArkMessageCacheStore.readString(value, 'title'),
      SteamArkMessageCacheStore.readString(value, 'body'),
      SteamArkMessageCacheStore.readString(value, 'url'),
      SteamArkMessageCacheStore.readString(value, 'source'),
      createdAtEpochSeconds,
      SteamArkMessageCacheStore.readBoolean(value, 'unread', true),
      SteamArkMessageCacheStore.readString(value, 'imageUrl'),
      SteamArkMessageCacheStore.readString(value, 'remoteId'),
      SteamArkMessageCacheStore.readNumber(value, 'notificationType'),
      SteamArkMessageCacheStore.readString(value, 'tradeOfferId'),
      SteamArkMessageCacheStore.readBoolean(value, 'tradeOfferSent', false)
    );
  }

  private static readCategory(value: SteamJsonValue): SteamArkMessageCategory {
    const raw: string = SteamArkMessageCacheStore.readString(value, 'category');
    if (raw === String(SteamArkMessageCategory.PROMOTION)) {
      return SteamArkMessageCategory.PROMOTION;
    }
    if (raw === String(SteamArkMessageCategory.FRIEND)) {
      return SteamArkMessageCategory.FRIEND;
    }
    if (raw === String(SteamArkMessageCategory.TRADE)) {
      return SteamArkMessageCategory.TRADE;
    }
    if (raw === String(SteamArkMessageCategory.INVENTORY)) {
      return SteamArkMessageCategory.INVENTORY;
    }
    return SteamArkMessageCategory.SYSTEM;
  }

  private static readString(root: SteamJsonValue, key: string): string {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      return '';
    }
    const value: SteamJsonValue | null = root.getProperty(key);
    if (value === null || value.kind !== SteamJsonValueKind.STRING) {
      return '';
    }
    return value.stringValue;
  }

  private static readNumber(root: SteamJsonValue, key: string): number {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      return 0;
    }
    const value: SteamJsonValue | null = root.getProperty(key);
    if (value === null) {
      return 0;
    }
    if (value.kind === SteamJsonValueKind.NUMBER) {
      return Number(value.numberValue);
    }
    if (value.kind === SteamJsonValueKind.STRING) {
      return Number(value.stringValue);
    }
    return 0;
  }

  private static readBoolean(root: SteamJsonValue, key: string, fallback: boolean): boolean {
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      return fallback;
    }
    const value: SteamJsonValue | null = root.getProperty(key);
    if (value === null || value.kind !== SteamJsonValueKind.BOOLEAN) {
      return fallback;
    }
    return value.booleanValue;
  }

  private static accountGeneration(accountId: string): number {
    const inMemory: number | undefined = SteamArkMessageCacheStore.accountGenerations.get(accountId);
    if (inMemory !== undefined) {
      return inMemory;
    }
    const serialized: string = ngfContentCacheFacade.get(
      SteamArkMessageCacheStore.generationCacheKey(accountId)
    ).trim();
    const parsed: number = Number(serialized);
    const generation: number = Number.isFinite(parsed) && parsed >= DEFAULT_CACHE_GENERATION &&
      Math.floor(parsed) === parsed ? parsed : DEFAULT_CACHE_GENERATION;
    SteamArkMessageCacheStore.accountGenerations.set(accountId, generation);
    if (serialized.length <= 0 || generation !== parsed) {
      ngfContentCacheFacade.put(
        SteamArkMessageCacheStore.generationCacheKey(accountId),
        generation.toString(),
        0
      );
    }
    return generation;
  }

  private static isGenerationCurrent(accountId: string, generation: number): boolean {
    return SteamArkMessageCacheStore.captureGeneration(accountId) === generation;
  }

  private static generationCacheKey(accountId: string): string {
    return CACHE_NAMESPACE + '.generation.' + encodeURIComponent(accountId);
  }

  private static cacheKey(accountId: string, generation: number): string {
    return CACHE_NAMESPACE + '.entry.' + encodeURIComponent(accountId) + '.g' + generation.toString();
  }

  private static remoteSyncCacheKey(accountId: string, generation: number): string {
    return CACHE_NAMESPACE + '.remote_sync_at.' + encodeURIComponent(accountId) + '.g' + generation.toString();
  }

  private static notificationLedgerKey(accountId: string, generation: number): string {
    return CACHE_NAMESPACE + '.notification_ledger.' + encodeURIComponent(accountId) + '.g' + generation.toString();
  }

  private static notificationBaselineKey(accountId: string, generation: number): string {
    return CACHE_NAMESPACE + '.notification_baseline.' + encodeURIComponent(accountId) + '.g' + generation.toString();
  }

  private static legacyCacheKey(accountId: string): string {
    return LEGACY_CACHE_PREFIX + accountId;
  }
}
