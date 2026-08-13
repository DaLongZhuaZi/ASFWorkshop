import { describe, expect, it } from '@ohos/hypium';
import { ISettingsStore } from 'ngf_framework';
import {
  SteamArkWidgetFormPayload,
  SteamArkWidgetStateStore
} from '../main/ets/steamServices';

class FakeWidgetSettingsStore implements ISettingsStore {
  private readonly values: Map<string, string>;
  failWrites: boolean = false;

  constructor(values: Map<string, string> = new Map<string, string>()) {
    this.values = values;
  }

  getString(key: string, defaultValue: string): string {
    const value: string | undefined = this.values.get(key);
    return value === undefined ? defaultValue : value;
  }

  getNumber(_key: string, defaultValue: number): number {
    return defaultValue;
  }

  getBoolean(_key: string, defaultValue: boolean): boolean {
    return defaultValue;
  }

  setString(key: string, value: string): void {
    this.values.set(key, value);
  }

  async setStringAsync(key: string, value: string): Promise<boolean> {
    if (this.failWrites) {
      return false;
    }
    this.values.set(key, value);
    return true;
  }

  setNumber(_key: string, _value: number): void {
    return;
  }

  setBoolean(_key: string, _value: boolean): void {
    return;
  }

  async waitUntilReady(): Promise<boolean> {
    return true;
  }
}

export default function steamArkWidgetStateStoreTest() {
  describe('SteamArkWidgetStateStoreTest', () => {
    it('loads defaults and creates a typed form payload', 0, async () => {
      const store = new SteamArkWidgetStateStore(new FakeWidgetSettingsStore());
      expect(await store.initialize()).assertTrue();
      const snapshot = store.getSnapshot();
      expect(snapshot.sessionState).assertEqual('disconnected');
      expect(snapshot.farmingState).assertEqual('disabled');
      expect(snapshot.accountCount).assertEqual(0);
      const payload = new SteamArkWidgetFormPayload(snapshot);
      expect(payload.steamSessionState).assertEqual('disconnected');
      expect(payload.steamAccountCount).assertEqual('0');
      expect(payload.lastUpdate).assertEqual('--:--:--');
    });

    it('merges account and farming changes into one persisted snapshot', 0, async () => {
      const values: Map<string, string> = new Map<string, string>();
      const store = new SteamArkWidgetStateStore(new FakeWidgetSettingsStore(values));
      expect(await store.updateAccountState('logged_on', 2)).assertTrue();
      expect(await store.updateFarmingState('running')).assertTrue();

      const restored = new SteamArkWidgetStateStore(new FakeWidgetSettingsStore(values));
      expect(await restored.initialize()).assertTrue();
      const snapshot = restored.getSnapshot();
      expect(snapshot.sessionState).assertEqual('logged_on');
      expect(snapshot.farmingState).assertEqual('running');
      expect(snapshot.accountCount).assertEqual(2);
      expect(snapshot.updatedAtEpochSeconds > 0).assertTrue();
    });

    it('normalizes invalid values and rejects a failed write without throwing', 0, async () => {
      const settings = new FakeWidgetSettingsStore();
      const store = new SteamArkWidgetStateStore(settings);
      settings.failWrites = true;
      expect(await store.updateAccountState('invalid', -2)).assertFalse();
      const snapshot = store.getSnapshot();
      expect(snapshot.sessionState).assertEqual('disconnected');
      expect(snapshot.accountCount).assertEqual(0);
    });
  });
}
