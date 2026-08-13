import { SteamAccountProfile, SteamCredentialSet } from 'steam_core';

export enum SteamArkMessageCategory {
  SYSTEM = 'system',
  PROMOTION = 'promotion',
  FRIEND = 'friend',
  TRADE = 'trade',
  INVENTORY = 'inventory'
}

export class SteamArkMessageItem {
  readonly id: string;
  readonly category: SteamArkMessageCategory;
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

  constructor(
    id: string,
    category: SteamArkMessageCategory,
    title: string,
    body: string,
    url: string,
    source: string,
    createdAtEpochSeconds: number,
    unread: boolean = true,
    imageUrl: string = '',
    remoteId: string = '',
    notificationType: number = 0,
    tradeOfferId: string = '',
    tradeOfferSent: boolean = false
  ) {
    this.id = id;
    this.category = category;
    this.title = title;
    this.body = body;
    this.url = url;
    this.source = source;
    this.imageUrl = imageUrl;
    this.createdAtEpochSeconds = createdAtEpochSeconds;
    this.unread = unread;
    this.remoteId = remoteId;
    this.notificationType = notificationType;
    this.tradeOfferId = tradeOfferId;
    this.tradeOfferSent = tradeOfferSent;
  }
}

export class SteamArkMessageSyncResult {
  readonly items: Array<SteamArkMessageItem>;
  readonly syncedAtEpochSeconds: number;
  readonly sourceWarning: string;

  constructor(items: Array<SteamArkMessageItem>, syncedAtEpochSeconds: number, sourceWarning: string = '') {
    this.items = items.slice();
    this.syncedAtEpochSeconds = syncedAtEpochSeconds;
    this.sourceWarning = sourceWarning;
  }
}

/** Publishes a newly observed message-center item through the host notification channel. */
export interface ISteamArkMessageNotificationPublisher {
  publishSynchronizedMessage(accountId: string, item: SteamArkMessageItem): Promise<void>;
}

export interface ISteamArkMessageResolver {
  resolve(
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    proxyPassword: string
  ): Promise<SteamArkMessageSyncResult>;
  markRead(profile: SteamAccountProfile, credentials: SteamCredentialSet,
    proxyPassword: string, item: SteamArkMessageItem): Promise<void>;
  markAllRead(profile: SteamAccountProfile, credentials: SteamCredentialSet,
    proxyPassword: string): Promise<void>;
  hide(profile: SteamAccountProfile, credentials: SteamCredentialSet,
    proxyPassword: string, item: SteamArkMessageItem): Promise<void>;
}
