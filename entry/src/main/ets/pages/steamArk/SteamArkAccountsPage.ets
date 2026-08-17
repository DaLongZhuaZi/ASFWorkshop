import { HdsNavDestination } from '@kit.UIDesignKit';
import {
  NGFControlStyleTokens,
  NGFDocumentReadError,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  ngfI18nManagerFacade,
  ngfMediaPickerFacade,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import {
  SteamAuthChallengeKind,
  SteamAuthErrorKind,
  SteamAuthFlowKind,
  SteamAuthPendingSnapshot,
  SteamAuthResult,
  SteamSessionSnapshot,
  SteamSessionState
} from 'steam_core';
import {
  SteamArkAccountSnapshot,
  SteamArkContentLocale,
  SteamArkGlobalImportSummary,
  SteamArkRegionPolicy,
  SteamArkImportSummary,
  SteamArkLog,
  SteamArkQrAuthenticationSnapshot,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { steamArkTabScrollers } from './SteamArkTabScrollers';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';

class SteamArkImportKind {
  static readonly ASF_JSON: number = 1;
  static readonly MAFILE: number = 2;
  static readonly ASF_GLOBAL_JSON: number = 3;
}

class SteamArkAuthActionKind {
  static readonly SIGN_IN: number = 1;
  static readonly COMPLETE_CHALLENGE: number = 2;
  static readonly POLL: number = 3;
  static readonly REFRESH: number = 4;
  static readonly REMOVE_FAILED_QR: number = 5;
  static readonly SIGN_OUT: number = 6;
  static readonly REMOVE_ACCOUNT: number = 7;
}

class SteamArkAuthModeKind {
  static readonly PASSWORD: number = 1;
  static readonly QR: number = 2;
}

class SteamArkAccountOperationScope {
  readonly lifecycleGeneration: number;
  readonly operationGeneration: number;
  readonly accountId: string;
  readonly accountScopeGeneration: number;
  readonly allowsAccountAbsence: boolean;

  constructor(
    lifecycleGeneration: number,
    operationGeneration: number,
    accountId: string,
    accountScopeGeneration: number,
    allowsAccountAbsence: boolean
  ) {
    this.lifecycleGeneration = lifecycleGeneration;
    this.operationGeneration = operationGeneration;
    this.accountId = accountId;
    this.accountScopeGeneration = accountScopeGeneration;
    this.allowsAccountAbsence = allowsAccountAbsence;
  }
}

class SteamArkSummaryPart {
  readonly kind: number;
  readonly value: string;

  constructor(kind: number, value: string) {
    this.kind = kind;
    this.value = value;
  }
}

class SteamArkSummaryPartKind {
  static readonly TEXT: number = 0;
  static readonly IMAGE: number = 1;
}

@Component
export struct SteamArkAccountsPage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private statusMessage: ResourceStr = $r('app.string.steam_accounts_status_idle');
  @State private accounts: Array<SteamArkAccountSnapshot> = [];
  @State private selectedAccountId: string = '';
  @State private isImporting: boolean = false;
  @State private challengeCode: string = '';
  @State private isAuthenticating: boolean = false;
  @State private isSelectingAccount: boolean = false;
  @State private authMode: number = SteamArkAuthModeKind.PASSWORD;
  @State private loginAccountName: string = '';
  @State private loginPassword: string = '';
  @State private qrAccountId: string = '';
  @State private qrChallengeUrl: string = '';
  @State private pendingQrAuthentication: SteamArkQrAuthenticationSnapshot | null = null;
  @State private showMaFileGuide: boolean = false;
  @State private stateReady: boolean = false;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('steam_ark_profile_background_enabled') private backgroundEnabled: boolean = true;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly scroller: Scroller = steamArkTabScrollers.accounts;
  private authPollTimer: number = -1;
  private authPollAccountId: string = '';
  private authPollChallengeIdentity: string = '';
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private operationGeneration: number = 0;
  private accountScopeGeneration: number = 0;
  private accountScopeKey: string = '';
  private activeAccountOperationGeneration: number = -1;
  private activeAccountOperationAccountId: string = '';
  private activeAccountOperationScopeGeneration: number = -1;
  private activeAccountOperationAllowsAccountAbsence: boolean = false;
  private authPollGeneration: number = 0;
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    SteamArkLog.debug('AccountsPage', 'state snapshot received; accounts=' + snapshot.accounts.length.toString());
    this.applyStateSnapshot(snapshot);
  };

  private isAccountBusy(): boolean {
    return this.isAuthenticating || this.isSelectingAccount || this.isImporting;
  }

  private summaryParts(summary: string): Array<SteamArkSummaryPart> {
    const parts: Array<SteamArkSummaryPart> = [];
    const imagePattern = /<img\b[^>]*>/gi;
    let cursor: number = 0;
    let match: RegExpExecArray | null = imagePattern.exec(summary);
    while (match !== null) {
      const textBefore: string = this.cleanSummaryText(summary.substring(cursor, match.index));
      if (textBefore.length > 0) {
        parts.push(new SteamArkSummaryPart(SteamArkSummaryPartKind.TEXT, textBefore));
      }
      const imageTag: string = match[0];
      const sourceMatch = /\bsrc\s*=\s*["']([^"']+)["']/i.exec(imageTag);
      if (sourceMatch !== null && sourceMatch[1].startsWith('https://')) {
        parts.push(new SteamArkSummaryPart(SteamArkSummaryPartKind.IMAGE, sourceMatch[1]));
      } else {
        const altMatch = /\balt\s*=\s*["']([^"']*)["']/i.exec(imageTag);
        if (altMatch !== null && altMatch[1].trim().length > 0) {
          parts.push(new SteamArkSummaryPart(
            SteamArkSummaryPartKind.TEXT,
            '[' + this.decodeSummaryEntities(altMatch[1].trim()) + ']'
          ));
        }
      }
      cursor = match.index + imageTag.length;
      match = imagePattern.exec(summary);
    }
    const trailing: string = this.cleanSummaryText(summary.substring(cursor));
    if (trailing.length > 0) {
      parts.push(new SteamArkSummaryPart(SteamArkSummaryPartKind.TEXT, trailing));
    }
    return parts;
  }

  private cleanSummaryText(value: string): string {
    return this.decodeSummaryEntities(value.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim());
  }

  private decodeSummaryEntities(value: string): string {
    return value.replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'");
  }

  private beginOperation(): number {
    this.operationGeneration += 1;
    this.clearActiveAccountOperation();
    return this.operationGeneration;
  }

  private beginAccountOperation(
    accountId: string,
    allowsAccountAbsence: boolean = false
  ): SteamArkAccountOperationScope {
    const operationGeneration: number = this.beginOperation();
    const scope = new SteamArkAccountOperationScope(
      this.lifecycleGeneration,
      operationGeneration,
      accountId,
      this.accountScopeGeneration,
      allowsAccountAbsence
    );
    this.activeAccountOperationGeneration = scope.operationGeneration;
    this.activeAccountOperationAccountId = scope.accountId;
    this.activeAccountOperationScopeGeneration = scope.accountScopeGeneration;
    this.activeAccountOperationAllowsAccountAbsence = scope.allowsAccountAbsence;
    return scope;
  }

  private clearActiveAccountOperation(): void {
    this.activeAccountOperationGeneration = -1;
    this.activeAccountOperationAccountId = '';
    this.activeAccountOperationScopeGeneration = -1;
    this.activeAccountOperationAllowsAccountAbsence = false;
  }

  private isCurrentLifecycle(generation: number): boolean {
    return this.isPageActive && generation === this.lifecycleGeneration;
  }

  private isCurrentOperation(lifecycleGeneration: number, operationGeneration: number): boolean {
    return this.isCurrentLifecycle(lifecycleGeneration) &&
      operationGeneration === this.operationGeneration;
  }

  private isCurrentAccountOperation(scope: SteamArkAccountOperationScope): boolean {
    if (!this.isCurrentOperation(scope.lifecycleGeneration, scope.operationGeneration) ||
      this.activeAccountOperationGeneration !== scope.operationGeneration ||
      this.activeAccountOperationAccountId !== scope.accountId ||
      this.activeAccountOperationScopeGeneration !== this.accountScopeGeneration) {
      return false;
    }
    if (scope.allowsAccountAbsence || scope.accountId.length <= 0) {
      return true;
    }
    return this.hasAccountInCurrentSnapshot(scope.accountId);
  }

  private hasAccountInCurrentSnapshot(accountId: string): boolean {
    const pendingQr = this.pendingQrAuthentication;
    if (pendingQr !== null && pendingQr.session.accountId === accountId) {
      return true;
    }
    for (let index = 0; index < this.accounts.length; index++) {
      if (this.accounts[index].profile.accountId === accountId) {
        return true;
      }
    }
    return false;
  }

  private updateAccountScope(snapshot: SteamArkStateSnapshot): void {
    const nextScopeKey: string = this.accountScopeKeyForSnapshot(snapshot);
    if (this.accountScopeKey === nextScopeKey) {
      return;
    }
    this.accountScopeKey = nextScopeKey;
    this.accountScopeGeneration += 1;
    this.invalidateStaleAccountOperation();
  }

  private invalidateMissingAccountOperation(snapshot: SteamArkStateSnapshot): void {
    if (this.activeAccountOperationGeneration !== this.operationGeneration ||
      this.activeAccountOperationAllowsAccountAbsence ||
      this.activeAccountOperationAccountId.length <= 0 ||
      this.snapshotContainsAccount(snapshot, this.activeAccountOperationAccountId)) {
      return;
    }
    this.invalidateStaleAccountOperation();
  }

  private accountScopeKeyForSnapshot(snapshot: SteamArkStateSnapshot): string {
    if (snapshot.selectedAccountId.length > 0) {
      return 'account:' + snapshot.selectedAccountId;
    }
    const pendingQr = snapshot.pendingQrAuthentication;
    return pendingQr === null ? '' : 'qr:' + pendingQr.session.accountId;
  }

  private snapshotContainsAccount(snapshot: SteamArkStateSnapshot, accountId: string): boolean {
    const pendingQr = snapshot.pendingQrAuthentication;
    if (pendingQr !== null && pendingQr.session.accountId === accountId) {
      return true;
    }
    for (let index = 0; index < snapshot.accounts.length; index++) {
      if (snapshot.accounts[index].profile.accountId === accountId) {
        return true;
      }
    }
    return false;
  }

  private invalidateStaleAccountOperation(): void {
    const invalidatedOperationGeneration: number = this.activeAccountOperationGeneration;
    const invalidatedAccountId: string = this.activeAccountOperationAccountId;
    this.clearActiveAccountOperation();
    if (invalidatedOperationGeneration !== this.operationGeneration) {
      return;
    }
    this.isSelectingAccount = false;
    this.isAuthenticating = false;
    this.challengeCode = '';
    this.loginPassword = '';
    this.statusMessage = $r('app.string.steam_accounts_status_idle');
    SteamArkLog.info('AccountsPage', 'stale account operation UI update ignored; account=' +
      SteamArkLog.accountId(invalidatedAccountId));
  }

  aboutToAppear(): void {
    SteamArkLog.lifecycle('AccountsPage', 'aboutToAppear', 'embedded=' + String(this.embedded));
    this.lifecycleGeneration += 1;
    this.operationGeneration += 1;
    this.clearActiveAccountOperation();
    this.isPageActive = true;
    this.isAuthenticating = false;
    this.isSelectingAccount = false;
    this.isImporting = false;
    if (this.embedded) {
      this.topInsetVp = this.contentTopInsetVp;
    } else {
      const lifecycleGeneration: number = this.lifecycleGeneration;
      SteamArkPageWindowSupport.loadDynamicTopInset(
        this.getUIContext(),
        108,
        SteamArkTheme.CONTENT_TOP_INSET,
        (inset: number): void => {
          if (this.isCurrentLifecycle(lifecycleGeneration)) {
            this.topInsetVp = inset;
          }
        }
      );
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.ACCOUNTS);
    }
    steamArkStateService.subscribe('SteamArkAccountsPage', this.stateListener);
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    void this.initializeStateService();
    SteamArkLog.info('AccountsPage', 'state subscription registered');
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle('AccountsPage', 'aboutToDisappear', 'embedded=' + String(this.embedded));
    this.isPageActive = false;
    this.lifecycleGeneration += 1;
    this.operationGeneration += 1;
    this.clearActiveAccountOperation();
    this.isAuthenticating = false;
    this.isSelectingAccount = false;
    this.isImporting = false;
    this.loginPassword = '';
    this.challengeCode = '';
    this.clearAuthPolling();
    steamArkStateService.unsubscribe('SteamArkAccountsPage');
    if (!this.embedded) {
      SteamArkPageWindowSupport.restoreHome();
    }
  }

  build() {
    if (this.embedded) {
      this.buildPageBody();
    } else {
      HdsNavDestination() {
        this.buildPageBody();
      }
      .titleBar(NGFHdsTitleBarOptionsFactory.buildOverContentWithTitleColors(
        $r('app.string.steam_accounts_title'),
        $r('app.string.steam_accounts_subtitle'),
        $r('app.color.background_transparent'),
        SteamArkTheme.textPrimary(this.isDarkMode),
        SteamArkTheme.textSecondary(this.isDarkMode),
        true,
        false
      ))
      .backgroundImage(this.backgroundEnabled ? this.profileBackgroundUrl : '')
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
      });
    }
  }

  @Builder
  private buildPageBody(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.embedded) {
        SteamArkProfileBackground()
      }

      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (!this.stateReady) {
            SteamArkStateUnavailableCard({
              isDarkMode: this.isDarkMode,
              useSysMat: this.useSysMat
            });
          } else {
            this.buildLoginCard();
            if (this.accounts.length <= 0) {
              if (this.pendingQrAuthentication === null) {
                this.buildEmptyStateCard();
              }
            } else {
              this.buildAccountListCard();
            }
            this.buildImportCard();
            this.buildSecurityCard();
          }
          this.buildStatusMessage();
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: this.embedded ? this.contentTopInsetVp : this.topInsetVp,
          bottom: this.embedded
            ? 84 + SteamArkExperiencePolicy.FRIENDS_BAR_RESERVE
            : 92
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .backgroundColor($r('app.color.background_transparent'))
      .onDidScroll((_xOffset: number, yOffset: number): void => {
        if (this.embedded) {
          steamArkTabScrollers.notifyScrollDelta(yOffset);
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.embedded
      ? $r('app.color.background_transparent') : SteamArkTheme.background(this.isDarkMode))
    .opacity(this.stateReady && !this.isAccountBusy() ? 1 : 0.88)
    .animation({ duration: SteamArkExperiencePolicy.CONTENT_REFRESH_DURATION, curve: Curve.EaseOut })
  }

  @Builder
  private buildLoginCard(): void {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.person_2'))
          .fontSize(20)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        Text($r('app.string.steam_accounts_login_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')

      Row({ space: 6 }) {
        this.buildAuthModeButton(
          SteamArkAuthModeKind.PASSWORD,
          $r('app.string.steam_accounts_login_mode_password'),
          $r('sys.symbol.person_2')
        )
        this.buildAuthModeButton(
          SteamArkAuthModeKind.QR,
          $r('app.string.steam_accounts_login_mode_qr'),
          $r('sys.symbol.qrcode')
        )
      }
      .width('100%')
      .padding(4)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceControl(this.isDarkMode),
        this.useSysMat
      ))
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)

      if (this.authMode === SteamArkAuthModeKind.PASSWORD) {
        this.buildPasswordLoginForm();
      } else {
        this.buildQrLoginForm();
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwarePanelShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildAuthModeButton(mode: number, title: ResourceStr, icon: Resource): void {
    Button() {
      Row({ space: 5 }) {
        SymbolGlyph(icon)
          .fontSize(15)
          .fontColor([this.authMode === mode
            ? SteamArkTheme.onAccent(this.isDarkMode)
            : SteamArkTheme.textSecondary(this.isDarkMode)])
        Text(title)
          .fontSize(NGFControlStyleTokens.SEGMENT_BUTTON_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.authMode === mode
            ? SteamArkTheme.onAccent(this.isDarkMode)
            : SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
    .padding(0)
    .borderRadius(NGFControlStyleTokens.DENSE_BUTTON_RADIUS)
    .backgroundColor(this.authMode === mode
      ? SteamArkTheme.accent(this.isDarkMode)
      : NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceControl(this.isDarkMode),
        this.useSysMat
      ))
    .fontColor(this.authMode === mode
      ? SteamArkTheme.onAccent(this.isDarkMode)
      : SteamArkTheme.buttonForeground(this.isDarkMode))
    .id(mode === SteamArkAuthModeKind.PASSWORD
      ? 'steam-ark-accounts-login-password-mode'
      : 'steam-ark-accounts-login-qr-mode')
    .onClick((): void => {
      if (!this.isAccountBusy()) {
        this.authMode = mode;
      }
    })
  }

  @Builder
  private buildPasswordLoginForm(): void {
    Column({ space: 8 }) {
      TextInput({
        placeholder: $r('app.string.steam_accounts_login_account_placeholder'),
        text: this.loginAccountName
      })
        .id('steam-ark-accounts-login-account')
        .width('100%')
        .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
        .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
        .padding({ left: 12, right: 12 })
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceControl(this.isDarkMode),
          this.useSysMat
        ))
        .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
        .enabled(!this.isAccountBusy())
        .onChange((value: string): void => {
          this.loginAccountName = value;
        })

      TextInput({
        placeholder: $r('app.string.steam_accounts_login_password_placeholder'),
        text: this.loginPassword
      })
        .id('steam-ark-accounts-login-password')
        .width('100%')
        .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
        .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
        .padding({ left: 12, right: 12 })
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .type(InputType.Password)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceControl(this.isDarkMode),
          this.useSysMat
        ))
        .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
        .enabled(!this.isAccountBusy())
        .onChange((value: string): void => {
          this.loginPassword = value;
        })

      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.person_2'))
            .fontSize(16)
            .fontColor([this.canSubmitPasswordLogin()
              ? SteamArkTheme.onAccent(this.isDarkMode)
              : SteamArkTheme.buttonDisabledText(this.isDarkMode)])
          Text(this.isAuthenticating
            ? $r('app.string.steam_accounts_auth_busy')
            : $r('app.string.steam_accounts_login_submit'))
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.canSubmitPasswordLogin()
              ? SteamArkTheme.onAccent(this.isDarkMode)
              : SteamArkTheme.buttonDisabledText(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
        .width('100%')
        .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .backgroundColor(this.canSubmitPasswordLogin()
          ? SteamArkTheme.accent(this.isDarkMode)
          : SteamArkTheme.buttonDisabled(this.isDarkMode))
        .fontColor(this.canSubmitPasswordLogin()
          ? SteamArkTheme.onAccent(this.isDarkMode)
          : SteamArkTheme.buttonDisabledText(this.isDarkMode))
        .id('steam-ark-accounts-login-password-submit')
        .enabled(this.canSubmitPasswordLogin())
        .onClick((): void => {
          void this.handlePasswordSignIn();
        })
    }
    .width('100%')
  }

  @Builder
  private buildQrLoginForm(): void {
    Column({ space: 10 }) {
      if (this.qrChallengeUrl.length > 0) {
        this.buildQrGuidance();
        Column() {
          QRCode(this.qrChallengeUrl)
            .width(220)
            .height(220)
            .color($r('app.color.steam_ark_qr_foreground'))
            .backgroundColor($r('app.color.steam_ark_qr_background'))
            .contentOpacity(1)
        }
        .width(244)
        .height(244)
        .padding(12)
        .backgroundColor($r('app.color.steam_ark_qr_background'))
        .borderRadius(8)
        Text($r('app.string.steam_accounts_login_qr_waiting'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .textAlign(TextAlign.Center)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        this.buildQrCancelButton();
      } else if (this.pendingQrAuthentication !== null) {
        this.buildPendingQrAuthenticationStatus();
        this.buildQrCancelButton();
      } else {
        Text($r('app.string.steam_accounts_login_qr_desc'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        Button() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.qrcode'))
              .fontSize(16)
              .fontColor([this.isAuthenticating
              ? SteamArkTheme.buttonDisabledText(this.isDarkMode)
              : SteamArkTheme.onAccent(this.isDarkMode)])
            Text(this.isAuthenticating
              ? $r('app.string.steam_accounts_auth_busy')
              : $r('app.string.steam_accounts_login_qr_start'))
              .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isAuthenticating
                ? SteamArkTheme.buttonDisabledText(this.isDarkMode)
                : SteamArkTheme.onAccent(this.isDarkMode))
          }
          .justifyContent(FlexAlign.Center)
        }
          .width('100%')
          .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
          .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
          .backgroundColor(this.isAuthenticating
          ? SteamArkTheme.buttonDisabled(this.isDarkMode)
            : SteamArkTheme.accent(this.isDarkMode))
          .fontColor(this.isAuthenticating
            ? SteamArkTheme.buttonDisabledText(this.isDarkMode)
            : SteamArkTheme.onAccent(this.isDarkMode))
          .id('steam-ark-accounts-login-qr-start')
          .enabled(!this.isAccountBusy())
          .onClick((): void => {
            void this.handleBeginQrSignIn();
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private buildQrGuidance(): void {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.info_circle'))
          .fontSize(18)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        Text($r('app.string.steam_accounts_login_qr_guidance_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')

      this.buildQrGuidanceRow($r('app.string.steam_accounts_login_qr_guidance_client'))
      this.buildQrGuidanceRow($r('app.string.steam_accounts_login_qr_guidance_location'))
      this.buildQrGuidanceRow($r('app.string.steam_accounts_login_qr_guidance_other'))
    }
    .width('100%')
    .padding(12)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode),
      this.useSysMat
    ))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: SteamArkTheme.accent(this.isDarkMode)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildQrGuidanceRow(message: ResourceStr): void {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(14)
        .fontColor([SteamArkTheme.success(this.isDarkMode)])
      Text(message)
        .layoutWeight(1)
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private buildPendingQrAuthenticationStatus(): void {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        SymbolGlyph(this.pendingQrSessionState() === SteamSessionState.ERROR
          ? $r('sys.symbol.exclamationmark_triangle')
          : $r('sys.symbol.arrow_clockwise'))
          .fontSize(18)
          .fontColor([this.pendingQrSessionState() === SteamSessionState.ERROR
            ? SteamArkTheme.error(this.isDarkMode)
            : SteamArkTheme.accent(this.isDarkMode)])
        Text(this.sessionLabel(this.pendingQrSessionState()))
          .layoutWeight(1)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')
      if (this.pendingQrFailureMessage().length > 0) {
        Text(this.pendingQrFailureMessage())
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(this.pendingQrSessionState() === SteamSessionState.ERROR
            ? SteamArkTheme.error(this.isDarkMode)
            : SteamArkTheme.textSecondary(this.isDarkMode))
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode),
      this.useSysMat
    ))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: this.pendingQrSessionState() === SteamSessionState.ERROR
        ? SteamArkTheme.error(this.isDarkMode)
        : SteamArkTheme.divider(this.isDarkMode)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildQrCancelButton(): void {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(15)
          .fontColor([SteamArkTheme.buttonForeground(this.isDarkMode)])
        Text($r('app.string.steam_accounts_login_qr_cancel'))
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode),
      this.useSysMat
    ))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .id('steam-ark-accounts-login-qr-cancel')
    .enabled(!this.isAccountBusy())
    .onClick((): void => {
      void this.handleCancelQrSignIn();
    })
  }

  @Builder
  private buildEmptyStateCard(): void {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.person_2'))
        .fontSize(24)
        .fontColor([SteamArkTheme.accent(this.isDarkMode)])
      Column({ space: 5 }) {
        Text($r('app.string.steam_accounts_empty_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_accounts_empty_desc'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
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
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildImportCard(): void {
    Column({ space: 12 }) {
      Text($r('app.string.steam_accounts_import_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_accounts_import_mafile_desc'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))

      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(16)
            .fontColor([SteamArkTheme.accent(this.isDarkMode)])
          Text($r('app.string.steam_accounts_mafile_guide_action'))
            .layoutWeight(1)
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
            .textAlign(TextAlign.Start)
          SymbolGlyph(this.showMaFileGuide
            ? $r('sys.symbol.chevron_up')
            : $r('sys.symbol.chevron_down'))
            .fontSize(14)
            .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
        }
        .width('100%')
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .padding({ left: 12, right: 12 })
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceControl(this.isDarkMode),
        this.useSysMat
      ))
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
      .onClick((): void => {
        this.getUIContext().animateTo({
          duration: SteamArkExperiencePolicy.SECTION_EXPAND_DURATION,
          curve: Curve.EaseOut
        }, (): void => {
          this.showMaFileGuide = !this.showMaFileGuide;
        });
      })

      if (this.showMaFileGuide) {
        this.buildMaFileGuide()
      }

      Column({ space: 10 }) {
        Row({ space: 10 }) {
          this.buildImportButton(
            $r('sys.symbol.file_preview'),
            $r('app.string.steam_accounts_import_json'),
            SteamArkImportKind.ASF_JSON
          )
          this.buildImportButton(
            $r('sys.symbol.lock_shield'),
            $r('app.string.steam_accounts_import_mafile'),
            SteamArkImportKind.MAFILE
          )
        }
        .width('100%')
        Row({ space: 10 }) {
          this.buildImportButton(
            $r('sys.symbol.gearshape'),
            $r('app.string.steam_accounts_import_global_json'),
            SteamArkImportKind.ASF_GLOBAL_JSON
          )
        }
        .width('100%')
      }
      .width('100%')
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
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwarePanelShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildMaFileGuide(): void {
    Column({ space: 10 }) {
      this.buildMaFileGuideRow(
        $r('sys.symbol.doc_text'),
        $r('app.string.steam_accounts_mafile_origin_title'),
        $r('app.string.steam_accounts_mafile_origin_desc')
      )
      this.buildMaFileGuideRow(
        $r('sys.symbol.qrcode'),
        $r('app.string.steam_accounts_mafile_existing_title'),
        $r('app.string.steam_accounts_mafile_existing_desc')
      )
      this.buildMaFileGuideRow(
        $r('sys.symbol.lock_shield'),
        $r('app.string.steam_accounts_mafile_create_title'),
        $r('app.string.steam_accounts_mafile_create_desc')
      )
      this.buildMaFileGuideRow(
        $r('sys.symbol.arrow_clockwise'),
        $r('app.string.steam_accounts_mafile_merge_title'),
        $r('app.string.steam_accounts_mafile_merge_desc')
      )
      this.buildMaFileGuideRow(
        $r('sys.symbol.exclamationmark_triangle'),
        $r('app.string.steam_accounts_mafile_risk_title'),
        $r('app.string.steam_accounts_mafile_risk_desc')
      )
      this.buildMaFileGuideRow(
        $r('sys.symbol.lock_shield'),
        $r('app.string.steam_accounts_mafile_security_title'),
        $r('app.string.steam_accounts_mafile_security_desc')
      )
    }
    .width('100%')
    .padding(12)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode),
        this.useSysMat
      )
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: '10vp' }))
      .animation({ duration: SteamArkExperiencePolicy.SECTION_EXPAND_DURATION, curve: Curve.EaseOut }))
  }

  @Builder
  private buildMaFileGuideRow(icon: Resource, title: ResourceStr, description: ResourceStr): void {
    Row({ space: 10 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([SteamArkTheme.accent(this.isDarkMode)])
      Column({ space: 3 }) {
        Text(title)
          .width('100%')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text(description)
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private buildImportButton(icon: Resource, title: ResourceStr, kind: number): void {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph(icon)
          .fontSize(16)
          .fontColor([SteamArkTheme.buttonForeground(this.isDarkMode)])
        Text(title)
          .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .padding({ left: 6, right: 6 })
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .id(this.importButtonId(kind))
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .enabled(!this.isAccountBusy())
    .onClick((): void => {
      if (!this.isAccountBusy()) {
        void this.handleImport(kind);
      }
    })
  }

  private importButtonId(kind: number): string {
    switch (kind) {
      case SteamArkImportKind.ASF_JSON:
        return 'steam-ark-accounts-import-json';
      case SteamArkImportKind.MAFILE:
        return 'steam-ark-accounts-import-mafile';
      case SteamArkImportKind.ASF_GLOBAL_JSON:
        return 'steam-ark-accounts-import-global-json';
      default:
        return 'steam-ark-accounts-import';
    }
  }

  @Builder
  private buildAccountListCard(): void {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.person_2'))
          .fontSize(18)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        Text($r('app.string.steam_accounts_count_label'))
          .fontSize(14)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        Text(String(this.accounts.length))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      }
      .width('100%')

      // The key must include UI-visible state: ArkUI ForEach reuses components
      // for identical keys without re-running the item builder, so a sign-out,
      // selection change or session transition would otherwise leave stale rows.
      ForEach(this.accounts, (account: SteamArkAccountSnapshot) => {
        this.buildAccountRow(account)
      }, (account: SteamArkAccountSnapshot): string => account.profile.accountId + '|' +
        String(account.session.state) + '|' + this.selectedAccountId)
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
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwarePanelShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildAccountRow(account: SteamArkAccountSnapshot): void {
    Stack({ alignContent: Alignment.Center }) {
      if (account.profile.miniProfileBackgroundImageUrl.length > 0) {
        Image(account.profile.miniProfileBackgroundImageUrl)
          .width('100%')
          .height(120)
          .objectFit(ImageFit.Cover)
          .opacity(0.34)
          .onError((): void => {
            SteamArkLog.warn('AccountsPage', 'mini profile background image failed; account=' +
              SteamArkLog.accountId(account.profile.accountId));
          })
      }
      Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.buildAccountAvatar(account)
        Column({ space: 3 }) {
          Text(account.profile.displayName.length > 0 ? account.profile.displayName : account.profile.accountId)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.sessionLabel(account.session.state))
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          Row({ space: 8 }) {
            if (account.profile.level > 0) {
              Text($r('app.string.steam_accounts_level_prefix'))
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
              Text(account.profile.level.toString())
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            }
            if (account.profile.countryCode.length > 0) {
              Text(account.profile.countryCode.toUpperCase())
                .fontSize(11)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            }
            Text(this.accountRegionBadge(account))
              .fontSize(11)
              .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            if (account.profile.walletBalance.length > 0) {
              Text(account.profile.walletCurrency + ' ' + account.profile.walletBalance)
                .fontSize(11)
                .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (account.profile.accountId === this.selectedAccountId) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(20)
            .fontColor([SteamArkTheme.success(this.isDarkMode)])
        }
      }
      .width('100%')

      if (account.session.state === SteamSessionState.ERROR) {
        this.buildAccountError(account)
      }

      if (account.profile.summary.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.summaryParts(account.profile.summary), (part: SteamArkSummaryPart) => {
            if (part.kind === SteamArkSummaryPartKind.IMAGE) {
              Image(part.value)
                .width(20)
                .height(20)
                .objectFit(ImageFit.Contain)
                .margin({ left: 2, right: 2 })
                .onError((): void => {
                  SteamArkLog.debug('AccountsPage', 'profile summary image failed; account=' +
                    SteamArkLog.accountId(account.profile.accountId));
                })
            } else {
              Text(part.value)
                .fontSize(12)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }, (part: SteamArkSummaryPart) => part.kind.toString() + '-' + part.value)
        }
        .width('100%')
      }

      Text($r('app.string.steam_accounts_long_press_hint'))
        .width('100%')
        .fontSize(11)
        .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (account.profile.accountId === this.selectedAccountId &&
        account.session.state !== SteamSessionState.LOGGED_ON) {
        this.buildAuthenticationControls(account)
      }
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.background_transparent'))
    }
    .width('100%')
    .constraintSize({ minHeight: 120 })
    .backgroundColor(account.profile.accountId === this.selectedAccountId
      ? SteamArkTheme.surfaceControl(this.isDarkMode)
      : SteamArkTheme.surface(this.isDarkMode))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .clip(true)
    .border({
      width: 1,
      color: account.profile.accountId === this.selectedAccountId
        ? SteamArkTheme.accent(this.isDarkMode)
        : SteamArkTheme.divider(this.isDarkMode)
    })
    .id('steam-ark-accounts-row-' + account.profile.accountId)
    .onClick((): void => {
      if (account.profile.accountId !== this.selectedAccountId && !this.isAccountBusy()) {
        void this.selectAccount(account.profile.accountId);
      }
    })
    .bindContextMenuWithResponse(this.accountMenuItems(account), ResponseType.LongPress)
  }

  private accountMenuItems(account: SteamArkAccountSnapshot): Array<MenuElement> {
    const items: Array<MenuElement> = [];
    if (account.profile.accountId !== this.selectedAccountId) {
      const selectItem: MenuElement = {
        value: $r('app.string.steam_accounts_select'),
        enabled: !this.isAccountBusy(),
        action: (): void => {
          void this.selectAccount(account.profile.accountId);
        }
      };
      items.push(selectItem);
    }
    if (account.session.state === SteamSessionState.LOGGED_ON) {
      const refreshItem: MenuElement = {
        value: $r('app.string.steam_accounts_auth_refresh'),
        enabled: !this.isAccountBusy(),
        action: (): void => {
          this.handleAuthenticationAction(account.profile.accountId, SteamArkAuthActionKind.REFRESH);
        }
      };
      const signOutItem: MenuElement = {
        value: $r('app.string.steam_accounts_sign_out'),
        enabled: !this.isAccountBusy(),
        action: (): void => {
          this.handleAuthenticationAction(account.profile.accountId, SteamArkAuthActionKind.SIGN_OUT);
        }
      };
      items.push(refreshItem);
      items.push(signOutItem);
    }
    const removeItem: MenuElement = {
      value: $r('app.string.steam_accounts_remove_confirm'),
      enabled: !this.isAccountBusy(),
      action: (): void => {
        this.confirmRemoveAccount(account.profile.accountId);
      }
    };
    items.push(removeItem);
    return items;
  }

  private accountRegionBadge(account: SteamArkAccountSnapshot): string {
    const locale: SteamArkContentLocale = SteamArkRegionPolicy.resolve(
      account.region, account.profile.countryCode, account.profile.walletCurrency);
    return locale.region + ' · ' + locale.currencyCode;
  }

  @Builder
  private buildAccountAvatar(account: SteamArkAccountSnapshot): void {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.person_2'))
        .fontSize(22)
        .fontColor([SteamArkTheme.accent(this.isDarkMode)])
      if (account.profile.avatarUrl.length > 0) {
        Image(account.profile.avatarUrl)
          .width(44)
          .height(44)
          .objectFit(ImageFit.Cover)
          .borderRadius(10)
      }
      if (account.profile.avatarFrameUrl.length > 0) {
        Image(account.profile.avatarFrameUrl)
          .width(52)
          .height(52)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(52)
    .height(52)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode),
      this.useSysMat
    ))
    .borderRadius(12)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
  }

  @Builder
  private buildAuthenticationControls(account: SteamArkAccountSnapshot): void {
    Column({ space: 8 }) {
      if (this.isRetryablePollingAccount(account)) {
        this.buildAuthActionButton(
          $r('sys.symbol.arrow_clockwise'),
          $r('app.string.steam_accounts_auth_poll'),
          account.profile.accountId,
          SteamArkAuthActionKind.POLL
        )
      } else if (account.session.state === SteamSessionState.NEEDS_QR_SCAN) {
        Text($r('app.string.steam_accounts_auth_qr_pending'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      } else if (account.session.state === SteamSessionState.NEEDS_EMAIL_CODE ||
        account.session.state === SteamSessionState.NEEDS_TWO_FACTOR ||
        this.isRetryableCodeAccount(account)) {
        TextInput({
          placeholder: $r('app.string.steam_accounts_auth_code_placeholder'),
          text: this.challengeCode
        })
          .id('steam-ark-accounts-challenge-input-' + account.profile.accountId)
          .width('100%')
          .height(NGFControlStyleTokens.FORM_CONTROL_MIN_HEIGHT)
          .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
          .padding({ left: 12, right: 12 })
          .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
          .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
            SteamArkTheme.surfaceControl(this.isDarkMode),
            this.useSysMat
          ))
          .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
          .enabled(!this.isAccountBusy())
          .onChange((value: string): void => {
            this.challengeCode = value;
          })

        this.buildAuthActionButton(
          $r('sys.symbol.checkmark'),
          $r('app.string.steam_accounts_auth_submit_code'),
          account.profile.accountId,
          SteamArkAuthActionKind.COMPLETE_CHALLENGE
        )
      } else if (account.session.state === SteamSessionState.NEEDS_MOBILE_CONFIRMATION) {
        this.buildAuthActionButton(
          $r('sys.symbol.arrow_clockwise'),
          $r('app.string.steam_accounts_auth_poll'),
          account.profile.accountId,
          SteamArkAuthActionKind.POLL
        )
      } else if (account.session.state === SteamSessionState.CONNECTING ||
        account.session.state === SteamSessionState.RECONNECTING) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(SteamArkTheme.accent(this.isDarkMode))
          Text($r('app.string.steam_accounts_auth_busy'))
            .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .width('100%')
        .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
        .justifyContent(FlexAlign.Center)
      } else if (account.session.state === SteamSessionState.LOGGED_ON) {
        this.buildAuthActionButton(
          $r('sys.symbol.arrow_clockwise'),
          $r('app.string.steam_accounts_auth_refresh'),
          account.profile.accountId,
          SteamArkAuthActionKind.REFRESH
        )
      } else if (this.isTerminalTemporaryQrAccount(account)) {
        this.buildAuthActionButton(
          $r('sys.symbol.trash'),
          $r('app.string.steam_accounts_remove_failed_qr'),
          account.profile.accountId,
          SteamArkAuthActionKind.REMOVE_FAILED_QR
        )
      } else {
        this.buildAuthActionButton(
          $r('sys.symbol.person_2'),
          $r('app.string.steam_accounts_auth_sign_in'),
          account.profile.accountId,
          SteamArkAuthActionKind.SIGN_IN
        )
      }
      if (!this.isTerminalTemporaryQrAccount(account)) {
        this.buildAuthActionButton(
          $r('sys.symbol.xmark'),
          $r('app.string.steam_accounts_sign_out'),
          account.profile.accountId,
          SteamArkAuthActionKind.SIGN_OUT
        )
        this.buildAuthActionButton(
          $r('sys.symbol.trash'),
          $r('app.string.steam_accounts_remove'),
          account.profile.accountId,
          SteamArkAuthActionKind.REMOVE_ACCOUNT
        )
      }
    }
    .width('100%')
    .padding({ top: 8 })
  }

  @Builder
  private buildAccountError(account: SteamArkAccountSnapshot): void {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(15)
          .fontColor([SteamArkTheme.error(this.isDarkMode)])
        Text($r('app.string.steam_accounts_error_details'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.error(this.isDarkMode))
      }
      .width('100%')
      if (account.session.lastErrorType.length > 0) {
        this.buildErrorDetailRow($r('app.string.steam_accounts_error_type'), account.session.lastErrorType)
      }
      if (account.session.lastErrorStage.length > 0) {
        this.buildErrorDetailRow($r('app.string.steam_accounts_error_stage'), account.session.lastErrorStage)
      }
      if (account.session.lastErrorCode !== 0) {
        this.buildErrorDetailRow($r('app.string.steam_accounts_error_code'), account.session.lastErrorCode.toString())
      }
      if (account.session.lastErrorHttpStatusCode !== 0) {
        this.buildErrorDetailRow(
          $r('app.string.steam_accounts_error_http_status'),
          account.session.lastErrorHttpStatusCode.toString()
        )
      }
      if (account.session.lastErrorMessageType !== 0) {
        this.buildErrorDetailRow(
          $r('app.string.steam_accounts_error_message_type'),
          account.session.lastErrorMessageType.toString()
        )
      }
      if (account.session.lastErrorHeaderKind.length > 0) {
        this.buildErrorDetailRow(
          $r('app.string.steam_accounts_error_header_kind'),
          account.session.lastErrorHeaderKind
        )
      }
      if (account.session.lastErrorFrameBytes !== 0) {
        this.buildErrorDetailRow(
          $r('app.string.steam_accounts_error_frame_bytes'),
          account.session.lastErrorFrameBytes.toString()
        )
      }
      if (account.session.lastErrorHeaderBytes !== 0) {
        this.buildErrorDetailRow(
          $r('app.string.steam_accounts_error_header_bytes'),
          account.session.lastErrorHeaderBytes.toString()
        )
      }
      if (account.session.lastErrorBodyBytes !== 0) {
        this.buildErrorDetailRow(
          $r('app.string.steam_accounts_error_body_bytes'),
          account.session.lastErrorBodyBytes.toString()
        )
      }
      if (account.session.lastErrorServerMessage.length > 0) {
        this.buildErrorDetailRow(
          $r('app.string.steam_accounts_error_server_message'),
          this.safeDisplayError(account.session.lastErrorServerMessage)
        )
      }
      Text(account.session.lastErrorMessage.length > 0
        ? this.safeDisplayError(account.session.lastErrorMessage)
        : $r('app.string.steam_accounts_account_operation_failed'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(10)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(10)
    .backgroundColor(SteamArkTheme.background(this.isDarkMode))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({ width: 1, color: SteamArkTheme.error(this.isDarkMode) })
  }

  @Builder
  private buildErrorDetailRow(label: ResourceStr, value: string): void {
    Row({ space: 6 }) {
      Text(label)
        .fontSize(11)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      Text(this.safeDisplayError(value))
        .layoutWeight(1)
        .fontSize(11)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  @Builder
  private buildAuthActionButton(
    icon: Resource,
    title: ResourceStr,
    accountId: string,
    actionKind: number
  ): void {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph(icon)
          .fontSize(16)
          .fontColor([this.isAuthenticating ? SteamArkTheme.textMuted(this.isDarkMode) : SteamArkTheme.buttonForeground(this.isDarkMode)])
        Text(this.isAuthenticating ? $r('app.string.steam_accounts_auth_busy') : title)
          .fontSize(NGFControlStyleTokens.FORM_CONTROL_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isAuthenticating ? SteamArkTheme.textMuted(this.isDarkMode) : SteamArkTheme.buttonForeground(this.isDarkMode))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
    .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
    .backgroundColor(this.isAuthenticating
      ? SteamArkTheme.surfaceControl(this.isDarkMode)
      : NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .id('steam-ark-accounts-auth-' + accountId + '-' + this.authActionId(actionKind))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
    .enabled(!this.isAccountBusy())
    .onClick((): void => {
      if (!this.isAccountBusy()) {
        this.handleAuthenticationAction(accountId, actionKind);
      }
    })
  }

  private authActionId(actionKind: number): string {
    switch (actionKind) {
      case SteamArkAuthActionKind.SIGN_IN:
        return 'sign-in';
      case SteamArkAuthActionKind.COMPLETE_CHALLENGE:
        return 'complete-challenge';
      case SteamArkAuthActionKind.POLL:
        return 'poll';
      case SteamArkAuthActionKind.REFRESH:
        return 'refresh';
      case SteamArkAuthActionKind.REMOVE_FAILED_QR:
        return 'remove-failed-qr';
      case SteamArkAuthActionKind.SIGN_OUT:
        return 'sign-out';
      case SteamArkAuthActionKind.REMOVE_ACCOUNT:
        return 'remove-account';
      default:
        return 'action';
    }
  }

  private isRetryableAuthAccount(account: SteamArkAccountSnapshot): boolean {
    return account.session.state === SteamSessionState.ERROR &&
      account.pendingAuth !== null &&
      (account.session.lastErrorType === SteamAuthErrorKind.TRANSPORT ||
        account.session.lastErrorType === SteamAuthErrorKind.TIMEOUT);
  }

  private isRetryablePollingAccount(account: SteamArkAccountSnapshot): boolean {
    if (!this.isRetryableAuthAccount(account) || account.pendingAuth === null) {
      return false;
    }
    return account.pendingAuth.challenge === SteamAuthChallengeKind.QR_SCAN ||
      account.pendingAuth.challenge === SteamAuthChallengeKind.MOBILE_CONFIRMATION;
  }

  private isRetryableCodeAccount(account: SteamArkAccountSnapshot): boolean {
    if (!this.isRetryableAuthAccount(account) || account.pendingAuth === null) {
      return false;
    }
    return account.pendingAuth.challenge === SteamAuthChallengeKind.EMAIL_CODE ||
      account.pendingAuth.challenge === SteamAuthChallengeKind.TWO_FACTOR;
  }

  private isAutoPollableAuthAccount(account: SteamArkAccountSnapshot): boolean {
    if (account.pendingAuth === null) {
      return false;
    }
    const challengeIsPollable = account.pendingAuth.challenge === SteamAuthChallengeKind.QR_SCAN ||
      account.pendingAuth.challenge === SteamAuthChallengeKind.MOBILE_CONFIRMATION;
    if (!challengeIsPollable) {
      return false;
    }
    return account.session.state === SteamSessionState.NEEDS_QR_SCAN ||
      account.session.state === SteamSessionState.NEEDS_MOBILE_CONFIRMATION ||
      this.isRetryablePollingAccount(account);
  }

  private isAutoPollableQrAuthentication(snapshot: SteamArkQrAuthenticationSnapshot): boolean {
    const pending = snapshot.pendingAuth;
    if (pending === null) {
      return false;
    }
    const challengeIsPollable = pending.challenge === SteamAuthChallengeKind.QR_SCAN ||
      pending.challenge === SteamAuthChallengeKind.MOBILE_CONFIRMATION;
    if (!challengeIsPollable) {
      return false;
    }
    return snapshot.session.state === SteamSessionState.NEEDS_QR_SCAN ||
      snapshot.session.state === SteamSessionState.NEEDS_MOBILE_CONFIRMATION ||
      (snapshot.session.state === SteamSessionState.ERROR &&
        (snapshot.session.lastErrorType === SteamAuthErrorKind.TRANSPORT ||
          snapshot.session.lastErrorType === SteamAuthErrorKind.TIMEOUT));
  }

  private isTerminalTemporaryQrAccount(account: SteamArkAccountSnapshot): boolean {
    return account.session.state === SteamSessionState.ERROR &&
      account.profile.accountId.indexOf('qr-') === 0 &&
      !account.hasCredentialMaterial && account.profile.steamId64.length === 0 &&
      account.pendingAuth === null;
  }

  private authenticationFailureStatus(accountId: string): string {
    const targetId: string = accountId.length > 0 ? accountId : this.selectedAccountId;
    const pendingQr = this.pendingQrAuthentication;
    if (pendingQr !== null &&
      (targetId.length <= 0 || pendingQr.session.accountId === targetId) &&
      this.hasAuthenticationErrorDetails(pendingQr.session)) {
      return this.formatAuthenticationFailure(pendingQr.session);
    }
    for (let index = 0; index < this.accounts.length; index++) {
      const account = this.accounts[index];
      if (account.profile.accountId === targetId && this.hasAuthenticationErrorDetails(account.session)) {
        return this.formatAuthenticationFailure(account.session);
      }
    }
    return '';
  }

  private hasAuthenticationErrorDetails(session: SteamSessionSnapshot): boolean {
    return session.lastErrorMessage.length > 0 ||
      session.lastErrorType.length > 0 ||
      session.lastErrorStage.length > 0 ||
      session.lastErrorCode !== 0 ||
      session.lastErrorHttpStatusCode !== 0 ||
      session.lastErrorMessageType !== 0 ||
      session.lastErrorHeaderKind.length > 0 ||
      session.lastErrorFrameBytes !== 0 ||
      session.lastErrorHeaderBytes !== 0 ||
      session.lastErrorBodyBytes !== 0 ||
      session.lastErrorServerMessage.length > 0;
  }

  private formatAuthenticationFailure(session: SteamSessionSnapshot): string {
    const message: string = this.safeDisplayError(session.lastErrorMessage);
    const formatted: string = ngfI18nManagerFacade.resolveStringWithArgs(
      $r('app.string.steam_accounts_error_status'),
      [
        this.errorStatusValue(session.lastErrorType),
        this.errorStatusValue(session.lastErrorStage),
        this.errorStatusNumber(session.lastErrorCode),
        this.errorStatusNumber(session.lastErrorHttpStatusCode),
        this.errorStatusNumber(session.lastErrorMessageType),
        this.errorStatusValue(session.lastErrorHeaderKind),
        this.errorStatusValue(session.lastErrorServerMessage),
        this.errorStatusValue(message)
      ]
    );
    if (formatted.length > 0 && formatted !== 'Resource') {
      return formatted;
    }
    return message;
  }

  private errorStatusValue(value: string): string {
    const normalized: string = this.safeDisplayError(value);
    return normalized.length > 0 ? normalized : '-';
  }

  private errorStatusNumber(value: number): string {
    return value === 0 ? '-' : value.toString();
  }

  private async handleRemoveFailedQrAccount(accountId: string): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy()) {
      return;
    }
    const scope = this.beginAccountOperation(accountId, true);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'failed QR account removal started; account=' +
      SteamArkLog.accountId(accountId));
    try {
      const removed: boolean = await steamArkStateService.removeAccount(accountId);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = removed
        ? $r('app.string.steam_accounts_remove_success')
        : $r('app.string.steam_accounts_account_operation_failed');
      if (removed) {
        this.qrAccountId = '';
        this.qrChallengeUrl = '';
        this.clearAuthPolling();
      }
      SteamArkLog.info('AccountsPage', 'failed QR account removal completed; account=' +
        SteamArkLog.accountId(accountId) + ', removed=' + String(removed));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_auth_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'failed QR account removal failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
      }
    }
  }

  private async handleSignOut(accountId: string): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy()) {
      return;
    }
    const scope = this.beginAccountOperation(accountId);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'account sign-out started; account=' + SteamArkLog.accountId(accountId));
    try {
      const signedOut = await steamArkStateService.signOut(accountId);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = signedOut
        ? $r('app.string.steam_accounts_sign_out_success')
        : $r('app.string.steam_accounts_account_operation_failed');
      this.challengeCode = '';
      SteamArkLog.info('AccountsPage', 'account sign-out completed; account=' +
        SteamArkLog.accountId(accountId) + ', signedOut=' + String(signedOut));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_account_operation_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'account sign-out failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
      }
    }
  }

  private confirmRemoveAccount(accountId: string): void {
    if (!this.isPageActive || this.isAccountBusy()) {
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const operationGeneration: number = this.operationGeneration;
    this.getUIContext().showAlertDialog({
      title: $r('app.string.steam_accounts_remove_title'),
      message: $r('app.string.steam_accounts_remove_message'),
      primaryButton: {
        value: $r('app.string.steam_accounts_remove_confirm'),
        action: (): void => {
          if (this.isCurrentOperation(lifecycleGeneration, operationGeneration)) {
            void this.handleRemoveAccount(accountId);
          }
        }
      },
      secondaryButton: {
        value: $r('app.string.steam_accounts_cancel'),
        action: (): void => {
          return;
        }
      }
    });
  }

  private async handleRemoveAccount(accountId: string): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy()) {
      return;
    }
    const scope = this.beginAccountOperation(accountId, true);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'account removal started; account=' + SteamArkLog.accountId(accountId));
    try {
      const removed = await steamArkStateService.removeAccount(accountId);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = removed
        ? $r('app.string.steam_accounts_remove_success')
        : $r('app.string.steam_accounts_account_operation_failed');
      this.challengeCode = '';
      if (removed && this.qrAccountId === accountId) {
        this.qrAccountId = '';
        this.qrChallengeUrl = '';
        this.clearAuthPolling();
      }
      SteamArkLog.info('AccountsPage', 'account removal completed; account=' +
        SteamArkLog.accountId(accountId) + ', removed=' + String(removed));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_account_operation_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'account removal failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
      }
    }
  }

  @Builder
  private buildSecurityCard(): void {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(23)
        .fontColor([SteamArkTheme.success(this.isDarkMode)])
      Column({ space: 5 }) {
        Text($r('app.string.steam_accounts_secure_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_accounts_secure_desc'))
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
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
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildStatusMessage(): void {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(16)
        .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      Text(this.statusMessage)
        .layoutWeight(1)
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4, bottom: 8 })
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    if (!this.isPageActive) {
      return;
    }
    const wasStateReady: boolean = this.stateReady;
    this.stateReady = snapshot.initialized;
    if (!this.stateReady) {
      this.statusMessage = $r('app.string.steam_state_unavailable_status');
    } else if (!wasStateReady) {
      this.statusMessage = $r('app.string.steam_accounts_status_idle');
    }
    const previousSelectedAccountId: string = this.selectedAccountId;
    this.updateAccountScope(snapshot);
    this.invalidateMissingAccountOperation(snapshot);
    this.accounts = snapshot.accounts;
    this.selectedAccountId = snapshot.selectedAccountId;
    this.pendingQrAuthentication = snapshot.pendingQrAuthentication;
    if (previousSelectedAccountId !== snapshot.selectedAccountId) {
      this.challengeCode = '';
    }
    let pendingPoll: SteamAuthPendingSnapshot | null = null;
    const pendingQr = snapshot.pendingQrAuthentication;
    if (pendingQr !== null) {
      this.authMode = SteamArkAuthModeKind.QR;
      this.qrAccountId = pendingQr.session.accountId;
      const candidate = pendingQr.pendingAuth;
      if (this.isAutoPollableQrAuthentication(pendingQr) && candidate !== null) {
        pendingPoll = candidate;
      }
      if (candidate !== null && candidate.flow === SteamAuthFlowKind.QR &&
        candidate.challenge === SteamAuthChallengeKind.QR_SCAN) {
        this.qrChallengeUrl = candidate.challengeUrl;
      } else {
        this.qrChallengeUrl = '';
      }
    } else {
      this.qrAccountId = '';
      this.qrChallengeUrl = '';
      for (let index = 0; index < snapshot.accounts.length; index++) {
        const account = snapshot.accounts[index];
        const candidate = account.pendingAuth;
        if (!this.isAutoPollableAuthAccount(account)) {
          continue;
        }
        if (candidate !== null && (candidate.challenge === SteamAuthChallengeKind.QR_SCAN ||
          candidate.challenge === SteamAuthChallengeKind.MOBILE_CONFIRMATION)) {
          pendingPoll = candidate;
          break;
        }
      }
      if (pendingPoll !== null && pendingPoll.flow === SteamAuthFlowKind.QR &&
        pendingPoll.challenge === SteamAuthChallengeKind.QR_SCAN) {
        this.qrAccountId = pendingPoll.accountId;
        this.qrChallengeUrl = pendingPoll.challengeUrl;
        this.authMode = SteamArkAuthModeKind.QR;
      }
    }
    if (pendingPoll === null) {
      if (pendingQr === null) {
        this.qrAccountId = '';
        this.qrChallengeUrl = '';
      }
      this.clearAuthPolling();
      SteamArkLog.debug('AccountsPage', 'state applied; accounts=' + snapshot.accounts.length.toString() +
        ', pendingPoll=false, pendingQr=' + String(pendingQr !== null));
      return;
    }
    this.scheduleAuthPolling(pendingPoll);
    SteamArkLog.debug('AccountsPage', 'state applied; accounts=' + snapshot.accounts.length.toString() +
      ', pendingPoll=true, account=' + SteamArkLog.accountId(pendingPoll.accountId) +
      ', challenge=' + String(pendingPoll.challenge));
  }

  private async initializeStateService(): Promise<void> {
    const startedAt: number = Date.now();
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const operationGeneration: number = this.operationGeneration;
    try {
      const initialized: boolean = await steamArkStateService.initialize();
      if (!this.isCurrentOperation(lifecycleGeneration, operationGeneration)) {
        return;
      }
      this.applyStateSnapshot(steamArkStateService.getSnapshot());
      SteamArkLog.info('AccountsPage', 'state service ready; initialized=' + String(initialized));
      SteamArkLog.performance('AccountsPage', 'state initialization', startedAt);
    } catch (error) {
      if (!this.isCurrentOperation(lifecycleGeneration, operationGeneration)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        '',
        $r('app.string.steam_accounts_auth_unavailable'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'state service initialization failed; errorType=' +
        SteamArkLog.errorKind(error));
    }
  }

  private async selectAccount(accountId: string): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy()) {
      return;
    }
    const scope = this.beginAccountOperation(accountId);
    this.isSelectingAccount = true;
    SteamArkLog.info('AccountsPage', 'account selection requested; account=' + SteamArkLog.accountId(accountId));
    try {
      const selected = await steamArkStateService.selectAccount(accountId);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      if (selected) {
        this.challengeCode = '';
        this.statusMessage = $r('app.string.steam_accounts_import_report_clean');
        SteamArkLog.info('AccountsPage', 'account selected; account=' + SteamArkLog.accountId(accountId));
      } else {
        this.statusMessage = $r('app.string.steam_accounts_account_operation_failed');
        SteamArkLog.warn('AccountsPage', 'account selection rejected; account=' + SteamArkLog.accountId(accountId));
      }
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_account_operation_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'account selection failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isSelectingAccount = false;
      }
    }
  }

  private failureStatus(accountId: string, fallback: ResourceStr, errorMessage: string): ResourceStr {
    const structuredError: string = this.authenticationFailureStatus(accountId);
    if (structuredError.length > 0) {
      return structuredError;
    }
    const currentError: string = this.safeDisplayError(errorMessage);
    return currentError.length > 0 ? currentError : fallback;
  }

  private safeDisplayError(message: string): string {
    const normalized = message.replace(/\r/g, ' ').replace(/\n/g, ' ').trim();
    if (normalized.length <= 512) {
      return normalized;
    }
    return normalized.substring(0, 512);
  }

  private pendingQrSessionState(): SteamSessionState {
    const pendingQr = this.pendingQrAuthentication;
    return pendingQr === null ? SteamSessionState.DISCONNECTED : pendingQr.session.state;
  }

  private pendingQrFailureMessage(): string {
    const pendingQr = this.pendingQrAuthentication;
    if (pendingQr === null) {
      return '';
    }
    return this.safeDisplayError(pendingQr.session.lastErrorMessage);
  }

  private ensureAuthServiceReady(): boolean {
    if (!this.stateReady) {
      if (this.isPageActive) {
        this.statusMessage = $r('app.string.steam_state_unavailable_status');
      }
      SteamArkLog.warn('AccountsPage', 'authentication action blocked; state service unavailable');
      return false;
    }
    if (this.isPageActive && steamArkStateService.isAuthServiceReady()) {
      return true;
    }
    if (this.isPageActive) {
      this.statusMessage = $r('app.string.steam_accounts_auth_unavailable');
    }
    SteamArkLog.warn('AccountsPage', 'authentication action blocked; auth service unavailable');
    return false;
  }

  private handleAuthenticationAction(accountId: string, actionKind: number): void {
    if (!this.isPageActive || this.isAccountBusy()) {
      return;
    }
    SteamArkLog.info('AccountsPage', 'authentication action requested; action=' + actionKind.toString() +
      ', account=' + SteamArkLog.accountId(accountId));
    switch (actionKind) {
      case SteamArkAuthActionKind.SIGN_IN:
        void this.handleSignIn(accountId);
        break;
      case SteamArkAuthActionKind.COMPLETE_CHALLENGE:
        void this.handleCompleteChallenge(accountId);
        break;
      case SteamArkAuthActionKind.POLL:
        void this.handlePollAuthentication(accountId);
        break;
      case SteamArkAuthActionKind.REFRESH:
        void this.handleRefreshAuthentication(accountId);
        break;
      case SteamArkAuthActionKind.REMOVE_FAILED_QR:
        void this.handleRemoveFailedQrAccount(accountId);
        break;
      case SteamArkAuthActionKind.SIGN_OUT:
        void this.handleSignOut(accountId);
        break;
      case SteamArkAuthActionKind.REMOVE_ACCOUNT:
        this.confirmRemoveAccount(accountId);
        break;
      default:
        this.statusMessage = $r('app.string.steam_accounts_auth_failed');
        SteamArkLog.warn('AccountsPage', 'unknown authentication action; action=' + actionKind.toString());
        break;
    }
  }

  private async handleSignIn(accountId: string): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy() || !this.ensureAuthServiceReady()) {
      return;
    }
    const scope = this.beginAccountOperation(accountId);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'stored-credential sign-in started; account=' + SteamArkLog.accountId(accountId));
    try {
      const result: SteamAuthResult = await steamArkStateService.signIn(accountId);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.authResultMessage(result);
      SteamArkLog.info('AccountsPage', 'stored-credential sign-in completed; account=' +
        SteamArkLog.accountId(accountId) + ', state=' + String(result.session.state));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_auth_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'stored-credential sign-in failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
      }
    }
  }

  private canSubmitPasswordLogin(): boolean {
    return this.stateReady && !this.isAccountBusy() && this.loginAccountName.trim().length > 0 &&
      this.loginPassword.length > 0;
  }

  private async handlePasswordSignIn(): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy() || !this.ensureAuthServiceReady()) {
      return;
    }
    const accountName = this.loginAccountName.trim();
    if (accountName.length <= 0) {
      this.statusMessage = $r('app.string.steam_accounts_login_account_required');
      return;
    }
    if (this.loginPassword.length <= 0) {
      this.statusMessage = $r('app.string.steam_accounts_login_password_required');
      return;
    }
    const scope = this.beginAccountOperation(accountName, true);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'password sign-in started; account=' + SteamArkLog.accountId(accountName));
    try {
      const result: SteamAuthResult = await steamArkStateService.signInWithPassword(
        accountName,
        this.loginPassword
      );
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.authResultMessage(result);
      this.loginPassword = '';
      SteamArkLog.info('AccountsPage', 'password sign-in completed; state=' + String(result.session.state));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        '',
        $r('app.string.steam_accounts_auth_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'password sign-in failed; account=' +
        SteamArkLog.accountId(accountName) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.loginPassword = '';
        this.isAuthenticating = false;
      }
    }
  }

  private async handleBeginQrSignIn(): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy() || !this.ensureAuthServiceReady()) {
      return;
    }
    const scope = this.beginAccountOperation('', true);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'QR sign-in started');
    try {
      const result: SteamAuthResult = await steamArkStateService.beginQrSignIn();
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.authMode = SteamArkAuthModeKind.QR;
      this.statusMessage = this.authResultMessage(result);
      SteamArkLog.info('AccountsPage', 'QR sign-in request completed; account=' +
        SteamArkLog.accountId(result.session.accountId) + ', state=' + String(result.session.state));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        '',
        $r('app.string.steam_accounts_auth_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'QR sign-in request failed; errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
      }
    }
  }

  private async handleCancelQrSignIn(): Promise<void> {
    const accountId = this.qrAccountId;
    if (!this.isPageActive || this.isAccountBusy() || accountId.length <= 0) {
      return;
    }
    const scope = this.beginAccountOperation(accountId, true);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'QR sign-in cancellation started; account=' + SteamArkLog.accountId(accountId));
    try {
      await steamArkStateService.cancelAuthentication(accountId);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = $r('app.string.steam_accounts_login_qr_cancelled');
      this.qrAccountId = '';
      this.qrChallengeUrl = '';
      this.clearAuthPolling();
      SteamArkLog.info('AccountsPage', 'QR sign-in cancelled; account=' + SteamArkLog.accountId(accountId));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_auth_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'QR sign-in cancellation failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
      }
    }
  }

  private scheduleAuthPolling(pending: SteamAuthPendingSnapshot): void {
    const requiresChallengeUrl: boolean = pending.challenge === SteamAuthChallengeKind.QR_SCAN;
    if (!this.isPageActive || pending.accountId.length <= 0 ||
      (requiresChallengeUrl && pending.challengeUrl.length <= 0)) {
      return;
    }
    const challengeIdentity: string = this.authChallengeIdentity(pending);
    if (this.authPollAccountId === pending.accountId &&
      this.authPollChallengeIdentity === challengeIdentity && this.authPollTimer >= 0) {
      return;
    }
    this.clearAuthPolling();
    this.authPollAccountId = pending.accountId;
    this.authPollChallengeIdentity = challengeIdentity;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    this.authPollGeneration += 1;
    const authPollGeneration: number = this.authPollGeneration;
    const intervalMilliseconds: number = Math.max(1, pending.intervalSeconds) * 1000;
    const remainingMilliseconds: number = Math.max(
      1,
      (pending.expiresAtEpochSeconds - Math.floor(Date.now() / 1000)) * 1000
    );
    const delayMilliseconds: number = Math.min(intervalMilliseconds, remainingMilliseconds);
    SteamArkLog.debug('AccountsPage', 'authentication polling scheduled; account=' +
      SteamArkLog.accountId(pending.accountId) + ', challenge=' + String(pending.challenge) +
      ', delayMs=' + delayMilliseconds.toString());
    this.authPollTimer = setTimeout((): void => {
      if (this.authPollGeneration !== authPollGeneration) {
        return;
      }
      this.authPollTimer = -1;
      this.authPollAccountId = '';
      this.authPollChallengeIdentity = '';
      void this.handleScheduledAuthPoll(pending, lifecycleGeneration, authPollGeneration);
    }, delayMilliseconds);
  }

  private async handleScheduledAuthPoll(
    expected: SteamAuthPendingSnapshot,
    lifecycleGeneration: number,
    authPollGeneration: number
  ): Promise<void> {
    if (!this.isCurrentLifecycle(lifecycleGeneration) || this.authPollGeneration !== authPollGeneration) {
      return;
    }
    const accountId: string = expected.accountId;
    const pending = this.findPendingPoll(accountId);
    if (pending === null || this.authChallengeIdentity(pending) !== this.authChallengeIdentity(expected)) {
      return;
    }
    if (this.isAuthenticating) {
      this.scheduleAuthPolling(pending);
      return;
    }
    if (!this.ensureAuthServiceReady()) {
      return;
    }
    const scope = this.beginAccountOperation(accountId);
    this.isAuthenticating = true;
    SteamArkLog.debug('AccountsPage', 'scheduled authentication poll started; account=' +
      SteamArkLog.accountId(accountId));
    try {
      const result: SteamAuthResult | null =
        await steamArkStateService.pollAuthenticationIfCurrent(expected);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      if (result === null) {
        SteamArkLog.debug('AccountsPage', 'scheduled authentication poll skipped because challenge changed; account=' +
          SteamArkLog.accountId(accountId));
        return;
      }
      this.statusMessage = this.authResultMessage(result);
      SteamArkLog.debug('AccountsPage', 'scheduled authentication poll completed; state=' +
        String(result.session.state));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_auth_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.warn('AccountsPage', 'scheduled authentication poll failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
        const nextPending = this.findPendingPoll(accountId);
        if (nextPending !== null) {
          this.scheduleAuthPolling(nextPending);
        }
      }
    }
  }

  private findPendingPoll(accountId: string): SteamAuthPendingSnapshot | null {
    const pendingQr = this.pendingQrAuthentication;
    if (pendingQr !== null && pendingQr.session.accountId === accountId &&
      this.isAutoPollableQrAuthentication(pendingQr)) {
      const pending = pendingQr.pendingAuth;
      return pending === null ? null : pending;
    }
    for (let index = 0; index < this.accounts.length; index++) {
      const account = this.accounts[index];
      if (account.profile.accountId !== accountId || !this.isAutoPollableAuthAccount(account)) {
        continue;
      }
      const pending = account.pendingAuth;
      if (pending === null) {
        continue;
      }
      if (pending.challenge === SteamAuthChallengeKind.QR_SCAN ||
        pending.challenge === SteamAuthChallengeKind.MOBILE_CONFIRMATION) {
        return pending;
      }
    }
    return null;
  }

  private clearAuthPolling(): void {
    this.authPollGeneration += 1;
    if (this.authPollTimer >= 0) {
      clearTimeout(this.authPollTimer);
      this.authPollTimer = -1;
      SteamArkLog.debug('AccountsPage', 'authentication polling timer cleared');
    }
    this.authPollAccountId = '';
    this.authPollChallengeIdentity = '';
  }

  private authChallengeIdentity(pending: SteamAuthPendingSnapshot): string {
    return pending.accountId + '|' + pending.clientId + '|' + pending.requestId + '|' +
      String(pending.challenge) + '|' + String(pending.flow) + '|' +
      pending.createdAtEpochSeconds.toString() + '|' + pending.expiresAtEpochSeconds.toString() + '|' +
      pending.challengeUrl;
  }

  private async handleCompleteChallenge(accountId: string): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy() || !this.ensureAuthServiceReady()) {
      return;
    }
    const code = this.challengeCode.trim();
    let pending: SteamAuthPendingSnapshot | null = null;
    for (let index: number = 0; index < this.accounts.length; index++) {
      const account: SteamArkAccountSnapshot = this.accounts[index];
      if (account.profile.accountId === accountId) {
        pending = account.pendingAuth;
        break;
      }
    }
    const pendingQr = this.pendingQrAuthentication;
    if (pending === null && pendingQr !== null && pendingQr.session.accountId === accountId) {
      pending = pendingQr.pendingAuth;
    }
    if (pending === null) {
      this.statusMessage = $r('app.string.steam_accounts_auth_challenge_expired');
      this.challengeCode = '';
      SteamArkLog.warn('AccountsPage', 'auth challenge completion rejected; pending challenge is missing; account=' +
        SteamArkLog.accountId(accountId));
      return;
    }
    const challenge = pending.challenge;
    const requiresEmailCode = challenge === SteamAuthChallengeKind.EMAIL_CODE;
    const requiresTwoFactorCode = challenge === SteamAuthChallengeKind.TWO_FACTOR;
    const scope = this.beginAccountOperation(accountId);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'auth challenge completion started; account=' + SteamArkLog.accountId(accountId) +
      ', codeProvided=' + String(code.length > 0));
    try {
      if (requiresEmailCode && code.length <= 0) {
        this.statusMessage = $r('app.string.steam_accounts_auth_code_required');
        return;
      }
      if (requiresTwoFactorCode && code.length <= 0) {
        let sharedSecretAvailable: boolean = false;
        try {
          sharedSecretAvailable = await steamArkStateService.hasSharedSecret(accountId);
        } catch (error) {
          if (this.isCurrentAccountOperation(scope)) {
            this.statusMessage = $r('app.string.steam_accounts_auth_shared_secret_check_failed');
          }
          SteamArkLog.warn('AccountsPage', 'shared secret capability check failed; account=' +
            SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
          return;
        }
        if (!sharedSecretAvailable) {
          this.statusMessage = $r('app.string.steam_accounts_auth_two_factor_code_required');
          return;
        }
      }
      const result: SteamAuthResult = await steamArkStateService.completeAuthChallenge(accountId, code);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.challengeCode = '';
      if (result.session.state === SteamSessionState.LOGGED_ON) {
        // A completed CM response is authoritative even if Steam echoes the
        // previous guard challenge in its envelope.
        this.clearAuthPolling();
      }
      this.statusMessage = this.authResultMessage(result);
      SteamArkLog.info('AccountsPage', 'auth challenge completion finished; state=' + String(result.session.state));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_auth_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'auth challenge completion failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
      }
    }
  }

  private async handlePollAuthentication(accountId: string): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy() || !this.ensureAuthServiceReady()) {
      return;
    }
    const scope = this.beginAccountOperation(accountId);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'manual authentication poll started; account=' + SteamArkLog.accountId(accountId));
    try {
      const result: SteamAuthResult = await steamArkStateService.pollAuthentication(accountId);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.authResultMessage(result);
      SteamArkLog.info('AccountsPage', 'manual authentication poll finished; state=' + String(result.session.state));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_auth_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'manual authentication poll failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
      }
    }
  }

  private async handleRefreshAuthentication(accountId: string): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy() || !this.ensureAuthServiceReady()) {
      return;
    }
    const scope = this.beginAccountOperation(accountId);
    this.isAuthenticating = true;
    this.statusMessage = $r('app.string.steam_accounts_auth_busy');
    SteamArkLog.info('AccountsPage', 'authentication refresh started; account=' + SteamArkLog.accountId(accountId));
    try {
      const result: SteamAuthResult = await steamArkStateService.refreshAuthentication(accountId);
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.authResultMessage(result);
      SteamArkLog.info('AccountsPage', 'authentication refresh finished; state=' + String(result.session.state));
    } catch (error) {
      if (!this.isCurrentAccountOperation(scope)) {
        return;
      }
      this.statusMessage = this.failureStatus(
        accountId,
        $r('app.string.steam_accounts_auth_failed'),
        error instanceof Error ? error.message : ''
      );
      SteamArkLog.error('AccountsPage', 'authentication refresh failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrentAccountOperation(scope)) {
        this.isAuthenticating = false;
      }
    }
  }

  private authResultMessage(result: SteamAuthResult): ResourceStr {
    if (result.session.state === SteamSessionState.ERROR) {
      const structuredError: string = this.formatAuthenticationFailure(result.session);
      return structuredError.length > 0
        ? structuredError
        : $r('app.string.steam_accounts_auth_failed');
    }
    if (result.session.state === SteamSessionState.EXPIRED) {
      return $r('app.string.steam_accounts_session_expired');
    }
    // The session state is the source of truth after challenge completion.
    // Steam may keep the submitted guard type in the response envelope.
    if (result.session.state === SteamSessionState.LOGGED_ON) {
      return $r('app.string.steam_accounts_auth_success');
    }
    switch (result.challenge) {
      case SteamAuthChallengeKind.QR_SCAN:
        return $r('app.string.steam_accounts_auth_qr_pending');
      case SteamAuthChallengeKind.EMAIL_CODE:
      case SteamAuthChallengeKind.TWO_FACTOR:
        return $r('app.string.steam_accounts_auth_challenge');
      case SteamAuthChallengeKind.MOBILE_CONFIRMATION:
        return $r('app.string.steam_accounts_auth_mobile_pending');
      case SteamAuthChallengeKind.NONE:
      default:
        return $r('app.string.steam_accounts_auth_failed');
    }
  }

  private sessionLabel(state: SteamSessionState): ResourceStr {
    switch (state) {
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

  private async handleImport(kind: number): Promise<void> {
    if (!this.isPageActive || this.isAccountBusy()) {
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const operationGeneration: number = this.beginOperation();
    this.isImporting = true;
    SteamArkLog.info('AccountsPage', 'document import started; kind=' + kind.toString());
    try {
      const document = await ngfMediaPickerFacade.pickDocumentText();
      if (!this.isCurrentOperation(lifecycleGeneration, operationGeneration)) {
        return;
      }
      if (document === null) {
        this.statusMessage = $r('app.string.steam_accounts_import_cancelled');
        SteamArkLog.info('AccountsPage', 'document import cancelled by user');
        return;
      }
      if (kind === SteamArkImportKind.ASF_JSON) {
        const summary: SteamArkImportSummary = await steamArkStateService.importAsfBotJson(
          document.name,
          document.content
        );
        if (!this.isCurrentOperation(lifecycleGeneration, operationGeneration)) {
          return;
        }
        this.statusMessage = summary.account.migrationReport.unknownFields.length > 0
          ? $r('app.string.steam_accounts_import_report_unknown')
          : $r('app.string.steam_accounts_import_success');
        SteamArkLog.info('AccountsPage', 'ASF bot JSON import completed; unknownFields=' +
          summary.account.migrationReport.unknownFields.length.toString());
      } else if (kind === SteamArkImportKind.MAFILE) {
        const summary: SteamArkImportSummary = await steamArkStateService.importMaFile(
          document.name,
          document.content
        );
        if (!this.isCurrentOperation(lifecycleGeneration, operationGeneration)) {
          return;
        }
        this.statusMessage = summary.mergedExistingAccount
          ? $r('app.string.steam_accounts_import_mafile_merged')
          : summary.account.migrationReport.unknownFields.length > 0
          ? $r('app.string.steam_accounts_import_report_unknown')
          : $r('app.string.steam_accounts_import_success');
        SteamArkLog.info('AccountsPage', 'maFile import completed; unknownFields=' +
          summary.account.migrationReport.unknownFields.length.toString());
      } else {
        const summary: SteamArkGlobalImportSummary = await steamArkStateService.importAsfGlobalJson(
          document.name,
          document.content
        );
        if (!this.isCurrentOperation(lifecycleGeneration, operationGeneration)) {
          return;
        }
        this.statusMessage = summary.globalConfig.migrationReport.unknownFields.length > 0
          ? $r('app.string.steam_accounts_import_report_unknown')
          : $r('app.string.steam_accounts_import_success');
        SteamArkLog.info('AccountsPage', 'ASF global JSON import completed; unknownFields=' +
          summary.globalConfig.migrationReport.unknownFields.length.toString());
      }
    } catch (error) {
      if (!this.isCurrentOperation(lifecycleGeneration, operationGeneration)) {
        return;
      }
      if (error instanceof NGFDocumentReadError) {
        // 用户已选中文件但读取失败：不能伪装成“已取消”，必须显示结构化失败。
        this.statusMessage = $r('app.string.steam_accounts_import_read_failed');
        SteamArkLog.error('AccountsPage', 'document import read failed; kind=' + kind.toString() +
          ', errorType=' + SteamArkLog.errorKind(error) + ', detail=' + error.detail);
      } else {
        const detail = this.safeDisplayError(error instanceof Error && error.message.length > 0
          ? error.message
          : '');
        this.statusMessage = detail.length > 0 ? detail : $r('app.string.steam_accounts_import_parse_failed');
        SteamArkLog.error('AccountsPage', 'document import failed; kind=' + kind.toString() +
          ', errorType=' + SteamArkLog.errorKind(error));
      }
    } finally {
      if (this.isCurrentOperation(lifecycleGeneration, operationGeneration)) {
        this.isImporting = false;
      }
    }
  }
}
