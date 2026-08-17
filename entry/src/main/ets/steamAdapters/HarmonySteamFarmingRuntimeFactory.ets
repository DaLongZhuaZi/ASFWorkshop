import {
  IHttpSession,
  NGFHttpSession,
  NGFProxyConfiguration
} from 'ngf_framework';
import {
  FarmingCoordinator,
  IClock,
  IStateStore,
  SteamAccountProfile,
  SteamBadgeSyncReport,
  SteamBotConfig,
  SteamCmClient,
  SteamCmClientOptions,
  SteamCmEndpoint,
  SteamCmEvent,
  SteamCredentialSet,
  SteamFarmEvent,
  SteamFarmEventListener,
  SteamFarmEventType,
  SteamFarmPauseMode,
  SteamFarmSnapshot,
  SteamFarmingBridge,
  SteamFarmingBridgeOptions,
  SteamProxyKind,
  SteamSessionSnapshot,
  SteamSessionState,
  SteamWebSession
} from 'steam_core';
import {
  ISteamArkFarmingRuntime,
  ISteamArkFarmingRuntimeFactory,
  SteamSessionEventListener
} from '../steamServices/SteamArkFarmingContracts';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { SteamArkContentLocale } from '../steamServices/SteamArkRegionPolicy';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';
import { HarmonySteamClock, HarmonySteamCmMultiDecompressor, HarmonySteamCmScheduler } from './HarmonySteamCmRuntime';
import { HarmonySteamCmClientFactory } from './HarmonySteamCmClientFactory';
import {
  HarmonySteamCmWireTransportOptions
} from './HarmonySteamCmWireTransport';
import { HarmonySteamWebSessionFactory } from './HarmonySteamWebSessionFactory';

const DEFAULT_CM_SERVER: string = SteamCmEndpoint.DEFAULT_SERVER;
const DEFAULT_USER_AGENT: string = ASFWorkshopProductIdentity.userAgent();
const TAG: string = 'HarmonySteamFarmingRuntime';
const CM_CONNECTION_GATE_REASON: string =
  'Real Steam farming is disabled until WSS TLS, ClientHello, proxy behavior and API26 connection verification are complete';

/** Runtime options are explicit so the real-network release gate is visible. */
export class HarmonySteamFarmingRuntimeOptions {
  readonly cmServer: string;
  readonly userAgent: string;
  readonly cmLogonTimeoutSeconds: number;
  readonly enabled: boolean;

  constructor(
    cmServer: string = DEFAULT_CM_SERVER,
    userAgent: string = DEFAULT_USER_AGENT,
    cmLogonTimeoutSeconds: number = 60,
    enabled: boolean = true
  ) {
    if (cmServer.trim().length <= 0) {
      throw new Error('Steam CM server is required');
    }
    if (cmLogonTimeoutSeconds <= 0 || Math.floor(cmLogonTimeoutSeconds) !== cmLogonTimeoutSeconds) {
      throw new Error('Steam CM logon timeout must be a positive integer');
    }
    this.cmServer = cmServer;
    this.userAgent = userAgent;
    this.cmLogonTimeoutSeconds = cmLogonTimeoutSeconds;
    this.enabled = enabled;
  }
}

/**
 * One account's HarmonyOS composition root. All Steam protocol behavior is
 * delegated to steam_core; this class only owns platform adapters and timers.
 */
export class HarmonySteamFarmingRuntime implements ISteamArkFarmingRuntime {
  readonly accountId: string;
  private readonly cmClient: SteamCmClient;
  private readonly providedCredentials: SteamCredentialSet;
  private readonly webSession: SteamWebSession;
  private readonly coordinator: FarmingCoordinator;
  private readonly bridge: SteamFarmingBridge;
  private readonly scheduler: HarmonySteamCmScheduler;
  private readonly clock: IClock;
  private readonly options: HarmonySteamFarmingRuntimeOptions;
  private readonly farmListeners: Array<SteamFarmEventListener> = [];
  private readonly sessionListeners: Array<SteamSessionEventListener> = [];
  private readonly cmListener: (event: SteamCmEvent) => void;
  private readonly farmListener: SteamFarmEventListener;
  private started: boolean = false;
  private disposed: boolean = false;

  constructor(
    profile: SteamAccountProfile,
    config: SteamBotConfig,
    credentials: SteamCredentialSet,
    stateStore: IStateStore,
    proxyPassword: string = '',
    locale: SteamArkContentLocale | null = null,
    options: HarmonySteamFarmingRuntimeOptions = new HarmonySteamFarmingRuntimeOptions()
  ) {
    this.accountId = profile.accountId;
    this.providedCredentials = credentials;
    this.options = options;
    this.scheduler = new HarmonySteamCmScheduler();
    this.clock = new HarmonySteamClock();
    const proxy = HarmonySteamFarmingRuntime.toProxy(profile, proxyPassword);
    const cmLanguage: string = locale !== null ? locale.steamLanguage : 'english';
    const cmOptions = new SteamCmClientOptions(
      options.cmServer,
      profile.steamId64,
      ASFWorkshopProductIdentity.DEVICE_FRIENDLY_NAME,
      65581,
      1771,
      cmLanguage,
      0,
      30,
      2,
      60,
      0,
      Math.min(32, Math.max(1, config.maxGamesPlayedConcurrently)),
      '',
      '',
      true,
      true,
      steamArkCoreLogger,
      30000,
      new HarmonySteamCmMultiDecompressor()
    );
    const wireOptions = new HarmonySteamCmWireTransportOptions(
      proxy,
      options.userAgent + ' SteamCm'
    );
    this.cmClient = HarmonySteamCmClientFactory.create(
      profile.accountId,
      credentials,
      cmOptions,
      wireOptions
    );
    const httpSession: IHttpSession = new NGFHttpSession();
    this.webSession = HarmonySteamWebSessionFactory.create(
      httpSession,
      this.clock,
      profile.steamId64,
      proxy,
      options.userAgent + ' SteamWeb',
      cmLanguage
    );
    this.coordinator = new FarmingCoordinator(
      profile.accountId,
      config,
      this.cmClient,
      stateStore,
      this.clock,
      steamArkCoreLogger
    );
    this.bridge = new SteamFarmingBridge(
      profile.accountId,
      this.cmClient,
      this.webSession,
      this.coordinator,
      this.scheduler,
      new SteamFarmingBridgeOptions(
        300,
        60,
        (report: SteamBadgeSyncReport, snapshot: SteamFarmSnapshot): void => {
          this.notifyFarm(new SteamFarmEvent(
            SteamFarmEventType.BADGE_SYNCED,
            snapshot,
            null,
            'Badge synchronization completed',
            report
          ));
        },
        steamArkCoreLogger
      )
    );
    this.cmListener = (event: SteamCmEvent): void => {
      SteamArkLog.debug(TAG, 'CM event received by farming runtime; account=' +
        SteamArkLog.accountId(this.accountId) + ', type=' + String(event.type) +
        ', sessionState=' + String(this.cmClient.session.state));
      this.notifySession(this.cmClient.session);
    };
    this.farmListener = (event: SteamFarmEvent): void => {
      this.notifyFarm(event);
    };
    this.cmClient.addEventListener(this.cmListener);
    this.coordinator.addEventListener(this.farmListener);
    SteamArkLog.info(TAG, 'farming runtime constructed; account=' + SteamArkLog.accountId(this.accountId) +
      ', enabled=' + String(options.enabled) + ', maxGames=' +
      cmOptions.maxGamesPlayedConcurrently.toString());
  }

  get session(): SteamSessionSnapshot {
    return this.cmClient.session;
  }

  get snapshot(): SteamFarmSnapshot {
    return this.coordinator.getSnapshot();
  }

  async load(): Promise<SteamFarmSnapshot> {
    this.ensureAvailable();
    SteamArkLog.debug(TAG, 'farming runtime state load started; account=' + SteamArkLog.accountId(this.accountId));
    try {
      const snapshot = await this.coordinator.load();
      this.notifyFarmSnapshot(snapshot);
      SteamArkLog.info(TAG, 'farming runtime state load completed; account=' +
        SteamArkLog.accountId(this.accountId) + ', state=' + String(snapshot.state));
      return snapshot;
    } catch (error) {
      SteamArkLog.warn(TAG, 'farming runtime state load failed; account=' +
        SteamArkLog.accountId(this.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      throw error instanceof Error ? error : new Error('Steam farming runtime state load failed');
    }
  }

  async refreshGames(): Promise<SteamFarmSnapshot> {
    this.ensureAvailable();
    SteamArkLog.info(TAG, 'read-only farming game refresh started; account=' +
      SteamArkLog.accountId(this.accountId));
    let openedForRefresh: boolean = false;
    try {
      if (!this.started) {
        await this.webSession.open(this.accountId, this.credentials());
        openedForRefresh = true;
      }
      const snapshot = await this.bridge.refreshBadges();
      this.notifyFarmSnapshot(snapshot);
      SteamArkLog.info(TAG, 'read-only farming game refresh completed; account=' +
        SteamArkLog.accountId(this.accountId) + ', games=' + snapshot.games.length.toString());
      return snapshot;
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming game refresh failed');
      SteamArkLog.warn(TAG, 'read-only farming game refresh failed; account=' +
        SteamArkLog.accountId(this.accountId) + ', errorType=' + SteamArkLog.errorKind(normalized));
      throw normalized;
    } finally {
      if (openedForRefresh && !this.started) {
        try {
          await this.webSession.close(this.accountId);
        } catch (error) {
          SteamArkLog.warn(TAG, 'read-only Web session close failed; account=' +
            SteamArkLog.accountId(this.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
        }
      }
    }
  }

  async start(): Promise<SteamFarmSnapshot> {
    this.ensureAvailable();
    SteamArkLog.info(TAG, 'farming runtime start requested; account=' + SteamArkLog.accountId(this.accountId));
    if (this.started) {
      SteamArkLog.debug(TAG, 'farming runtime start skipped; already started; account=' +
        SteamArkLog.accountId(this.accountId));
      return this.snapshot;
    }
    try {
      await this.webSession.open(this.accountId, this.credentials());
      await this.cmClient.connect();
      await this.waitForCmLogon();
      const snapshot = await this.bridge.start();
      this.started = true;
      SteamArkLog.info(TAG, 'farming runtime start completed; account=' + SteamArkLog.accountId(this.accountId) +
        ', state=' + String(snapshot.state));
      this.notifySession(this.cmClient.session);
      this.notifyFarmSnapshot(snapshot);
      return snapshot;
    } catch (error) {
      const normalized = this.normalizeError(error, 'Steam farming runtime start failed');
      SteamArkLog.error(TAG, 'farming runtime start failed; account=' + SteamArkLog.accountId(this.accountId) +
        ', errorType=' + SteamArkLog.errorKind(normalized));
      await this.closeTransports();
      throw normalized;
    }
  }

  async pause(): Promise<SteamFarmSnapshot> {
    this.ensureAvailable();
    SteamArkLog.info(TAG, 'farming runtime pause requested; account=' + SteamArkLog.accountId(this.accountId));
    if (!this.started) {
      SteamArkLog.debug(TAG, 'farming runtime pause skipped; not started; account=' +
        SteamArkLog.accountId(this.accountId));
      return this.snapshot;
    }
    const snapshot = await this.coordinator.pause();
    this.notifyFarmSnapshot(snapshot);
    SteamArkLog.info(TAG, 'farming runtime pause completed; account=' + SteamArkLog.accountId(this.accountId) +
      ', state=' + String(snapshot.state));
    return snapshot;
  }

  async pauseFor(pauseMode: SteamFarmPauseMode, seconds: number): Promise<SteamFarmSnapshot> {
    this.ensureAvailable();
    SteamArkLog.info(TAG, 'farming runtime pause variant requested; account=' +
      SteamArkLog.accountId(this.accountId) + ', mode=' + String(pauseMode) +
      ', seconds=' + seconds.toString());
    if (!this.started) {
      SteamArkLog.debug(TAG, 'farming runtime pause variant skipped; not started; account=' +
        SteamArkLog.accountId(this.accountId));
      return this.snapshot;
    }
    let snapshot: SteamFarmSnapshot;
    if (pauseMode === SteamFarmPauseMode.TIMED) {
      snapshot = await this.coordinator.pauseForSeconds(seconds);
    } else {
      snapshot = await this.coordinator.pauseTemporarily();
    }
    this.notifyFarmSnapshot(snapshot);
    return snapshot;
  }

  async resume(): Promise<SteamFarmSnapshot> {
    this.ensureAvailable();
    SteamArkLog.info(TAG, 'farming runtime resume requested; account=' + SteamArkLog.accountId(this.accountId));
    if (!this.started) {
      return await this.start();
    }
    const snapshot = await this.coordinator.resume();
    this.notifyFarmSnapshot(snapshot);
    SteamArkLog.info(TAG, 'farming runtime resume completed; account=' + SteamArkLog.accountId(this.accountId) +
      ', state=' + String(snapshot.state));
    return snapshot;
  }

  async stop(): Promise<SteamFarmSnapshot> {
    this.ensureAvailable();
    SteamArkLog.info(TAG, 'farming runtime stop requested; account=' + SteamArkLog.accountId(this.accountId));
    let snapshot = this.snapshot;
    try {
      if (this.started) {
        snapshot = await this.bridge.stop();
      }
    } finally {
      await this.closeTransports();
      this.started = false;
    }
    this.notifySession(this.cmClient.session);
    this.notifyFarmSnapshot(snapshot);
    SteamArkLog.info(TAG, 'farming runtime stop completed; account=' + SteamArkLog.accountId(this.accountId) +
      ', state=' + String(snapshot.state));
    return snapshot;
  }

  async playManual(appIds: Array<string>, gameName: string): Promise<SteamFarmSnapshot> {
    this.ensureAvailable();
    SteamArkLog.info(TAG, 'runtime manual farming requested; account=' + SteamArkLog.accountId(this.accountId) +
      ', appCount=' + appIds.length.toString() + ', customName=' + String(gameName.trim().length > 0));
    if (!this.started) {
      throw new Error('Steam farming runtime is not started');
    }
    const snapshot = await this.coordinator.playManual(appIds, gameName);
    this.notifyFarmSnapshot(snapshot);
    SteamArkLog.info(TAG, 'runtime manual farming completed; account=' + SteamArkLog.accountId(this.accountId) +
      ', state=' + String(snapshot.state));
    return snapshot;
  }

  async resetManual(): Promise<SteamFarmSnapshot> {
    this.ensureAvailable();
    SteamArkLog.info(TAG, 'runtime manual farming reset requested; account=' + SteamArkLog.accountId(this.accountId));
    if (!this.started) {
      return this.snapshot;
    }
    const snapshot = await this.coordinator.resetManual();
    this.notifyFarmSnapshot(snapshot);
    SteamArkLog.info(TAG, 'runtime manual farming reset completed; account=' +
      SteamArkLog.accountId(this.accountId) + ', state=' + String(snapshot.state));
    return snapshot;
  }

  addEventListener(listener: SteamFarmEventListener): void {
    if (this.farmListeners.indexOf(listener) < 0) {
      this.farmListeners.push(listener);
      SteamArkLog.debug(TAG, 'farming event listener added; account=' + SteamArkLog.accountId(this.accountId) +
        ', count=' + this.farmListeners.length.toString());
    }
  }

  removeEventListener(listener: SteamFarmEventListener): void {
    const index = this.farmListeners.indexOf(listener);
    if (index >= 0) {
      this.farmListeners.splice(index, 1);
      SteamArkLog.debug(TAG, 'farming event listener removed; account=' + SteamArkLog.accountId(this.accountId) +
        ', count=' + this.farmListeners.length.toString());
    }
  }

  addSessionListener(listener: SteamSessionEventListener): void {
    if (this.sessionListeners.indexOf(listener) < 0) {
      this.sessionListeners.push(listener);
      SteamArkLog.debug(TAG, 'session listener added; account=' + SteamArkLog.accountId(this.accountId) +
        ', count=' + this.sessionListeners.length.toString());
    }
  }

  removeSessionListener(listener: SteamSessionEventListener): void {
    const index = this.sessionListeners.indexOf(listener);
    if (index >= 0) {
      this.sessionListeners.splice(index, 1);
      SteamArkLog.debug(TAG, 'session listener removed; account=' + SteamArkLog.accountId(this.accountId) +
        ', count=' + this.sessionListeners.length.toString());
    }
  }

  async dispose(): Promise<void> {
    if (this.disposed) {
      SteamArkLog.debug(TAG, 'farming runtime dispose skipped; already disposed; account=' +
        SteamArkLog.accountId(this.accountId));
      return;
    }
    SteamArkLog.lifecycle(TAG, 'dispose started', 'account=' + SteamArkLog.accountId(this.accountId));
    if (this.started) {
      try {
        await this.stop();
      } catch (error) {
        SteamArkLog.warn(TAG, 'runtime stop during dispose failed; account=' +
          SteamArkLog.accountId(this.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
    this.cmClient.removeEventListener(this.cmListener);
    this.coordinator.removeEventListener(this.farmListener);
    this.bridge.dispose();
    this.cmClient.dispose();
    await this.webSession.close(this.accountId);
    this.farmListeners.splice(0, this.farmListeners.length);
    this.sessionListeners.splice(0, this.sessionListeners.length);
    this.disposed = true;
    SteamArkLog.lifecycle(TAG, 'dispose completed', 'account=' + SteamArkLog.accountId(this.accountId));
  }

  private credentials(): SteamCredentialSet {
    return this.providedCredentials;
  }

  private async waitForCmLogon(): Promise<void> {
    SteamArkLog.debug(TAG, 'CM logon wait started; account=' + SteamArkLog.accountId(this.accountId) +
      ', timeoutSeconds=' + this.options.cmLogonTimeoutSeconds.toString());
    for (let attempt = 0; attempt < this.options.cmLogonTimeoutSeconds; attempt++) {
      const state = this.cmClient.session.state;
      if (state === SteamSessionState.LOGGED_ON) {
        SteamArkLog.info(TAG, 'CM logon wait completed; account=' + SteamArkLog.accountId(this.accountId) +
          ', attempts=' + attempt.toString());
        return;
      }
      if (state === SteamSessionState.NEEDS_EMAIL_CODE ||
        state === SteamSessionState.NEEDS_TWO_FACTOR ||
        state === SteamSessionState.NEEDS_MOBILE_CONFIRMATION) {
        SteamArkLog.warn(TAG, 'CM logon requires user challenge; account=' +
          SteamArkLog.accountId(this.accountId) + ', state=' + String(state));
        throw new Error('Steam CM authentication challenge is required');
      }
      if (state === SteamSessionState.EXPIRED) {
        SteamArkLog.warn(TAG, 'CM logon expired while waiting; account=' + SteamArkLog.accountId(this.accountId));
        throw new Error('Steam CM session expired during farming start');
      }
      await this.waitMilliseconds(1000);
    }
    SteamArkLog.warn(TAG, 'CM logon wait timed out; account=' + SteamArkLog.accountId(this.accountId));
    throw new Error('Steam CM logon timed out');
  }

  private async waitMilliseconds(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, milliseconds);
    });
  }

  private async closeTransports(): Promise<void> {
    SteamArkLog.debug(TAG, 'Steam runtime transport close started; account=' + SteamArkLog.accountId(this.accountId));
    try {
      await this.cmClient.disconnect();
      SteamArkLog.debug(TAG, 'CM transport closed; account=' + SteamArkLog.accountId(this.accountId));
    } catch (error) {
      SteamArkLog.warn(TAG, 'CM disconnect failed; account=' + SteamArkLog.accountId(this.accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
    try {
      await this.webSession.close(this.accountId);
      SteamArkLog.debug(TAG, 'Web transport closed; account=' + SteamArkLog.accountId(this.accountId));
    } catch (error) {
      SteamArkLog.warn(TAG, 'Web session close failed; account=' + SteamArkLog.accountId(this.accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
    SteamArkLog.debug(TAG, 'Steam runtime transport close completed; account=' + SteamArkLog.accountId(this.accountId));
  }

  private notifyFarm(event: SteamFarmEvent): void {
    SteamArkLog.debug(TAG, 'farm event dispatch; account=' + SteamArkLog.accountId(this.accountId) +
      ', type=' + String(event.type) + ', listeners=' + this.farmListeners.length.toString());
    const currentListeners: Array<SteamFarmEventListener> = [];
    for (let index = 0; index < this.farmListeners.length; index++) {
      currentListeners.push(this.farmListeners[index]);
    }
    for (let index = 0; index < currentListeners.length; index++) {
      try {
        currentListeners[index](event);
      } catch (error) {
        SteamArkLog.warn(TAG, 'farm event listener failed; account=' +
          SteamArkLog.accountId(this.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
  }

  private notifyFarmSnapshot(snapshot: SteamFarmSnapshot): void {
    this.notifyFarm(new SteamFarmEvent(SteamFarmEventType.STATE_CHANGED, snapshot, null, ''));
  }

  private notifySession(session: SteamSessionSnapshot): void {
    SteamArkLog.debug(TAG, 'session event dispatch; account=' + SteamArkLog.accountId(session.accountId) +
      ', state=' + String(session.state) + ', listeners=' + this.sessionListeners.length.toString());
    const currentListeners: Array<SteamSessionEventListener> = [];
    for (let index = 0; index < this.sessionListeners.length; index++) {
      currentListeners.push(this.sessionListeners[index]);
    }
    for (let index = 0; index < currentListeners.length; index++) {
      try {
        currentListeners[index](session);
      } catch (error) {
        SteamArkLog.warn(TAG, 'session listener failed; account=' +
          SteamArkLog.accountId(this.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      }
    }
  }

  private ensureAvailable(): void {
    if (this.disposed) {
      SteamArkLog.error(TAG, 'runtime operation rejected; runtime disposed; account=' +
        SteamArkLog.accountId(this.accountId));
      throw new Error('Steam farming runtime has been disposed');
    }
  }

  private normalizeError(error: Error | Object, fallback: string): Error {
    return error instanceof Error ? error : new Error(fallback);
  }

  private static toProxy(profile: SteamAccountProfile, proxyPassword: string = ''): NGFProxyConfiguration {
    if (profile.proxy.kind === SteamProxyKind.DIRECT) {
      return NGFProxyConfiguration.direct();
    }
    if (profile.proxy.kind === SteamProxyKind.HTTP) {
      return NGFProxyConfiguration.http(
        profile.proxy.host,
        profile.proxy.port,
        profile.proxy.username,
        proxyPassword
      );
    }
    if (profile.proxy.kind === SteamProxyKind.SOCKS5) {
      return NGFProxyConfiguration.socks5(
        profile.proxy.host,
        profile.proxy.port,
        profile.proxy.username,
        proxyPassword
      );
    }
    return NGFProxyConfiguration.system();
  }
}

/** Default Harmony factory supports read-only badge sync and explicit farming operations. */
export class HarmonySteamFarmingRuntimeFactory implements ISteamArkFarmingRuntimeFactory {
  readonly isEnabled: boolean;
  readonly unavailableReason: string;
  private readonly options: HarmonySteamFarmingRuntimeOptions;

  constructor(options: HarmonySteamFarmingRuntimeOptions = new HarmonySteamFarmingRuntimeOptions()) {
    this.options = options;
    this.isEnabled = options.enabled;
    this.unavailableReason = options.enabled
      ? ''
      : CM_CONNECTION_GATE_REASON;
    SteamArkLog.info(TAG, 'farming runtime factory constructed; enabled=' + String(this.isEnabled));
  }

  create(
    profile: SteamAccountProfile,
    config: SteamBotConfig,
    credentials: SteamCredentialSet,
    stateStore: IStateStore,
    proxyPassword: string = '',
    locale: SteamArkContentLocale | null = null
  ): ISteamArkFarmingRuntime {
    SteamArkLog.info(TAG, 'farming runtime factory create requested; account=' +
      SteamArkLog.accountId(profile.accountId) + ', enabled=' + String(this.isEnabled));
    if (!this.isEnabled) {
      SteamArkLog.warn(TAG, 'farming runtime factory create blocked; real-network gate disabled; account=' +
        SteamArkLog.accountId(profile.accountId));
      throw new Error(this.unavailableReason);
    }
    const runtime = new HarmonySteamFarmingRuntime(profile, config, credentials, stateStore, proxyPassword, locale, this.options);
    SteamArkLog.info(TAG, 'farming runtime factory create completed; account=' +
      SteamArkLog.accountId(profile.accountId));
    return runtime;
  }
}
