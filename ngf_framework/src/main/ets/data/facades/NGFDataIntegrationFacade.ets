import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { NGFIntegrationFacadeBase } from '../../core/facades/NGFIntegrationFacadeBase';
import { NGFServiceRegistration } from '../../core/contracts/NGFServiceRegistration';
import { logger } from '../../utils/Logger';
import { FileUtils } from '../../utils/FileUtils';
import { SettingsManager } from '../SettingsManager';
import { ngfCacheStoreFacade } from './CacheStoreFacade';
import { ngfDataFacade } from './DataFacade';
import { ngfDbMigratorFacade } from './DbMigratorFacade';
import { ngfRelationalStoreFacade } from './RelationalStoreFacade';
import { ngfSettingsStoreFacade } from './SettingsStoreFacade';
import { ngfStorageProviderFacade } from './StorageProviderFacade';
import { ngfSyncManagerFacade } from './SyncManagerFacade';
import { ngfEncryptedSettingsStore } from './EncryptedSettingsStoreFacade';

const TAG: string = 'NGFDataIntegrationFacade';
const DB_NAME: string = 'ngf_data.db';

export class NGFDataIntegrationFacade extends NGFIntegrationFacadeBase {
  protected readonly tag: string = 'NGFDataIntegrationFacade';
  protected readonly appStorageKey: string = 'ngf_data_integrated';
  private runtimeInitialized: boolean = false;

  protected getServiceRegistrations(): Array<NGFServiceRegistration> {
    const registrations: Array<NGFServiceRegistration> = [];
    registrations.push(new NGFServiceRegistration('ngf.data.data_facade', 'DataFacade', ngfDataFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.data.settings_store', 'SettingsStoreFacade', ngfSettingsStoreFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.data.cache_store', 'CacheStoreFacade', ngfCacheStoreFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.data.storage_provider', 'StorageProviderFacade', ngfStorageProviderFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.data.db_migrator', 'DbMigratorFacade', ngfDbMigratorFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.data.relational_store', 'RelationalStoreFacade', ngfRelationalStoreFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.data.sync_manager', 'SyncManagerFacade', ngfSyncManagerFacade as object));
    registrations.push(new NGFServiceRegistration('ngf.data.encrypted_settings_store', 'EncryptedSettingsStoreFacade', ngfEncryptedSettingsStore as object));
    return registrations;
  }

  protected onBootstrapped(): void {
    // Module bootstrap can run from onCreate before the WindowStage context is
    // valid for Preferences/RDB. Runtime data initialization is started by the
    // ability after onWindowStageCreate.
    logger.debug(TAG, '数据模块已引导，等待有效 AbilityContext 后初始化运行时');
  }

  initializeRuntime(context: common.UIAbilityContext): void {
    if (this.runtimeInitialized) {
      return;
    }
    this.runtimeInitialized = true;
    FileUtils.setSandboxBaseDir(context.filesDir);
    ngfStorageProviderFacade.initialize(context.filesDir);
    void SettingsManager.getInstance().initialize(context);
    void this.initializeRdb(context);
    logger.info(TAG, '数据运行时初始化完成');
  }

  private async initializeRdb(context: common.UIAbilityContext): Promise<void> {
    try {
      const storeConfig: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      await ngfRelationalStoreFacade.initialize(context, storeConfig);
      const rdbStore = ngfRelationalStoreFacade.getRdbStore();
      if (rdbStore !== null) {
        ngfDbMigratorFacade.initialize(rdbStore);
        logger.info(TAG, 'RDB 和 DbMigrator 初始化完成');
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logger.error(TAG, 'RDB 初始化异常: ' + message);
    }
  }
}

export const ngfDataIntegrationFacade = new NGFDataIntegrationFacade();
