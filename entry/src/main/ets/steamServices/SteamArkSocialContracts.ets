import { SteamAccountProfile, SteamCredentialSet } from 'steam_core';

export enum SteamArkSocialConnectionState {
  DISCONNECTED = 'disconnected',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  ERROR = 'error'
}

export class SteamArkFriendProfile {
  readonly steamId64: string;
  readonly accountId32: number;
  readonly displayName: string;
  readonly avatarUrl: string;
  readonly profileUrl: string;
  readonly personaState: number;
  readonly gameName: string;
  readonly gameAppId: string;
  readonly lastLogoffEpochSeconds: number;
  readonly friendSinceEpochSeconds: number;

  constructor(
    steamId64: string,
    accountId32: number,
    displayName: string,
    avatarUrl: string,
    profileUrl: string,
    personaState: number,
    gameName: string,
    gameAppId: string,
    lastLogoffEpochSeconds: number,
    friendSinceEpochSeconds: number
  ) {
    this.steamId64 = steamId64;
    this.accountId32 = accountId32;
    this.displayName = displayName;
    this.avatarUrl = avatarUrl;
    this.profileUrl = profileUrl;
    this.personaState = personaState;
    this.gameName = gameName;
    this.gameAppId = gameAppId;
    this.lastLogoffEpochSeconds = lastLogoffEpochSeconds;
    this.friendSinceEpochSeconds = friendSinceEpochSeconds;
  }
}

export class SteamArkChatSession {
  readonly friendSteamId64: string;
  readonly lastMessageEpochSeconds: number;
  readonly lastViewEpochSeconds: number;
  readonly unreadCount: number;
  readonly suspicious: boolean;

  constructor(
    friendSteamId64: string,
    lastMessageEpochSeconds: number,
    lastViewEpochSeconds: number,
    unreadCount: number,
    suspicious: boolean = false
  ) {
    this.friendSteamId64 = friendSteamId64;
    this.lastMessageEpochSeconds = lastMessageEpochSeconds;
    this.lastViewEpochSeconds = lastViewEpochSeconds;
    this.unreadCount = unreadCount;
    this.suspicious = suspicious;
  }
}

export class SteamArkChatReaction {
  readonly reactionType: number;
  readonly reaction: string;
  readonly reactorAccountIds: Array<number>;

  constructor(reactionType: number, reaction: string, reactorAccountIds: Array<number> = []) {
    this.reactionType = reactionType;
    this.reaction = reaction;
    this.reactorAccountIds = reactorAccountIds.slice();
  }
}

export class SteamArkEmoticon {
  readonly name: string;
  readonly imageUrl: string;
  readonly appId: number;
  readonly count: number;
  readonly lastUsedEpochSeconds: number;

  constructor(
    name: string,
    imageUrl: string,
    appId: number = 0,
    count: number = 0,
    lastUsedEpochSeconds: number = 0
  ) {
    this.name = name;
    this.imageUrl = imageUrl;
    this.appId = appId;
    this.count = count;
    this.lastUsedEpochSeconds = lastUsedEpochSeconds;
  }

  toChatToken(): string {
    return ':' + this.name + ':';
  }
}

export class SteamArkChatMessage {
  readonly id: string;
  readonly friendSteamId64: string;
  readonly senderAccountId32: number;
  readonly message: string;
  readonly timestamp: number;
  readonly ordinal: number;
  readonly outgoing: boolean;
  readonly pending: boolean;
  readonly failed: boolean;
  readonly reactions: Array<SteamArkChatReaction>;

  constructor(
    id: string,
    friendSteamId64: string,
    senderAccountId32: number,
    message: string,
    timestamp: number,
    ordinal: number,
    outgoing: boolean,
    pending: boolean = false,
    failed: boolean = false,
    reactions: Array<SteamArkChatReaction> = []
  ) {
    this.id = id;
    this.friendSteamId64 = friendSteamId64;
    this.senderAccountId32 = senderAccountId32;
    this.message = message;
    this.timestamp = timestamp;
    this.ordinal = ordinal;
    this.outgoing = outgoing;
    this.pending = pending;
    this.failed = failed;
    this.reactions = reactions.slice();
  }
}

export interface ISteamArkSocialNotificationPublisher {
  publishIncomingMessage(
    accountId: string,
    friendSteamId64: string,
    senderDisplayName: string,
    message: SteamArkChatMessage
  ): Promise<void>;
}

export class SteamArkSocialSnapshot {
  readonly accountId: string;
  readonly state: SteamArkSocialConnectionState;
  readonly friends: Array<SteamArkFriendProfile>;
  readonly sessions: Array<SteamArkChatSession>;
  readonly updatedAtEpochSeconds: number;
  readonly errorMessage: string;

  constructor(
    accountId: string = '',
    state: SteamArkSocialConnectionState = SteamArkSocialConnectionState.DISCONNECTED,
    friends: Array<SteamArkFriendProfile> = [],
    sessions: Array<SteamArkChatSession> = [],
    updatedAtEpochSeconds: number = 0,
    errorMessage: string = ''
  ) {
    this.accountId = accountId;
    this.state = state;
    this.friends = friends.slice();
    this.sessions = sessions.slice();
    this.updatedAtEpochSeconds = updatedAtEpochSeconds;
    this.errorMessage = errorMessage;
  }
}

export enum SteamArkSocialEventType {
  SNAPSHOT_CHANGED = 'snapshot_changed',
  MESSAGE_RECEIVED = 'message_received',
  MESSAGES_CHANGED = 'messages_changed',
  MESSAGE_ACKNOWLEDGED = 'message_acknowledged',
  MESSAGE_REACTION_CHANGED = 'message_reaction_changed',
  SESSION_NOTICE_CHANGED = 'session_notice_changed',
  ERROR = 'error'
}

export class SteamArkSocialEvent {
  readonly type: SteamArkSocialEventType;
  readonly accountId: string;
  readonly friendSteamId64: string;
  readonly message: SteamArkChatMessage | null;
  readonly detail: string;
  readonly timestamp: number;
  readonly ordinal: number;
  readonly reactionType: number;
  readonly reaction: string;
  readonly reactorSteamId64: string;
  readonly active: boolean;
  readonly noticeType: number;
  readonly reactorAccountId32: number;

  constructor(
    type: SteamArkSocialEventType,
    accountId: string,
    friendSteamId64: string = '',
    message: SteamArkChatMessage | null = null,
    detail: string = '',
    timestamp: number = 0,
    ordinal: number = 0,
    reactionType: number = 0,
    reaction: string = '',
    reactorSteamId64: string = '',
    active: boolean = false,
    noticeType: number = 0,
    reactorAccountId32: number = 0
  ) {
    this.type = type;
    this.accountId = accountId;
    this.friendSteamId64 = friendSteamId64;
    this.message = message;
    this.detail = detail;
    this.timestamp = timestamp;
    this.ordinal = ordinal;
    this.reactionType = reactionType;
    this.reaction = reaction;
    this.reactorSteamId64 = reactorSteamId64;
    this.active = active;
    this.noticeType = noticeType;
    this.reactorAccountId32 = reactorAccountId32;
  }
}

export type SteamArkSocialEventListener = (event: SteamArkSocialEvent) => void;
export type SteamArkSocialSnapshotListener = (snapshot: SteamArkSocialSnapshot) => void;

export interface ISteamArkSocialRuntime {
  readonly accountId: string;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  syncFriends(): Promise<Array<SteamArkFriendProfile>>;
  syncSessions(): Promise<Array<SteamArkChatSession>>;
  loadMessages(friendSteamId64: string, count: number, beforeTimestamp?: number,
    beforeOrdinal?: number): Promise<Array<SteamArkChatMessage>>;
  loadEmoticons(): Promise<Array<SteamArkEmoticon>>;
  sendMessage(friendSteamId64: string, message: string): Promise<SteamArkChatMessage>;
  acknowledge(friendSteamId64: string, timestamp: number): Promise<void>;
  updateReaction(friendSteamId64: string, timestamp: number, ordinal: number,
    reactionType: number, reaction: string, isAdd: boolean): Promise<void>;
  reportMessage(fromSteamId64: string, toSteamId64: string, timestamp: number,
    ordinal: number, reason: number, reportText: string): Promise<void>;
  dismissSessionNotice(friendSteamId64: string, noticeType: number): Promise<void>;
  addListener(listener: SteamArkSocialEventListener): void;
  removeListener(listener: SteamArkSocialEventListener): void;
  dispose(): Promise<void>;
}

export interface ISteamArkSocialRuntimeFactory {
  create(profile: SteamAccountProfile, credentials: SteamCredentialSet,
    proxyPassword: string): ISteamArkSocialRuntime;
}
