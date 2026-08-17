import {
  SteamAccountProfile,
  SteamCredentialSet,
  SteamGameDetailBundle,
  SteamGameLibraryResult,
  SteamLibraryGame,
  SteamSessionSnapshot
} from 'steam_core';

/** Immutable snapshot of one account's game library for the UI. */
export class SteamArkGameLibrarySnapshot {
  readonly accountId: string;
  readonly games: Array<SteamLibraryGame>;
  readonly totalCount: number;
  readonly updatedAtEpochSeconds: number;
  /** Empty when the last synchronization succeeded. */
  readonly errorMessage: string;

  constructor(
    accountId: string,
    games: Array<SteamLibraryGame> = [],
    totalCount: number = 0,
    updatedAtEpochSeconds: number = 0,
    errorMessage: string = ''
  ) {
    this.accountId = accountId;
    this.games = games.slice();
    this.totalCount = totalCount;
    this.updatedAtEpochSeconds = updatedAtEpochSeconds;
    this.errorMessage = errorMessage;
  }
}

export type SteamArkGameLibrarySnapshotListener = (snapshot: SteamArkGameLibrarySnapshot) => void;

/** Late library updates delivered when a slow source (for example the CM channel) completes after the fast Web sources already returned. */
export type SteamLibraryUpdateListener = (result: SteamGameLibraryResult) => void;

/** Application boundary for one isolated, read-only Steam library Web session. */
export interface ISteamArkGameLibraryAdapter {
  open(accountId: string, credentials: SteamCredentialSet): Promise<SteamSessionSnapshot>;
  syncGameLibrary(accountId: string, language: string): Promise<SteamGameLibraryResult>;
  fetchGameDetail(accountId: string, appId: string, language: string): Promise<SteamGameDetailBundle>;
  setLibraryUpdateListener(listener: SteamLibraryUpdateListener | null): void;
  drainPendingLibraryUpdate(): SteamGameLibraryResult | null;
  close(accountId: string): Promise<void>;
  readonly session: SteamSessionSnapshot;
}

/** Platform adapter factory kept outside steam_core for fake-host testing and open-source reuse. */
export interface ISteamArkGameLibraryAdapterFactory {
  create(profile: SteamAccountProfile, proxyPassword?: string): ISteamArkGameLibraryAdapter;
}
