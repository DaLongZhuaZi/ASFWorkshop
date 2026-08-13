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
  static readonly BROWSER: string = 'steam.ark.browser';
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
