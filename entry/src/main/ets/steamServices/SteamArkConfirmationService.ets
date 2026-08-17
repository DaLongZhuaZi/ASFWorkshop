import {
  SteamAccountProfile,
  SteamConfirmationEntry,
  SteamConfirmationPageResult,
  SteamCredentialSet,
  SteamSessionState
} from 'steam_core';
import { SteamArkContentLocale } from './SteamArkRegionPolicy';
import { SteamArkAccountSnapshot, steamArkStateService } from './SteamArkStateService';
import { SteamArkLog } from './SteamArkLogger';

/** Read-only fetch boundary for the Steam mobile confirmation list. */
export interface ISteamArkConfirmationClient {
  fetchConfirmations(
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    proxyPassword: string,
    locale: SteamArkContentLocale | null
  ): Promise<SteamConfirmationPageResult>;
}

export enum SteamArkConfirmationState {
  IDLE = 'idle',
  LOADING = 'loading',
  READY = 'ready',
  UNAVAILABLE = 'unavailable',
  ERROR = 'error'
}

export class SteamArkConfirmationSnapshot {
  readonly accountId: string;
  readonly state: SteamArkConfirmationState;
  readonly updatedAtEpochSeconds: number;
  readonly errorMessage: string;
  readonly entries: Array<SteamConfirmationEntry>;

  constructor(
    accountId: string = '',
    state: SteamArkConfirmationState = SteamArkConfirmationState.IDLE,
    updatedAtEpochSeconds: number = 0,
    errorMessage: string = '',
    entries: Array<SteamConfirmationEntry> = []
  ) {
    this.accountId = accountId;
    this.state = state;
    this.updatedAtEpochSeconds = updatedAtEpochSeconds;
    this.errorMessage = errorMessage;
    this.entries = entries.slice();
  }
}

/**
 * Read-only confirmation center orchestration. Fetching requires the stored
 * identity secret and stays behind the secure credential boundary; accepting
 * or rejecting confirmations is deliberately not implemented (browser handoff).
 */
export class SteamArkConfirmationService {
  private static readonly instance: SteamArkConfirmationService = new SteamArkConfirmationService();
  private readonly snapshots: Map<string, SteamArkConfirmationSnapshot> = new Map<string, SteamArkConfirmationSnapshot>();
  private readonly generationByAccount: Map<string, number> = new Map<string, number>();
  private client: ISteamArkConfirmationClient | null = null;

  static getInstance(): SteamArkConfirmationService {
    return SteamArkConfirmationService.instance;
  }

  setClient(client: ISteamArkConfirmationClient | null): void {
    this.client = client;
    SteamArkLog.debug('SteamArkConfirmationService',
      'confirmation client ' + (client === null ? 'cleared' : 'configured'));
  }

  getSnapshot(accountId: string): SteamArkConfirmationSnapshot {
    const existing: SteamArkConfirmationSnapshot | undefined =
      this.snapshots.get(accountId.trim());
    return existing === undefined ? new SteamArkConfirmationSnapshot(accountId.trim()) : existing;
  }

  clearAccount(accountId: string): void {
    const normalizedId: string = accountId.trim();
    this.generationByAccount.set(normalizedId, (this.generationByAccount.get(normalizedId) ?? 0) + 1);
    this.snapshots.delete(normalizedId);
  }

  async fetch(accountId: string): Promise<SteamArkConfirmationSnapshot> {
    const normalizedId: string = accountId.trim();
    if (normalizedId.length <= 0 || this.client === null) {
      return this.unavailableSnapshot(normalizedId, 'Confirmation capability is not configured');
    }
    const generation: number = (this.generationByAccount.get(normalizedId) ?? 0) + 1;
    this.generationByAccount.set(normalizedId, generation);
    this.snapshots.set(normalizedId, new SteamArkConfirmationSnapshot(
      normalizedId, SteamArkConfirmationState.LOADING));
    const account: SteamArkAccountSnapshot | undefined =
      steamArkStateService.getSnapshot().accounts.find(
        (candidate: SteamArkAccountSnapshot): boolean => candidate.profile.accountId === normalizedId);
    if (account === undefined || account.session.state !== SteamSessionState.LOGGED_ON) {
      return this.errorSnapshot(normalizedId, generation, 'The account must be logged on first');
    }
    try {
      const credentials = await steamArkStateService.getCredentials(normalizedId);
      if (credentials.identitySecret.trim().length <= 0 || credentials.deviceId.trim().length <= 0) {
        return this.errorSnapshot(normalizedId, generation,
          'This account has no Steam Guard authenticator material on file');
      }
      const proxyPassword: string = await steamArkStateService.getProxyPassword(normalizedId);
      const result: SteamConfirmationPageResult = await this.client.fetchConfirmations(
        account.profile, credentials, proxyPassword,
        steamArkStateService.resolveAccountLocale(normalizedId));
      if ((this.generationByAccount.get(normalizedId) ?? 0) !== generation) {
        return this.getSnapshot(normalizedId);
      }
      if (!result.success) {
        return this.errorSnapshot(normalizedId, generation,
          SteamArkConfirmationService.describeFailure(result.errorMessage));
      }
      const snapshot: SteamArkConfirmationSnapshot = new SteamArkConfirmationSnapshot(
        normalizedId, SteamArkConfirmationState.READY, Math.floor(Date.now() / 1000),
        '', result.entries);
      this.snapshots.set(normalizedId, snapshot);
      SteamArkLog.info('SteamArkConfirmationService',
        'confirmation list fetched; account=' + SteamArkLog.accountId(normalizedId) +
        ', entries=' + result.entries.length.toString());
      return snapshot;
    } catch (error) {
      return this.errorSnapshot(normalizedId, generation,
        error instanceof Error ? error.message : 'Confirmation fetch failed');
    }
  }

  private unavailableSnapshot(accountId: string, message: string): SteamArkConfirmationSnapshot {
    const snapshot: SteamArkConfirmationSnapshot = new SteamArkConfirmationSnapshot(
      accountId, SteamArkConfirmationState.UNAVAILABLE, 0, message);
    this.snapshots.set(accountId, snapshot);
    return snapshot;
  }

  private errorSnapshot(
    accountId: string,
    generation: number,
    message: string
  ): SteamArkConfirmationSnapshot {
    if ((this.generationByAccount.get(accountId) ?? 0) !== generation) {
      return this.getSnapshot(accountId);
    }
    const snapshot: SteamArkConfirmationSnapshot = new SteamArkConfirmationSnapshot(
      accountId, SteamArkConfirmationState.ERROR, Math.floor(Date.now() / 1000), message);
    this.snapshots.set(accountId, snapshot);
    SteamArkLog.warn('SteamArkConfirmationService',
      'confirmation fetch failed; account=' + SteamArkLog.accountId(accountId));
    return snapshot;
  }

  private static describeFailure(code: string): string {
    if (code === 'not_authorized') {
      return 'Steam rejected the confirmation request; sign in again or refresh the session';
    }
    if (code === 'empty_response') {
      return 'Steam returned an empty confirmation response';
    }
    return 'Confirmation fetch failed';
  }
}

export const steamArkConfirmationService: SteamArkConfirmationService = SteamArkConfirmationService.getInstance();
