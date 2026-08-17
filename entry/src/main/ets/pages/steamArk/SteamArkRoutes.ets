import { SteamInventoryCardDropState, SteamInventoryItem } from 'steam_core';

/** Product routes are kept separate from the legacy NGF demonstration routes. */
export class SteamArkRouteName {
  static readonly HOME: string = 'pages/steamArk/SteamArkHomePage';
  static readonly WORKSPACE: string = 'steam.ark.workspace';
  static readonly ACCOUNTS: string = 'steam.ark.accounts';
  static readonly INVENTORY: string = 'steam.ark.inventory';
  static readonly NETWORK: string = 'steam.ark.network';
  static readonly TOKENS: string = 'steam.ark.tokens';
  static readonly SETTINGS: string = 'steam.ark.settings';
  static readonly DIAGNOSTICS: string = 'steam.ark.diagnostics';
  static readonly MESSAGES: string = 'steam.ark.messages';
  static readonly SOCIAL: string = 'steam.ark.social';
  static readonly LIBRARY: string = 'steam.ark.library';
  static readonly BROWSER: string = 'steam.ark.browser';
  static readonly MARKET_BROWSE: string = 'steam.ark.market.browse';
  static readonly CONFIRMATIONS: string = 'steam.ark.confirmations';
  static readonly STORE: string = 'steam.ark.store';
  static readonly GAME_DETAIL: string = 'steam.ark.game.detail';
}

export class SteamArkBrowserRequest {
  readonly url: string;
  readonly title: string;
  readonly subtitle: string;

  constructor(url: string = 'https://steamcommunity.com/', title: string = 'Steam', subtitle: string = '') {
    this.url = url;
    this.title = title;
    this.subtitle = subtitle;
  }
}

/**
 * The in-app game detail page request. It carries the known library fields so
 * the header renders instantly; the store/news/achievement sections are then
 * fetched in the background.
 */
export class SteamArkGameDetailRequest {
  readonly appId: string;
  readonly name: string;
  readonly logoUrl: string;
  readonly iconUrl: string;
  readonly playtimeForeverSeconds: number;
  readonly playtimeTwoWeeksSeconds: number;
  readonly lastPlayedEpochSeconds: number;
  readonly favorite: boolean;

  constructor(
    appId: string = '',
    name: string = '',
    logoUrl: string = '',
    iconUrl: string = '',
    playtimeForeverSeconds: number = 0,
    playtimeTwoWeeksSeconds: number = 0,
    lastPlayedEpochSeconds: number = 0,
    favorite: boolean = false
  ) {
    this.appId = appId.trim();
    this.name = name;
    this.logoUrl = logoUrl;
    this.iconUrl = iconUrl;
    this.playtimeForeverSeconds = playtimeForeverSeconds;
    this.playtimeTwoWeeksSeconds = playtimeTwoWeeksSeconds;
    this.lastPlayedEpochSeconds = lastPlayedEpochSeconds;
    this.favorite = favorite;
  }

  /** geometryTransition id shared by the library tile cover and the detail header cover. */
  static coverGeometryId(appId: string): string {
    return 'game-cover-' + appId;
  }

  static fromRouteParameter(value: Object): SteamArkGameDetailRequest | null {
    if (value instanceof SteamArkGameDetailRequest) {
      return value;
    }
    return null;
  }
}

/** The in-page achievement detail request carried by the game detail page. */
export class SteamArkAchievementDetailRequest {
  readonly apiName: string;
  readonly name: string;
  readonly description: string;
  readonly iconUrl: string;
  readonly achieved: boolean;
  readonly unlockTimeEpochSeconds: number;

  constructor(
    apiName: string = '',
    name: string = '',
    description: string = '',
    iconUrl: string = '',
    achieved: boolean = false,
    unlockTimeEpochSeconds: number = 0
  ) {
    this.apiName = apiName;
    this.name = name;
    this.description = description;
    this.iconUrl = iconUrl;
    this.achieved = achieved;
    this.unlockTimeEpochSeconds = unlockTimeEpochSeconds;
  }

  /** geometryTransition id shared by the achievement tile icon and the detail hero icon. */
  static iconGeometryId(apiName: string, name: string): string {
    const key: string = apiName.length > 0 ? apiName : name;
    return 'achievement-icon-' + key;
  }
}

/**
 * The in-app inventory detail page request. Every field comes from the
 * inventory row that opened the page, so the header, attributes and
 * description render instantly; market, badge and game sections are then
 * fetched independently in the background.
 */
export class SteamArkInventoryDetailRequest {
  readonly assetId: string;
  readonly classId: string;
  readonly instanceId: string;
  readonly appId: string;
  readonly contextId: string;
  readonly amount: number;
  readonly originalAmount: number;
  readonly name: string;
  readonly type: string;
  readonly description: string;
  readonly iconUrl: string;
  readonly iconUrlLarge: string;
  readonly marketHashName: string;
  readonly marketName: string;
  readonly marketable: boolean;
  readonly tradable: boolean;
  readonly isTradingCard: boolean;
  readonly cardDropState: SteamInventoryCardDropState;
  readonly ownerAppId: string;
  readonly ownerAppName: string;

  constructor(
    assetId: string = '',
    classId: string = '',
    instanceId: string = '',
    appId: string = '',
    contextId: string = '',
    amount: number = 0,
    originalAmount: number = 0,
    name: string = '',
    type: string = '',
    description: string = '',
    iconUrl: string = '',
    iconUrlLarge: string = '',
    marketHashName: string = '',
    marketName: string = '',
    marketable: boolean = false,
    tradable: boolean = false,
    isTradingCard: boolean = false,
    cardDropState: SteamInventoryCardDropState = SteamInventoryCardDropState.UNKNOWN,
    ownerAppId: string = '',
    ownerAppName: string = ''
  ) {
    this.assetId = assetId;
    this.classId = classId;
    this.instanceId = instanceId;
    this.appId = appId.trim();
    this.contextId = contextId;
    this.amount = amount;
    this.originalAmount = originalAmount;
    this.name = name;
    this.type = type;
    this.description = description;
    this.iconUrl = iconUrl;
    this.iconUrlLarge = iconUrlLarge;
    this.marketHashName = marketHashName;
    this.marketName = marketName;
    this.marketable = marketable;
    this.tradable = tradable;
    this.isTradingCard = isTradingCard;
    this.cardDropState = cardDropState;
    this.ownerAppId = ownerAppId;
    this.ownerAppName = ownerAppName;
  }

  static fromItem(item: SteamInventoryItem): SteamArkInventoryDetailRequest {
    return new SteamArkInventoryDetailRequest(
      item.assetId,
      item.classId,
      item.instanceId,
      item.appId,
      item.contextId,
      item.amount,
      item.originalAmount,
      item.name,
      item.type,
      item.description,
      item.iconUrl,
      item.iconUrlLarge,
      item.marketHashName,
      item.marketName,
      item.marketable,
      item.tradable,
      item.isTradingCard,
      item.cardDropState,
      item.ownerAppId,
      item.ownerAppName
    );
  }

  /** geometryTransition id shared by the inventory tile icon and the detail header icon. */
  static iconGeometryId(assetId: string): string {
    return 'inventory-icon-' + assetId;
  }

  static fromRouteParameter(value: Object): SteamArkInventoryDetailRequest | null {
    if (value instanceof SteamArkInventoryDetailRequest) {
      return value;
    }
    return null;
  }
}

/** Kinds of in-app badge detail targets. */
export enum SteamArkBadgeKind {
  /** A game badge (crafted or not yet crafted) from the badge sync report. */
  GAME = 1,
  /** A Steam Community badge from the badge sync report. */
  COMMUNITY = 2
}

/**
 * The in-app badge detail page request. All fields come from the cached badge
 * sync report, so the detail page renders entirely from this request without
 * extra fetches. The workspace badge tile expands into the detail page through
 * the home navigation custom content transition (一镜到底).
 */
export class SteamArkBadgeDetailRequest {
  readonly kind: SteamArkBadgeKind;
  readonly appId: string;
  readonly badgeId: string;
  readonly name: string;
  readonly imageUrl: string;
  readonly badgeLevel: number;
  readonly experience: number;
  readonly hoursPlayed: number;
  readonly cardsRemaining: number;
  readonly badgeCrafted: boolean;
  readonly badgeUrl: string;
  readonly storeUrl: string;

  constructor(
    kind: SteamArkBadgeKind = SteamArkBadgeKind.GAME,
    appId: string = '',
    badgeId: string = '',
    name: string = '',
    imageUrl: string = '',
    badgeLevel: number = 0,
    experience: number = 0,
    hoursPlayed: number = 0,
    cardsRemaining: number = 0,
    badgeCrafted: boolean = false,
    badgeUrl: string = '',
    storeUrl: string = ''
  ) {
    this.kind = kind;
    this.appId = appId.trim();
    this.badgeId = badgeId.trim();
    this.name = name;
    this.imageUrl = imageUrl;
    this.badgeLevel = badgeLevel;
    this.experience = experience;
    this.hoursPlayed = hoursPlayed;
    this.cardsRemaining = cardsRemaining;
    this.badgeCrafted = badgeCrafted;
    this.badgeUrl = badgeUrl;
    this.storeUrl = storeUrl;
  }

  /** geometryTransition id shared by the workspace badge tile image and the detail header image. */
  static geometryId(kind: SteamArkBadgeKind, appId: string, badgeId: string): string {
    if (kind === SteamArkBadgeKind.COMMUNITY) {
      return 'badge-image-community-' + badgeId;
    }
    return 'badge-image-game-' + appId;
  }

  static fromRouteParameter(value: Object): SteamArkBadgeDetailRequest | null {
    if (value instanceof SteamArkBadgeDetailRequest) {
      return value;
    }
    return null;
  }
}

/** A typed in-app target for a system notification that opens one message-center item. */
export class SteamArkMessageNavigationRequest {
  readonly accountId: string;
  readonly messageId: string;

  constructor(accountId: string, messageId: string) {
    this.accountId = accountId.trim();
    this.messageId = messageId.trim();
  }

  static fromRouteParameter(value: Object): SteamArkMessageNavigationRequest | null {
    if (value instanceof SteamArkMessageNavigationRequest) {
      return value;
    }
    return null;
  }
}
