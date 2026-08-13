import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { SteamArkLog } from '../steamServices';

const TAG: string = 'EntryBackupAbility';

export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup() {
    SteamArkLog.lifecycle(TAG, 'onBackup');
    await Promise.resolve();
  }

  async onRestore(bundleVersion: BundleVersion) {
    SteamArkLog.lifecycle(TAG, 'onRestore', 'bundle version received');
    await Promise.resolve();
  }
}
