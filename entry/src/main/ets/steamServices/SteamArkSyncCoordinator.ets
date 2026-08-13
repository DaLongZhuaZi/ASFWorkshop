import {
  SteamBadgeSyncReport,
  SteamInventoryPage,
  SteamInventoryQuery,
  SteamSessionState
} from 'steam_core';
import { SteamArkLog } from './SteamArkLogger';
import {
  SteamArkAccountSnapshot,
  SteamArkStateListener,
  SteamArkStateService,
  SteamArkStateSnapshot,
  steamArkStateService
} from './SteamArkStateService';
import {
  SteamArkFarmingService,
  steamArkFarmingService
} from './SteamArkFarmingService';
import {
  SteamArkSocialService,
  steamArkSocialService
} from './SteamArkSocialService';
import { SteamArkSocialConnectionState } from './SteamArkSocialContracts';
import { SteamArkMessageCacheStore } from './SteamArkMessageCacheStore';
import {
  ISteamArkMessageNotificationPublisher,
  SteamArkMessageItem,
  SteamArkMessageSyncResult
} from './SteamArkMessageContracts';
import {
  SteamArkAccountSyncSnapshot,
  SteamArkCacheFreshnessSnapshot,
  SteamArkCapabilitySnapshot,
  SteamArkSyncFailure,
  SteamArkSyncFailureKind,
  SteamArkSyncSnapshot,
  SteamArkSyncSnapshotListener,
  SteamArkSyncStage
} from './SteamArkSyncContracts';

const TAG: string = 'SteamArkSyncCoordinator';
const INVENTORY_FRESHNESS_SECONDS: number = 5 * 60;
const BADGE_FRESHNESS_SECONDS: number = 5 * 60;
const PROFILE_FRESHNESS_SECONDS: number = 15 * 60;
const SOCIAL_FRESHNESS_SECONDS: number = 5 * 60;
const MAX_FUTURE_SYNC_CLOCK_SKEW_SECONDS: number = 5 * 60;
const DEFAULT_INVENTORY_APP_ID: string = '753';
const DEFAULT_INVENTORY_CONTEXT_ID: string = '6';
const DEFAULT_INVENTORY_PAGE_SIZE: number = 100;
const MAX_INVENTORY_PAGES_PER_SILENT_SYNC: number = 100;

class SteamArkMessageNotificationLedger {
  initialized: boolean = false;
  baselineEstablished: boolean = false;
  generation: number = 0;
  readonly notifiedMessageIds: Set<string> = new Set<string>();
}

class SteamArkSyncRecord {
  stage: SteamArkSyncStage = SteamArkSyncStage.IDLE;
  running: boolean = false;
  lastCompletedAtEpochSeconds: number = 0;
  profileUpdatedAtEpochSeconds: number = 0;
  inventoryUpdatedAtEpochSeconds: number = 0;
  farmingUpdatedAtEpochSeconds: number = 0;
  socialUpdatedAtEpochSeconds: number = 0;
  messagesUpdatedAtEpochSeconds: number = 0;
  failure: SteamArkSyncFailure = new SteamArkSyncFailure();
  stageFailures: Array<SteamArkSyncFailure> = [];
}

class SteamArkSyncTask {
  readonly generation: number;
  readonly completion: Promise<void>;

  constructor(generation: number, completion: Promise<void>) {
    this.generation = generation;
    this.completion = completion;
  }
}

/**
 * Serializes passive account data refreshes. It intentionally never owns
 * credentials or changes a session state; authentication stays in state service.
 */
export class SteamArkSyncCoordinator {
  private readonly stateService: SteamArkStateService;
  private readonly farmingService: SteamArkFarmingService;
  private readonly socialService: SteamArkSocialService;
  private readonly records: Map<string, SteamArkSyncRecord> = new Map<string, SteamArkSyncRecord>();
  private readonly listeners: Map<string, SteamArkSyncSnapshotListener> = new Map<string, SteamArkSyncSnapshotListener>();
  private readonly tasks: Map<string, SteamArkSyncTask> = new Map<string, SteamArkSyncTask>();
  private readonly loggedOnAccountIds: Set<string> = new Set<string>();
  private readonly messageNotificationLedgers: Map<string, SteamArkMessageNotificationLedger> =
    new Map<string, SteamArkMessageNotificationLedger>();
  private messageNotificationPublisher: ISteamArkMessageNotificationPublisher | null = null;
  private initialized: boolean = false;
  private disposed: boolean = false;
  private generation: number = 0;
  private stopPromise: Promise<void> | null = null;
  private hasObservedStateSnapshot: boolean = false;
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    this.handleStateSnapshot(snapshot);
  };

  constructor(
    stateService: SteamArkStateService = steamArkStateService,
    farmingService: SteamArkFarmingService = steamArkFarmingService,
    socialService: SteamArkSocialService = steamArkSocialService
  ) {
    this.stateService = stateService;
    this.farmingService = farmingService;
    this.socialService = socialService;
  }

  setMessageNotificationPublisher(publisher: ISteamArkMessageNotificationPublisher | null): void {
    this.messageNotificationPublisher = publisher;
    SteamArkLog.info(TAG, 'message notification publisher configured; enabled=' + String(publisher !== null));
  }

  async start(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const stopping: Promise<void> | null = this.stopPromise;
    if (stopping !== null) {
      await stopping;
      if (this.disposed) {
        return;
      }
    }
    if (this.initialized) {
      void this.requestSilentSync('start_repeat').catch((error: Error): void => {
        SteamArkLog.warn(TAG, 'repeated background sync dispatch failed; errorType=' + SteamArkLog.errorKind(error));
      });
      return;
    }
    this.generation += 1;
    this.initialized = true;
    this.stateService.subscribe('SteamArkSyncCoordinator', this.stateListener);
    this.handleStateSnapshot(this.stateService.getSnapshot());
    void this.requestSilentSync('start').catch((error: Error): void => {
      SteamArkLog.warn(TAG, 'startup background sync dispatch failed; errorType=' + SteamArkLog.errorKind(error));
    });
  }

  async stop(): Promise<void> {
    const existingStop: Promise<void> | null = this.stopPromise;
    if (existingStop !== null) {
      await existingStop;
      return;
    }
    const stoppedGeneration: number = this.generation;
    this.generation += 1;
    this.initialized = false;
    this.stateService.unsubscribe('SteamArkSyncCoordinator');
    const stopPromise: Promise<void> = this.finishStop(stoppedGeneration);
    this.stopPromise = stopPromise;
    try {
      await stopPromise;
    } finally {
      if (this.stopPromise === stopPromise) {
        this.stopPromise = null;
      }
    }
  }

  private async finishStop(stoppedGeneration: number): Promise<void> {
    const pending: Array<Promise<void>> = [];
    this.tasks.forEach((task: SteamArkSyncTask): void => {
      if (task.generation === stoppedGeneration) {
        pending.push(task.completion);
      }
    });
    for (let index: number = 0; index < pending.length; index++) {
      try {
        await pending[index];
      } catch (_error) {
        // The task already recorded a redacted failure.
      }
    }
    if (this.generation !== stoppedGeneration + 1 || this.initialized) {
      SteamArkLog.debug(TAG, 'stale stop cleanup skipped; stoppedGeneration=' + stoppedGeneration.toString() +
        ', currentGeneration=' + this.generation.toString());
      return;
    }
    const taskIds: Array<string> = [];
    this.tasks.forEach((task: SteamArkSyncTask, accountId: string): void => {
      if (task.generation === stoppedGeneration) {
        taskIds.push(accountId);
      }
    });
    for (let index: number = 0; index < taskIds.length; index++) {
      this.tasks.delete(taskIds[index]);
    }
    this.loggedOnAccountIds.clear();
    this.messageNotificationLedgers.clear();
    this.hasObservedStateSnapshot = false;
    this.emit();
  }

  async dispose(): Promise<void> {
    this.disposed = true;
    await this.stop();
    this.listeners.clear();
    this.records.clear();
    this.messageNotificationLedgers.clear();
  }

  subscribe(listenerId: string, listener: SteamArkSyncSnapshotListener): boolean {
    const id: string = listenerId.trim();
    if (id.length <= 0 || this.listeners.has(id)) {
      return false;
    }
    this.listeners.set(id, listener);
    return true;
  }

  unsubscribe(listenerId: string): boolean {
    return this.listeners.delete(listenerId.trim());
  }

  getSnapshot(): SteamArkSyncSnapshot {
    const accounts: Array<SteamArkAccountSyncSnapshot> = [];
    const state: SteamArkStateSnapshot = this.stateService.getSnapshot();
    for (let index: number = 0; index < state.accounts.length; index++) {
      const account: SteamArkAccountSnapshot = state.accounts[index];
      const record: SteamArkSyncRecord = this.ensureRecord(account.profile.accountId);
      accounts.push(this.toSnapshot(account, record));
    }
    return new SteamArkSyncSnapshot(this.initialized, this.nowEpochSeconds(), accounts);
  }

  getAccountSnapshot(accountId: string): SteamArkAccountSyncSnapshot | null {
    const state: SteamArkStateSnapshot = this.stateService.getSnapshot();
    for (let index: number = 0; index < state.accounts.length; index++) {
      const account: SteamArkAccountSnapshot = state.accounts[index];
      if (account.profile.accountId === accountId.trim()) {
        return this.toSnapshot(account, this.ensureRecord(account.profile.accountId));
      }
    }
    return null;
  }

  async requestSilentSync(reason: string): Promise<void> {
    if (!this.initialized || this.disposed) {
      return;
    }
    const snapshot: SteamArkStateSnapshot = this.stateService.getSnapshot();
    const jobs: Array<Promise<void>> = [];
    for (let index: number = 0; index < snapshot.accounts.length; index++) {
      const account: SteamArkAccountSnapshot = snapshot.accounts[index];
      if (account.session.state === SteamSessionState.LOGGED_ON) {
        jobs.push(this.requestAccountSync(account.profile.accountId, reason));
      }
    }
    for (let index: number = 0; index < jobs.length; index++) {
      await jobs[index];
    }
  }

  async requestAccountSync(accountId: string, reason: string): Promise<void> {
    const normalizedId: string = accountId.trim();
    if (!this.initialized || this.disposed || normalizedId.length <= 0) {
      return;
    }
    const currentGeneration: number = this.generation;
    const existing: SteamArkSyncTask | undefined = this.tasks.get(normalizedId);
    if (existing !== undefined && existing.generation === currentGeneration) {
      await existing.completion;
      return;
    }
    const task: Promise<void> = this.syncAccount(normalizedId, reason, currentGeneration);
    const operation: SteamArkSyncTask = new SteamArkSyncTask(currentGeneration, task);
    this.tasks.set(normalizedId, operation);
    try {
      await task;
    } finally {
      if (this.tasks.get(normalizedId) === operation) {
        this.tasks.delete(normalizedId);
      }
    }
  }

  private async syncAccount(accountId: string, reason: string, generation: number): Promise<void> {
    const account: SteamArkAccountSnapshot | null = this.findAccount(accountId);
    if (account === null || account.session.state !== SteamSessionState.LOGGED_ON) {
      return;
    }
    const record: SteamArkSyncRecord = this.ensureRecord(accountId);
    record.running = true;
    record.failure = new SteamArkSyncFailure();
    record.stageFailures = [];
    this.emit();
    SteamArkLog.info(TAG, 'silent sync started; account=' + SteamArkLog.accountId(accountId) + ', reason=' + reason);
    try {
      await this.runStage(accountId, record, generation, SteamArkSyncStage.PROFILE);
      await this.runStage(accountId, record, generation, SteamArkSyncStage.INVENTORY);
      await this.runStage(accountId, record, generation, SteamArkSyncStage.FARMING);
      await this.runStage(accountId, record, generation, SteamArkSyncStage.SOCIAL);
      await this.runStage(accountId, record, generation, SteamArkSyncStage.MESSAGES);
      if (this.isCurrent(generation)) {
        if (record.stageFailures.length > 0) {
          record.stage = SteamArkSyncStage.FAILED;
          record.failure = record.stageFailures[record.stageFailures.length - 1];
        } else {
          record.stage = SteamArkSyncStage.COMPLETE;
          record.lastCompletedAtEpochSeconds = this.nowEpochSeconds();
          record.failure = new SteamArkSyncFailure();
        }
      }
    } finally {
      if (this.isCurrent(generation)) {
        record.running = false;
      }
      this.emit();
    }
  }

  private async runStage(
    accountId: string,
    record: SteamArkSyncRecord,
    generation: number,
    stage: SteamArkSyncStage
  ): Promise<void> {
    if (!this.isCurrent(generation)) {
      return;
    }
    try {
      if (stage === SteamArkSyncStage.PROFILE) {
        await this.syncProfile(accountId, record, generation);
      } else if (stage === SteamArkSyncStage.INVENTORY) {
        await this.syncInventory(accountId, record, generation);
      } else if (stage === SteamArkSyncStage.FARMING) {
        await this.syncFarming(accountId, record, generation);
      } else if (stage === SteamArkSyncStage.SOCIAL) {
        await this.syncSocial(accountId, record, generation);
      } else if (stage === SteamArkSyncStage.MESSAGES) {
        await this.syncMessages(accountId, record, generation);
      }
    } catch (error) {
      if (this.isCurrent(generation)) {
        const failure: SteamArkSyncFailure = this.failureFor(stage, error);
        record.stageFailures.push(failure);
        record.failure = failure;
      }
      SteamArkLog.warn(TAG, 'silent sync stage failed; account=' + SteamArkLog.accountId(accountId) +
        ', stage=' + String(stage) + ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private async syncProfile(accountId: string, record: SteamArkSyncRecord, generation: number): Promise<void> {
    record.stage = SteamArkSyncStage.PROFILE;
    this.emit();
    if (!this.isCurrent(generation)) {
      return;
    }
    const account: SteamArkAccountSnapshot | null = this.findAccount(accountId);
    if (account === null) {
      return;
    }
    const profileKnown: boolean = account.profile.avatarUrl.length > 0 || account.profile.displayName.length > 0;
    if (!profileKnown || this.isStale(record.profileUpdatedAtEpochSeconds, PROFILE_FRESHNESS_SECONDS)) {
      const refreshed: boolean = await this.stateService.refreshProfile(accountId);
      if (!refreshed) {
        throw new Error('profile synchronization did not complete');
      }
      record.profileUpdatedAtEpochSeconds = this.nowEpochSeconds();
    }
  }

  private async syncInventory(accountId: string, record: SteamArkSyncRecord, generation: number): Promise<void> {
    record.stage = SteamArkSyncStage.INVENTORY;
    this.emit();
    if (!this.isCurrent(generation)) {
      return;
    }
    if (!this.stateService.isInventoryAdapterReady()) {
      throw new Error('Steam inventory synchronization is not configured');
    }
    const cachedPages: Array<SteamInventoryPage> = this.stateService.getCachedDefaultInventoryPages(accountId);
    const cachedFirstPage: SteamInventoryPage | null = cachedPages.length > 0 ? cachedPages[0] : null;
    const refreshStartIndex: number = this.inventoryRefreshStartIndex(cachedPages);
    const refreshFirstPage: boolean = refreshStartIndex === 0;
    let currentPage: SteamInventoryPage | null = refreshStartIndex > 0
      ? cachedPages[refreshStartIndex - 1]
      : null;
    let pagesFetched: number = 0;
    const seenStartAssetIds: Set<string> = new Set<string>();

    if (refreshFirstPage) {
      const firstQuery = new SteamInventoryQuery(
        DEFAULT_INVENTORY_APP_ID,
        DEFAULT_INVENTORY_CONTEXT_ID,
        1,
        DEFAULT_INVENTORY_PAGE_SIZE,
        '',
        false,
        false,
        '',
        'english'
      );
      const refreshedFirstPage: SteamInventoryPage = await this.stateService.syncInventory(accountId, firstQuery);
      if (!this.isCurrent(generation)) {
        return;
      }
      if (!this.matchesInventoryQuery(refreshedFirstPage, firstQuery)) {
        throw new Error('inventory first page does not match its request');
      }
      if (!this.isValidSyncTimestamp(refreshedFirstPage.syncedAtEpochSeconds)) {
        throw new Error('inventory synchronization timestamp is invalid');
      }
      currentPage = refreshedFirstPage;
      record.inventoryUpdatedAtEpochSeconds = refreshedFirstPage.syncedAtEpochSeconds;
      pagesFetched = 1;
      seenStartAssetIds.add(firstQuery.startAssetId);
    } else if (cachedFirstPage !== null) {
      record.inventoryUpdatedAtEpochSeconds = cachedFirstPage.syncedAtEpochSeconds;
      for (let index: number = 0; index < refreshStartIndex; index++) {
        seenStartAssetIds.add(cachedPages[index].query.startAssetId);
      }
    } else {
      record.inventoryUpdatedAtEpochSeconds = 0;
    }

    if (currentPage === null || !currentPage.hasMore) {
      return;
    }

    SteamArkLog.debug(TAG, 'inventory continuation synchronization started; account=' +
      SteamArkLog.accountId(accountId) + ', cachedPages=' + cachedPages.length.toString() +
      ', refreshStartIndex=' + refreshStartIndex.toString());
    while (currentPage.hasMore) {
      if (!this.isCurrent(generation)) {
        return;
      }
      if (pagesFetched >= MAX_INVENTORY_PAGES_PER_SILENT_SYNC) {
        SteamArkLog.warn(TAG, 'inventory continuation synchronization reached page safety limit; account=' +
          SteamArkLog.accountId(accountId) + ', fetchedPages=' + pagesFetched.toString());
        throw new Error('inventory continuation synchronization reached the page safety limit');
      }
      const nextStartAssetId: string = currentPage.nextStartAssetId;
      if (nextStartAssetId.length <= 0) {
        throw new Error('inventory continuation cursor is missing');
      }
      if (seenStartAssetIds.has(nextStartAssetId)) {
        throw new Error('inventory continuation cursor repeated');
      }
      const nextPageNumber: number = currentPage.query.page + 1;
      if (!Number.isSafeInteger(nextPageNumber) || nextPageNumber <= currentPage.query.page ||
        !Number.isSafeInteger(currentPage.query.pageSize) || currentPage.query.pageSize <= 0) {
        throw new Error('inventory continuation pagination is invalid');
      }
      const nextQuery = new SteamInventoryQuery(
        currentPage.query.appId,
        currentPage.query.contextId,
        nextPageNumber,
        currentPage.query.pageSize,
        '',
        false,
        false,
        nextStartAssetId,
        currentPage.query.language
      );
      const nextPage: SteamInventoryPage = await this.stateService.syncInventory(accountId, nextQuery);
      if (!this.isCurrent(generation)) {
        return;
      }
      if (!this.matchesInventoryQuery(nextPage, nextQuery)) {
        throw new Error('inventory continuation page does not match its request');
      }
      if (!this.isValidSyncTimestamp(nextPage.syncedAtEpochSeconds)) {
        throw new Error('inventory continuation timestamp is invalid');
      }
      seenStartAssetIds.add(nextStartAssetId);
      currentPage = nextPage;
      pagesFetched += 1;
    }
    SteamArkLog.info(TAG, 'inventory continuation synchronization completed; account=' +
      SteamArkLog.accountId(accountId) + ', fetchedPages=' + pagesFetched.toString());
  }

  private inventoryRefreshStartIndex(cachedPages: Array<SteamInventoryPage>): number {
    if (cachedPages.length <= 0) {
      return 0;
    }
    for (let index: number = 0; index < cachedPages.length; index++) {
      if (this.isStale(cachedPages[index].syncedAtEpochSeconds, INVENTORY_FRESHNESS_SECONDS)) {
        return index;
      }
    }
    return cachedPages.length;
  }

  private matchesInventoryQuery(page: SteamInventoryPage, query: SteamInventoryQuery): boolean {
    return page.query.appId === query.appId && page.query.contextId === query.contextId &&
      page.query.page === query.page && page.query.pageSize === query.pageSize &&
      page.query.search === query.search && page.query.marketableOnly === query.marketableOnly &&
      page.query.tradableOnly === query.tradableOnly && page.query.startAssetId === query.startAssetId &&
      page.query.language === query.language;
  }

  private async syncFarming(accountId: string, record: SteamArkSyncRecord, generation: number): Promise<void> {
    record.stage = SteamArkSyncStage.FARMING;
    this.emit();
    if (!this.isCurrent(generation)) {
      return;
    }
    if (!this.farmingService.isFarmingReady()) {
      throw new Error('Steam farming synchronization is not available: ' + this.farmingService.availabilityMessage());
    }
    const snapshot = this.farmingService.getSnapshot(accountId);
    const cachedFarmingUpdatedAtEpochSeconds: number = snapshot === null ? 0 : snapshot.updatedAtEpochSeconds;
    const cachedBadgeReport: SteamBadgeSyncReport | null = this.farmingService.getBadgeSyncReport(accountId);
    const cachedBadgeUpdatedAtEpochSeconds: number = this.farmingService
      .getBadgeSyncReportUpdatedAtEpochSeconds(accountId);
    const farmingSnapshotFresh: boolean = this.isValidSyncTimestamp(cachedFarmingUpdatedAtEpochSeconds) &&
      !this.isStale(cachedFarmingUpdatedAtEpochSeconds, INVENTORY_FRESHNESS_SECONDS);
    const badgeReportFresh: boolean = this.hasCompleteFreshBadgeReport(
      cachedBadgeReport,
      cachedBadgeUpdatedAtEpochSeconds
    );
    if (!farmingSnapshotFresh || !badgeReportFresh) {
      const refreshed = await this.farmingService.refreshGames(accountId);
      if (!this.isValidSyncTimestamp(refreshed.updatedAtEpochSeconds)) {
        throw new Error('farming synchronization timestamp is invalid');
      }
      const refreshedBadgeReport: SteamBadgeSyncReport | null = this.farmingService.getBadgeSyncReport(accountId);
      const refreshedBadgeUpdatedAtEpochSeconds: number = this.farmingService
        .getBadgeSyncReportUpdatedAtEpochSeconds(accountId);
      if (!this.hasCompleteFreshBadgeReport(refreshedBadgeReport, refreshedBadgeUpdatedAtEpochSeconds)) {
        throw new Error('badge synchronization did not produce a complete report');
      }
      record.farmingUpdatedAtEpochSeconds = refreshedBadgeUpdatedAtEpochSeconds;
    } else {
      record.farmingUpdatedAtEpochSeconds = Math.min(
        cachedFarmingUpdatedAtEpochSeconds,
        cachedBadgeUpdatedAtEpochSeconds
      );
    }
  }

  private hasCompleteFreshBadgeReport(
    report: SteamBadgeSyncReport | null,
    updatedAtEpochSeconds: number
  ): boolean {
    return report !== null && report.requestedPageCount > 0 &&
      report.fetchedPageCount >= report.requestedPageCount &&
      this.isValidSyncTimestamp(updatedAtEpochSeconds) &&
      !this.isStale(updatedAtEpochSeconds, BADGE_FRESHNESS_SECONDS);
  }

  private async syncSocial(accountId: string, record: SteamArkSyncRecord, generation: number): Promise<void> {
    record.stage = SteamArkSyncStage.SOCIAL;
    this.emit();
    if (!this.isCurrent(generation)) {
      return;
    }
    const social = await this.socialService.connectAndSyncIfStale(accountId, SOCIAL_FRESHNESS_SECONDS);
    if (!this.isValidSyncTimestamp(social.updatedAtEpochSeconds)) {
      throw new Error('social synchronization timestamp is invalid');
    }
    record.socialUpdatedAtEpochSeconds = social.updatedAtEpochSeconds;
  }

  private async syncMessages(accountId: string, record: SteamArkSyncRecord, generation: number): Promise<void> {
    record.stage = SteamArkSyncStage.MESSAGES;
    this.emit();
    if (!this.isCurrent(generation)) {
      return;
    }
    const cachedRemoteSyncAtEpochSeconds: number = SteamArkMessageCacheStore.readRemoteSyncAtEpochSeconds(accountId);
    if (this.isValidSyncTimestamp(cachedRemoteSyncAtEpochSeconds)) {
      record.messagesUpdatedAtEpochSeconds = cachedRemoteSyncAtEpochSeconds;
    } else {
      record.messagesUpdatedAtEpochSeconds = 0;
    }
    if (!this.isStale(record.messagesUpdatedAtEpochSeconds, INVENTORY_FRESHNESS_SECONDS)) {
      return;
    }
    const messages: SteamArkMessageSyncResult = await this.stateService.syncMessages(accountId);
    if (!this.isValidSyncTimestamp(messages.syncedAtEpochSeconds)) {
      throw new Error('message synchronization timestamp is invalid');
    }
    record.messagesUpdatedAtEpochSeconds = messages.syncedAtEpochSeconds;
    await this.publishNewMessageNotifications(accountId, messages, generation);
  }

  private async publishNewMessageNotifications(
    accountId: string,
    result: SteamArkMessageSyncResult,
    generation: number
  ): Promise<void> {
    if (!this.isCurrent(generation)) {
      return;
    }
    if (!this.isMessageNotificationAccountActive(accountId)) {
      SteamArkLog.debug(TAG, 'message notification skipped because account is no longer logged on; account=' +
        SteamArkLog.accountId(accountId));
      return;
    }
    const remote: Array<SteamArkMessageItem> = result.items;
    const ledger: SteamArkMessageNotificationLedger = this.messageNotificationLedger(accountId);
    if (!ledger.initialized) {
      const persistedIds: Array<string> = SteamArkMessageCacheStore.readNotificationMessageIds(accountId);
      const hadPersistedLedger: boolean = SteamArkMessageCacheStore.hasNotificationMessageLedger(accountId);
      const hadPersistedBaseline: boolean = SteamArkMessageCacheStore.hasNotificationMessageBaseline(accountId);
      for (let index: number = 0; index < persistedIds.length; index++) {
        ledger.notifiedMessageIds.add(persistedIds[index]);
      }
      ledger.initialized = true;
      ledger.baselineEstablished = hadPersistedLedger;
      if (hadPersistedLedger && !hadPersistedBaseline) {
        const baselineSaved: boolean = SteamArkMessageCacheStore.writeNotificationMessageBaseline(
          accountId,
          ledger.generation
        );
        if (!baselineSaved) {
          SteamArkLog.debug(TAG, 'legacy message notification baseline migration deferred; account=' +
            SteamArkLog.accountId(accountId));
        }
      }
    }
    if (!ledger.baselineEstablished) {
      if (!this.isCompleteMessageSnapshot(result)) {
        SteamArkLog.debug(TAG, 'message notification baseline deferred until a complete snapshot is available; account=' +
          SteamArkLog.accountId(accountId));
        return;
      }
      for (let index: number = 0; index < remote.length; index++) {
        const id: string = remote[index].id.trim();
        if (id.length > 0) {
          ledger.notifiedMessageIds.add(id);
        }
      }
      const ledgerSaved: boolean = this.persistMessageNotificationLedger(accountId, ledger);
      if (!ledgerSaved) {
        SteamArkLog.debug(TAG, 'message notification baseline persistence deferred; account=' +
          SteamArkLog.accountId(accountId));
        return;
      }
      ledger.baselineEstablished = true;
      const baselineSaved: boolean = SteamArkMessageCacheStore.writeNotificationMessageBaseline(
        accountId,
        ledger.generation
      );
      if (!baselineSaved) {
        SteamArkLog.debug(TAG, 'message notification baseline marker write deferred; account=' +
          SteamArkLog.accountId(accountId));
      }
      SteamArkLog.debug(TAG, 'message notification baseline established; account=' +
        SteamArkLog.accountId(accountId) + ', messages=' + remote.length.toString());
      return;
    }
    const publisher: ISteamArkMessageNotificationPublisher | null = this.messageNotificationPublisher;
    let changed: boolean = false;
    for (let index: number = 0; index < remote.length; index++) {
      if (!this.isCurrent(generation) || !this.isMessageNotificationAccountActive(accountId)) {
        return;
      }
      const item: SteamArkMessageItem = remote[index];
      const itemId: string = item.id.trim();
      if (itemId.length <= 0 || ledger.notifiedMessageIds.has(itemId)) {
        continue;
      }
      if (publisher === null || !item.unread) {
        ledger.notifiedMessageIds.add(itemId);
        changed = true;
        continue;
      }
      try {
        await publisher.publishSynchronizedMessage(accountId, item);
        if (!this.isCurrent(generation) || !this.isMessageNotificationAccountActive(accountId)) {
          return;
        }
        ledger.notifiedMessageIds.add(itemId);
        changed = true;
      } catch (error) {
        SteamArkLog.warn(TAG, 'message notification publish failed; account=' +
          SteamArkLog.accountId(accountId) + ', message=' + SteamArkLog.opaqueId(itemId) +
          ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
    if (changed) {
      this.persistMessageNotificationLedger(accountId, ledger);
    }
  }

  private isMessageNotificationAccountActive(accountId: string): boolean {
    const account: SteamArkAccountSnapshot | null = this.findAccount(accountId);
    return account !== null && account.session.state === SteamSessionState.LOGGED_ON;
  }

  private messageNotificationLedger(accountId: string): SteamArkMessageNotificationLedger {
    const currentGeneration: number = SteamArkMessageCacheStore.captureGeneration(accountId);
    const existing: SteamArkMessageNotificationLedger | undefined = this.messageNotificationLedgers.get(accountId);
    if (existing !== undefined && existing.generation === currentGeneration) {
      return existing;
    }
    const ledger: SteamArkMessageNotificationLedger = new SteamArkMessageNotificationLedger();
    ledger.generation = currentGeneration;
    this.messageNotificationLedgers.set(accountId, ledger);
    return ledger;
  }

  private persistMessageNotificationLedger(accountId: string, ledger: SteamArkMessageNotificationLedger): boolean {
    const ids: Array<string> = [];
    ledger.notifiedMessageIds.forEach((id: string): void => {
      ids.push(id);
    });
    const saved: boolean = SteamArkMessageCacheStore.writeNotificationMessageIds(
      accountId,
      ledger.generation,
      ids
    );
    if (!saved) {
      SteamArkLog.debug(TAG, 'message notification ledger write ignored; account=' +
        SteamArkLog.accountId(accountId));
    }
    return saved;
  }

  private isCompleteMessageSnapshot(result: SteamArkMessageSyncResult): boolean {
    return result.sourceWarning.trim().length <= 0;
  }

  private handleStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    const activeIds: Array<string> = [];
    const newlyLoggedOnAccountIds: Array<string> = [];
    const shouldDispatchLoggedOnTransitions: boolean = this.hasObservedStateSnapshot;
    for (let index: number = 0; index < snapshot.accounts.length; index++) {
      const account: SteamArkAccountSnapshot = snapshot.accounts[index];
      const accountId: string = account.profile.accountId;
      activeIds.push(accountId);
      this.ensureRecord(accountId);
      const wasLoggedOn: boolean = this.loggedOnAccountIds.has(accountId);
      if (account.session.state === SteamSessionState.LOGGED_ON) {
        this.loggedOnAccountIds.add(accountId);
        if (shouldDispatchLoggedOnTransitions && !wasLoggedOn) {
          newlyLoggedOnAccountIds.push(accountId);
        }
      } else {
        this.loggedOnAccountIds.delete(accountId);
      }
    }
    const staleIds: Array<string> = [];
    this.records.forEach((_record: SteamArkSyncRecord, accountId: string): void => {
      if (!activeIds.includes(accountId)) {
        staleIds.push(accountId);
      }
    });
    for (let index: number = 0; index < staleIds.length; index++) {
      this.records.delete(staleIds[index]);
      this.messageNotificationLedgers.delete(staleIds[index]);
      this.sharedSecretCapabilities.delete(staleIds[index]);
      this.webApiCredentialCapabilities.delete(staleIds[index]);
      this.loggedOnAccountIds.delete(staleIds[index]);
    }
    this.hasObservedStateSnapshot = true;
    this.emit();
    for (let index: number = 0; index < newlyLoggedOnAccountIds.length; index++) {
      this.dispatchLoggedOnSync(newlyLoggedOnAccountIds[index]);
    }
  }

  private dispatchLoggedOnSync(accountId: string): void {
    void this.requestAccountSync(accountId, 'session_logged_on').catch((error: Error): void => {
      SteamArkLog.warn(TAG, 'logged-on sync dispatch failed; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    });
  }

  private toSnapshot(account: SteamArkAccountSnapshot, record: SteamArkSyncRecord): SteamArkAccountSyncSnapshot {
    const social = this.socialService.getSnapshot(account.profile.accountId);
    const authenticated: boolean = account.session.state === SteamSessionState.LOGGED_ON;
    const capability = new SteamArkCapabilitySnapshot(
      account.profile.accountId,
      account.session.state,
      authenticated,
      false,
      false,
      social.state === SteamArkSocialConnectionState.CONNECTED,
      account.hasCredentialMaterial
    );
    void this.resolveSharedSecret(account.profile.accountId);
    void this.resolveWebApiCredentials(account.profile.accountId);
    const cachedCapability: SteamArkCapabilitySnapshot = this.capabilityWithCachedCredentials(capability);
    return new SteamArkAccountSyncSnapshot(
      account.profile.accountId,
      record.stage,
      record.running,
      record.lastCompletedAtEpochSeconds,
      cachedCapability,
      new SteamArkCacheFreshnessSnapshot(
        record.profileUpdatedAtEpochSeconds,
        record.inventoryUpdatedAtEpochSeconds,
        record.farmingUpdatedAtEpochSeconds,
        record.socialUpdatedAtEpochSeconds,
        record.messagesUpdatedAtEpochSeconds
      ),
      record.failure,
      record.stageFailures
    );
  }

  private readonly sharedSecretCapabilities: Map<string, boolean> = new Map<string, boolean>();
  private readonly webApiCredentialCapabilities: Map<string, boolean> = new Map<string, boolean>();

  private capabilityWithCachedCredentials(capability: SteamArkCapabilitySnapshot): SteamArkCapabilitySnapshot {
    const sharedSecretAvailable: boolean = this.sharedSecretCapabilities.get(capability.accountId) === true;
    const webApiCredentialsAvailable: boolean = this.webApiCredentialCapabilities.get(capability.accountId) === true;
    return new SteamArkCapabilitySnapshot(
      capability.accountId,
      capability.sessionState,
      capability.authenticated,
      webApiCredentialsAvailable,
      sharedSecretAvailable,
      capability.socialConnected,
      capability.credentialsAvailable
    );
  }

  private async resolveSharedSecret(accountId: string): Promise<void> {
    if (this.sharedSecretCapabilities.has(accountId) || this.disposed) {
      return;
    }
    try {
      const available: boolean = await this.stateService.hasSharedSecret(accountId);
      this.sharedSecretCapabilities.set(accountId, available);
      this.emit();
    } catch (_error) {
      this.sharedSecretCapabilities.set(accountId, false);
    }
  }

  private async resolveWebApiCredentials(accountId: string): Promise<void> {
    if (this.webApiCredentialCapabilities.has(accountId) || this.disposed) {
      return;
    }
    try {
      const available: boolean = await this.stateService.hasWebApiCredentials(accountId);
      this.webApiCredentialCapabilities.set(accountId, available);
      this.emit();
    } catch (_error) {
      this.webApiCredentialCapabilities.set(accountId, false);
    }
  }

  private failureFor(stage: SteamArkSyncStage, error: Object): SteamArkSyncFailure {
    const raw: string = error instanceof Error ? error.message : '';
    const message: string = this.redactFailureMessage(raw);
    const normalized: string = raw.toLowerCase();
    let kind: SteamArkSyncFailureKind = SteamArkSyncFailureKind.DATA;
    if (normalized.indexOf('credential') >= 0 || normalized.indexOf('token') >= 0 ||
      normalized.indexOf('logged on') >= 0 || normalized.indexOf('authentication') >= 0) {
      kind = SteamArkSyncFailureKind.AUTHENTICATION;
    } else if (normalized.indexOf('network') >= 0 || normalized.indexOf('transport') >= 0 ||
      normalized.indexOf('timeout') >= 0 || normalized.indexOf('http') >= 0) {
      kind = SteamArkSyncFailureKind.NETWORK;
    } else if (normalized.indexOf('configured') >= 0 || normalized.indexOf('available') >= 0) {
      kind = SteamArkSyncFailureKind.CONFIGURATION;
    }
    return new SteamArkSyncFailure(kind, stage, message, this.nowEpochSeconds());
  }

  private redactFailureMessage(message: string): string {
    const normalized: string = message.replace(/\r/g, ' ').replace(/\n/g, ' ').trim();
    if (normalized.length <= 0) {
      return 'Data refresh did not complete.';
    }
    return normalized.length <= 240 ? normalized : normalized.substring(0, 240);
  }

  private findAccount(accountId: string): SteamArkAccountSnapshot | null {
    const snapshot: SteamArkStateSnapshot = this.stateService.getSnapshot();
    for (let index: number = 0; index < snapshot.accounts.length; index++) {
      if (snapshot.accounts[index].profile.accountId === accountId) {
        return snapshot.accounts[index];
      }
    }
    return null;
  }

  private ensureRecord(accountId: string): SteamArkSyncRecord {
    const existing: SteamArkSyncRecord | undefined = this.records.get(accountId);
    if (existing !== undefined) {
      return existing;
    }
    const record = new SteamArkSyncRecord();
    this.records.set(accountId, record);
    return record;
  }

  private isValidSyncTimestamp(updatedAtEpochSeconds: number): boolean {
    return Number.isSafeInteger(updatedAtEpochSeconds) && updatedAtEpochSeconds > 0 &&
      updatedAtEpochSeconds <= this.nowEpochSeconds() + MAX_FUTURE_SYNC_CLOCK_SKEW_SECONDS;
  }

  private isStale(updatedAtEpochSeconds: number, thresholdSeconds: number): boolean {
    return !this.isValidSyncTimestamp(updatedAtEpochSeconds) ||
      this.nowEpochSeconds() - updatedAtEpochSeconds >= thresholdSeconds;
  }

  private isCurrent(generation: number): boolean {
    return this.initialized && !this.disposed && generation === this.generation;
  }

  private emit(): void {
    const snapshot: SteamArkSyncSnapshot = this.getSnapshot();
    const currentListeners: Array<SteamArkSyncSnapshotListener> = [];
    this.listeners.forEach((listener: SteamArkSyncSnapshotListener): void => {
      currentListeners.push(listener);
    });
    for (let index: number = 0; index < currentListeners.length; index++) {
      try {
        currentListeners[index](snapshot);
      } catch (error) {
        SteamArkLog.warn(TAG, 'sync snapshot listener failed; errorType=' + SteamArkLog.errorKind(error));
      }
    }
  }

  private nowEpochSeconds(): number {
    return Math.floor(Date.now() / 1000);
  }
}

export const steamArkSyncCoordinator: SteamArkSyncCoordinator = new SteamArkSyncCoordinator();
