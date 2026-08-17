import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { clearContext, NGFAbilityContextLike, setContext } from '../GlobalContext';
import { NGFThemeMode, uiContextManager } from 'ngf_framework';
import { ngfStarterKernel } from 'ngf_framework';
import { ngfSettingsStoreFacade } from 'ngf_framework';
import { ngfDataIntegrationFacade } from 'ngf_framework';
import { ngfContentSourceIntegrationFacade } from 'ngf_framework';

import { ngfPlatformWindowManagerFacade } from 'ngf_framework';
import { ngfThemeManagerFacade } from 'ngf_framework';
import { ngfI18nManagerFacade } from 'ngf_framework';
import { ngfHoldingAwarenessFacade } from 'ngf_framework';
import { ngfDeviceAdaptationFacade } from 'ngf_framework';
import { ngfVisualEffectsFacade } from 'ngf_framework';
import { ngfSystem } from 'ngf_framework';
import { crashAnalytics } from 'ngf_framework';
import { ngfContinuationManagerFacade } from 'ngf_framework';
import {
  ISteamArkAccountLifecycle,
  SteamArkLog,
  STEAM_ARK_PROFILE_BACKGROUND_ENABLED_STORAGE_KEY,
  SteamArkNotificationChatLaunchRequest,
  SteamArkNotificationFarmingLaunchRequest,
  SteamArkNotificationMessageLaunchRequest,
  SteamArkNotificationNavigation,
  steamArkFarmingService,
  steamArkSocialService,
  steamArkGameLibraryService,
  steamArkStateService,
  steamArkSyncCoordinator,
  steamArkConfirmationService,
  steamArkWidgetStateCoordinator,
  steamArkHyperSnapRecoveryCoordinator
} from '../steamServices';
import {
  HarmonySteamAuthServiceFactory,
  HarmonySteamConfirmationClient,
  HarmonySteamFarmingNotificationPublisher,
  HarmonySteamFarmingRuntimeFactory,
  HarmonySteamGameLibraryAdapterFactory,
  HarmonySteamInventoryAdapterFactory,
  HarmonySteamMessageNotificationPublisher,
  HarmonySteamMessageResolver,
  HarmonySteamProfileResolver,
  HarmonySteamSocialNotificationPublisher,
  HarmonySteamSocialRuntimeFactory
} from '../steamAdapters';
import { SteamArkPageWindowSupport } from '../pages/steamArk/SteamArkPageWindowSupport';
import { steamArkFloatingWindowCoordinator } from '../pages/steamArk/SteamArkFloatingWindowCoordinator';
import { SteamArkNavigationBridge } from '../pages/steamArk/SteamArkNavigationBridge';
import { SteamArkMessageNavigationRequest, SteamArkRouteName } from '../pages/steamArk/SteamArkRoutes';

const TAG: string = 'EntryAbility';
const NAVIGATION_READY_LISTENER_ID: string = 'EntryAbility.NotificationNavigation';

class SteamArkAccountLifecycleAdapter implements ISteamArkAccountLifecycle {
  async stop(accountId: string): Promise<void> {
    let firstFailure: Error | null = null;
    try {
      await steamArkFloatingWindowCoordinator.closeWindowsForAccount(accountId);
    } catch (error) {
      firstFailure = error instanceof Error ? error : new Error('Steam floating window cleanup failed');
    }
    try {
      await steamArkSocialService.disconnectAccount(accountId);
    } catch (error) {
      if (firstFailure === null) {
        firstFailure = error instanceof Error ? error : new Error('Steam social runtime cleanup failed');
      }
    }
    try {
      await steamArkFarmingService.stop(accountId);
    } catch (error) {
      if (firstFailure === null) {
        firstFailure = error instanceof Error ? error : new Error('Steam farming cleanup failed');
      }
    }
    if (firstFailure !== null) {
      throw firstFailure;
    }
  }

  async remove(accountId: string): Promise<void> {
    let firstFailure: Error | null = null;
    try {
      await steamArkFloatingWindowCoordinator.closeWindowsForAccount(accountId);
    } catch (error) {
      firstFailure = error instanceof Error ? error : new Error('Steam floating window cleanup failed');
    }
    try {
      await steamArkFarmingService.removeAccount(accountId);
    } catch (error) {
      if (firstFailure === null) {
        firstFailure = error instanceof Error ? error : new Error('Steam farming removal failed');
      }
    }
    try {
      await steamArkSocialService.removeAccount(accountId);
    } catch (error) {
      if (firstFailure === null) {
        firstFailure = error instanceof Error ? error : new Error('Steam social removal failed');
      }
    }
    try {
      steamArkGameLibraryService.clearCachedAccount(accountId);
    } catch (error) {
      if (firstFailure === null) {
        firstFailure = error instanceof Error ? error : new Error('Steam game library cache cleanup failed');
      }
    }
    if (firstFailure !== null) {
      throw firstFailure;
    }
  }
}

export default class EntryAbility extends UIAbility {
  private isDestroying: boolean = false;
  private steamServicesReady: boolean = false;
  private homeContentReady: boolean = false;
  private notificationChatLaunchInProgress: boolean = false;
  private notificationChatLaunchGeneration: number = 0;
  private pendingNotificationChatLaunch: SteamArkNotificationChatLaunchRequest | null = null;
  private notificationMessageLaunchInProgress: boolean = false;
  private notificationMessageLaunchGeneration: number = 0;
  private pendingNotificationMessageLaunch: SteamArkNotificationMessageLaunchRequest | null = null;
  private notificationFarmingLaunchInProgress: boolean = false;
  private notificationFarmingLaunchGeneration: number = 0;
  private pendingNotificationFarmingLaunch: SteamArkNotificationFarmingLaunchRequest | null = null;
  private readonly homeStackReadyCallback = (): void => {
    if (!this.isDestroying) {
      void this.tryOpenPendingNotificationMessage();
      void this.tryOpenPendingNotificationFarming();
    }
  };
  private readonly themeChangedCallback = (_mode: NGFThemeMode): void => {
    SteamArkPageWindowSupport.refreshTheme();
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    SteamArkLog.lifecycle(TAG, 'onCreate');
    this.isDestroying = false;
    const abilityContext = this.context as NGFAbilityContextLike;
    setContext(abilityContext);
    uiContextManager.bindAbilityContext(this.context as common.UIAbilityContext);
    const bootstrapResult = ngfStarterKernel.bootstrap();
    SteamArkLog.startup(TAG, 'NGF bootstrap', 'success=' + String(bootstrapResult));
    steamArkStateService.setAuthServiceFactory(new HarmonySteamAuthServiceFactory());
    steamArkStateService.setInventoryAdapterFactory(new HarmonySteamInventoryAdapterFactory());
    const profileResolver: HarmonySteamProfileResolver = new HarmonySteamProfileResolver();
    steamArkStateService.setProfileResolver(profileResolver);
    steamArkStateService.setProfileVisualResolver(profileResolver);
    steamArkStateService.setMessageResolver(new HarmonySteamMessageResolver());
    steamArkSyncCoordinator.setMessageNotificationPublisher(new HarmonySteamMessageNotificationPublisher());
    steamArkSocialService.setRuntimeFactory(new HarmonySteamSocialRuntimeFactory());
    steamArkSocialService.setNotificationPublisher(new HarmonySteamSocialNotificationPublisher());
    steamArkGameLibraryService.setAdapterFactory(new HarmonySteamGameLibraryAdapterFactory());
    steamArkFarmingService.setRuntimeFactory(new HarmonySteamFarmingRuntimeFactory());
    steamArkFarmingService.setNotificationPublisher(new HarmonySteamFarmingNotificationPublisher());
    steamArkConfirmationService.setClient(new HarmonySteamConfirmationClient());
    steamArkStateService.setRegionChangeHandler(async (accountId: string): Promise<void> => {
      // Library names and badge names are language-dependent; the region save
      // already clears inventory and market caches inside the state service.
      steamArkGameLibraryService.clearCachedAccount(accountId);
      await steamArkFarmingService.clearBadgeReportForAccount(accountId);
    });
    steamArkStateService.setAccountLifecycle(new SteamArkAccountLifecycleAdapter());
    SteamArkNavigationBridge.onHomeStackReady(NAVIGATION_READY_LISTENER_ID, this.homeStackReadyCallback);
    crashAnalytics.initialize();
    SteamArkLog.startup(TAG, 'NGF services configured');

    // 解析流转数据
    if (want.parameters) {
      ngfContinuationManagerFacade.receiveContinuationData(want.parameters as Record<string, Object>);
    }
    this.captureNotificationLaunches(want);

    /**
     * API 23 适配说明：
     * getApplicationContext().setColorMode() 在 API 21 已废弃
     * 颜色模式现在通过 ThemeManagerFacade 统一管理
     * 系统颜色模式变化通过 onConfigurationUpdate 监听
     */
    SteamArkLog.info(TAG, 'ThemeManagerFacade owns system color mode updates');

    ngfThemeManagerFacade.initializeDefaults();
    ngfThemeManagerFacade.onThemeChanged(this.themeChangedCallback);
    ngfI18nManagerFacade.initializeDefaults();
    // ASF工坊使用握持感知为 HDS 导航和高频操作提供手持方向适配。
    void ngfHoldingAwarenessFacade.initialize().then((): void => {
      SteamArkLog.startup(TAG, 'holding awareness initialized');
    }).catch((_error: Error): void => {
      SteamArkLog.warn(TAG, 'holding awareness initialization failed');
    });
    void ngfVisualEffectsFacade.initialize().then((): void => {
      SteamArkLog.startup(TAG, 'visual effects initialized');
    }).catch((_error: Error): void => {
      SteamArkLog.warn(TAG, 'visual effects initialization failed');
    });

    SteamArkLog.lifecycle(TAG, 'onCreate completed');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    SteamArkLog.lifecycle(TAG, 'onNewWant');
    if (want.parameters) {
      ngfContinuationManagerFacade.receiveContinuationData(want.parameters as Record<string, Object>);
      SteamArkLog.info(TAG, 'continuation data received');
    }
    this.captureNotificationLaunches(want);
  }

  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    SteamArkLog.lifecycle(TAG, 'onContinue');
    try {
      ngfContinuationManagerFacade.collectAllContinuationData(wantParam);
      SteamArkLog.info(TAG, 'continuation data collected');
      return AbilityConstant.OnContinueResult.AGREE;
    } catch (e) {
      SteamArkLog.error(TAG, 'continuation data collection failed');
      return AbilityConstant.OnContinueResult.REJECT;
    }
  }

  async onDestroy(): Promise<void> {
    SteamArkLog.lifecycle(TAG, 'onDestroy');
    this.isDestroying = true;
    this.steamServicesReady = false;
    this.homeContentReady = false;
    this.notificationChatLaunchGeneration++;
    this.pendingNotificationChatLaunch = null;
    this.notificationMessageLaunchGeneration++;
    this.pendingNotificationMessageLaunch = null;
    SteamArkNavigationBridge.offHomeStackReady(NAVIGATION_READY_LISTENER_ID);
    // Start the state-service disposal barrier before CM, web, social, and
    // farming runtimes begin closing. Their late callbacks must not persist a
    // logged-on account as disconnected while a replacement ability starts.
    const stateDisposePromise: Promise<void> = steamArkStateService.dispose();
    // Capture the old social runtime before a replacement ability can configure
    // its own factory. The service protects the captured instances by generation.
    const socialDisposePromise: Promise<void> = steamArkSocialService.dispose();
    // Capture farming runtime instances before the next ability configures its
    // factory, so stale cleanup cannot clear the replacement farm runtime.
    const farmingDisposePromise: Promise<void> = steamArkFarmingService.dispose();
    steamArkWidgetStateCoordinator.stop();
    steamArkFloatingWindowCoordinator.releaseForAbilityTeardown();
    ngfThemeManagerFacade.offThemeChanged(this.themeChangedCallback);
    try {
      await this.disposeSteamServices(stateDisposePromise, socialDisposePromise, farmingDisposePromise);
    } finally {
      ngfHoldingAwarenessFacade.destroy();
      uiContextManager.clearAbilityContext();
      clearContext();
      crashAnalytics.terminate();
      SteamArkLog.lifecycle(TAG, 'onDestroy completed');
    }
  }

  private async disposeSteamServices(
    stateDisposePromise: Promise<void>,
    socialDisposePromise: Promise<void>,
    farmingDisposePromise: Promise<void>
  ): Promise<void> {
    try {
      await steamArkSyncCoordinator.stop();
      SteamArkLog.info(TAG, 'Steam synchronization coordinator stopped');
    } catch {
      SteamArkLog.error(TAG, 'Steam synchronization coordinator stop failed');
    }
    try {
      await socialDisposePromise;
      SteamArkLog.info(TAG, 'Steam social service disposed');
    } catch {
      SteamArkLog.error(TAG, 'Steam social service dispose failed');
    }
    try {
      await farmingDisposePromise;
      SteamArkLog.info(TAG, 'Steam farming service disposed');
    } catch {
      SteamArkLog.error(TAG, 'Steam farming service dispose failed');
    }
    try {
      await stateDisposePromise;
      SteamArkLog.info(TAG, 'Steam state service runtime resources released');
    } catch {
      SteamArkLog.error(TAG, 'Steam state service dispose failed');
    }
  }

  private async initializeSteamServices(): Promise<void> {
    try {
      const settingsReady: boolean = await ngfSettingsStoreFacade.initialize(this.context);
      SteamArkLog.startup(TAG, 'Settings store initialized', 'success=' + String(settingsReady));
      if (this.isDestroying) {
        SteamArkLog.debug(TAG, 'Steam service initialization cancelled during destroy');
        return;
      }
      if (!settingsReady) {
        SteamArkLog.warn(TAG, 'Steam service initialization deferred; settings store is unavailable');
        return;
      }
      // Load the profile-background preference into AppStorage before any
      // page renders, so the default solid background can be enforced.
      AppStorage.setOrCreate<boolean>(
        STEAM_ARK_PROFILE_BACKGROUND_ENABLED_STORAGE_KEY,
        ngfSettingsStoreFacade.getBoolean(STEAM_ARK_PROFILE_BACKGROUND_ENABLED_STORAGE_KEY, true)
      );
      ngfDataIntegrationFacade.initializeRuntime(this.context as common.UIAbilityContext);
      ngfContentSourceIntegrationFacade.initializeRuntime(this.context as common.UIAbilityContext);
      steamArkWidgetStateCoordinator.start();
      const initialized: boolean = await steamArkStateService.initialize();
      SteamArkLog.startup(TAG, 'Steam state service initialized', 'success=' + String(initialized));
      if (!initialized) {
        SteamArkLog.warn(TAG, 'Steam state service remains unavailable until settings storage is ready');
      } else {
        await steamArkSyncCoordinator.start();
        SteamArkLog.startup(TAG, 'Steam synchronization coordinator started');
        this.steamServicesReady = true;
        steamArkHyperSnapRecoveryCoordinator.notifyServicesReady();
        void this.tryOpenPendingNotificationChat();
        void this.tryOpenPendingNotificationMessage();
      }
    } catch (error) {
      SteamArkLog.error(TAG, 'Steam service initialization failed; errorType=' + SteamArkLog.errorKind(error));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    SteamArkLog.lifecycle(TAG, 'onWindowStageCreate');
    this.homeContentReady = false;
    this.steamServicesReady = false;
    ngfPlatformWindowManagerFacade.bindWindowStage(windowStage);
    ngfDeviceAdaptationFacade.bindWindowStage(windowStage);
    SteamArkLog.info(TAG, 'window stage managers bound');

    void this.initializeSteamServices();
    windowStage.loadContent('pages/steamArk/SteamArkHomePage', (err: BusinessError): void => {
      if (err.code !== 0) {
        SteamArkLog.error(TAG, 'SteamArkHomePage content load failed; code=' + String(err.code));
        return;
      }
      SteamArkLog.info(TAG, 'SteamArkHomePage content loaded');
      this.homeContentReady = true;
      void this.tryOpenPendingNotificationChat();
      void this.tryOpenPendingNotificationMessage();
      void ngfSystem.requestNotificationPermission().then((enabled: boolean): void => {
        SteamArkLog.info(TAG, 'System notification permission checked; enabled=' + String(enabled));
      }).catch((error: Error): void => {
        SteamArkLog.warn(TAG, 'System notification permission check failed; errorType=' +
          SteamArkLog.errorKind(error));
      });
    });
  }

  onWindowStageDestroy(): void {
    SteamArkLog.lifecycle(TAG, 'onWindowStageDestroy');
    this.homeContentReady = false;
    steamArkFloatingWindowCoordinator.onWindowStageDestroyed();
    ngfDeviceAdaptationFacade.clearWindowStage();
    ngfPlatformWindowManagerFacade.clearWindowStage();
    SteamArkLog.info(TAG, 'window stage managers cleared');
  }

  onForeground(): void {
    SteamArkLog.lifecycle(TAG, 'onForeground');
    ngfDeviceAdaptationFacade.refresh('ability_foreground');
    void ngfHoldingAwarenessFacade.resume().then((): void => {
      SteamArkLog.info(TAG, 'holding awareness resumed');
    }).catch((_error: Error): void => {
      SteamArkLog.warn(TAG, 'holding awareness resume failed');
    });
    void steamArkSyncCoordinator.requestSilentSync('ability_foreground');
  }

  onBackground(): void {
    SteamArkLog.lifecycle(TAG, 'onBackground');
  }

  onConfigurationUpdate(config: Configuration): void {
    SteamArkLog.info(TAG, 'configuration updated; colorMode=' + String(config.colorMode) +
      ', language=' + String(config.language));
    ngfDeviceAdaptationFacade.refresh('configuration_update');

    const colorMode = config.colorMode;
    if (colorMode !== undefined) {
      ngfThemeManagerFacade.handleSystemColorModeChanged(colorMode);
    }

    const language = config.language;
    if (language !== undefined) {
      ngfI18nManagerFacade.handleSystemLocaleChanged(language);
    }
  }

  private captureNotificationLaunches(want: Want): void {
    this.captureNotificationChatLaunch(want);
    this.captureNotificationMessageLaunch(want);
    this.captureNotificationFarmingLaunch(want);
  }

  private captureNotificationChatLaunch(want: Want): void {
    const request: SteamArkNotificationChatLaunchRequest | null =
      SteamArkNotificationNavigation.readOpenChatRequest(want.parameters);
    if (request === null) {
      return;
    }
    this.pendingNotificationChatLaunch = request;
    this.notificationChatLaunchGeneration++;
    SteamArkLog.info(TAG, 'notification chat launch queued; account=' +
      SteamArkLog.accountId(request.accountId) + ', friend=' + SteamArkLog.steamId64(request.friendSteamId64));
    void this.tryOpenPendingNotificationChat();
  }

  private captureNotificationMessageLaunch(want: Want): void {
    const request: SteamArkNotificationMessageLaunchRequest | null =
      SteamArkNotificationNavigation.readOpenMessageRequest(want.parameters);
    if (request === null) {
      return;
    }
    this.pendingNotificationMessageLaunch = request;
    this.notificationMessageLaunchGeneration++;
    SteamArkLog.info(TAG, 'notification message launch queued; account=' +
      SteamArkLog.accountId(request.accountId) + ', message=' + SteamArkLog.opaqueId(request.messageId));
    void this.tryOpenPendingNotificationMessage();
  }

  private async tryOpenPendingNotificationChat(): Promise<void> {
    if (this.isDestroying || !this.steamServicesReady || !this.homeContentReady ||
      this.notificationChatLaunchInProgress || this.pendingNotificationChatLaunch === null) {
      return;
    }
    const request: SteamArkNotificationChatLaunchRequest = this.pendingNotificationChatLaunch;
    const generation: number = this.notificationChatLaunchGeneration;
    this.notificationChatLaunchInProgress = true;
    try {
      const selectedAccountId: string = steamArkStateService.getSnapshot().selectedAccountId;
      if (selectedAccountId !== request.accountId) {
        const selected: boolean = await steamArkStateService.selectAccount(request.accountId);
        if (!selected) {
          this.clearPendingNotificationChatLaunch(generation);
          SteamArkLog.warn(TAG, 'notification chat launch rejected because the target account is unavailable; account=' +
            SteamArkLog.accountId(request.accountId));
          return;
        }
      }
      if (this.isDestroying || generation !== this.notificationChatLaunchGeneration) {
        return;
      }
      if (steamArkStateService.getSnapshot().selectedAccountId !== request.accountId) {
        SteamArkLog.warn(TAG, 'notification chat launch deferred because account selection changed; account=' +
          SteamArkLog.accountId(request.accountId));
        return;
      }
      await steamArkFloatingWindowCoordinator.openChat(request.accountId, request.friendSteamId64);
      this.clearPendingNotificationChatLaunch(generation);
      SteamArkLog.info(TAG, 'notification chat launch completed; account=' +
        SteamArkLog.accountId(request.accountId) + ', friend=' + SteamArkLog.steamId64(request.friendSteamId64));
    } catch (error) {
      SteamArkLog.warn(TAG, 'notification chat launch failed; account=' + SteamArkLog.accountId(request.accountId) +
        ', friend=' + SteamArkLog.steamId64(request.friendSteamId64) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      this.notificationChatLaunchInProgress = false;
      if (!this.isDestroying && this.pendingNotificationChatLaunch !== null &&
        generation !== this.notificationChatLaunchGeneration) {
        void this.tryOpenPendingNotificationChat();
      }
    }
  }

  private clearPendingNotificationChatLaunch(generation: number): void {
    if (generation === this.notificationChatLaunchGeneration) {
      this.pendingNotificationChatLaunch = null;
    }
  }

  private async tryOpenPendingNotificationMessage(): Promise<void> {
    if (this.isDestroying || !this.steamServicesReady || !this.homeContentReady ||
      this.notificationMessageLaunchInProgress || this.pendingNotificationMessageLaunch === null) {
      return;
    }
    const request: SteamArkNotificationMessageLaunchRequest = this.pendingNotificationMessageLaunch;
    const generation: number = this.notificationMessageLaunchGeneration;
    this.notificationMessageLaunchInProgress = true;
    try {
      const selectedAccountId: string = steamArkStateService.getSnapshot().selectedAccountId;
      if (selectedAccountId !== request.accountId) {
        const selected: boolean = await steamArkStateService.selectAccount(request.accountId);
        if (!selected) {
          this.clearPendingNotificationMessageLaunch(generation);
          SteamArkLog.warn(TAG, 'notification message launch rejected because the target account is unavailable; account=' +
            SteamArkLog.accountId(request.accountId));
          return;
        }
      }
      if (this.isDestroying || generation !== this.notificationMessageLaunchGeneration) {
        return;
      }
      if (steamArkStateService.getSnapshot().selectedAccountId !== request.accountId) {
        SteamArkLog.warn(TAG, 'notification message launch deferred because account selection changed; account=' +
          SteamArkLog.accountId(request.accountId));
        return;
      }
      const opened: boolean = SteamArkNavigationBridge.pushHomeRoute(
        SteamArkRouteName.MESSAGES,
        new SteamArkMessageNavigationRequest(request.accountId, request.messageId)
      );
      if (!opened) {
        SteamArkLog.warn(TAG, 'notification message launch awaiting the home navigation stack; account=' +
          SteamArkLog.accountId(request.accountId));
        return;
      }
      this.clearPendingNotificationMessageLaunch(generation);
      SteamArkLog.info(TAG, 'notification message launch completed; account=' +
        SteamArkLog.accountId(request.accountId) + ', message=' + SteamArkLog.opaqueId(request.messageId));
    } catch (error) {
      SteamArkLog.warn(TAG, 'notification message launch failed; account=' + SteamArkLog.accountId(request.accountId) +
        ', message=' + SteamArkLog.opaqueId(request.messageId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      this.notificationMessageLaunchInProgress = false;
      if (!this.isDestroying && this.pendingNotificationMessageLaunch !== null &&
        generation !== this.notificationMessageLaunchGeneration) {
        void this.tryOpenPendingNotificationMessage();
      }
    }
  }

  private captureNotificationFarmingLaunch(want: Want): void {
    const request: SteamArkNotificationFarmingLaunchRequest | null =
      SteamArkNotificationNavigation.readOpenFarmingRequest(want.parameters);
    if (request === null) {
      return;
    }
    this.pendingNotificationFarmingLaunch = request;
    this.notificationFarmingLaunchGeneration++;
    SteamArkLog.info(TAG, 'notification farming launch queued; account=' +
      SteamArkLog.accountId(request.accountId));
    void this.tryOpenPendingNotificationFarming();
  }

  private clearPendingNotificationMessageLaunch(generation: number): void {
    if (generation === this.notificationMessageLaunchGeneration) {
      this.pendingNotificationMessageLaunch = null;
    }
  }

  private async tryOpenPendingNotificationFarming(): Promise<void> {
    if (this.isDestroying || !this.steamServicesReady || !this.homeContentReady ||
      this.notificationFarmingLaunchInProgress || this.pendingNotificationFarmingLaunch === null) {
      return;
    }
    const request: SteamArkNotificationFarmingLaunchRequest = this.pendingNotificationFarmingLaunch;
    const generation: number = this.notificationFarmingLaunchGeneration;
    this.notificationFarmingLaunchInProgress = true;
    try {
      const selectedAccountId: string = steamArkStateService.getSnapshot().selectedAccountId;
      if (selectedAccountId !== request.accountId) {
        const selected: boolean = await steamArkStateService.selectAccount(request.accountId);
        if (!selected) {
          this.clearPendingNotificationFarmingLaunch(generation);
          SteamArkLog.warn(TAG, 'notification farming launch rejected because the target account is unavailable; account=' +
            SteamArkLog.accountId(request.accountId));
          return;
        }
      }
      if (this.isDestroying || generation !== this.notificationFarmingLaunchGeneration) {
        return;
      }
      if (steamArkStateService.getSnapshot().selectedAccountId !== request.accountId) {
        SteamArkLog.warn(TAG, 'notification farming launch deferred because account selection changed; account=' +
          SteamArkLog.accountId(request.accountId));
        return;
      }
      const opened: boolean = SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.WORKSPACE, null);
      if (!opened) {
        SteamArkLog.warn(TAG, 'notification farming launch awaiting the home navigation stack; account=' +
          SteamArkLog.accountId(request.accountId));
        return;
      }
      this.clearPendingNotificationFarmingLaunch(generation);
      SteamArkLog.info(TAG, 'notification farming launch completed; account=' +
        SteamArkLog.accountId(request.accountId));
    } catch (error) {
      SteamArkLog.warn(TAG, 'notification farming launch failed; account=' +
        SteamArkLog.accountId(request.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      this.notificationFarmingLaunchInProgress = false;
      if (!this.isDestroying && this.pendingNotificationFarmingLaunch !== null &&
        generation !== this.notificationFarmingLaunchGeneration) {
        void this.tryOpenPendingNotificationFarming();
      }
    }
  }

  private clearPendingNotificationFarmingLaunch(generation: number): void {
    if (generation === this.notificationFarmingLaunchGeneration) {
      this.pendingNotificationFarmingLaunch = null;
    }
  }
}
