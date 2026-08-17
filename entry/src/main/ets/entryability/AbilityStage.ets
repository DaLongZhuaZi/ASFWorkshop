import { AbilityStage } from '@kit.AbilityKit';
import { steamArkHyperSnapRecoveryCoordinator, SteamArkLog } from '../steamServices';

const TAG: string = 'AbilityStage';

/**
 * Module-level component container. Receives Hyper Snap quick launch
 * callbacks (since API 24) so the product can compensate for resources that
 * do not survive the snapshot restore.
 */
export default class SteamArkAbilityStage extends AbilityStage {
  onLaunch(): void {
    SteamArkLog.lifecycle(TAG, 'onLaunch');
  }

  onLaunchFromHyperSnap(): void {
    SteamArkLog.startup(TAG, 'launchFromHyperSnap', 'process restored from hyper snap snapshot');
    steamArkHyperSnapRecoveryCoordinator.requestRecovery();
  }

  onAboutToCreateAbility(): void {
    SteamArkLog.lifecycle(TAG, 'onAboutToCreateAbility');
  }
}
