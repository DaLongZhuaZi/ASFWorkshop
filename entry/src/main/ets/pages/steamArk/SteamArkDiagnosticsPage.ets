import { HdsNavDestination } from '@kit.UIDesignKit';
import {
  NGFControlStyleTokens,
  NGFDateStyle,
  NGFEventListener,
  NGFEventPayload,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  ngfI18nManagerFacade,
  ngfStarterKernel,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import {
  SteamFarmSnapshot,
  SteamFarmState,
  SteamSessionState
} from 'steam_core';
import {
  SteamArkAccountSnapshot,
  SteamArkFarmingEvent,
  SteamArkFarmingEventListener,
  SteamArkLog,
  SteamArkSensitiveAction,
  SteamArkSensitiveActionAuditEntry,
  SteamArkSensitiveActionOutcome,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  STEAM_ARK_SENSITIVE_ACTION_AUDIT_EVENT,
  steamArkSensitiveActionAuditStore,
  steamArkFarmingService,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';

const AUDIT_LISTENER_ID: string = 'SteamArkDiagnosticsPage.sensitiveActionAudit';

@Component
export struct SteamArkDiagnosticsPage {
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private stateReady: boolean = false;
  @State private authReady: boolean = false;
  @State private inventoryReady: boolean = false;
  @State private accountCount: number = 0;
  @State private selectedAccountName: string = '';
  @State private selectedAccountId: string = '';
  @State private selectedSessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  @State private hasCredentialMaterial: boolean = false;
  @State private selectedErrorMessage: string = '';
  @State private selectedErrorType: string = '';
  @State private selectedErrorStage: string = '';
  @State private selectedErrorCode: number = 0;
  @State private selectedErrorHttpStatusCode: number = 0;
  @State private selectedErrorMessageType: number = 0;
  @State private selectedErrorHeaderKind: string = '';
  @State private selectedErrorFrameBytes: number = 0;
  @State private selectedErrorHeaderBytes: number = 0;
  @State private selectedErrorBodyBytes: number = 0;
  @State private selectedErrorServerMessage: string = '';
  @State private farmingState: SteamFarmState = SteamFarmState.IDLE;
  @State private farmingNow: boolean = false;
  @State private farmingGameCount: number = 0;
  @State private farmingReady: boolean = false;
  @State private farmingAvailabilityMessage: string = '';
  @State private unknownFieldCount: number = 0;
  @State private warningCount: number = 0;
  @State private updatedAtEpochSeconds: number = 0;
  @State private auditEntries: Array<SteamArkSensitiveActionAuditEntry> = [];
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly scroller: Scroller = new Scroller();
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private auditRefreshGeneration: number = 0;
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('DiagnosticsPage', 'state snapshot received; accounts=' + snapshot.accounts.length.toString());
    this.applyStateSnapshot(snapshot);
  };
  private readonly farmingListener: SteamArkFarmingEventListener = (event: SteamArkFarmingEvent): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('DiagnosticsPage', 'farming event received; type=' + String(event.type));
    this.applyFarmingReadiness();
    if (event.snapshot !== null && event.snapshot.accountId === this.selectedAccountId) {
      this.applyFarmingSnapshot(event.snapshot);
    }
  };
  private readonly auditListener: NGFEventListener = (_payload: NGFEventPayload): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('DiagnosticsPage', 'sensitive action audit event received');
    void this.refreshAuditEntries(this.lifecycleGeneration);
  };

  aboutToAppear(): void {
    SteamArkLog.lifecycle('DiagnosticsPage', 'aboutToAppear');
    this.lifecycleGeneration += 1;
    this.isPageActive = true;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    SteamArkPageWindowSupport.loadDynamicTopInset(
      this.getUIContext(),
      108,
      SteamArkTheme.CONTENT_TOP_INSET,
      (inset: number): void => {
        if (this.isPageActive && this.lifecycleGeneration === lifecycleGeneration) {
          this.topInsetVp = inset;
        }
      }
    );
    SteamArkPageWindowSupport.apply(SteamArkPageWindowName.DIAGNOSTICS);
    steamArkStateService.subscribe('SteamArkDiagnosticsPage', this.stateListener);
    steamArkFarmingService.subscribe('SteamArkDiagnosticsPage', this.farmingListener);
    ngfStarterKernel.eventBus.subscribe(
      STEAM_ARK_SENSITIVE_ACTION_AUDIT_EVENT,
      AUDIT_LISTENER_ID,
      this.auditListener
    );
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    this.applyFarmingReadiness();
    this.applyFarmingSnapshot(steamArkFarmingService.getSnapshot(this.selectedAccountId));
    void this.initializeStateService();
    SteamArkLog.info('DiagnosticsPage', 'state, farming and audit subscriptions registered');
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle('DiagnosticsPage', 'aboutToDisappear');
    this.isPageActive = false;
    this.lifecycleGeneration += 1;
    this.auditRefreshGeneration += 1;
    steamArkStateService.unsubscribe('SteamArkDiagnosticsPage');
    steamArkFarmingService.unsubscribe('SteamArkDiagnosticsPage');
    ngfStarterKernel.eventBus.unsubscribe(STEAM_ARK_SENSITIVE_ACTION_AUDIT_EVENT, AUDIT_LISTENER_ID);
    SteamArkPageWindowSupport.restoreHome();
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        SteamArkProfileBackground()

        Scroll(this.scroller) {
          Column({ space: 12 }) {
            this.buildRuntimeCard()
            this.buildAccountCard()
            if (this.hasSelectedError()) {
              this.buildErrorCard()
            }
            this.buildMigrationCard()
            this.buildAuditCard()
            this.buildReadOnlyNotice()
            this.buildRefreshButton()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: this.topInsetVp, bottom: 92 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .backgroundColor($r('app.color.background_transparent'))
      }
      .width('100%')
      .height('100%')
    }
    .titleBar(NGFHdsTitleBarOptionsFactory.buildOverContentWithTitleColors(
      $r('app.string.steam_diagnostics_title'),
      $r('app.string.steam_diagnostics_subtitle'),
      $r('app.color.background_transparent'),
      SteamArkTheme.textPrimary(this.isDarkMode),
      SteamArkTheme.textSecondary(this.isDarkMode),
      true,
      false
    ))
    .backgroundImage(this.profileBackgroundUrl)
    .backgroundImageSize(ImageSize.Cover)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.scroller])
    .onReady((context: NavDestinationContext): void => {
      this.pathStack = context.pathStack;
    })
    .onBackPressed((): boolean => {
      SteamArkPageWindowSupport.restoreHome();
      this.pathStack.pop();
      return true;
    })
  }

  @Builder
  private buildRuntimeCard(): void {
    Column({ space: 8 }) {
      this.buildSectionTitle($r('sys.symbol.wrench_and_screwdriver'), $r('app.string.steam_diagnostics_runtime_title'))
      this.buildStatusRow($r('sys.symbol.checkmark_circle'), $r('app.string.steam_diagnostics_state_service'), this.stateReady
        ? $r('app.string.steam_diagnostics_ready')
        : $r('app.string.steam_diagnostics_not_ready'), this.readyColor(this.stateReady))
      this.buildStatusRow($r('sys.symbol.person_badge_checkmark'), $r('app.string.steam_diagnostics_auth_adapter'), this.authReady
        ? $r('app.string.steam_diagnostics_ready')
        : $r('app.string.steam_diagnostics_not_ready'), this.readyColor(this.authReady))
      this.buildStatusRow($r('sys.symbol.archivebox'), $r('app.string.steam_diagnostics_inventory_adapter'), this.inventoryReady
        ? $r('app.string.steam_diagnostics_ready')
        : $r('app.string.steam_diagnostics_not_ready'), this.readyColor(this.inventoryReady))
      this.buildStatusRow($r('sys.symbol.play_round_triangle_fill'), $r('app.string.steam_diagnostics_farming_runtime'), this.farmingReady
        ? $r('app.string.steam_diagnostics_ready')
        : $r('app.string.steam_diagnostics_runtime_disabled'), this.readyColor(this.farmingReady))
      if (!this.farmingReady && this.farmingAvailabilityMessage.length > 0) {
        this.buildInfoRow($r('app.string.steam_diagnostics_farming_reason'), this.farmingAvailabilityMessage)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildAccountCard(): void {
    Column({ space: 8 }) {
      this.buildSectionTitle($r('sys.symbol.person_2'), $r('app.string.steam_diagnostics_accounts_title'))
      this.buildInfoRow($r('app.string.steam_diagnostics_account_count'), this.accountCount.toString())
      this.buildInfoRow($r('app.string.steam_diagnostics_selected_account'), this.selectedAccountName.length > 0
        ? this.selectedAccountName
        : $r('app.string.steam_diagnostics_no_account'))
      this.buildInfoRow($r('app.string.steam_diagnostics_session_state'), this.sessionText())
      this.buildInfoRow($r('app.string.steam_diagnostics_credentials'), this.hasCredentialMaterial
        ? $r('app.string.steam_diagnostics_present')
        : $r('app.string.steam_diagnostics_absent'))
      this.buildInfoRow($r('app.string.steam_diagnostics_farming_runtime'), this.farmingText())
      this.buildInfoRow($r('app.string.steam_diagnostics_farming_games'), this.farmingGameCount.toString())
      this.buildInfoRow($r('app.string.steam_diagnostics_last_updated'), this.updatedAtEpochSeconds.toString())
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildMigrationCard(): void {
    Column({ space: 8 }) {
      this.buildSectionTitle($r('sys.symbol.arrow_clockwise'), $r('app.string.steam_diagnostics_migration_title'))
      this.buildInfoRow($r('app.string.steam_diagnostics_unknown_fields'), this.unknownFieldCount.toString())
      this.buildInfoRow($r('app.string.steam_diagnostics_warnings'), this.warningCount.toString())
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildErrorCard(): void {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(16)
          .fontColor([SteamArkTheme.error(this.isDarkMode)])
        Text($r('app.string.steam_accounts_error_details'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.error(this.isDarkMode))
      }
      .width('100%')
      this.buildInfoRow($r('app.string.steam_accounts_error_type'), this.selectedErrorType)
      this.buildInfoRow($r('app.string.steam_accounts_error_stage'), this.selectedErrorStage)
      this.buildInfoRow($r('app.string.steam_accounts_error_code'), this.selectedErrorCode.toString())
      this.buildInfoRow(
        $r('app.string.steam_accounts_error_http_status'),
        this.selectedErrorHttpStatusCode.toString()
      )
      this.buildInfoRow(
        $r('app.string.steam_accounts_error_message_type'),
        this.selectedErrorMessageType.toString()
      )
      this.buildInfoRow($r('app.string.steam_accounts_error_header_kind'), this.selectedErrorHeaderKind)
      this.buildInfoRow(
        $r('app.string.steam_accounts_error_frame_bytes'),
        this.selectedErrorFrameBytes.toString()
      )
      this.buildInfoRow(
        $r('app.string.steam_accounts_error_header_bytes'),
        this.selectedErrorHeaderBytes.toString()
      )
      this.buildInfoRow(
        $r('app.string.steam_accounts_error_body_bytes'),
        this.selectedErrorBodyBytes.toString()
      )
      if (this.selectedErrorServerMessage.length > 0) {
        this.buildInfoRow(
          $r('app.string.steam_accounts_error_server_message'),
          this.selectedErrorServerMessage
        )
      }
      Text(this.selectedErrorMessage)
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(10)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({ width: 1, color: SteamArkTheme.error(this.isDarkMode) })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildAuditCard(): void {
    Column({ space: 8 }) {
      this.buildSectionTitle($r('sys.symbol.lock_shield'), $r('app.string.steam_diagnostics_audit_title'))
      Text($r('app.string.steam_diagnostics_audit_intro'))
        .width('100%')
        .fontSize(11)
        .lineHeight(16)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      if (this.auditEntries.length <= 0) {
        Text($r('app.string.steam_diagnostics_audit_empty'))
          .width('100%')
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
      } else {
        ForEach(
          this.auditEntries,
          (entry: SteamArkSensitiveActionAuditEntry): void => {
            this.buildAuditRow(entry);
          },
          (entry: SteamArkSensitiveActionAuditEntry): string => entry.eventId
        )
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildAuditRow(entry: SteamArkSensitiveActionAuditEntry): void {
    Column({ space: 3 }) {
      Row({ space: 8 }) {
        Text(this.auditActionText(entry.action))
          .layoutWeight(1)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text(this.auditOutcomeText(entry.outcome))
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.auditOutcomeColor(entry.outcome))
      }
      .width('100%')
      this.buildInfoRow(
        $r('app.string.steam_diagnostics_audit_account'),
        this.maskAuditIdentifier(entry.accountId.length > 0 ? entry.accountId : entry.steamId64)
      )
      if (entry.assetCount > 0) {
        this.buildInfoRow($r('app.string.steam_diagnostics_audit_assets'), entry.assetCount.toString())
      }
      this.buildInfoRow(
        $r('app.string.steam_diagnostics_audit_time'),
        this.auditTimestampText(entry.createdAtEpochSeconds)
      )
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({ width: 1, color: SteamArkTheme.divider(this.isDarkMode) })
  }

  @Builder
  private buildReadOnlyNotice(): void {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(21)
        .fontColor([SteamArkTheme.success(this.isDarkMode)])
      Column({ space: 3 }) {
        Text($r('app.string.steam_diagnostics_read_only'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_diagnostics_intro'))
          .fontSize(11)
          .lineHeight(16)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildRefreshButton(): void {
    Button() {
      Row({ space: 7 }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(16)
          .fontColor([SteamArkTheme.onAccent(this.isDarkMode)])
        Text($r('app.string.steam_diagnostics_refresh'))
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .padding(0)
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
    .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
    .id('steam-ark-diagnostics-refresh')
    .onClick((): void => {
      void this.initializeStateService();
    })
  }

  @Builder
  private buildSectionTitle(icon: Resource, title: ResourceStr): void {
    Row({ space: 8 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
    }
    .width('100%')
  }

  @Builder
  private buildStatusRow(icon: Resource, label: ResourceStr, value: ResourceStr, color: ResourceColor): void {
    Row({ space: 8 }) {
      SymbolGlyph(icon)
        .fontSize(16)
        .fontColor([color])
      Text(label)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .layoutWeight(1)
      Text(value)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  @Builder
  private buildInfoRow(label: ResourceStr, value: ResourceStr): void {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .layoutWeight(1)
      Text(value)
        .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    if (!this.isPageActive) {
      return;
    }
    this.applyFarmingReadiness();
    this.stateReady = snapshot.initialized;
    this.authReady = steamArkStateService.isAuthServiceReady();
    this.inventoryReady = steamArkStateService.isInventoryAdapterReady();
    this.accountCount = snapshot.accounts.length;
    this.selectedAccountId = snapshot.selectedAccountId;
    this.updatedAtEpochSeconds = snapshot.updatedAtEpochSeconds;
    let unknownFieldCount: number = snapshot.globalMigrationReport.unknownFields.length;
    let warningCount: number = snapshot.globalMigrationReport.warnings.length;
    const selected: SteamArkAccountSnapshot | null = steamArkStateService.getSelectedAccount();
    if (selected === null) {
      this.selectedAccountName = '';
      this.selectedSessionState = SteamSessionState.DISCONNECTED;
      this.hasCredentialMaterial = false;
      this.clearSelectedError();
      this.applyFarmingSnapshot(null);
      this.unknownFieldCount = unknownFieldCount;
      this.warningCount = warningCount;
      return;
    }
    this.selectedAccountName = selected.profile.displayName.length > 0
      ? selected.profile.displayName
      : selected.profile.accountId;
    this.selectedSessionState = selected.session.state;
    this.hasCredentialMaterial = selected.hasCredentialMaterial;
    this.selectedErrorMessage = selected.session.lastErrorMessage;
    this.selectedErrorType = selected.session.lastErrorType;
    this.selectedErrorStage = selected.session.lastErrorStage;
    this.selectedErrorCode = selected.session.lastErrorCode;
    this.selectedErrorHttpStatusCode = selected.session.lastErrorHttpStatusCode;
    this.selectedErrorMessageType = selected.session.lastErrorMessageType;
    this.selectedErrorHeaderKind = selected.session.lastErrorHeaderKind;
    this.selectedErrorFrameBytes = selected.session.lastErrorFrameBytes;
    this.selectedErrorHeaderBytes = selected.session.lastErrorHeaderBytes;
    this.selectedErrorBodyBytes = selected.session.lastErrorBodyBytes;
    this.selectedErrorServerMessage = selected.session.lastErrorServerMessage;
    unknownFieldCount += selected.migrationReport.unknownFields.length;
    warningCount += selected.migrationReport.warnings.length;
    this.unknownFieldCount = unknownFieldCount;
    this.warningCount = warningCount;
    this.applyFarmingSnapshot(steamArkFarmingService.getSnapshot(selected.profile.accountId));
    SteamArkLog.debug('DiagnosticsPage', 'state applied; accounts=' + this.accountCount.toString() +
      ', selectedAccount=' + SteamArkLog.accountId(this.selectedAccountId) +
      ', session=' + String(this.selectedSessionState));
  }

  private applyFarmingSnapshot(snapshot: SteamFarmSnapshot | null): void {
    if (snapshot === null) {
      this.farmingState = SteamFarmState.IDLE;
      this.farmingNow = false;
      this.farmingGameCount = 0;
      return;
    }
    this.farmingState = snapshot.state;
    this.farmingNow = snapshot.nowFarming;
    this.farmingGameCount = snapshot.games.length;
  }

  private applyFarmingReadiness(): void {
    this.farmingReady = steamArkFarmingService.isFarmingReady();
    this.farmingAvailabilityMessage = steamArkFarmingService.availabilityMessage();
  }

  private async initializeStateService(): Promise<void> {
    if (!this.isPageActive) {
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const startedAt: number = Date.now();
    try {
      const initialized: boolean = await steamArkStateService.initialize();
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      this.applyStateSnapshot(steamArkStateService.getSnapshot());
      this.applyFarmingReadiness();
      await this.refreshAuditEntries(lifecycleGeneration);
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
        return;
      }
      SteamArkLog.info('DiagnosticsPage', 'diagnostics state ready; initialized=' + String(initialized));
      SteamArkLog.performance('DiagnosticsPage', 'diagnostics initialization', startedAt);
    } catch (_error) {
      SteamArkLog.error('DiagnosticsPage', 'diagnostics initialization failed');
    }
  }

  private async refreshAuditEntries(lifecycleGeneration: number): Promise<void> {
    if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration) {
      return;
    }
    this.auditRefreshGeneration += 1;
    const auditRefreshGeneration: number = this.auditRefreshGeneration;
    SteamArkLog.debug('DiagnosticsPage', 'audit entries refresh started');
    try {
      const entries: Array<SteamArkSensitiveActionAuditEntry> =
        await steamArkSensitiveActionAuditStore.listRecent(20);
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration ||
        this.auditRefreshGeneration !== auditRefreshGeneration) {
        return;
      }
      this.auditEntries = entries;
      SteamArkLog.debug('DiagnosticsPage', 'audit entries refreshed; count=' + this.auditEntries.length.toString());
    } catch {
      if (!this.isPageActive || this.lifecycleGeneration !== lifecycleGeneration ||
        this.auditRefreshGeneration !== auditRefreshGeneration) {
        return;
      }
      this.auditEntries = [];
      SteamArkLog.warn('DiagnosticsPage', 'audit entries refresh failed');
    }
  }

  private hasSelectedError(): boolean {
    return this.selectedErrorMessage.length > 0 || this.selectedErrorType.length > 0 ||
      this.selectedErrorStage.length > 0 || this.selectedErrorCode !== 0 ||
      this.selectedErrorServerMessage.length > 0;
  }

  private clearSelectedError(): void {
    this.selectedErrorMessage = '';
    this.selectedErrorType = '';
    this.selectedErrorStage = '';
    this.selectedErrorCode = 0;
    this.selectedErrorHttpStatusCode = 0;
    this.selectedErrorMessageType = 0;
    this.selectedErrorHeaderKind = '';
    this.selectedErrorFrameBytes = 0;
    this.selectedErrorHeaderBytes = 0;
    this.selectedErrorBodyBytes = 0;
    this.selectedErrorServerMessage = '';
  }

  private readyColor(ready: boolean): ResourceColor {
    return ready ? SteamArkTheme.success(this.isDarkMode) : SteamArkTheme.warning(this.isDarkMode);
  }

  private sessionText(): ResourceStr {
    switch (this.selectedSessionState) {
      case SteamSessionState.CONNECTING:
        return $r('app.string.steam_accounts_session_connecting');
      case SteamSessionState.CONNECTED:
        return $r('app.string.steam_accounts_session_connected');
      case SteamSessionState.LOGGED_ON:
        return $r('app.string.steam_accounts_session_logged_on');
      case SteamSessionState.NEEDS_QR_SCAN:
        return $r('app.string.steam_accounts_session_qr_scan');
      case SteamSessionState.NEEDS_EMAIL_CODE:
        return $r('app.string.steam_accounts_session_email_code');
      case SteamSessionState.NEEDS_TWO_FACTOR:
        return $r('app.string.steam_accounts_session_two_factor');
      case SteamSessionState.NEEDS_MOBILE_CONFIRMATION:
        return $r('app.string.steam_accounts_session_mobile_confirmation');
      case SteamSessionState.EXPIRED:
        return $r('app.string.steam_accounts_session_expired');
      case SteamSessionState.RECONNECTING:
        return $r('app.string.steam_accounts_session_reconnecting');
      case SteamSessionState.ERROR:
        return $r('app.string.steam_accounts_session_error');
      case SteamSessionState.DISCONNECTED:
      default:
        return $r('app.string.steam_accounts_session_disconnected');
    }
  }

  private farmingText(): ResourceStr {
    if (!this.farmingReady) {
      return $r('app.string.steam_diagnostics_runtime_disabled');
    }
    if (this.farmingNow) {
      return $r('app.string.steam_workspace_farming_running');
    }
    switch (this.farmingState) {
      case SteamFarmState.STARTING:
        return $r('app.string.steam_workspace_farming_starting');
      case SteamFarmState.FARMING:
        return $r('app.string.steam_workspace_farming_running');
      case SteamFarmState.PAUSED:
        return $r('app.string.steam_workspace_farming_paused');
      case SteamFarmState.RECONNECTING:
        return $r('app.string.steam_workspace_farming_reconnecting');
      case SteamFarmState.ERROR:
        return $r('app.string.steam_workspace_farming_error');
      case SteamFarmState.COMPLETED:
        return $r('app.string.steam_workspace_farming_completed');
      case SteamFarmState.IDLE:
      default:
        return $r('app.string.steam_workspace_farming_idle');
    }
  }

  private auditActionText(action: SteamArkSensitiveAction): ResourceStr {
    switch (action) {
      case SteamArkSensitiveAction.PRIVACY_VERIFICATION:
        return $r('app.string.steam_diagnostics_action_privacy_verification');
      case SteamArkSensitiveAction.INVENTORY_WRITE:
        return $r('app.string.steam_diagnostics_action_inventory_write');
      case SteamArkSensitiveAction.BADGE_CRAFT:
        return $r('app.string.steam_diagnostics_action_badge_craft');
      case SteamArkSensitiveAction.TRADE_PREVIEW:
        return $r('app.string.steam_diagnostics_action_trade_preview');
      case SteamArkSensitiveAction.TRADE_ACCEPT:
        return $r('app.string.steam_diagnostics_action_trade_accept');
      case SteamArkSensitiveAction.TRADE_DECLINE:
        return $r('app.string.steam_diagnostics_action_trade_decline');
      case SteamArkSensitiveAction.TRADE_CANCEL:
        return $r('app.string.steam_diagnostics_action_trade_cancel');
      case SteamArkSensitiveAction.MOBILE_CONFIRM:
        return $r('app.string.steam_diagnostics_action_mobile_confirm');
      case SteamArkSensitiveAction.REDEEM:
        return $r('app.string.steam_diagnostics_action_redeem');
      case SteamArkSensitiveAction.ASSET_TRANSFER:
        return $r('app.string.steam_diagnostics_action_asset_transfer');
      default:
        return $r('app.string.steam_diagnostics_action_inventory_write');
    }
  }

  private auditOutcomeText(outcome: SteamArkSensitiveActionOutcome): ResourceStr {
    switch (outcome) {
      case SteamArkSensitiveActionOutcome.GRANTED:
        return $r('app.string.steam_diagnostics_outcome_granted');
      case SteamArkSensitiveActionOutcome.PERMISSION_DENIED:
        return $r('app.string.steam_diagnostics_outcome_permission_denied');
      case SteamArkSensitiveActionOutcome.UNSUPPORTED:
        return $r('app.string.steam_diagnostics_outcome_unsupported');
      case SteamArkSensitiveActionOutcome.AUTHENTICATION_FAILED:
        return $r('app.string.steam_diagnostics_outcome_authentication_failed');
      case SteamArkSensitiveActionOutcome.BUSY:
        return $r('app.string.steam_diagnostics_outcome_busy');
      case SteamArkSensitiveActionOutcome.INVALID_REQUEST:
        return $r('app.string.steam_diagnostics_outcome_invalid_request');
      case SteamArkSensitiveActionOutcome.ERROR:
        return $r('app.string.steam_diagnostics_outcome_error');
      case SteamArkSensitiveActionOutcome.AUDIT_FAILED:
      default:
        return $r('app.string.steam_diagnostics_outcome_audit_failed');
    }
  }

  private auditOutcomeColor(outcome: SteamArkSensitiveActionOutcome): ResourceColor {
    if (outcome === SteamArkSensitiveActionOutcome.GRANTED) {
      return SteamArkTheme.success(this.isDarkMode);
    }
    if (outcome === SteamArkSensitiveActionOutcome.BUSY) {
      return SteamArkTheme.warning(this.isDarkMode);
    }
    return SteamArkTheme.error(this.isDarkMode);
  }

  private maskAuditIdentifier(value: string): string {
    const normalized: string = value.trim();
    if (normalized.length <= 4) {
      return '****';
    }
    return normalized.substring(0, 2) + '****' + normalized.substring(normalized.length - 2);
  }

  private auditTimestampText(epochSeconds: number): string {
    return ngfI18nManagerFacade.formatDate(
      new Date(epochSeconds * 1000),
      NGFDateStyle.MEDIUM
    );
  }
}
