import { SteamArkLog } from './SteamArkLogger';
import { steamArkSocialService } from './SteamArkSocialService';
import { steamArkStateService } from './SteamArkStateService';
import { steamArkSyncCoordinator } from './SteamArkSyncCoordinator';
import { steamArkWidgetStateCoordinator } from './SteamArkWidgetStateCoordinator';

const TAG: string = 'HyperSnapRecovery';

/**
 * Composes the incremental compensation run after the process is restored
 * from a Hyper Snap memory snapshot.
 *
 * Process memory (account sessions, caches, service singletons, page stack)
 * survives the snapshot, but kernel sockets, timers and system task state do
 * not. Recovery therefore re-establishes external resources instead of
 * re-running the full cold start sequence.
 *
 * Wiring:
 * - AbilityStage.onLaunchFromHyperSnap() calls requestRecovery().
 * - EntryAbility calls notifyServicesReady() after Steam service
 *   initialization so a snapshot taken mid-initialization still recovers.
 */
export class SteamArkHyperSnapRecoveryCoordinator {
  private recoveryPending: boolean = false;
  private recoveryCompleted: boolean = false;

  requestRecovery(): void {
    SteamArkLog.startup(TAG, 'recovery requested', 'launch_from_hyper_snap');
    this.recoveryPending = true;
    this.runRecoveryIfReady();
  }

  notifyServicesReady(): void {
    if (this.recoveryPending) {
      SteamArkLog.startup(TAG, 'services ready while recovery pending', 'retry');
      this.runRecoveryIfReady();
    }
  }

  private runRecoveryIfReady(): void {
    if (!this.recoveryPending || this.recoveryCompleted) {
      return;
    }
    if (!steamArkStateService.getSnapshot().initialized) {
      SteamArkLog.startup(TAG, 'recovery deferred', 'state_service_not_initialized');
      return;
    }
    this.recoveryCompleted = true;
    this.recoveryPending = false;
    this.performRecovery();
  }

  private performRecovery(): void {
    SteamArkLog.startup(TAG, 'recovery started', 'incremental compensation');
    void steamArkSocialService.connectLoggedOnAccounts().catch((error: Error): void => {
      SteamArkLog.warn(TAG, 'social reconnection failed; errorType=' + SteamArkLog.errorKind(error));
    });
    void steamArkSyncCoordinator.requestSilentSync('hyper_snap_recovery').catch((error: Error): void => {
      SteamArkLog.warn(TAG, 'silent sync after recovery failed; errorType=' + SteamArkLog.errorKind(error));
    });
    steamArkWidgetStateCoordinator.start();
    SteamArkLog.startup(TAG, 'recovery dispatched', 'social+sync+widget');
  }
}

export const steamArkHyperSnapRecoveryCoordinator: SteamArkHyperSnapRecoveryCoordinator =
  new SteamArkHyperSnapRecoveryCoordinator();
