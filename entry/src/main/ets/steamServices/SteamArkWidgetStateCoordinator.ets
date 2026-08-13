import {
  SteamFarmSnapshot,
  SteamFarmState,
  SteamSessionState
} from 'steam_core';
import {
  SteamArkFarmingEvent,
  SteamArkFarmingEventListener
} from './SteamArkFarmingContracts';
import {
  SteamArkStateListener,
  SteamArkStateService,
  SteamArkStateSnapshot,
  steamArkStateService
} from './SteamArkStateService';
import {
  SteamArkFarmingService,
  steamArkFarmingService
} from './SteamArkFarmingService';
import { SteamArkLog } from './SteamArkLogger';
import {
  SteamArkWidgetStateStore,
  steamArkWidgetStateStore
} from './SteamArkWidgetStateStore';

const TAG: string = 'SteamArkWidgetStateCoordinator';
const STATE_LISTENER_ID: string = 'SteamArkWidgetStateCoordinator.state';
const FARMING_LISTENER_ID: string = 'SteamArkWidgetStateCoordinator.farming';

export class SteamArkWidgetStateCoordinator {
  private readonly stateService: SteamArkStateService;
  private readonly farmingService: SteamArkFarmingService;
  private readonly store: SteamArkWidgetStateStore;
  private started: boolean = false;
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    this.publishState(snapshot);
  };
  private readonly farmingListener: SteamArkFarmingEventListener = (_event: SteamArkFarmingEvent): void => {
    this.publishState(this.stateService.getSnapshot());
  };

  constructor(
    stateService: SteamArkStateService = steamArkStateService,
    farmingService: SteamArkFarmingService = steamArkFarmingService,
    store: SteamArkWidgetStateStore = steamArkWidgetStateStore
  ) {
    this.stateService = stateService;
    this.farmingService = farmingService;
    this.store = store;
  }

  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.stateService.subscribe(STATE_LISTENER_ID, this.stateListener);
    this.farmingService.subscribe(FARMING_LISTENER_ID, this.farmingListener);
    this.publishState(this.stateService.getSnapshot());
    SteamArkLog.lifecycle(TAG, 'started');
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.stateService.unsubscribe(STATE_LISTENER_ID);
    this.farmingService.unsubscribe(FARMING_LISTENER_ID);
    SteamArkLog.lifecycle(TAG, 'stopped');
  }

  private publishState(snapshot: SteamArkStateSnapshot): void {
    let sessionState: string = 'disconnected';
    let farmingState: string = 'disabled';
    const selectedId: string = snapshot.selectedAccountId;
    for (let index = 0; index < snapshot.accounts.length; index++) {
      const account = snapshot.accounts[index];
      if (account.profile.accountId !== selectedId) {
        continue;
      }
      sessionState = this.mapSessionState(account.session.state);
      const farmSnapshot: SteamFarmSnapshot | null = this.farmingService.getSnapshot(selectedId);
      farmingState = this.mapFarmingState(selectedId, farmSnapshot);
      break;
    }
    void this.persist(sessionState, farmingState, snapshot.accounts.length);
  }

  private async persist(sessionState: string, farmingState: string, accountCount: number): Promise<void> {
    const accountSaved: boolean = await this.store.updateAccountState(sessionState, accountCount);
    const farmingSaved: boolean = await this.store.updateFarmingState(farmingState);
    if (!accountSaved || !farmingSaved) {
      SteamArkLog.debug(TAG, 'widget state update deferred or rejected; accountSaved=' +
        String(accountSaved) + ', farmingSaved=' + String(farmingSaved));
    }
  }

  private mapSessionState(state: SteamSessionState): string {
    switch (state) {
      case SteamSessionState.LOGGED_ON:
        return 'logged_on';
      case SteamSessionState.CONNECTED:
        return 'connected';
      case SteamSessionState.CONNECTING:
      case SteamSessionState.RECONNECTING:
        return 'connecting';
      case SteamSessionState.NEEDS_QR_SCAN:
      case SteamSessionState.NEEDS_EMAIL_CODE:
      case SteamSessionState.NEEDS_TWO_FACTOR:
      case SteamSessionState.NEEDS_MOBILE_CONFIRMATION:
        return 'challenge';
      case SteamSessionState.ERROR:
      case SteamSessionState.EXPIRED:
        return 'error';
      case SteamSessionState.DISCONNECTED:
      default:
        return 'disconnected';
    }
  }

  private mapFarmingState(accountId: string, snapshot: SteamFarmSnapshot | null): string {
    if (accountId.length <= 0 || !this.farmingService.isFarmingReady() || snapshot === null) {
      return 'disabled';
    }
    if (snapshot.state === SteamFarmState.ERROR) {
      return 'error';
    }
    if (snapshot.state === SteamFarmState.PAUSED) {
      return 'paused';
    }
    if (snapshot.nowFarming || snapshot.state === SteamFarmState.STARTING ||
      snapshot.state === SteamFarmState.FARMING || snapshot.state === SteamFarmState.RECONNECTING) {
      return 'running';
    }
    return 'idle';
  }
}

export const steamArkWidgetStateCoordinator: SteamArkWidgetStateCoordinator =
  new SteamArkWidgetStateCoordinator();
