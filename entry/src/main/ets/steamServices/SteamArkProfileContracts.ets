import { SteamAccountProfile, SteamCredentialSet } from 'steam_core';

/** Non-secret profile fields returned by a post-authentication profile lookup. */
export class SteamArkResolvedProfile {
  readonly displayName: string;
  readonly avatarUrl: string;
  readonly backgroundImageUrl: string;
  readonly backgroundMovieUrl: string;
  readonly backgroundTiled: boolean;
  readonly avatarFrameUrl: string;
  readonly summary: string;
  readonly level: number;
  readonly countryCode: string;
  readonly walletBalance: string;
  readonly walletCurrency: string;
  readonly miniProfileBackgroundImageUrl: string;
  readonly miniProfileBackgroundMovieUrl: string;

  constructor(
    displayName: string = '',
    avatarUrl: string = '',
    backgroundImageUrl: string = '',
    backgroundMovieUrl: string = '',
    backgroundTiled: boolean = false,
    avatarFrameUrl: string = '',
    summary: string = '',
    level: number = 0,
    countryCode: string = '',
    walletBalance: string = '',
    walletCurrency: string = '',
    miniProfileBackgroundImageUrl: string = '',
    miniProfileBackgroundMovieUrl: string = ''
  ) {
    this.displayName = displayName;
    this.avatarUrl = avatarUrl;
    this.backgroundImageUrl = backgroundImageUrl;
    this.backgroundMovieUrl = backgroundMovieUrl;
    this.backgroundTiled = backgroundTiled;
    this.avatarFrameUrl = avatarFrameUrl;
    this.summary = summary;
    this.level = level;
    this.countryCode = countryCode;
    this.walletBalance = walletBalance;
    this.walletCurrency = walletCurrency;
    this.miniProfileBackgroundImageUrl = miniProfileBackgroundImageUrl;
    this.miniProfileBackgroundMovieUrl = miniProfileBackgroundMovieUrl;
  }
}

/** Resolves user-facing profile data without changing authentication state. */
export interface ISteamArkProfileResolver {
  resolve(
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    proxyPassword?: string
  ): Promise<SteamArkResolvedProfile>;
}

/** Resolves profile decoration after the basic identity has already reached the UI. */
export interface ISteamArkProfileVisualResolver {
  resolveVisuals(
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    baseline: SteamArkResolvedProfile,
    proxyPassword?: string
  ): Promise<SteamArkResolvedProfile>;
}
