import { ngfSettingsStoreFacade } from 'ngf_framework';
import { SteamAccountProfile, SteamCredentialSet, SteamSessionState } from 'steam_core';
import {
  ISteamArkSocialNotificationPublisher,
  ISteamArkSocialRuntime,
  ISteamArkSocialRuntimeFactory,
  SteamArkChatMessage,
  SteamArkChatReaction,
  SteamArkChatSession,
  SteamArkEmoticon,
  SteamArkFriendProfile,
  SteamArkSocialConnectionState,
  SteamArkSocialEvent,
  SteamArkSocialEventListener,
  SteamArkSocialEventType,
  SteamArkSocialSnapshot,
  SteamArkSocialSnapshotListener
} from './SteamArkSocialContracts';
import { SteamArkAccountSnapshot, SteamArkStateSnapshot, steamArkStateService } from './SteamArkStateService';
import { SteamArkLog } from './SteamArkLogger';

const TAG: string = 'SteamArkSocialService';
const LEGACY_CACHE_PREFIX: string = 'steam-ark-social-v1:';
const CACHE_NAMESPACE: string = 'steam-ark-social-v2';
const CACHE_GENERATION_PREFIX: string = CACHE_NAMESPACE + '.generation:';
const DEFAULT_CACHE_GENERATION: number = 1;
const MAX_MESSAGES_PER_CONVERSATION: number = 200;
const MAX_CACHED_MESSAGES: number = 2000;

interface SteamArkFriendCacheItem {
  steamId64: string;
  accountId32: number;
  displayName: string;
  avatarUrl: string;
  profileUrl: string;
  personaState: number;
  gameName: string;
  gameAppId?: string;
  lastLogoffEpochSeconds: number;
  friendSinceEpochSeconds: number;
}

interface SteamArkSessionCacheItem {
  friendSteamId64: string;
  lastMessageEpochSeconds: number;
  lastViewEpochSeconds: number;
  unreadCount: number;
  suspicious: boolean;
}

interface SteamArkChatCacheItem {
  id: string;
  friendSteamId64: string;
  senderAccountId32: number;
  message: string;
  timestamp: number;
  ordinal: number;
  outgoing: boolean;
  reactions?: Array<SteamArkReactionCacheItem>;
}

interface SteamArkReactionCacheItem {
  reactionType: number;
  reaction: string;
  reactorAccountIds: Array<number>;
}

interface SteamArkEmoticonCacheItem {
  name: string;
  imageUrl: string;
  appId: number;
  count: number;
  lastUsedEpochSeconds: number;
}

interface SteamArkSocialCacheDocument {
  accountId: string;
  generation?: number;
  updatedAtEpochSeconds: number;
  friends: Array<SteamArkFriendCacheItem>;
  sessions: Array<SteamArkSessionCacheItem>;
  messages: Array<SteamArkChatCacheItem>;
  emoticons?: Array<SteamArkEmoticonCacheItem>;
}

class SteamArkSocialRuntimeHandle {
  readonly accountId: string;
  readonly runtime: ISteamArkSocialRuntime;
  readonly listener: SteamArkSocialEventListener | null;

  constructor(
    accountId: string,
    runtime: ISteamArkSocialRuntime,
    listener: SteamArkSocialEventListener | null
  ) {
    this.accountId = accountId;
    this.runtime = runtime;
    this.listener = listener;
  }
}

export class SteamArkSocialService {
  private runtimeFactory: ISteamArkSocialRuntimeFactory | null = null;
  private notificationPublisher: ISteamArkSocialNotificationPublisher | null = null;
  private readonly runtimes: Map<string, ISteamArkSocialRuntime> = new Map<string, ISteamArkSocialRuntime>();
  private readonly runtimeListeners: Map<string, SteamArkSocialEventListener> =
    new Map<string, SteamArkSocialEventListener>();
  private readonly snapshots: Map<string, SteamArkSocialSnapshot> = new Map<string, SteamArkSocialSnapshot>();
  private readonly conversations: Map<string, Array<SteamArkChatMessage>> =
    new Map<string, Array<SteamArkChatMessage>>();
  private readonly emoticons: Map<string, Array<SteamArkEmoticon>> =
    new Map<string, Array<SteamArkEmoticon>>();
  private readonly listeners: Map<string, SteamArkSocialSnapshotListener> =
    new Map<string, SteamArkSocialSnapshotListener>();
  private readonly syncTasks: Map<string, Promise<SteamArkSocialSnapshot>> =
    new Map<string, Promise<SteamArkSocialSnapshot>>();
  private readonly syncTaskGenerations: Map<string, number> = new Map<string, number>();
  private readonly syncTaskConfigurationGenerations: Map<string, number> = new Map<string, number>();
  private readonly runtimeGenerations: Map<string, number> = new Map<string, number>();
  private readonly runtimeConfigurationGenerations: Map<string, number> = new Map<string, number>();
  private readonly cacheGenerations: Map<string, number> = new Map<string, number>();
  private readonly cacheWriteTails: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  private disposed: boolean = false;
  private runtimeConfigurationGeneration: number = 0;
  private disposePromise: Promise<void> | null = null;

  setRuntimeFactory(factory: ISteamArkSocialRuntimeFactory | null): void {
    this.runtimeConfigurationGeneration += 1;
    this.runtimeFactory = factory;
    this.disposed = false;
    SteamArkLog.info(TAG, 'social runtime factory configured; enabled=' + String(factory !== null));
  }

  setNotificationPublisher(publisher: ISteamArkSocialNotificationPublisher | null): void {
    this.notificationPublisher = publisher;
    SteamArkLog.info(TAG, 'social notification publisher configured; enabled=' +
      String(publisher !== null));
  }

  subscribe(listenerId: string, listener: SteamArkSocialSnapshotListener): boolean {
    const normalized: string = listenerId.trim();
    if (normalized.length <= 0 || this.listeners.has(normalized)) {
      return false;
    }
    this.listeners.set(normalized, listener);
    return true;
  }

  unsubscribe(listenerId: string): boolean {
    return this.listeners.delete(listenerId.trim());
  }

  getSnapshot(accountId: string): SteamArkSocialSnapshot {
    const normalized: string = accountId.trim();
    const snapshot: SteamArkSocialSnapshot | undefined = this.snapshots.get(normalized);
    if (snapshot !== undefined) {
      return this.copySnapshot(snapshot);
    }
    return new SteamArkSocialSnapshot(normalized);
  }

  getMessages(accountId: string, friendSteamId64: string): Array<SteamArkChatMessage> {
    const values: Array<SteamArkChatMessage> | undefined = this.conversations.get(
      this.conversationKey(accountId, friendSteamId64));
    return values === undefined ? [] : values.slice();
  }

  getEmoticons(accountId: string): Array<SteamArkEmoticon> {
    const normalized: string = accountId.trim();
    if (!this.snapshots.has(normalized)) {
      this.restoreCache(normalized, this.captureCacheGeneration(normalized));
    }
    const values: Array<SteamArkEmoticon> | undefined = this.emoticons.get(normalized);
    return values === undefined ? [] : values.slice();
  }

  async loadEmoticons(accountId: string, forceRefresh: boolean = false): Promise<Array<SteamArkEmoticon>> {
    const normalized: string = accountId.trim();
    const generation: number = this.captureCacheGeneration(normalized);
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    const cached: Array<SteamArkEmoticon> = this.getEmoticons(normalized);
    if (!forceRefresh && cached.length > 0) {
      return cached;
    }
    const runtime: ISteamArkSocialRuntime = await this.requireRuntime(normalized, generation, configurationGeneration);
    const loaded: Array<SteamArkEmoticon> = await runtime.loadEmoticons();
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(normalized, generation);
    this.emoticons.set(normalized, loaded.slice());
    await this.persist(normalized, generation, configurationGeneration);
    return loaded.slice();
  }

  restore(accountId: string): SteamArkSocialSnapshot {
    const normalized: string = accountId.trim();
    if (normalized.length <= 0) {
      return new SteamArkSocialSnapshot();
    }
    if (!this.snapshots.has(normalized)) {
      this.restoreCache(normalized, this.captureCacheGeneration(normalized));
    }
    return this.getSnapshot(normalized);
  }

  async connectLoggedOnAccounts(): Promise<void> {
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    await steamArkStateService.initialize();
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration)) {
      return;
    }
    const snapshot: SteamArkStateSnapshot = steamArkStateService.getSnapshot();
    SteamArkLog.info(TAG, 'background social synchronization started; accounts=' +
      snapshot.accounts.length.toString());
    const accountIds: Array<string> = [];
    for (let index: number = 0; index < snapshot.accounts.length; index++) {
      if (!this.isCurrentRuntimeConfiguration(configurationGeneration)) {
        return;
      }
      const account: SteamArkAccountSnapshot = snapshot.accounts[index];
      if (account.session.state !== SteamSessionState.LOGGED_ON) {
        continue;
      }
      this.restore(account.profile.accountId);
      accountIds.push(account.profile.accountId);
    }
    const connectionTasks: Array<Promise<void>> = [];
    for (let index: number = 0; index < accountIds.length; index++) {
      connectionTasks.push(this.connectRealtime(accountIds[index], configurationGeneration));
    }
    await Promise.all<void>(connectionTasks);
    for (let index: number = 0; index < accountIds.length; index++) {
      if (!this.isCurrentRuntimeConfiguration(configurationGeneration)) {
        return;
      }
      const accountId: string = accountIds[index];
      try {
        SteamArkLog.info(TAG, 'background account social synchronization started; account=' +
          SteamArkLog.accountId(accountId));
        await this.connectAndSyncForConfiguration(accountId, configurationGeneration);
        const synced: SteamArkSocialSnapshot = this.getSnapshot(accountId);
        SteamArkLog.info(TAG, 'background account social synchronization completed; account=' +
          SteamArkLog.accountId(accountId) + ', friends=' + synced.friends.length.toString() +
          ', sessions=' + synced.sessions.length.toString());
      } catch (error) {
        SteamArkLog.warn(TAG, 'background social connection failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
  }

  async connectAndSync(accountId: string): Promise<SteamArkSocialSnapshot> {
    return await this.connectAndSyncForConfiguration(accountId, this.runtimeConfigurationGeneration);
  }

  private async connectAndSyncForConfiguration(
    accountId: string,
    configurationGeneration: number
  ): Promise<SteamArkSocialSnapshot> {
    const normalized: string = accountId.trim();
    const generation: number = this.captureCacheGeneration(normalized);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    const existing: Promise<SteamArkSocialSnapshot> | undefined = this.syncTasks.get(normalized);
    if (existing !== undefined && this.syncTaskGenerations.get(normalized) === generation &&
      this.syncTaskConfigurationGenerations.get(normalized) === configurationGeneration) {
      return await existing;
    }
    const task: Promise<SteamArkSocialSnapshot> = this.connectAndSyncInternal(
      normalized,
      generation,
      configurationGeneration
    );
    this.syncTasks.set(normalized, task);
    this.syncTaskGenerations.set(normalized, generation);
    this.syncTaskConfigurationGenerations.set(normalized, configurationGeneration);
    try {
      return await task;
    } finally {
      if (this.syncTasks.get(normalized) === task) {
        this.syncTasks.delete(normalized);
        this.syncTaskGenerations.delete(normalized);
        this.syncTaskConfigurationGenerations.delete(normalized);
      }
    }
  }

  /**
   * Reuses an already-connected, warning-free social snapshot until it reaches the caller's
   * freshness threshold. Explicit user refreshes should continue to call connectAndSync().
   */
  async connectAndSyncIfStale(accountId: string, freshnessSeconds: number): Promise<SteamArkSocialSnapshot> {
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    const normalized: string = accountId.trim();
    const cached: SteamArkSocialSnapshot = this.restore(normalized);
    if (this.isFreshConnectedSnapshot(cached, freshnessSeconds)) {
      SteamArkLog.debug(TAG, 'social refresh reused connected cache; account=' +
        SteamArkLog.accountId(normalized));
      return cached;
    }
    return await this.connectAndSyncForConfiguration(normalized, configurationGeneration);
  }

  async loadConversation(accountId: string, friendSteamId64: string,
    loadOlder: boolean = false): Promise<Array<SteamArkChatMessage>> {
    const normalizedAccountId: string = accountId.trim();
    const normalizedFriendId: string = friendSteamId64.trim();
    const generation: number = this.captureCacheGeneration(normalizedAccountId);
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    const runtime: ISteamArkSocialRuntime = await this.requireRuntime(
      normalizedAccountId,
      generation,
      configurationGeneration
    );
    const current: Array<SteamArkChatMessage> = this.getMessages(normalizedAccountId, normalizedFriendId);
    let beforeTimestamp: number = 0;
    let beforeOrdinal: number = 0;
    if (loadOlder && current.length > 0) {
      beforeTimestamp = current[0].timestamp;
      beforeOrdinal = current[0].ordinal;
    }
    const loaded: Array<SteamArkChatMessage> = await runtime.loadMessages(
      normalizedFriendId, 100, beforeTimestamp, beforeOrdinal);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(normalizedAccountId, generation);
    const merged: Array<SteamArkChatMessage> = this.mergeMessages(current, loaded);
    this.conversations.set(this.conversationKey(normalizedAccountId, normalizedFriendId), merged);
    this.updateSessionFromMessages(normalizedAccountId, normalizedFriendId, merged, false, generation);
    await this.persist(normalizedAccountId, generation, configurationGeneration);
    this.emit(normalizedAccountId, generation, configurationGeneration);
    return merged.slice();
  }

  async sendMessage(accountId: string, friendSteamId64: string, message: string): Promise<SteamArkChatMessage> {
    const normalizedAccountId: string = accountId.trim();
    const normalizedFriendId: string = friendSteamId64.trim();
    const normalizedMessage: string = message.trim();
    if (normalizedAccountId.length <= 0 || normalizedFriendId.length <= 0 || normalizedMessage.length <= 0) {
      throw new Error('Steam chat requires an account, recipient and message');
    }
    const generation: number = this.captureCacheGeneration(normalizedAccountId);
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    SteamArkLog.info(TAG, 'chat send dispatching; account=' + SteamArkLog.accountId(normalizedAccountId) +
      ', friend=' + SteamArkLog.steamId64(normalizedFriendId) +
      ', messageLength=' + normalizedMessage.length.toString());
    try {
      const runtime: ISteamArkSocialRuntime = await this.requireRuntime(
        normalizedAccountId,
        generation,
        configurationGeneration
      );
      const sent: SteamArkChatMessage = await runtime.sendMessage(normalizedFriendId, normalizedMessage);
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.requireCurrentCacheGeneration(normalizedAccountId, generation);
      this.mergeConversationMessage(normalizedAccountId, sent, generation);
      this.updateSessionFromMessage(normalizedAccountId, sent, false, generation);
      await this.persist(normalizedAccountId, generation, configurationGeneration);
      this.emit(normalizedAccountId, generation, configurationGeneration);
      SteamArkLog.info(TAG, 'chat send persisted; account=' + SteamArkLog.accountId(normalizedAccountId) +
        ', friend=' + SteamArkLog.steamId64(normalizedFriendId) +
        ', messageId=' + SteamArkLog.opaqueId(sent.id));
      return sent;
    } catch (error) {
      SteamArkLog.warn(TAG, 'chat send dispatch failed; account=' + SteamArkLog.accountId(normalizedAccountId) +
        ', friend=' + SteamArkLog.steamId64(normalizedFriendId) +
        ', errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('Steam chat send failed');
    }
  }

  async acknowledge(accountId: string, friendSteamId64: string, timestamp: number): Promise<void> {
    const normalizedAccountId: string = accountId.trim();
    const generation: number = this.captureCacheGeneration(normalizedAccountId);
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    const runtime: ISteamArkSocialRuntime = await this.requireRuntime(
      normalizedAccountId,
      generation,
      configurationGeneration
    );
    await runtime.acknowledge(friendSteamId64.trim(), timestamp);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(normalizedAccountId, generation);
    this.markSessionRead(normalizedAccountId, friendSteamId64.trim(), timestamp, generation);
    await this.persist(normalizedAccountId, generation, configurationGeneration);
    this.emit(normalizedAccountId, generation, configurationGeneration);
  }

  async updateReaction(accountId: string, friendSteamId64: string, timestamp: number, ordinal: number,
    reactionType: number, reaction: string, isAdd: boolean): Promise<void> {
    const normalizedAccountId: string = accountId.trim();
    const generation: number = this.captureCacheGeneration(normalizedAccountId);
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    const runtime: ISteamArkSocialRuntime = await this.requireRuntime(
      normalizedAccountId,
      generation,
      configurationGeneration
    );
    await runtime.updateReaction(friendSteamId64.trim(), timestamp, ordinal, reactionType, reaction, isAdd);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(normalizedAccountId, generation);
  }

  async reportMessage(accountId: string, fromSteamId64: string, toSteamId64: string,
    timestamp: number, ordinal: number, reason: number, reportText: string): Promise<void> {
    const normalizedAccountId: string = accountId.trim();
    const generation: number = this.captureCacheGeneration(normalizedAccountId);
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    const runtime: ISteamArkSocialRuntime = await this.requireRuntime(
      normalizedAccountId,
      generation,
      configurationGeneration
    );
    await runtime.reportMessage(fromSteamId64, toSteamId64, timestamp, ordinal, reason, reportText);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(normalizedAccountId, generation);
  }

  async dismissSessionNotice(accountId: string, friendSteamId64: string, noticeType: number): Promise<void> {
    const normalizedAccountId: string = accountId.trim();
    const generation: number = this.captureCacheGeneration(normalizedAccountId);
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    const runtime: ISteamArkSocialRuntime = await this.requireRuntime(
      normalizedAccountId,
      generation,
      configurationGeneration
    );
    await runtime.dismissSessionNotice(friendSteamId64.trim(), noticeType);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(normalizedAccountId, generation);
    this.clearSessionNotice(normalizedAccountId, friendSteamId64.trim(), generation);
    await this.persist(normalizedAccountId, generation, configurationGeneration);
    this.emit(normalizedAccountId, generation, configurationGeneration);
  }

  async removeAccount(accountId: string): Promise<void> {
    const normalized: string = accountId.trim();
    if (normalized.length <= 0) {
      return;
    }
    // Invalidate first so every already-started sync, listener callback and queued write becomes stale.
    const previousGeneration: number = this.captureCacheGeneration(normalized);
    const nextGeneration: number = previousGeneration + 1;
    this.cacheGenerations.set(normalized, nextGeneration);
    this.runtimeGenerations.delete(normalized);
    this.runtimeConfigurationGenerations.delete(normalized);
    this.syncTaskGenerations.delete(normalized);
    this.syncTaskConfigurationGenerations.delete(normalized);
    await this.closeRuntime(normalized);
    this.snapshots.delete(normalized);
    this.removeConversations(normalized);
    this.emoticons.delete(normalized);
    await this.clearCacheAfterRemoval(normalized, previousGeneration, nextGeneration);
    SteamArkLog.debug(TAG, 'social cache invalidated after account deletion; account=' +
      SteamArkLog.accountId(normalized));
  }

  async disconnectAccount(accountId: string): Promise<void> {
    const normalized: string = accountId.trim();
    if (normalized.length <= 0) {
      return;
    }
    const previousGeneration: number = this.captureCacheGeneration(normalized);
    const nextGeneration: number = previousGeneration + 1;
    this.cacheGenerations.set(normalized, nextGeneration);
    this.runtimeGenerations.delete(normalized);
    this.runtimeConfigurationGenerations.delete(normalized);
    this.syncTaskGenerations.delete(normalized);
    this.syncTaskConfigurationGenerations.delete(normalized);
    await this.closeRuntime(normalized);
    const cached: SteamArkSocialSnapshot = this.getSnapshot(normalized);
    this.snapshots.set(normalized, new SteamArkSocialSnapshot(
      normalized,
      SteamArkSocialConnectionState.DISCONNECTED,
      cached.friends,
      cached.sessions,
      cached.updatedAtEpochSeconds
    ));
    const configurationGeneration: number = this.runtimeConfigurationGeneration;
    await this.persist(normalized, nextGeneration, configurationGeneration);
    this.emit(normalized, nextGeneration, configurationGeneration);
    SteamArkLog.info(TAG, 'social runtime disconnected while cache was retained; account=' +
      SteamArkLog.accountId(normalized));
  }

  async dispose(): Promise<void> {
    const existingDispose: Promise<void> | null = this.disposePromise;
    if (existingDispose !== null) {
      await existingDispose;
      return;
    }
    const disposedConfigurationGeneration: number = this.runtimeConfigurationGeneration;
    this.disposed = true;
    const oldRuntimes: Array<SteamArkSocialRuntimeHandle> = this.captureRuntimeHandles();
    const disposePromise: Promise<void> = this.disposeRuntimeGeneration(
      disposedConfigurationGeneration,
      oldRuntimes
    );
    this.disposePromise = disposePromise;
    try {
      await disposePromise;
    } finally {
      if (this.disposePromise === disposePromise) {
        this.disposePromise = null;
      }
    }
  }

  private async disposeRuntimeGeneration(
    disposedConfigurationGeneration: number,
    oldRuntimes: Array<SteamArkSocialRuntimeHandle>
  ): Promise<void> {
    for (let index: number = 0; index < oldRuntimes.length; index++) {
      await this.closeRuntimeHandle(oldRuntimes[index]);
    }
    if (this.runtimeConfigurationGeneration !== disposedConfigurationGeneration || !this.disposed) {
      SteamArkLog.debug(TAG, 'stale social dispose cleanup skipped; disposedConfiguration=' +
        disposedConfigurationGeneration.toString() + ', currentConfiguration=' +
        this.runtimeConfigurationGeneration.toString());
      return;
    }
    this.snapshots.clear();
    this.conversations.clear();
    this.emoticons.clear();
    this.listeners.clear();
    this.syncTasks.clear();
    this.syncTaskGenerations.clear();
    this.syncTaskConfigurationGenerations.clear();
    this.runtimeGenerations.clear();
    this.runtimeConfigurationGenerations.clear();
    this.cacheWriteTails.clear();
  }

  private async connectAndSyncInternal(
    accountId: string,
    generation: number,
    configurationGeneration: number
  ): Promise<SteamArkSocialSnapshot> {
    if (accountId.length <= 0) {
      throw new Error('Steam social account is required');
    }
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(accountId, generation);
    if (!this.snapshots.has(accountId)) {
      this.restoreCache(accountId, generation);
    }
    const cached: SteamArkSocialSnapshot = this.getSnapshot(accountId);
    SteamArkLog.info(TAG, 'social synchronization started; account=' + SteamArkLog.accountId(accountId) +
      ', cachedFriends=' + cached.friends.length.toString() + ', cachedSessions=' +
      cached.sessions.length.toString());
    this.setSnapshot(new SteamArkSocialSnapshot(accountId, SteamArkSocialConnectionState.CONNECTING,
      cached.friends, cached.sessions, cached.updatedAtEpochSeconds), generation, configurationGeneration);
    try {
      const runtime: ISteamArkSocialRuntime = await this.requireRuntime(accountId, generation, configurationGeneration);
      let friends: Array<SteamArkFriendProfile> = cached.friends;
      let sessions: Array<SteamArkChatSession> = cached.sessions;
      let warning: string = '';
      let cmConnected: boolean = false;
      try {
        // Establish the realtime CM channel before the slower profile requests.
        // This prevents incoming messages from being missed during startup.
        await runtime.connect();
        this.requireCurrentRuntimeConfiguration(configurationGeneration);
        this.requireCurrentCacheGeneration(accountId, generation);
        cmConnected = true;
        SteamArkLog.info(TAG, 'social realtime connection ready; account=' +
          SteamArkLog.accountId(accountId));
      } catch (error) {
        const cmWarning: string = 'Steam chat connection unavailable: ' + this.errorMessage(error);
        warning = cmWarning;
        SteamArkLog.warn(TAG, 'social CM connection failed; cached conversations retained; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
      try {
        friends = await runtime.syncFriends();
        this.requireCurrentRuntimeConfiguration(configurationGeneration);
        this.requireCurrentCacheGeneration(accountId, generation);
        SteamArkLog.info(TAG, 'friend synchronization published; account=' + SteamArkLog.accountId(accountId) +
          ', friends=' + friends.length.toString());
      } catch (error) {
        const friendWarning: string = 'Steam friend list unavailable: ' + this.errorMessage(error);
        warning = warning.length > 0 ? warning + '; ' + friendWarning : friendWarning;
        SteamArkLog.warn(TAG, 'friend sync failed; cached friends retained; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
      this.setSnapshot(new SteamArkSocialSnapshot(accountId, SteamArkSocialConnectionState.CONNECTING,
        friends, sessions, cached.updatedAtEpochSeconds, warning), generation, configurationGeneration);
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.requireCurrentCacheGeneration(accountId, generation);
      if (cmConnected) {
        try {
          sessions = await runtime.syncSessions();
          this.requireCurrentRuntimeConfiguration(configurationGeneration);
          this.requireCurrentCacheGeneration(accountId, generation);
          SteamArkLog.info(TAG, 'chat sessions published; account=' + SteamArkLog.accountId(accountId) +
            ', sessions=' + sessions.length.toString());
        } catch (error) {
          const sessionWarning: string = 'Steam chat sessions unavailable: ' + this.errorMessage(error);
          warning = warning.length > 0 ? warning + '; ' + sessionWarning : sessionWarning;
          SteamArkLog.warn(TAG, 'session sync failed; cached sessions retained; account=' +
            SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
        }
      }
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.requireCurrentCacheGeneration(accountId, generation);
      const snapshot: SteamArkSocialSnapshot = new SteamArkSocialSnapshot(
        accountId,
        SteamArkSocialConnectionState.CONNECTED,
        friends,
        sessions,
        Math.floor(Date.now() / 1000),
        warning
      );
      this.setSnapshot(snapshot, generation, configurationGeneration);
      await this.persist(accountId, generation, configurationGeneration);
      SteamArkLog.info(TAG, 'social synchronization completed; account=' + SteamArkLog.accountId(accountId) +
        ', friends=' + friends.length.toString() + ', sessions=' + sessions.length.toString() +
        ', warningPresent=' + String(warning.length > 0));
      return this.copySnapshot(snapshot);
    } catch (error) {
      if (!this.isCurrentRuntimeConfiguration(configurationGeneration)) {
        throw error instanceof Error ? error : new Error('Steam social service is disposed');
      }
      const failed: SteamArkSocialSnapshot = new SteamArkSocialSnapshot(
        accountId,
        SteamArkSocialConnectionState.ERROR,
        cached.friends,
        cached.sessions,
        cached.updatedAtEpochSeconds,
        this.errorMessage(error)
      );
      if (this.isCurrentCacheGeneration(accountId, generation)) {
        this.setSnapshot(failed, generation, configurationGeneration);
      }
      throw error instanceof Error ? error : new Error('Steam social synchronization failed');
    }
  }

  private async requireRuntime(
    accountId: string,
    generation: number,
    configurationGeneration: number
  ): Promise<ISteamArkSocialRuntime> {
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(accountId, generation);
    const existing: ISteamArkSocialRuntime | undefined = this.runtimes.get(accountId);
    if (existing !== undefined && this.runtimeGenerations.get(accountId) === generation &&
      this.runtimeConfigurationGenerations.get(accountId) === configurationGeneration) {
      return existing;
    }
    const factory: ISteamArkSocialRuntimeFactory | null = this.runtimeFactory;
    if (factory === null) {
      throw new Error('Steam social runtime is not configured');
    }
    await steamArkStateService.initialize();
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(accountId, generation);
    const state: SteamArkStateSnapshot = steamArkStateService.getSnapshot();
    const account: SteamArkAccountSnapshot | null = this.findAccount(state, accountId);
    if (account === null || account.session.state !== SteamSessionState.LOGGED_ON) {
      throw new Error('Steam account must be logged on before social synchronization');
    }
    const credentials: SteamCredentialSet = await steamArkStateService.getCredentials(accountId);
    if (credentials.accessToken.trim().length <= 0 && credentials.refreshToken.trim().length <= 0) {
      throw new Error('Steam social synchronization requires a persisted access or refresh token. Please sign in again.');
    }
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(accountId, generation);
    const proxyPassword: string = await steamArkStateService.getProxyPassword(accountId);
    this.requireCurrentRuntimeConfiguration(configurationGeneration);
    this.requireCurrentCacheGeneration(accountId, generation);
    const profile: SteamAccountProfile = account.profile;
    const runtime: ISteamArkSocialRuntime = factory.create(profile, credentials, proxyPassword,
      steamArkStateService.resolveAccountLocale(accountId));
    const concurrent: ISteamArkSocialRuntime | undefined = this.runtimes.get(accountId);
    if (concurrent !== undefined && this.runtimeGenerations.get(accountId) === generation &&
      this.runtimeConfigurationGenerations.get(accountId) === configurationGeneration) {
      await runtime.dispose();
      return concurrent;
    }
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      !this.isCurrentCacheGeneration(accountId, generation)) {
      await runtime.dispose();
      throw new Error('Steam social runtime configuration changed before creation completed');
    }
    const listener: SteamArkSocialEventListener = (event: SteamArkSocialEvent): void => {
      this.handleRuntimeEvent(event, generation, configurationGeneration);
    };
    runtime.addListener(listener);
    this.runtimeListeners.set(accountId, listener);
    this.runtimes.set(accountId, runtime);
    this.runtimeGenerations.set(accountId, generation);
    this.runtimeConfigurationGenerations.set(accountId, configurationGeneration);
    return runtime;
  }

  private async connectRealtime(accountId: string, configurationGeneration: number): Promise<void> {
    const generation: number = this.captureCacheGeneration(accountId);
    try {
      const runtime: ISteamArkSocialRuntime = await this.requireRuntime(
        accountId,
        generation,
        configurationGeneration
      );
      await runtime.connect();
      this.requireCurrentRuntimeConfiguration(configurationGeneration);
      this.requireCurrentCacheGeneration(accountId, generation);
      SteamArkLog.info(TAG, 'background realtime connection ready; account=' +
        SteamArkLog.accountId(accountId));
    } catch (error) {
      SteamArkLog.warn(TAG, 'background realtime connection failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private isFreshConnectedSnapshot(snapshot: SteamArkSocialSnapshot, freshnessSeconds: number): boolean {
    if (snapshot.state !== SteamArkSocialConnectionState.CONNECTED ||
      snapshot.errorMessage.trim().length > 0 || !Number.isSafeInteger(freshnessSeconds) ||
      freshnessSeconds <= 0 || !Number.isSafeInteger(snapshot.updatedAtEpochSeconds) ||
      snapshot.updatedAtEpochSeconds <= 0) {
      return false;
    }
    const nowEpochSeconds: number = Math.floor(Date.now() / 1000);
    const ageSeconds: number = nowEpochSeconds - snapshot.updatedAtEpochSeconds;
    return ageSeconds >= 0 && ageSeconds < freshnessSeconds;
  }

  private findAccount(snapshot: SteamArkStateSnapshot, accountId: string): SteamArkAccountSnapshot | null {
    for (let index: number = 0; index < snapshot.accounts.length; index++) {
      if (snapshot.accounts[index].profile.accountId === accountId) {
        return snapshot.accounts[index];
      }
    }
    return null;
  }

  private handleRuntimeEvent(
    event: SteamArkSocialEvent,
    generation: number,
    configurationGeneration: number
  ): void {
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      !this.isCurrentCacheGeneration(event.accountId, generation)) {
      SteamArkLog.debug(TAG, 'stale social runtime event ignored; account=' +
        SteamArkLog.accountId(event.accountId));
      return;
    }
    if (event.type === SteamArkSocialEventType.MESSAGE_RECEIVED && event.message !== null) {
      this.mergeConversationMessage(event.accountId, event.message, generation);
      this.updateSessionFromMessage(event.accountId, event.message, !event.message.outgoing, generation);
      SteamArkLog.info(TAG, 'incoming social message applied; account=' +
        SteamArkLog.accountId(event.accountId) + ', friend=' +
        SteamArkLog.steamId64(event.friendSteamId64) + ', outgoing=' +
        String(event.message.outgoing) + ', unreadIncrement=' + String(!event.message.outgoing));
      void this.persist(event.accountId, generation, configurationGeneration);
      this.emit(event.accountId, generation, configurationGeneration);
      if (!event.message.outgoing) {
        this.publishIncomingMessageNotification(event.accountId, event.message);
      }
      return;
    }
    if (event.type === SteamArkSocialEventType.ERROR) {
      const current: SteamArkSocialSnapshot = this.getSnapshot(event.accountId);
      this.setSnapshot(new SteamArkSocialSnapshot(event.accountId, SteamArkSocialConnectionState.ERROR,
        current.friends, current.sessions, current.updatedAtEpochSeconds, event.detail), generation,
        configurationGeneration);
      return;
    }
    if (event.type === SteamArkSocialEventType.MESSAGE_ACKNOWLEDGED) {
      this.markSessionRead(event.accountId, event.friendSteamId64, event.timestamp, generation);
      void this.persist(event.accountId, generation, configurationGeneration);
      this.emit(event.accountId, generation, configurationGeneration);
      return;
    }
    if (event.type === SteamArkSocialEventType.MESSAGE_REACTION_CHANGED) {
      this.applyReactionEvent(event, generation);
      void this.persist(event.accountId, generation, configurationGeneration);
      this.emit(event.accountId, generation, configurationGeneration);
      return;
    }
    if (event.type === SteamArkSocialEventType.SESSION_NOTICE_CHANGED) {
      this.setSessionNotice(event.accountId, event.friendSteamId64, event.active, generation);
      void this.persist(event.accountId, generation, configurationGeneration);
      this.emit(event.accountId, generation, configurationGeneration);
      return;
    }
    if (event.type === SteamArkSocialEventType.FRIEND_PRESENCE_CHANGED) {
      // Real-time CM persona pushes only refresh the in-memory snapshot; the
      // durable cache keeps the last full Web sync.
      const current: SteamArkSocialSnapshot = this.getSnapshot(event.accountId);
      const merged: Array<SteamArkFriendProfile> = this.mergePresenceChanges(current.friends, event.friends);
      this.setSnapshot(new SteamArkSocialSnapshot(event.accountId, current.state,
        merged, current.sessions, current.updatedAtEpochSeconds, current.errorMessage), generation,
        configurationGeneration);
      this.emit(event.accountId, generation, configurationGeneration);
    }
  }

  private mergePresenceChanges(
    current: Array<SteamArkFriendProfile>,
    changes: Array<SteamArkFriendProfile>
  ): Array<SteamArkFriendProfile> {
    const bySteamId: Map<string, SteamArkFriendProfile> = new Map<string, SteamArkFriendProfile>();
    for (let index: number = 0; index < current.length; index++) {
      bySteamId.set(current[index].steamId64, current[index]);
    }
    for (let index: number = 0; index < changes.length; index++) {
      bySteamId.set(changes[index].steamId64, changes[index]);
    }
    const merged: Array<SteamArkFriendProfile> = [];
    bySteamId.forEach((friend: SteamArkFriendProfile): void => {
      merged.push(friend);
    });
    merged.sort((left: SteamArkFriendProfile, right: SteamArkFriendProfile): number => {
      if (left.personaState !== right.personaState) return right.personaState - left.personaState;
      return left.displayName.localeCompare(right.displayName);
    });
    return merged;
  }

  private publishIncomingMessageNotification(accountId: string, message: SteamArkChatMessage): void {
    const publisher: ISteamArkSocialNotificationPublisher | null = this.notificationPublisher;
    if (publisher === null || message.message.trim().length <= 0) {
      return;
    }
    const senderDisplayName: string = this.resolveFriendDisplayName(accountId, message.friendSteamId64);
    SteamArkLog.debug(TAG, 'incoming chat notification publish started; account=' +
      SteamArkLog.accountId(accountId) + ', friend=' + SteamArkLog.steamId64(message.friendSteamId64));
    void publisher.publishIncomingMessage(accountId, message.friendSteamId64, senderDisplayName, message)
      .catch((error: Error): void => {
        SteamArkLog.warn(TAG, 'incoming chat notification publish failed; account=' +
          SteamArkLog.accountId(accountId) + ', friend=' +
          SteamArkLog.steamId64(message.friendSteamId64) + ', errorType=' +
          SteamArkLog.errorKind(error));
      });
  }

  private resolveFriendDisplayName(accountId: string, friendSteamId64: string): string {
    const snapshot: SteamArkSocialSnapshot = this.getSnapshot(accountId);
    for (let index: number = 0; index < snapshot.friends.length; index++) {
      const friend: SteamArkFriendProfile = snapshot.friends[index];
      if (friend.steamId64 === friendSteamId64) {
        return friend.displayName.trim();
      }
    }
    return '';
  }

  private applyReactionEvent(event: SteamArkSocialEvent, generation: number): void {
    if (!this.isCurrentCacheGeneration(event.accountId, generation)) {
      return;
    }
    const key: string = this.conversationKey(event.accountId, event.friendSteamId64);
    const current: Array<SteamArkChatMessage> | undefined = this.conversations.get(key);
    if (current === undefined) {
      return;
    }
    const values: Array<SteamArkChatMessage> = [];
    for (let index: number = 0; index < current.length; index++) {
      const message: SteamArkChatMessage = current[index];
      if (message.timestamp === event.timestamp && message.ordinal === event.ordinal) {
        values.push(new SteamArkChatMessage(message.id, message.friendSteamId64,
          message.senderAccountId32, message.message, message.timestamp, message.ordinal,
          message.outgoing, message.pending, message.failed,
          this.updatedReactions(message.reactions, event)));
      } else {
        values.push(message);
      }
    }
    this.conversations.set(key, values);
  }

  private updatedReactions(current: Array<SteamArkChatReaction>,
    event: SteamArkSocialEvent): Array<SteamArkChatReaction> {
    const values: Array<SteamArkChatReaction> = [];
    let matched: boolean = false;
    const reactorAccountId: number = event.reactorAccountId32;
    for (let index: number = 0; index < current.length; index++) {
      const item: SteamArkChatReaction = current[index];
      if (item.reactionType !== event.reactionType || item.reaction !== event.reaction) {
        values.push(item);
        continue;
      }
      matched = true;
      const reactors: Array<number> = item.reactorAccountIds.slice();
      const reactorIndex: number = reactors.indexOf(reactorAccountId);
      if (event.active && reactorIndex < 0) {
        reactors.push(reactorAccountId);
      } else if (!event.active && reactorIndex >= 0) {
        reactors.splice(reactorIndex, 1);
      }
      if (reactors.length > 0) {
        values.push(new SteamArkChatReaction(item.reactionType, item.reaction, reactors));
      }
    }
    if (!matched && event.active) {
      values.push(new SteamArkChatReaction(event.reactionType, event.reaction, [reactorAccountId]));
    }
    return values;
  }

  private mergeConversationMessage(accountId: string, message: SteamArkChatMessage, generation: number): void {
    if (!this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    const key: string = this.conversationKey(accountId, message.friendSteamId64);
    const current: Array<SteamArkChatMessage> | undefined = this.conversations.get(key);
    const values: Array<SteamArkChatMessage> = current === undefined ? [] : current;
    this.conversations.set(key, this.mergeMessages(values, [message]));
  }

  private mergeMessages(current: Array<SteamArkChatMessage>, incoming: Array<SteamArkChatMessage>): Array<SteamArkChatMessage> {
    const byId: Map<string, SteamArkChatMessage> = new Map<string, SteamArkChatMessage>();
    for (let index: number = 0; index < current.length; index++) {
      byId.set(current[index].id, current[index]);
    }
    for (let index: number = 0; index < incoming.length; index++) {
      byId.set(incoming[index].id, incoming[index]);
    }
    const result: Array<SteamArkChatMessage> = [];
    byId.forEach((value: SteamArkChatMessage): void => {
      result.push(value);
    });
    result.sort((left: SteamArkChatMessage, right: SteamArkChatMessage): number => {
      if (left.timestamp !== right.timestamp) {
        return left.timestamp - right.timestamp;
      }
      return left.ordinal - right.ordinal;
    });
    if (result.length > MAX_MESSAGES_PER_CONVERSATION) {
      return result.slice(result.length - MAX_MESSAGES_PER_CONVERSATION);
    }
    return result;
  }

  private updateSessionFromMessages(accountId: string, friendSteamId64: string,
    messages: Array<SteamArkChatMessage>, incrementUnread: boolean, generation: number): void {
    if (!this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    if (messages.length <= 0) {
      return;
    }
    this.updateSessionFromMessage(accountId, messages[messages.length - 1], incrementUnread, generation);
  }

  private updateSessionFromMessage(accountId: string, message: SteamArkChatMessage, incrementUnread: boolean,
    generation: number): void {
    if (!this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    const snapshot: SteamArkSocialSnapshot = this.getSnapshot(accountId);
    const sessions: Array<SteamArkChatSession> = [];
    let found: boolean = false;
    for (let index: number = 0; index < snapshot.sessions.length; index++) {
      const session: SteamArkChatSession = snapshot.sessions[index];
      if (session.friendSteamId64 === message.friendSteamId64) {
        sessions.push(new SteamArkChatSession(
          session.friendSteamId64,
          Math.max(session.lastMessageEpochSeconds, message.timestamp),
          session.lastViewEpochSeconds,
          incrementUnread ? session.unreadCount + 1 : session.unreadCount,
          session.suspicious
        ));
        found = true;
      } else {
        sessions.push(session);
      }
    }
    if (!found) {
      sessions.push(new SteamArkChatSession(message.friendSteamId64, message.timestamp, 0,
        incrementUnread ? 1 : 0, false));
    }
    sessions.sort((left: SteamArkChatSession, right: SteamArkChatSession): number =>
      right.lastMessageEpochSeconds - left.lastMessageEpochSeconds);
    this.snapshots.set(accountId, new SteamArkSocialSnapshot(accountId, snapshot.state, snapshot.friends,
      sessions, snapshot.updatedAtEpochSeconds, snapshot.errorMessage));
  }

  private markSessionRead(accountId: string, friendSteamId64: string, timestamp: number, generation: number): void {
    if (!this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    const snapshot: SteamArkSocialSnapshot = this.getSnapshot(accountId);
    const sessions: Array<SteamArkChatSession> = [];
    for (let index: number = 0; index < snapshot.sessions.length; index++) {
      const session: SteamArkChatSession = snapshot.sessions[index];
      sessions.push(session.friendSteamId64 === friendSteamId64
        ? new SteamArkChatSession(friendSteamId64, session.lastMessageEpochSeconds,
          Math.max(timestamp, session.lastViewEpochSeconds), 0, session.suspicious)
        : session);
    }
    this.snapshots.set(accountId, new SteamArkSocialSnapshot(accountId, snapshot.state, snapshot.friends,
      sessions, snapshot.updatedAtEpochSeconds, snapshot.errorMessage));
  }

  private clearSessionNotice(accountId: string, friendSteamId64: string, generation: number): void {
    this.setSessionNotice(accountId, friendSteamId64, false, generation);
  }

  private setSessionNotice(accountId: string, friendSteamId64: string, active: boolean, generation: number): void {
    if (!this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    const snapshot: SteamArkSocialSnapshot = this.getSnapshot(accountId);
    const sessions: Array<SteamArkChatSession> = [];
    for (let index: number = 0; index < snapshot.sessions.length; index++) {
      const session: SteamArkChatSession = snapshot.sessions[index];
      sessions.push(session.friendSteamId64 === friendSteamId64
        ? new SteamArkChatSession(friendSteamId64, session.lastMessageEpochSeconds,
          session.lastViewEpochSeconds, session.unreadCount, active)
        : session);
    }
    this.snapshots.set(accountId, new SteamArkSocialSnapshot(accountId, snapshot.state, snapshot.friends,
      sessions, snapshot.updatedAtEpochSeconds, snapshot.errorMessage));
  }

  private setSnapshot(
    snapshot: SteamArkSocialSnapshot,
    generation: number,
    configurationGeneration: number = this.runtimeConfigurationGeneration
  ): void {
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      !this.isCurrentCacheGeneration(snapshot.accountId, generation)) {
      return;
    }
    this.snapshots.set(snapshot.accountId, this.copySnapshot(snapshot));
    this.emit(snapshot.accountId, generation, configurationGeneration);
  }

  private emit(
    accountId: string,
    generation: number,
    configurationGeneration: number = this.runtimeConfigurationGeneration
  ): void {
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      !this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    const snapshot: SteamArkSocialSnapshot = this.getSnapshot(accountId);
    const listeners: Array<SteamArkSocialSnapshotListener> = [];
    this.listeners.forEach((listener: SteamArkSocialSnapshotListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index++) {
      try {
        listeners[index](snapshot);
      } catch (error) {
        SteamArkLog.warn(TAG, 'social snapshot listener failed; errorType=' + SteamArkLog.errorKind(error));
      }
    }
  }

  private copySnapshot(snapshot: SteamArkSocialSnapshot): SteamArkSocialSnapshot {
    return new SteamArkSocialSnapshot(snapshot.accountId, snapshot.state, snapshot.friends,
      snapshot.sessions, snapshot.updatedAtEpochSeconds, snapshot.errorMessage);
  }

  private async persist(
    accountId: string,
    generation: number,
    configurationGeneration: number = this.runtimeConfigurationGeneration
  ): Promise<void> {
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      !this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    const snapshot: SteamArkSocialSnapshot = this.getSnapshot(accountId);
    const friends: Array<SteamArkFriendCacheItem> = [];
    for (let index: number = 0; index < snapshot.friends.length; index++) {
      const item: SteamArkFriendProfile = snapshot.friends[index];
      friends.push({
        steamId64: item.steamId64,
        accountId32: item.accountId32,
        displayName: item.displayName,
        avatarUrl: item.avatarUrl,
        profileUrl: item.profileUrl,
        personaState: item.personaState,
        gameName: item.gameName,
        gameAppId: item.gameAppId,
        lastLogoffEpochSeconds: item.lastLogoffEpochSeconds,
        friendSinceEpochSeconds: item.friendSinceEpochSeconds
      });
    }
    const sessions: Array<SteamArkSessionCacheItem> = [];
    for (let index: number = 0; index < snapshot.sessions.length; index++) {
      const item: SteamArkChatSession = snapshot.sessions[index];
      sessions.push({
        friendSteamId64: item.friendSteamId64,
        lastMessageEpochSeconds: item.lastMessageEpochSeconds,
        lastViewEpochSeconds: item.lastViewEpochSeconds,
        unreadCount: item.unreadCount,
        suspicious: item.suspicious
      });
    }
    const messages: Array<SteamArkChatCacheItem> = [];
    const prefix: string = accountId + '|';
    this.conversations.forEach((values: Array<SteamArkChatMessage>, key: string): void => {
      if (!key.startsWith(prefix) || messages.length >= MAX_CACHED_MESSAGES) {
        return;
      }
      for (let index: number = 0; index < values.length && messages.length < MAX_CACHED_MESSAGES; index++) {
        const item: SteamArkChatMessage = values[index];
        messages.push({
          id: item.id,
          friendSteamId64: item.friendSteamId64,
          senderAccountId32: item.senderAccountId32,
          message: item.message,
          timestamp: item.timestamp,
          ordinal: item.ordinal,
          outgoing: item.outgoing,
          reactions: this.toReactionCache(item.reactions)
        });
      }
    });
    const emoticons: Array<SteamArkEmoticonCacheItem> = [];
    const emoticonValues: Array<SteamArkEmoticon> | undefined = this.emoticons.get(accountId);
    if (emoticonValues !== undefined) {
      for (let index: number = 0; index < emoticonValues.length; index++) {
        const item: SteamArkEmoticon = emoticonValues[index];
        emoticons.push({
          name: item.name,
          imageUrl: item.imageUrl,
          appId: item.appId,
          count: item.count,
          lastUsedEpochSeconds: item.lastUsedEpochSeconds
        });
      }
    }
    const document: SteamArkSocialCacheDocument = {
      accountId: accountId,
      generation: generation,
      updatedAtEpochSeconds: snapshot.updatedAtEpochSeconds,
      friends: friends,
      sessions: sessions,
      messages: messages,
      emoticons: emoticons
    };
    const serialized: string = JSON.stringify(document);
    await this.enqueueCachePersistence(accountId, generation, serialized, configurationGeneration);
  }

  private async enqueueCachePersistence(
    accountId: string,
    generation: number,
    serialized: string,
    configurationGeneration: number
  ): Promise<void> {
    const previous: Promise<void> | undefined = this.cacheWriteTails.get(accountId);
    const pending: Promise<void> = this.persistAfterPrevious(
      accountId,
      generation,
      serialized,
      previous,
      configurationGeneration
    );
    this.cacheWriteTails.set(accountId, pending);
    try {
      await pending;
    } finally {
      if (this.cacheWriteTails.get(accountId) === pending) {
        this.cacheWriteTails.delete(accountId);
      }
    }
  }

  private async persistAfterPrevious(
    accountId: string,
    generation: number,
    serialized: string,
    previous: Promise<void> | undefined,
    configurationGeneration: number
  ): Promise<void> {
    if (previous !== undefined) {
      try {
        await previous;
      } catch (error) {
        SteamArkLog.warn(TAG, 'previous social cache operation failed; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      !this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    const generationSaved: boolean = await ngfSettingsStoreFacade.setStringAsync(
      this.generationCacheKey(accountId), generation.toString());
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      !this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    if (!generationSaved) {
      SteamArkLog.warn(TAG, 'social cache generation persistence failed; account=' +
        SteamArkLog.accountId(accountId));
      return;
    }
    const saved: boolean = await ngfSettingsStoreFacade.setStringAsync(
      this.cacheKey(accountId, generation), serialized);
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration) ||
      !this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    if (!saved) {
      SteamArkLog.warn(TAG, 'social cache persistence failed; account=' + SteamArkLog.accountId(accountId));
      return;
    }
    await ngfSettingsStoreFacade.setStringAsync(this.legacyCacheKey(accountId), '');
  }

  private async clearCacheAfterRemoval(accountId: string, previousGeneration: number,
    nextGeneration: number): Promise<void> {
    const previous: Promise<void> | undefined = this.cacheWriteTails.get(accountId);
    const pending: Promise<void> = this.clearCacheAfterPrevious(accountId, previousGeneration, nextGeneration, previous);
    this.cacheWriteTails.set(accountId, pending);
    try {
      await pending;
    } finally {
      if (this.cacheWriteTails.get(accountId) === pending) {
        this.cacheWriteTails.delete(accountId);
      }
    }
  }

  private async clearCacheAfterPrevious(accountId: string, previousGeneration: number,
    nextGeneration: number, previous: Promise<void> | undefined): Promise<void> {
    if (previous !== undefined) {
      try {
        await previous;
      } catch (error) {
        SteamArkLog.warn(TAG, 'previous social cache operation failed before account cleanup; account=' +
          SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
    if (!this.isCurrentCacheGeneration(accountId, nextGeneration)) {
      return;
    }
    const generationSaved: boolean = await ngfSettingsStoreFacade.setStringAsync(
      this.generationCacheKey(accountId), nextGeneration.toString());
    if (!generationSaved) {
      SteamArkLog.warn(TAG, 'social cache generation persistence failed; account=' +
        SteamArkLog.accountId(accountId));
    }
    if (!this.isCurrentCacheGeneration(accountId, nextGeneration)) {
      return;
    }
    await ngfSettingsStoreFacade.setStringAsync(this.cacheKey(accountId, previousGeneration), '');
    await ngfSettingsStoreFacade.setStringAsync(this.legacyCacheKey(accountId), '');
  }

  private restoreCache(accountId: string, generation: number): void {
    if (!this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    let serialized: string = ngfSettingsStoreFacade.getString(this.cacheKey(accountId, generation), '');
    let legacy: boolean = false;
    if (serialized.length <= 0 && generation === DEFAULT_CACHE_GENERATION) {
      serialized = ngfSettingsStoreFacade.getString(this.legacyCacheKey(accountId), '');
      legacy = serialized.length > 0;
    }
    if (serialized.length <= 0) {
      return;
    }
    try {
      const document: SteamArkSocialCacheDocument = JSON.parse(serialized) as SteamArkSocialCacheDocument;
      if (document.accountId !== accountId || (!legacy && document.generation !== generation) ||
        document.updatedAtEpochSeconds <= 0) {
        this.removeInvalidCache(accountId, generation, legacy);
        return;
      }
      if (!this.isCurrentCacheGeneration(accountId, generation)) {
        return;
      }
      const friends: Array<SteamArkFriendProfile> = [];
      for (let index: number = 0; index < document.friends.length; index++) {
        const item: SteamArkFriendCacheItem = document.friends[index];
        friends.push(new SteamArkFriendProfile(item.steamId64, item.accountId32, item.displayName,
          item.avatarUrl, item.profileUrl, item.personaState, item.gameName,
          item.gameAppId === undefined ? '' : item.gameAppId,
          item.lastLogoffEpochSeconds, item.friendSinceEpochSeconds));
      }
      const sessions: Array<SteamArkChatSession> = [];
      for (let index: number = 0; index < document.sessions.length; index++) {
        const item: SteamArkSessionCacheItem = document.sessions[index];
        sessions.push(new SteamArkChatSession(item.friendSteamId64, item.lastMessageEpochSeconds,
          item.lastViewEpochSeconds, item.unreadCount, item.suspicious));
      }
      this.snapshots.set(accountId, new SteamArkSocialSnapshot(accountId,
        SteamArkSocialConnectionState.DISCONNECTED, friends, sessions, document.updatedAtEpochSeconds));
      for (let index: number = 0; index < document.messages.length; index++) {
        const item: SteamArkChatCacheItem = document.messages[index];
        const reactions: Array<SteamArkChatReaction> = this.restoreReactions(item.reactions);
        this.mergeConversationMessage(accountId, new SteamArkChatMessage(item.id, item.friendSteamId64,
          item.senderAccountId32, item.message, item.timestamp, item.ordinal, item.outgoing,
          false, false, reactions), generation);
      }
      const restoredEmoticons: Array<SteamArkEmoticon> = [];
      if (document.emoticons !== undefined) {
        for (let index: number = 0; index < document.emoticons.length; index++) {
          const item: SteamArkEmoticonCacheItem = document.emoticons[index];
          restoredEmoticons.push(new SteamArkEmoticon(item.name, item.imageUrl, item.appId,
            item.count, item.lastUsedEpochSeconds));
        }
      }
      this.emoticons.set(accountId, restoredEmoticons);
    } catch (error) {
      this.removeInvalidCache(accountId, generation, legacy);
      SteamArkLog.warn(TAG, 'invalid social cache ignored; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private removeInvalidCache(accountId: string, generation: number, legacy: boolean): void {
    if (!this.isCurrentCacheGeneration(accountId, generation)) {
      return;
    }
    const cacheKey: string = legacy
      ? this.legacyCacheKey(accountId)
      : this.cacheKey(accountId, generation);
    ngfSettingsStoreFacade.setString(cacheKey, '');
    SteamArkLog.warn(TAG, 'invalid social cache removed; account=' + SteamArkLog.accountId(accountId));
  }

  private toReactionCache(values: Array<SteamArkChatReaction>): Array<SteamArkReactionCacheItem> {
    const result: Array<SteamArkReactionCacheItem> = [];
    for (let index: number = 0; index < values.length; index++) {
      result.push({
        reactionType: values[index].reactionType,
        reaction: values[index].reaction,
        reactorAccountIds: values[index].reactorAccountIds.slice()
      });
    }
    return result;
  }

  private restoreReactions(values: Array<SteamArkReactionCacheItem> | undefined): Array<SteamArkChatReaction> {
    const result: Array<SteamArkChatReaction> = [];
    if (values === undefined) {
      return result;
    }
    for (let index: number = 0; index < values.length; index++) {
      result.push(new SteamArkChatReaction(values[index].reactionType, values[index].reaction,
        values[index].reactorAccountIds));
    }
    return result;
  }

  private captureRuntimeHandles(): Array<SteamArkSocialRuntimeHandle> {
    const handles: Array<SteamArkSocialRuntimeHandle> = [];
    this.runtimes.forEach((runtime: ISteamArkSocialRuntime, accountId: string): void => {
      const listener: SteamArkSocialEventListener | undefined = this.runtimeListeners.get(accountId);
      handles.push(new SteamArkSocialRuntimeHandle(
        accountId,
        runtime,
        listener === undefined ? null : listener
      ));
    });
    return handles;
  }

  private async closeRuntime(accountId: string): Promise<void> {
    const runtime: ISteamArkSocialRuntime | undefined = this.runtimes.get(accountId);
    if (runtime === undefined) {
      return;
    }
    const listener: SteamArkSocialEventListener | undefined = this.runtimeListeners.get(accountId);
    const handle = new SteamArkSocialRuntimeHandle(
      accountId,
      runtime,
      listener === undefined ? null : listener
    );
    await this.closeRuntimeHandle(handle);
  }

  private async closeRuntimeHandle(handle: SteamArkSocialRuntimeHandle): Promise<void> {
    if (handle.listener !== null) {
      handle.runtime.removeListener(handle.listener);
    }
    if (this.runtimes.get(handle.accountId) === handle.runtime) {
      this.runtimeListeners.delete(handle.accountId);
      this.runtimes.delete(handle.accountId);
      this.runtimeGenerations.delete(handle.accountId);
      this.runtimeConfigurationGenerations.delete(handle.accountId);
    }
    await handle.runtime.dispose();
  }

  private removeConversations(accountId: string): void {
    const prefix: string = accountId + '|';
    const keys: Array<string> = [];
    this.conversations.forEach((_values: Array<SteamArkChatMessage>, key: string): void => {
      if (key.startsWith(prefix)) {
        keys.push(key);
      }
    });
    for (let index: number = 0; index < keys.length; index++) {
      this.conversations.delete(keys[index]);
    }
  }

  private conversationKey(accountId: string, friendSteamId64: string): string {
    return accountId.trim() + '|' + friendSteamId64.trim();
  }

  private captureCacheGeneration(accountId: string): number {
    const normalized: string = accountId.trim();
    if (normalized.length <= 0) {
      return 0;
    }
    const inMemory: number | undefined = this.cacheGenerations.get(normalized);
    if (inMemory !== undefined) {
      return inMemory;
    }
    const serialized: string = ngfSettingsStoreFacade.getString(this.generationCacheKey(normalized), '').trim();
    const parsed: number = Number(serialized);
    const generation: number = Number.isFinite(parsed) && parsed >= DEFAULT_CACHE_GENERATION &&
      Math.floor(parsed) === parsed ? parsed : DEFAULT_CACHE_GENERATION;
    this.cacheGenerations.set(normalized, generation);
    return generation;
  }

  private isCurrentCacheGeneration(accountId: string, generation: number): boolean {
    return generation >= DEFAULT_CACHE_GENERATION &&
      this.captureCacheGeneration(accountId) === generation;
  }

  private isCurrentRuntimeConfiguration(configurationGeneration: number): boolean {
    return !this.disposed && configurationGeneration === this.runtimeConfigurationGeneration;
  }

  private requireCurrentRuntimeConfiguration(configurationGeneration: number): void {
    if (!this.isCurrentRuntimeConfiguration(configurationGeneration)) {
      throw new Error('Steam social runtime configuration changed before the operation completed');
    }
  }

  private requireCurrentCacheGeneration(accountId: string, generation: number): void {
    if (!this.isCurrentCacheGeneration(accountId, generation)) {
      throw new Error('Steam social account state changed before the operation completed');
    }
  }

  private generationCacheKey(accountId: string): string {
    return CACHE_GENERATION_PREFIX + encodeURIComponent(accountId.trim());
  }

  private cacheKey(accountId: string, generation: number): string {
    return CACHE_NAMESPACE + '.entry:' + encodeURIComponent(accountId.trim()) + '.g' + generation.toString();
  }

  private legacyCacheKey(accountId: string): string {
    return LEGACY_CACHE_PREFIX + accountId.trim();
  }

  private ensureAvailable(): void {
    if (this.disposed) {
      throw new Error('Steam social service is disposed');
    }
  }

  private errorMessage(error: Object): string {
    return error instanceof Error ? error.message : 'Unknown Steam social error';
  }
}

export const steamArkSocialService: SteamArkSocialService = new SteamArkSocialService();
