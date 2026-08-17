import {
  NGFHttpMethod,
  NGFHttpSession,
  NGFHttpSessionRequest,
  NGFHttpSessionResponse,
  NGFProxyConfiguration
} from 'ngf_framework';
import {
  SteamAccountProfile,
  SteamClientPersonaStateRequestFlags,
  SteamCmClient,
  SteamCmClientOptions,
  SteamCmDecodedMessage,
  SteamCmEndpoint,
  SteamCmEvent,
  SteamCmEventType,
  SteamCmUnifiedMessage,
  SteamCredentialSet,
  SteamFriendListEntry,
  SteamFriendMessage,
  SteamFriendMessageAck,
  SteamFriendMessagePage,
  SteamFriendMessageReaction,
  SteamFriendMessageReactionNotification,
  SteamFriendMessageSendResult,
  SteamFriendMessageSession,
  SteamFriendMessageSessionNotice,
  SteamFriendMessageSessions,
  SteamFriendMessagesCodec,
  SteamIncomingFriendMessage,
  SteamJsonParser,
  SteamJsonValue,
  SteamJsonValueKind,
  SteamPersonaStateEntry,
  SteamPlayerEmoticon,
  SteamPlayerEmoticonCodec,
  SteamPlayerNicknameEntry,
  SteamProxyKind,
  SteamSessionState
} from 'steam_core';
import {
  ISteamArkSocialRuntime,
  ISteamArkSocialRuntimeFactory,
  SteamArkChatMessage,
  SteamArkChatReaction,
  SteamArkChatSession,
  SteamArkEmoticon,
  SteamArkFriendProfile,
  SteamArkSocialEvent,
  SteamArkSocialEventListener,
  SteamArkSocialEventType
} from '../steamServices/SteamArkSocialContracts';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { SteamArkContentLocale } from '../steamServices/SteamArkRegionPolicy';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';
import { HarmonySteamCmClientFactory } from './HarmonySteamCmClientFactory';
import { HarmonySteamCmMultiDecompressor } from './HarmonySteamCmRuntime';
import { HarmonySteamCmWireTransportOptions } from './HarmonySteamCmWireTransport';

const TAG: string = 'HarmonySteamSocialRuntime';
const STEAM_ID64_BASE: string = '76561197960265728';
// Login access tokens target Steam's OAuth interfaces. The similarly named
// ISteamUser endpoints require a Web API key and return HTTP 400 for these tokens.
const GET_FRIEND_LIST_URL: string = 'https://api.steampowered.com/ISteamUserOAuth/GetFriendList/v0001/';
const GET_PLAYER_SUMMARIES_URL: string = 'https://api.steampowered.com/ISteamUserOAuth/GetUserSummaries/v0001/';
const STEAM_EMOTICON_CDN_URL: string = 'https://community.akamai.steamstatic.com/economy/emoticon/';
const STEAM_AVATAR_CDN_URL: string = 'https://community.cloudflare.steamstatic.com/steamcommunity/public/images/avatars/';
const PERSONA_REQUEST_BATCH_SIZE: number = 500;

export class HarmonySteamSocialRuntime implements ISteamArkSocialRuntime {
  readonly accountId: string;
  private readonly profile: SteamAccountProfile;
  private readonly credentials: SteamCredentialSet;
  private readonly proxy: NGFProxyConfiguration;
  private readonly cmLanguage: string;
  private readonly cmClient: SteamCmClient;
  private readonly listeners: Array<SteamArkSocialEventListener> = [];
  private readonly cmEventListener: (event: SteamCmEvent) => void;
  private readonly unifiedListener: (message: SteamCmUnifiedMessage) => void;
  /** Real-time presence cache merged from Web API sync and CM persona pushes. */
  private readonly friendProfiles: Map<string, SteamArkFriendProfile> = new Map<string, SteamArkFriendProfile>();
  private readonly friendNicknames: Map<string, string> = new Map<string, string>();
  private friendIds: Array<string> = [];
  private connected: boolean = false;
  private connectTask: Promise<void> | null = null;
  private disposed: boolean = false;

  constructor(profile: SteamAccountProfile, credentials: SteamCredentialSet, proxyPassword: string,
    locale: SteamArkContentLocale | null = null) {
    this.accountId = profile.accountId;
    this.profile = profile;
    this.credentials = credentials;
    this.proxy = HarmonySteamSocialRuntime.toProxy(profile, proxyPassword);
    this.cmLanguage = locale !== null ? locale.steamLanguage : 'schinese';
    const options: SteamCmClientOptions = new SteamCmClientOptions(
      SteamCmEndpoint.DEFAULT_SERVER,
      profile.steamId64,
      ASFWorkshopProductIdentity.DEVICE_FRIENDLY_NAME + ' Social',
      65581,
      1771,
      this.cmLanguage,
      0,
      30,
      2,
      60,
      0,
      32,
      '',
      '',
      true,
      false,
      steamArkCoreLogger,
      30000,
      new HarmonySteamCmMultiDecompressor()
    );
    this.cmClient = HarmonySteamCmClientFactory.create(
      this.accountId,
      credentials,
      options,
      new HarmonySteamCmWireTransportOptions(this.proxy, ASFWorkshopProductIdentity.userAgent('SocialCm'))
    );
    this.cmEventListener = (event: SteamCmEvent): void => {
      this.handleCmEvent(event);
    };
    this.unifiedListener = (message: SteamCmUnifiedMessage): void => {
      this.handleUnifiedMessage(message);
    };
    this.cmClient.addEventListener(this.cmEventListener);
    this.cmClient.addUnifiedMessageListener(this.unifiedListener);
  }

  async connect(): Promise<void> {
    this.ensureAvailable();
    if (this.connected && this.cmClient.session.state === SteamSessionState.LOGGED_ON) {
      return;
    }
    if (this.connectTask !== null) {
      await this.connectTask;
      return;
    }
    const task: Promise<void> = this.connectInternal();
    this.connectTask = task;
    try {
      await task;
    } finally {
      if (this.connectTask === task) {
        this.connectTask = null;
      }
    }
  }

  private async connectInternal(): Promise<void> {
    await this.cmClient.connect();
    for (let attempt: number = 0; attempt < 45; attempt++) {
      this.ensureAvailable();
      if (this.cmClient.session.state === SteamSessionState.LOGGED_ON) {
        this.connected = true;
        return;
      }
      if (this.cmClient.session.state === SteamSessionState.ERROR ||
        this.cmClient.session.state === SteamSessionState.EXPIRED ||
        this.cmClient.session.state === SteamSessionState.NEEDS_EMAIL_CODE ||
        this.cmClient.session.state === SteamSessionState.NEEDS_TWO_FACTOR) {
        throw new Error('Steam social CM login failed; state=' + String(this.cmClient.session.state));
      }
      await this.wait(1000);
    }
    throw new Error('Steam social CM login timed out after 45 seconds; friends can still use the Web API and cached chats remain available');
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    this.connectTask = null;
    await this.cmClient.disconnect();
  }

  async syncFriends(): Promise<Array<SteamArkFriendProfile>> {
    this.ensureAvailable();
    SteamArkLog.info(TAG, 'friend synchronization started; account=' + SteamArkLog.accountId(this.accountId));
    const session: NGFHttpSession = new NGFHttpSession();
    try {
      const friendListResponse: NGFHttpSessionResponse = await this.get(session,
        GET_FRIEND_LIST_URL + '?access_token=' + encodeURIComponent(this.credentials.accessToken) +
          '&steamid=' + encodeURIComponent(this.profile.steamId64) + '&relationship=friend');
      if (!friendListResponse.isOk()) {
        throw new Error('Steam friend list returned HTTP ' + friendListResponse.statusCode.toString());
      }
      const friendSince: Map<string, number> = new Map<string, number>();
      const steamIds: Array<string> = this.readFriendIds(friendListResponse.body, friendSince);
      SteamArkLog.info(TAG, 'friend identifiers parsed; account=' + SteamArkLog.accountId(this.accountId) +
        ', count=' + steamIds.length.toString() + ', bodyBytes=' + friendListResponse.body.length.toString());
      const result: Array<SteamArkFriendProfile> = [];
      for (let offset: number = 0; offset < steamIds.length; offset += 100) {
        const chunk: Array<string> = steamIds.slice(offset, Math.min(offset + 100, steamIds.length));
        const summariesResponse: NGFHttpSessionResponse = await this.get(session,
          GET_PLAYER_SUMMARIES_URL + '?access_token=' + encodeURIComponent(this.credentials.accessToken) +
            '&steamids=' + encodeURIComponent(chunk.join(',')));
        if (!summariesResponse.isOk()) {
          throw new Error('Steam friend profiles returned HTTP ' + summariesResponse.statusCode.toString());
        }
        this.appendProfiles(summariesResponse.body, friendSince, result);
      }
      this.mergeFriendsIntoCache(result);
      result.sort((left: SteamArkFriendProfile, right: SteamArkFriendProfile): number => {
        if (left.personaState !== right.personaState) return right.personaState - left.personaState;
        return left.displayName.localeCompare(right.displayName);
      });
      SteamArkLog.info(TAG, 'friend synchronization completed; account=' + SteamArkLog.accountId(this.accountId) +
        ', profiles=' + result.length.toString());
      return result;
    } finally {
      session.clear();
    }
  }

  async syncSessions(): Promise<Array<SteamArkChatSession>> {
    SteamArkLog.info(TAG, 'chat session synchronization started; account=' + SteamArkLog.accountId(this.accountId));
    await this.connect();
    const response: SteamCmDecodedMessage = await this.cmClient.call(
      'FriendMessages.GetActiveMessageSessions#1',
      SteamFriendMessagesCodec.encodeGetActiveSessions(0, true)
    );
    const decoded: SteamFriendMessageSessions = SteamFriendMessagesCodec.decodeActiveSessions(response.body);
    const result: Array<SteamArkChatSession> = [];
    for (let index: number = 0; index < decoded.sessions.length; index++) {
      const session: SteamFriendMessageSession = decoded.sessions[index];
      result.push(new SteamArkChatSession(
        HarmonySteamSocialRuntime.accountIdToSteamId64(session.friendAccountId),
        session.lastMessageTimestamp,
        session.lastViewTimestamp,
        session.unreadCount,
        session.notices.includes(1)
      ));
    }
    result.sort((left: SteamArkChatSession, right: SteamArkChatSession): number =>
      right.lastMessageEpochSeconds - left.lastMessageEpochSeconds);
    SteamArkLog.info(TAG, 'chat session synchronization completed; account=' +
      SteamArkLog.accountId(this.accountId) + ', sessions=' + result.length.toString());
    return result;
  }

  async loadMessages(
    friendSteamId64: string,
    count: number,
    beforeTimestamp: number = 0,
    beforeOrdinal: number = 0
  ): Promise<Array<SteamArkChatMessage>> {
    await this.connect();
    const response: SteamCmDecodedMessage = await this.cmClient.call(
      'FriendMessages.GetRecentMessages#1',
      SteamFriendMessagesCodec.encodeGetRecentMessages(
        this.profile.steamId64,
        friendSteamId64,
        count,
        0,
        0,
        beforeTimestamp,
        beforeOrdinal
      )
    );
    const page: SteamFriendMessagePage = SteamFriendMessagesCodec.decodeRecentMessages(response.body);
    const ownerAccountId: number = HarmonySteamSocialRuntime.steamId64ToAccountId(this.profile.steamId64);
    const result: Array<SteamArkChatMessage> = [];
    for (let index: number = 0; index < page.messages.length; index++) {
      const value: SteamFriendMessage = page.messages[index];
      result.push(new SteamArkChatMessage(
        this.messageId(friendSteamId64, value.timestamp, value.ordinal, value.accountId),
        friendSteamId64,
        value.accountId,
        value.message,
        value.timestamp,
        value.ordinal,
        value.accountId === ownerAccountId,
        false,
        false,
        this.toChatReactions(value.reactions)
      ));
    }
    result.sort((left: SteamArkChatMessage, right: SteamArkChatMessage): number => {
      if (left.timestamp !== right.timestamp) return left.timestamp - right.timestamp;
      return left.ordinal - right.ordinal;
    });
    return result;
  }

  async loadEmoticons(): Promise<Array<SteamArkEmoticon>> {
    await this.connect();
    const response: SteamCmDecodedMessage = await this.cmClient.call(
      'Player.GetEmoticonList#1', SteamPlayerEmoticonCodec.encodeGetEmoticonList());
    const decoded: Array<SteamPlayerEmoticon> =
      SteamPlayerEmoticonCodec.decodeGetEmoticonList(response.body);
    const result: Array<SteamArkEmoticon> = [];
    for (let index: number = 0; index < decoded.length; index++) {
      const item: SteamPlayerEmoticon = decoded[index];
      const name: string = this.normalizeEmoticonName(item.name);
      if (name.length <= 0 || item.count <= 0) {
        continue;
      }
      result.push(new SteamArkEmoticon(name, STEAM_EMOTICON_CDN_URL + encodeURIComponent(name),
        item.appId, item.count, item.lastUsed));
    }
    result.sort((left: SteamArkEmoticon, right: SteamArkEmoticon): number => {
      if (left.lastUsedEpochSeconds !== right.lastUsedEpochSeconds) {
        return right.lastUsedEpochSeconds - left.lastUsedEpochSeconds;
      }
      return left.name.localeCompare(right.name);
    });
    SteamArkLog.info(TAG, 'Steam emoticon synchronization completed; account=' +
      SteamArkLog.accountId(this.accountId) + ', count=' + result.length.toString());
    return result;
  }

  async sendMessage(friendSteamId64: string, message: string): Promise<SteamArkChatMessage> {
    const normalizedFriendId: string = friendSteamId64.trim();
    const normalizedMessage: string = message.trim();
    SteamArkLog.info(TAG, 'chat send requested; account=' + SteamArkLog.accountId(this.accountId) +
      ', friend=' + SteamArkLog.steamId64(normalizedFriendId) +
      ', messageLength=' + normalizedMessage.length.toString());
    try {
      await this.connect();
      SteamArkLog.debug(TAG, 'chat send payload prepared; account=' + SteamArkLog.accountId(this.accountId) +
        ', friend=' + SteamArkLog.steamId64(normalizedFriendId) +
        ', chatEntryType=1, containsBbCode=true, echoToSender=false, lowPriority=false, clientMessageId=false');
      const response: SteamCmDecodedMessage = await this.cmClient.call(
        'FriendMessages.SendMessage#1',
        SteamFriendMessagesCodec.encodeSendMessage(normalizedFriendId, normalizedMessage, true)
      );
      const sent: SteamFriendMessageSendResult = SteamFriendMessagesCodec.decodeSendResult(response.body);
      const timestamp: number = sent.serverTimestamp > 0 ? sent.serverTimestamp : Math.floor(Date.now() / 1000);
      const content: string = sent.modifiedMessage.length > 0
        ? sent.modifiedMessage
        : sent.plainMessage.length > 0 ? sent.plainMessage : normalizedMessage;
      SteamArkLog.info(TAG, 'chat send acknowledged; account=' + SteamArkLog.accountId(this.accountId) +
        ', friend=' + SteamArkLog.steamId64(normalizedFriendId) +
        ', responseBytes=' + response.body.length.toString() +
        ', timestamp=' + timestamp.toString() + ', ordinal=' + sent.ordinal.toString());
      return new SteamArkChatMessage(
        this.messageId(normalizedFriendId, timestamp, sent.ordinal,
          HarmonySteamSocialRuntime.steamId64ToAccountId(this.profile.steamId64)),
        normalizedFriendId,
        HarmonySteamSocialRuntime.steamId64ToAccountId(this.profile.steamId64),
        content,
        timestamp,
        sent.ordinal,
        true
      );
    } catch (error) {
      const detail: string = error instanceof Error ? error.message : 'Steam chat send failed';
      SteamArkLog.warn(TAG, 'chat send failed; account=' + SteamArkLog.accountId(this.accountId) +
        ', friend=' + SteamArkLog.steamId64(normalizedFriendId) +
        ', errorType=' + SteamArkLog.errorKind(error) + ', detail=' + detail);
      throw error instanceof Error ? error : new Error('Steam chat send failed');
    }
  }

  async acknowledge(friendSteamId64: string, timestamp: number): Promise<void> {
    await this.connect();
    await this.cmClient.notify('FriendMessages.AckMessage#1',
      SteamFriendMessagesCodec.encodeAckMessage(friendSteamId64, timestamp));
  }

  async updateReaction(friendSteamId64: string, timestamp: number, ordinal: number,
    reactionType: number, reaction: string, isAdd: boolean): Promise<void> {
    await this.connect();
    await this.cmClient.call('FriendMessages.UpdateMessageReaction#1',
      SteamFriendMessagesCodec.encodeUpdateReaction(friendSteamId64, timestamp, ordinal,
        reactionType, reaction, isAdd));
  }

  async reportMessage(fromSteamId64: string, toSteamId64: string, timestamp: number,
    ordinal: number, reason: number, reportText: string): Promise<void> {
    await this.connect();
    await this.cmClient.call('FriendMessages.ReportMessage#1',
      SteamFriendMessagesCodec.encodeReportMessage(fromSteamId64, toSteamId64, timestamp,
        ordinal, reason, reportText, this.cmLanguage));
  }

  async dismissSessionNotice(friendSteamId64: string, noticeType: number): Promise<void> {
    await this.connect();
    await this.cmClient.notify('FriendMessages.DismissSessionNotice#1',
      SteamFriendMessagesCodec.encodeDismissSessionNotice(friendSteamId64, noticeType));
  }

  addListener(listener: SteamArkSocialEventListener): void {
    if (this.listeners.indexOf(listener) < 0) this.listeners.push(listener);
  }

  removeListener(listener: SteamArkSocialEventListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  async dispose(): Promise<void> {
    if (this.disposed) return;
    this.disposed = true;
    this.connectTask = null;
    this.cmClient.removeEventListener(this.cmEventListener);
    this.cmClient.removeUnifiedMessageListener(this.unifiedListener);
    try {
      await this.cmClient.disconnect();
    } finally {
      this.cmClient.dispose();
      this.listeners.splice(0, this.listeners.length);
    }
  }

  private handleCmEvent(event: SteamCmEvent): void {
    if (event.type === SteamCmEventType.LOGGED_ON) this.connected = true;
    if (event.type === SteamCmEventType.DISCONNECTED || event.type === SteamCmEventType.EXPIRED ||
      event.type === SteamCmEventType.ERROR) this.connected = false;
    if (event.type === SteamCmEventType.ERROR || event.type === SteamCmEventType.EXPIRED) {
      this.emit(new SteamArkSocialEvent(SteamArkSocialEventType.ERROR, this.accountId, '', null, event.message));
    }
    if (event.type === SteamCmEventType.FRIENDS_LIST && event.friendsList !== null) {
      this.handleFriendsList(event.friendsList.friends, event.friendsList.incremental);
    } else if (event.type === SteamCmEventType.PERSONA_STATE && event.personaStates !== null) {
      this.handlePersonaStates(event.personaStates.friends);
    } else if (event.type === SteamCmEventType.PLAYER_NICKNAMES && event.playerNicknames !== null) {
      this.handlePlayerNicknames(event.playerNicknames.nicknames);
    }
  }

  /** Stores the CM friends list and asks Steam to push persona state for friends. */
  private handleFriendsList(entries: Array<SteamFriendListEntry>, incremental: boolean): void {
    const friendIds: Array<string> = [];
    for (let index: number = 0; index < entries.length; index++) {
      const entry: SteamFriendListEntry = entries[index];
      if (entry.steamId64.length <= 0 || entry.steamId64 === '0') {
        continue;
      }
      friendIds.push(entry.steamId64);
    }
    if (!incremental || this.friendIds.length <= 0) {
      this.friendIds = friendIds.slice();
    } else {
      const merged: Array<string> = this.friendIds.slice();
      const known: Map<string, boolean> = new Map<string, boolean>();
      for (let index = 0; index < merged.length; index++) {
        known.set(merged[index], true);
      }
      for (let index = 0; index < friendIds.length; index++) {
        if (!known.has(friendIds[index])) {
          merged.push(friendIds[index]);
        }
      }
      this.friendIds = merged;
    }
    SteamArkLog.debug(TAG, 'CM friends list stored; account=' + SteamArkLog.accountId(this.accountId) +
      ', friends=' + this.friendIds.length.toString() + ', incremental=' + String(incremental));
    if (this.friendIds.length > 0) {
      this.requestPersonaDataForFriends().catch((error: Error): void => {
        SteamArkLog.warn(TAG, 'CM persona data request failed; account=' +
          SteamArkLog.accountId(this.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      });
    }
  }

  private async requestPersonaDataForFriends(): Promise<void> {
    for (let offset: number = 0; offset < this.friendIds.length; offset += PERSONA_REQUEST_BATCH_SIZE) {
      const chunk: Array<string> = this.friendIds.slice(
        offset, Math.min(offset + PERSONA_REQUEST_BATCH_SIZE, this.friendIds.length));
      const sent: boolean = await this.cmClient.requestFriendsPersonaData(
        chunk, SteamClientPersonaStateRequestFlags.DEFAULT);
      if (!sent) {
        return;
      }
    }
  }

  /** Merges persona pushes into the profile cache and emits one presence event. */
  private handlePersonaStates(entries: Array<SteamPersonaStateEntry>): void {
    const changed: Array<SteamArkFriendProfile> = [];
    for (let index: number = 0; index < entries.length; index++) {
      const entry: SteamPersonaStateEntry = entries[index];
      if (!this.isKnownFriend(entry.steamId64)) {
        continue;
      }
      const existing: SteamArkFriendProfile | undefined = this.friendProfiles.get(entry.steamId64);
      const nickname: string = this.friendNicknames.get(entry.steamId64) ?? '';
      const displayName: string = nickname.length > 0
        ? nickname
        : (entry.playerName.length > 0
          ? entry.playerName
          : (existing !== undefined ? existing.displayName : ''));
      const avatarUrl: string = existing !== undefined && existing.avatarUrl.length > 0
        ? existing.avatarUrl
        : this.buildAvatarUrl(entry.avatarHashHex);
      const profileUrl: string = existing !== undefined && existing.profileUrl.length > 0
        ? existing.profileUrl
        : 'https://steamcommunity.com/profiles/' + entry.steamId64 + '/';
      const updated: SteamArkFriendProfile = new SteamArkFriendProfile(
        entry.steamId64,
        HarmonySteamSocialRuntime.steamId64ToAccountId(entry.steamId64),
        displayName,
        avatarUrl,
        profileUrl,
        entry.personaState,
        entry.gameName,
        entry.gameAppId,
        entry.lastLogoffEpochSeconds,
        existing !== undefined ? existing.friendSinceEpochSeconds : 0
      );
      if (existing !== undefined &&
        existing.personaState === updated.personaState &&
        existing.gameAppId === updated.gameAppId &&
        existing.displayName === updated.displayName &&
        existing.gameName === updated.gameName) {
        continue;
      }
      this.friendProfiles.set(entry.steamId64, updated);
      changed.push(updated);
    }
    if (changed.length <= 0) {
      return;
    }
    SteamArkLog.debug(TAG, 'CM persona state applied; account=' + SteamArkLog.accountId(this.accountId) +
      ', changed=' + changed.length.toString());
    this.emit(new SteamArkSocialEvent(
      SteamArkSocialEventType.FRIEND_PRESENCE_CHANGED, this.accountId, '', null, '', 0, 0, 0, '', '',
      false, 0, 0, changed));
  }

  private handlePlayerNicknames(nicknames: Array<SteamPlayerNicknameEntry>): void {
    for (let index: number = 0; index < nicknames.length; index++) {
      const entry: SteamPlayerNicknameEntry = nicknames[index];
      if (entry.steamId64.length <= 0 || entry.steamId64 === '0') {
        continue;
      }
      this.friendNicknames.set(entry.steamId64, entry.nickname);
    }
  }

  private mergeFriendsIntoCache(friends: Array<SteamArkFriendProfile>): void {
    for (let index: number = 0; index < friends.length; index++) {
      const friend: SteamArkFriendProfile = friends[index];
      if (friend.steamId64.length <= 0 || friend.steamId64 === '0') {
        continue;
      }
      const nickname: string = this.friendNicknames.get(friend.steamId64) ?? '';
      const cached: SteamArkFriendProfile | undefined = this.friendProfiles.get(friend.steamId64);
      if (nickname.length > 0 && nickname !== friend.displayName) {
        this.friendProfiles.set(friend.steamId64, new SteamArkFriendProfile(
          friend.steamId64, friend.accountId32, nickname, friend.avatarUrl, friend.profileUrl,
          friend.personaState, friend.gameName, friend.gameAppId, friend.lastLogoffEpochSeconds,
          friend.friendSinceEpochSeconds));
        continue;
      }
      if (cached === undefined || cached.displayName.length <= 0) {
        this.friendProfiles.set(friend.steamId64, friend);
      }
    }
    const knownIds: Map<string, boolean> = new Map<string, boolean>();
    for (let index: number = 0; index < friends.length; index++) {
      knownIds.set(friends[index].steamId64, true);
    }
    const dropped: Array<string> = [];
    this.friendProfiles.forEach((_value: SteamArkFriendProfile, steamId64: string): void => {
      if (!knownIds.has(steamId64)) {
        dropped.push(steamId64);
      }
    });
    for (let index: number = 0; index < dropped.length; index++) {
      this.friendProfiles.delete(dropped[index]);
    }
    if (this.friendIds.length <= 0) {
      this.friendIds = friends.map((friend: SteamArkFriendProfile): string => friend.steamId64);
    }
  }

  private isKnownFriend(steamId64: string): boolean {
    if (this.friendIds.indexOf(steamId64) >= 0) {
      return true;
    }
    return this.friendProfiles.has(steamId64);
  }

  private buildAvatarUrl(avatarHashHex: string): string {
    if (avatarHashHex.length !== 40) {
      return '';
    }
    return STEAM_AVATAR_CDN_URL + avatarHashHex.substring(0, 2) + '/' + avatarHashHex + '_medium.jpg';
  }

  private handleUnifiedMessage(message: SteamCmUnifiedMessage): void {
    try {
      if (message.methodName.indexOf('FriendMessagesClient.') >= 0) {
        SteamArkLog.debug(TAG, 'friend message notification received; account=' +
          SteamArkLog.accountId(this.accountId) + ', method=' + message.methodName +
          ', bodyBytes=' + message.body.length.toString());
      }
      if (message.methodName.indexOf('FriendMessagesClient.IncomingMessage') >= 0) {
        const incoming: SteamIncomingFriendMessage = SteamFriendMessagesCodec.decodeIncomingMessage(message.body);
        const content: string = incoming.plainMessage.length > 0 ? incoming.plainMessage : incoming.message;
        const item: SteamArkChatMessage = new SteamArkChatMessage(
          this.messageId(incoming.friendSteamId64, incoming.serverTimestamp, incoming.ordinal,
            incoming.localEcho
              ? HarmonySteamSocialRuntime.steamId64ToAccountId(this.profile.steamId64)
              : HarmonySteamSocialRuntime.steamId64ToAccountId(incoming.friendSteamId64)),
          incoming.friendSteamId64,
          incoming.localEcho
            ? HarmonySteamSocialRuntime.steamId64ToAccountId(this.profile.steamId64)
            : HarmonySteamSocialRuntime.steamId64ToAccountId(incoming.friendSteamId64),
          content,
          incoming.serverTimestamp,
          incoming.ordinal,
          incoming.localEcho
        );
        SteamArkLog.info(TAG, 'incoming friend message decoded; account=' +
          SteamArkLog.accountId(this.accountId) + ', friend=' +
          SteamArkLog.steamId64(incoming.friendSteamId64) + ', timestamp=' +
          incoming.serverTimestamp.toString() + ', ordinal=' + incoming.ordinal.toString() +
          ', localEcho=' + String(incoming.localEcho) + ', contentLength=' + content.length.toString());
        this.emit(new SteamArkSocialEvent(SteamArkSocialEventType.MESSAGE_RECEIVED,
          this.accountId, incoming.friendSteamId64, item));
      } else if (message.methodName.indexOf('FriendMessagesClient.NotifyAckMessageEcho') >= 0) {
        const ack: SteamFriendMessageAck = SteamFriendMessagesCodec.decodeAckMessage(message.body);
        this.emit(new SteamArkSocialEvent(SteamArkSocialEventType.MESSAGE_ACKNOWLEDGED,
          this.accountId, ack.friendSteamId64, null, '', ack.timestamp));
      } else if (message.methodName.indexOf('FriendMessagesClient.MessageReaction') >= 0) {
        const reaction: SteamFriendMessageReactionNotification =
          SteamFriendMessagesCodec.decodeReactionNotification(message.body);
        this.emit(new SteamArkSocialEvent(SteamArkSocialEventType.MESSAGE_REACTION_CHANGED,
          this.accountId, reaction.friendSteamId64, null, '', reaction.serverTimestamp,
          reaction.ordinal, reaction.reactionType, reaction.reaction, reaction.reactorSteamId64,
          reaction.isAdd, 0, HarmonySteamSocialRuntime.steamId64ToAccountId(reaction.reactorSteamId64)));
      } else if (message.methodName.indexOf('FriendMessagesClient.SessionNotice') >= 0) {
        const notice: SteamFriendMessageSessionNotice = SteamFriendMessagesCodec.decodeSessionNotice(message.body);
        this.emit(new SteamArkSocialEvent(SteamArkSocialEventType.SESSION_NOTICE_CHANGED,
          this.accountId, notice.friendSteamId64, null, '', 0, 0, 0, '', '', notice.active,
          notice.noticeType));
      }
    } catch (error) {
      this.emit(new SteamArkSocialEvent(SteamArkSocialEventType.ERROR, this.accountId, '', null,
        error instanceof Error ? error.message : 'Incoming Steam message could not be decoded'));
    }
  }

  private toChatReactions(values: Array<SteamFriendMessageReaction>): Array<SteamArkChatReaction> {
    const result: Array<SteamArkChatReaction> = [];
    for (let index: number = 0; index < values.length; index++) {
      result.push(new SteamArkChatReaction(values[index].reactionType, values[index].reaction,
        values[index].reactors));
    }
    return result;
  }

  private normalizeEmoticonName(value: string): string {
    let name: string = value.trim();
    if (name.startsWith(':') && name.endsWith(':') && name.length > 2) {
      name = name.substring(1, name.length - 1);
    }
    return name;
  }

  private emit(event: SteamArkSocialEvent): void {
    const listeners: Array<SteamArkSocialEventListener> = this.listeners.slice();
    for (let index: number = 0; index < listeners.length; index++) {
      try { listeners[index](event); } catch (_error) { SteamArkLog.warn(TAG, 'social listener failed'); }
    }
  }

  private async get(session: NGFHttpSession, url: string): Promise<NGFHttpSessionResponse> {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('Social'));
    return await session.request(new NGFHttpSessionRequest(
      NGFHttpMethod.GET, url, headers, '', 20000, false, this.proxy));
  }

  private readFriendIds(body: string, friendSince: Map<string, number>): Array<string> {
    const root: SteamJsonValue = SteamJsonParser.parse(body, steamArkCoreLogger);
    const friendsList: SteamJsonValue | null = root.getProperty('friendslist');
    const response: SteamJsonValue | null = root.getProperty('response');
    const nestedFriends: SteamJsonValue | null = friendsList === null ? null : friendsList.getProperty('friends');
    const responseFriends: SteamJsonValue | null = response === null ? null : response.getProperty('friends');
    const rootFriends: SteamJsonValue | null = root.getProperty('friends');
    const friends: SteamJsonValue | null = nestedFriends !== null
      ? nestedFriends : (responseFriends !== null ? responseFriends : rootFriends);
    const result: Array<string> = [];
    if (friends === null || friends.kind !== SteamJsonValueKind.ARRAY) return result;
    for (let index: number = 0; index < friends.items.length; index++) {
      const item: SteamJsonValue = friends.items[index];
      if (item.kind !== SteamJsonValueKind.OBJECT) continue;
      const steamId64: string = this.readText(item.getProperty('steamid'));
      if (steamId64.length <= 0) continue;
      result.push(steamId64);
      friendSince.set(steamId64, this.readInteger(item.getProperty('friend_since')));
    }
    return result;
  }

  private appendProfiles(body: string, friendSince: Map<string, number>, target: Array<SteamArkFriendProfile>): void {
    const root: SteamJsonValue = SteamJsonParser.parse(body, steamArkCoreLogger);
    const response: SteamJsonValue | null = root.getProperty('response');
    const rootPlayers: SteamJsonValue | null = root.getProperty('players');
    const players: SteamJsonValue | null = rootPlayers !== null
      ? rootPlayers : (response === null ? null : response.getProperty('players'));
    if (players === null || players.kind !== SteamJsonValueKind.ARRAY) return;
    for (let index: number = 0; index < players.items.length; index++) {
      const item: SteamJsonValue = players.items[index];
      if (item.kind !== SteamJsonValueKind.OBJECT) continue;
      const steamId64: string = this.readText(item.getProperty('steamid'));
      const since: number | undefined = friendSince.get(steamId64);
      target.push(new SteamArkFriendProfile(
        steamId64,
        HarmonySteamSocialRuntime.steamId64ToAccountId(steamId64),
        this.readText(item.getProperty('personaname')),
        this.readText(item.getProperty('avatarfull')),
        this.readText(item.getProperty('profileurl')),
        this.readInteger(item.getProperty('personastate')),
        this.readText(item.getProperty('gameextrainfo')),
        this.readText(item.getProperty('gameid')),
        this.readInteger(item.getProperty('lastlogoff')),
        since === undefined ? 0 : since
      ));
    }
  }

  private readText(value: SteamJsonValue | null): string {
    if (value === null) return '';
    if (value.kind === SteamJsonValueKind.STRING) return value.stringValue.trim();
    if (value.kind === SteamJsonValueKind.NUMBER) return value.numberValue.trim();
    return '';
  }

  private readInteger(value: SteamJsonValue | null): number {
    const parsed: number = Number(this.readText(value));
    return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
  }

  private messageId(friendSteamId64: string, timestamp: number, ordinal: number, sender: number): string {
    return friendSteamId64 + '-' + timestamp.toString() + '-' + ordinal.toString() + '-' + sender.toString();
  }

  private wait(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, milliseconds);
    });
  }

  private ensureAvailable(): void {
    if (this.disposed) throw new Error('Steam social runtime is disposed');
  }

  private static steamId64ToAccountId(steamId64: string): number {
    if (steamId64.length !== STEAM_ID64_BASE.length || steamId64 < STEAM_ID64_BASE) return 0;
    let borrow: number = 0;
    let result: string = '';
    for (let index: number = steamId64.length - 1; index >= 0; index--) {
      let digit: number = steamId64.charCodeAt(index) - 48 -
        (STEAM_ID64_BASE.charCodeAt(index) - 48) - borrow;
      if (digit < 0) { digit += 10; borrow = 1; } else { borrow = 0; }
      result = String(digit) + result;
    }
    const parsed: number = Number(result);
    return Number.isSafeInteger(parsed) && parsed >= 0 && parsed <= 4294967295 ? parsed : 0;
  }

  private static accountIdToSteamId64(accountId: number): string {
    let carry: number = Math.max(0, Math.floor(accountId));
    let result: string = STEAM_ID64_BASE;
    let index: number = result.length - 1;
    while (carry > 0 && index >= 0) {
      const sum: number = result.charCodeAt(index) - 48 + carry;
      result = result.substring(0, index) + String(sum % 10) + result.substring(index + 1);
      carry = Math.floor(sum / 10);
      index--;
    }
    return result;
  }

  private static toProxy(profile: SteamAccountProfile, password: string): NGFProxyConfiguration {
    if (profile.proxy.kind === SteamProxyKind.DIRECT) return NGFProxyConfiguration.direct();
    if (profile.proxy.kind === SteamProxyKind.HTTP) {
      return NGFProxyConfiguration.http(profile.proxy.host, profile.proxy.port, profile.proxy.username, password);
    }
    if (profile.proxy.kind === SteamProxyKind.SOCKS5) {
      return NGFProxyConfiguration.socks5(profile.proxy.host, profile.proxy.port, profile.proxy.username, password);
    }
    return NGFProxyConfiguration.system();
  }
}

export class HarmonySteamSocialRuntimeFactory implements ISteamArkSocialRuntimeFactory {
  create(profile: SteamAccountProfile, credentials: SteamCredentialSet,
    proxyPassword: string, locale: SteamArkContentLocale | null = null): ISteamArkSocialRuntime {
    return new HarmonySteamSocialRuntime(profile, credentials, proxyPassword, locale);
  }
}
