/** Opaque Want parameter keys for routing a local system notification into Steam UI. */
export const STEAM_ARK_NOTIFICATION_ACTION_KEY: string = 'steam_ark_notification_action';
export const STEAM_ARK_NOTIFICATION_ACCOUNT_ID_KEY: string = 'steam_ark_notification_account_id';
export const STEAM_ARK_NOTIFICATION_FRIEND_ID_KEY: string = 'steam_ark_notification_friend_id';
export const STEAM_ARK_NOTIFICATION_MESSAGE_ID_KEY: string = 'steam_ark_notification_message_id';
export const STEAM_ARK_NOTIFICATION_ACTION_OPEN_CHAT: string = 'open_chat';
export const STEAM_ARK_NOTIFICATION_ACTION_OPEN_MESSAGE: string = 'open_message';
export const STEAM_ARK_NOTIFICATION_ACTION_OPEN_FARMING: string = 'open_farming';

export class SteamArkNotificationChatLaunchRequest {
  readonly accountId: string;
  readonly friendSteamId64: string;

  constructor(accountId: string, friendSteamId64: string) {
    this.accountId = accountId.trim();
    this.friendSteamId64 = friendSteamId64.trim();
  }
}

export class SteamArkNotificationMessageLaunchRequest {
  readonly accountId: string;
  readonly messageId: string;

  constructor(accountId: string, messageId: string) {
    this.accountId = accountId.trim();
    this.messageId = messageId.trim();
  }
}

export class SteamArkNotificationFarmingLaunchRequest {
  readonly accountId: string;

  constructor(accountId: string) {
    this.accountId = accountId.trim();
  }
}

export class SteamArkNotificationNavigation {
  static createOpenChatParameters(accountId: string, friendSteamId64: string): Record<string, Object> {
    const parameters: Record<string, Object> = {};
    parameters[STEAM_ARK_NOTIFICATION_ACTION_KEY] = STEAM_ARK_NOTIFICATION_ACTION_OPEN_CHAT;
    parameters[STEAM_ARK_NOTIFICATION_ACCOUNT_ID_KEY] = accountId.trim();
    parameters[STEAM_ARK_NOTIFICATION_FRIEND_ID_KEY] = friendSteamId64.trim();
    return parameters;
  }

  static createOpenMessageParameters(accountId: string, messageId: string): Record<string, Object> {
    const parameters: Record<string, Object> = {};
    parameters[STEAM_ARK_NOTIFICATION_ACTION_KEY] = STEAM_ARK_NOTIFICATION_ACTION_OPEN_MESSAGE;
    parameters[STEAM_ARK_NOTIFICATION_ACCOUNT_ID_KEY] = accountId.trim();
    parameters[STEAM_ARK_NOTIFICATION_MESSAGE_ID_KEY] = messageId.trim();
    return parameters;
  }

  static createOpenFarmingParameters(accountId: string): Record<string, Object> {
    const parameters: Record<string, Object> = {};
    parameters[STEAM_ARK_NOTIFICATION_ACTION_KEY] = STEAM_ARK_NOTIFICATION_ACTION_OPEN_FARMING;
    parameters[STEAM_ARK_NOTIFICATION_ACCOUNT_ID_KEY] = accountId.trim();
    return parameters;
  }

  static readOpenChatRequest(parameters: Record<string, Object> | undefined): SteamArkNotificationChatLaunchRequest | null {
    if (parameters === undefined) {
      return null;
    }
    const action: string = SteamArkNotificationNavigation.readString(
      parameters,
      STEAM_ARK_NOTIFICATION_ACTION_KEY
    );
    if (action !== STEAM_ARK_NOTIFICATION_ACTION_OPEN_CHAT) {
      return null;
    }
    const accountId: string = SteamArkNotificationNavigation.readString(
      parameters,
      STEAM_ARK_NOTIFICATION_ACCOUNT_ID_KEY
    );
    const friendSteamId64: string = SteamArkNotificationNavigation.readString(
      parameters,
      STEAM_ARK_NOTIFICATION_FRIEND_ID_KEY
    );
    if (accountId.length <= 0 || friendSteamId64.length <= 0) {
      return null;
    }
    return new SteamArkNotificationChatLaunchRequest(accountId, friendSteamId64);
  }

  static readOpenMessageRequest(parameters: Record<string, Object> | undefined): SteamArkNotificationMessageLaunchRequest | null {
    if (parameters === undefined) {
      return null;
    }
    const action: string = SteamArkNotificationNavigation.readString(
      parameters,
      STEAM_ARK_NOTIFICATION_ACTION_KEY
    );
    if (action !== STEAM_ARK_NOTIFICATION_ACTION_OPEN_MESSAGE) {
      return null;
    }
    const accountId: string = SteamArkNotificationNavigation.readString(
      parameters,
      STEAM_ARK_NOTIFICATION_ACCOUNT_ID_KEY
    );
    const messageId: string = SteamArkNotificationNavigation.readString(
      parameters,
      STEAM_ARK_NOTIFICATION_MESSAGE_ID_KEY
    );
    if (accountId.length <= 0 || messageId.length <= 0) {
      return null;
    }
    return new SteamArkNotificationMessageLaunchRequest(accountId, messageId);
  }

  static readOpenFarmingRequest(parameters: Record<string, Object> | undefined): SteamArkNotificationFarmingLaunchRequest | null {
    if (parameters === undefined) {
      return null;
    }
    const action: string = SteamArkNotificationNavigation.readString(
      parameters,
      STEAM_ARK_NOTIFICATION_ACTION_KEY
    );
    if (action !== STEAM_ARK_NOTIFICATION_ACTION_OPEN_FARMING) {
      return null;
    }
    const accountId: string = SteamArkNotificationNavigation.readString(
      parameters,
      STEAM_ARK_NOTIFICATION_ACCOUNT_ID_KEY
    );
    if (accountId.length <= 0) {
      return null;
    }
    return new SteamArkNotificationFarmingLaunchRequest(accountId);
  }

  private static readString(parameters: Record<string, Object>, key: string): string {
    const value: Object | undefined = parameters[key];
    return typeof value === 'string' ? value.trim() : '';
  }
}
