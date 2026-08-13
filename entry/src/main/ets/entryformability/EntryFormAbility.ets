import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { ngfSettingsStoreFacade } from 'ngf_framework';
import {
  SteamArkWidgetFormPayload,
  steamArkWidgetStateStore
} from '../steamServices';
import { SteamArkLog } from '../steamServices';

export default class EntryFormAbility extends FormExtensionAbility {
  private initializationPromise: Promise<boolean> | null = null;

  onAddForm(want: Want): formBindingData.FormBindingData {
    SteamArkLog.lifecycle('EntryFormAbility', 'onAddForm called');
    const formId: string = this.readFormId(want);
    void this.refreshAddedForm(formId);
    return this.createBindingData();
  }

  onCastToNormalForm(formId: string): void {
    SteamArkLog.lifecycle('EntryFormAbility', 'onCastToNormalForm; formId=' + SteamArkLog.opaqueId(formId));
  }

  onUpdateForm(formId: string): void {
    SteamArkLog.lifecycle('EntryFormAbility', 'onUpdateForm; formId=' + SteamArkLog.opaqueId(formId));
    void this.updateForm(formId);
  }

  onChangeFormVisibility(newStatus: Record<string, number>): void {
    SteamArkLog.lifecycle('EntryFormAbility', 'onChangeFormVisibility called');
  }

  onFormEvent(formId: string, message: string): void {
    SteamArkLog.lifecycle('EntryFormAbility', 'onFormEvent; formId=' + SteamArkLog.opaqueId(formId) +
      ', messageLength=' + message.length.toString());
    // Respond to widget message event (e.g., refresh button)
    if (message === 'refresh') {
      this.onUpdateForm(formId);
    }
  }

  onRemoveForm(formId: string): void {
    SteamArkLog.lifecycle('EntryFormAbility', 'onRemoveForm; formId=' + SteamArkLog.opaqueId(formId));
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    SteamArkLog.lifecycle('EntryFormAbility', 'onAcquireFormState');
    return formInfo.FormState.READY;
  }

  private createBindingData(): formBindingData.FormBindingData {
    const payload: SteamArkWidgetFormPayload = new SteamArkWidgetFormPayload(
      steamArkWidgetStateStore.getSnapshot()
    );
    return formBindingData.createFormBindingData(payload);
  }

  private async updateForm(formId: string): Promise<void> {
    try {
      const ready: boolean = await this.ensureStateStoreReady();
      if (!ready) {
        SteamArkLog.warn('EntryFormAbility', 'widget update deferred; state store is unavailable');
        return;
      }
      await formProvider.updateForm(formId, this.createBindingData());
      SteamArkLog.debug('EntryFormAbility', 'widget form updated; formId=' + SteamArkLog.opaqueId(formId));
    } catch (error) {
      SteamArkLog.error('EntryFormAbility', 'updateForm failed; formId=' + SteamArkLog.opaqueId(formId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private async refreshAddedForm(formId: string): Promise<void> {
    if (formId.length <= 0) {
      const ready: boolean = await this.ensureStateStoreReady();
      SteamArkLog.debug('EntryFormAbility', 'widget added without form identity; ready=' + String(ready));
      return;
    }
    try {
      const ready: boolean = await this.ensureStateStoreReady();
      if (!ready) {
        SteamArkLog.warn('EntryFormAbility', 'new widget refresh deferred; state store is unavailable; formId=' +
          SteamArkLog.opaqueId(formId));
        return;
      }
      await formProvider.updateForm(formId, this.createBindingData());
      SteamArkLog.debug('EntryFormAbility', 'new widget form refreshed; formId=' + SteamArkLog.opaqueId(formId));
    } catch (error) {
      SteamArkLog.error('EntryFormAbility', 'new widget refresh failed; formId=' +
        SteamArkLog.opaqueId(formId) + ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private readFormId(want: Want): string {
    const parameters: Record<string, Object> | undefined = want.parameters;
    if (parameters === undefined) {
      return '';
    }
    const value: Object | undefined = parameters[formInfo.FormParam.IDENTITY_KEY];
    return typeof value === 'string' ? value : '';
  }

  private async ensureStateStoreReady(): Promise<boolean> {
    const existing: Promise<boolean> | null = this.initializationPromise;
    if (existing !== null) {
      return await existing;
    }
    const task: Promise<boolean> = this.initializeStateStore();
    this.initializationPromise = task;
    try {
      return await task;
    } finally {
      if (this.initializationPromise === task) {
        this.initializationPromise = null;
      }
    }
  }

  private async initializeStateStore(): Promise<boolean> {
    const settingsReady: boolean = await ngfSettingsStoreFacade.initialize(this.context);
    const storeReady: boolean = await steamArkWidgetStateStore.initialize();
    SteamArkLog.startup('EntryFormAbility', 'widget state store initialized',
      'settings=' + String(settingsReady) + ', store=' + String(storeReady));
    return settingsReady && storeReady;
  }
}
