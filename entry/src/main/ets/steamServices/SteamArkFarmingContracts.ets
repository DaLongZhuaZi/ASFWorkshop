import {
  SteamAccountProfile,
  SteamBadgeSyncReport,
  SteamBotConfig,
  SteamCardDropEvent,
  SteamCredentialSet,
  SteamFarmEvent,
  SteamFarmPauseMode,
  SteamFarmSnapshot,
  SteamSessionSnapshot
} from 'steam_core';
import { IStateStore } from 'steam_core';
import { SteamArkContentLocale } from './SteamArkRegionPolicy';

/** Host-side runtime for one account. The core remains behind this seam. */
export interface ISteamArkFarmingRuntime {
  readonly accountId: string;
  readonly session: SteamSessionSnapshot;
  readonly snapshot: SteamFarmSnapshot;
  load(): Promise<SteamFarmSnapshot>;
  refreshGames(): Promise<SteamFarmSnapshot>;
  start(): Promise<SteamFarmSnapshot>;
  pause(): Promise<SteamFarmSnapshot>;
  /** ASF pause variants: temporary (`pause~`) and timed (`pause& seconds`). */
  pauseFor(pauseMode: SteamFarmPauseMode, seconds: number): Promise<SteamFarmSnapshot>;
  resume(): Promise<SteamFarmSnapshot>;
  stop(): Promise<SteamFarmSnapshot>;
  playManual(appIds: Array<string>, gameName: string): Promise<SteamFarmSnapshot>;
  resetManual(): Promise<SteamFarmSnapshot>;
  addEventListener(listener: SteamFarmEventListener): void;
  removeEventListener(listener: SteamFarmEventListener): void;
  addSessionListener(listener: SteamSessionEventListener): void;
  removeSessionListener(listener: SteamSessionEventListener): void;
  dispose(): Promise<void>;
}

export type SteamFarmEventListener = (event: SteamFarmEvent) => void;
export type SteamSessionEventListener = (session: SteamSessionSnapshot) => void;

/**
 * The factory is deliberately injectable so fake transport tests do not need
 * NGF or a device. Real transport availability is an explicit release gate.
 */
export interface ISteamArkFarmingRuntimeFactory {
  readonly isEnabled: boolean;
  readonly unavailableReason: string;
  create(
    profile: SteamAccountProfile,
    config: SteamBotConfig,
    credentials: SteamCredentialSet,
    stateStore: IStateStore,
    proxyPassword?: string,
    locale?: SteamArkContentLocale | null
  ): ISteamArkFarmingRuntime;
}

export enum SteamArkFarmingEventType {
  SNAPSHOT_CHANGED = 'snapshot_changed',
  SESSION_CHANGED = 'session_changed',
  BADGE_SYNCED = 'badge_synced',
  CARD_DROPPED = 'card_dropped',
  BACKGROUND_TASK_CHANGED = 'background_task_changed',
  ERROR = 'error'
}

export class SteamArkFarmingEvent {
  readonly accountId: string;
  readonly type: SteamArkFarmingEventType;
  readonly snapshot: SteamFarmSnapshot | null;
  readonly session: SteamSessionSnapshot | null;
  readonly badgeReport: SteamBadgeSyncReport | null;
  readonly drop: SteamCardDropEvent | null;
  readonly message: string;

  constructor(
    accountId: string,
    type: SteamArkFarmingEventType,
    snapshot: SteamFarmSnapshot | null = null,
    session: SteamSessionSnapshot | null = null,
    message: string = '',
    badgeReport: SteamBadgeSyncReport | null = null,
    drop: SteamCardDropEvent | null = null
  ) {
    this.accountId = accountId;
    this.type = type;
    this.snapshot = snapshot;
    this.session = session;
    this.badgeReport = badgeReport;
    this.drop = drop;
    this.message = message;
  }
}

export type SteamArkFarmingEventListener = (event: SteamArkFarmingEvent) => void;

/** Publishes local notifications for real-time card drops; execution stays in the host. */
export interface ISteamArkFarmingNotificationPublisher {
  publishCardDrop(
    accountId: string,
    drop: SteamCardDropEvent,
    snapshot: SteamFarmSnapshot
  ): Promise<void>;

  /** Local notification for the SEND_ON_FARMING_FINISHED preference. */
  publishFarmFinished(accountId: string, snapshot: SteamFarmSnapshot): Promise<void>;
}
