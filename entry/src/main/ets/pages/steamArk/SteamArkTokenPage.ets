import { pasteboard } from '@kit.BasicServicesKit';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { NGFHdsTitleBarOptionsFactory, NGFMaterialSurfaceTokens, ngfVisualEffectsFacade } from 'ngf_framework';
import { SteamCredentialSet, SteamSessionState, SteamTotp } from 'steam_core';
import {
  SteamArkAccountSnapshot,
  SteamArkLog,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { steamArkTabScrollers } from './SteamArkTabScrollers';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { HarmonyBinaryCryptoAdapter } from '../../steamAdapters/HarmonyBinaryCryptoAdapter';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';

class SteamArkTokenAccount {
  readonly accountId: string;
  readonly displayName: string;
  readonly avatarUrl: string;
  readonly sessionState: SteamSessionState;
  readonly hasCredentialMaterial: boolean;
  readonly code: string;
  secondsRemaining: number;
  readonly hasAuthenticator: boolean;
  copied: boolean;

  constructor(
    account: SteamArkAccountSnapshot,
    code: string,
    secondsRemaining: number,
    hasAuthenticator: boolean,
    copied: boolean = false
  ) {
    this.accountId = account.profile.accountId;
    this.displayName = account.profile.displayName.length > 0
      ? account.profile.displayName
      : account.profile.accountId;
    this.avatarUrl = account.profile.avatarUrl;
    this.sessionState = account.session.state;
    this.hasCredentialMaterial = account.hasCredentialMaterial;
    this.code = code;
    this.secondsRemaining = secondsRemaining;
    this.hasAuthenticator = hasAuthenticator;
    this.copied = copied;
  }
}

@Component
export struct SteamArkTokenPage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private rows: Array<SteamArkTokenAccount> = [];
  @State private stateReady: boolean = false;
  @State private loading: boolean = false;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private readonly scroller: Scroller = steamArkTabScrollers.tokens;
  private isPageActive: boolean = false;
  private generation: number = 0;
  private refreshGeneration: number = 0;
  private tokenTimer: number = -1;
  private readonly crypto: HarmonyBinaryCryptoAdapter = new HarmonyBinaryCryptoAdapter();
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    this.stateReady = snapshot.initialized;
    void this.refreshAccounts(snapshot);
    this.scheduleTokenTick();
  };

  aboutToAppear(): void {
    this.isPageActive = true;
    this.generation += 1;
    const currentGeneration: number = this.generation;
    if (this.embedded) {
      this.topInsetVp = this.contentTopInsetVp;
    } else {
      SteamArkPageWindowSupport.loadDynamicTopInset(
        this.getUIContext(),
        108,
        SteamArkTheme.CONTENT_TOP_INSET,
        (inset: number): void => {
          if (this.isPageActive && this.generation === currentGeneration) {
            this.topInsetVp = inset;
          }
        }
      );
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.TOKENS);
    }
    steamArkStateService.subscribe('SteamArkTokenPage', this.stateListener);
    const snapshot: SteamArkStateSnapshot = steamArkStateService.getSnapshot();
    this.stateReady = snapshot.initialized;
    void this.refreshAccounts(snapshot);
    this.scheduleTokenTick();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.generation += 1;
    this.refreshGeneration += 1;
    if (this.tokenTimer >= 0) {
      clearTimeout(this.tokenTimer);
      this.tokenTimer = -1;
    }
    steamArkStateService.unsubscribe('SteamArkTokenPage');
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
          $r('app.string.steam_token_title'),
          $r('app.string.steam_token_subtitle'),
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
            SteamArkStateUnavailableCard({ isDarkMode: this.isDarkMode, useSysMat: this.useSysMat });
          } else if (this.loading && this.rows.length === 0) {
            this.buildMessage($r('app.string.steam_token_loading'));
          } else if (this.rows.length === 0) {
            this.buildMessage($r('app.string.steam_token_no_accounts'));
          } else {
            ForEach(this.rows, (row: SteamArkTokenAccount) => {
              this.buildAccountCard(row);
            }, (row: SteamArkTokenAccount) => row.accountId);
          }
          Button() {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16);
              Text($r('app.string.steam_token_refresh'));
            }
          }
            .width('100%')
            .height(44)
            .enabled(!this.loading)
            .onClick((): void => {
              void this.refreshAccounts(steamArkStateService.getSnapshot());
            });
        }
          .width('100%')
          .padding({ left: 16, right: 16, top: this.embedded ? this.contentTopInsetVp : this.topInsetVp, bottom: this.embedded ? 84 : 92 });
      }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
      .width('100%')
      .height('100%')
      .backgroundColor(this.embedded
        ? $r('app.color.background_transparent') : SteamArkTheme.background(this.isDarkMode))
      .opacity(this.stateReady && !this.loading ? 1 : 0.9)
      .animation({ duration: SteamArkExperiencePolicy.CONTENT_REFRESH_DURATION, curve: Curve.EaseOut });
  }

  @Builder
  private buildMessage(message: ResourceStr): void {
    Text(message)
      .width('100%')
      .padding(20)
      .fontSize(14)
      .textAlign(TextAlign.Center)
      .fontColor(SteamArkTheme.textSecondary(this.isDarkMode));
  }

  @Builder
  private buildAccountCard(row: SteamArkTokenAccount): void {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        if (row.avatarUrl.length > 0) {
          Image(row.avatarUrl).width(52).height(52).borderRadius(12).objectFit(ImageFit.Cover);
        } else {
          SymbolGlyph($r('sys.symbol.person_crop_circle_fill')).fontSize(42).fontColor([SteamArkTheme.accent(this.isDarkMode)]);
        }
        Column({ space: 3 }) {
          Text(row.displayName).fontSize(16).fontWeight(FontWeight.Medium).fontColor(SteamArkTheme.textPrimary(this.isDarkMode));
          Text(row.accountId).fontSize(12).fontColor(SteamArkTheme.textSecondary(this.isDarkMode));
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      }.width('100%');
      if (row.hasAuthenticator && row.code.length > 0) {
        Row({ space: 12 }) {
          Text(row.code)
            .layoutWeight(1)
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
            .letterSpacing(4)
          Button() {
            SymbolGlyph($r('sys.symbol.doc_plaintext_and_checkmark')).fontSize(20)
          }
            .width(46)
            .height(46)
            .borderRadius(12)
            .backgroundColor(SteamArkTheme.surfaceControl(this.isDarkMode))
            .accessibilityText($r('app.string.steam_token_copy'))
            .onClick((): void => {
              void this.copyToken(row.accountId, row.code);
            })
        }.width('100%').alignItems(VerticalAlign.Center);
        Row({ space: 8 }) {
          Text($r('app.string.steam_token_expires_in'))
            .fontSize(13)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          Text(String(row.secondsRemaining) + 's')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          if (row.copied) {
            Text($r('app.string.steam_token_copied'))
              .fontSize(13)
              .fontColor(SteamArkTheme.success(this.isDarkMode));
          }
        }.width('100%');
      } else {
        Column({ space: 6 }) {
          Text($r('app.string.steam_token_authenticator_missing'))
            .width('100%')
            .fontSize(14)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode));
          Text($r('app.string.steam_token_authenticator_help'))
            .width('100%')
            .fontSize(12)
            .lineHeight(18)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode));
          this.buildAuthenticatorHelpRow(
            $r('app.string.steam_token_authenticator_existing_title'),
            $r('app.string.steam_token_authenticator_existing_desc')
          )
          this.buildAuthenticatorHelpRow(
            $r('app.string.steam_token_authenticator_backup_title'),
            $r('app.string.steam_token_authenticator_backup_desc')
          )
          this.buildAuthenticatorHelpRow(
            $r('app.string.steam_token_authenticator_new_title'),
            $r('app.string.steam_token_authenticator_new_desc')
          )
        }.width('100%').alignItems(HorizontalAlign.Start);
      }
    }
      .width('100%')
      .padding(16)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
      .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
      .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel());
  }

  @Builder
  private buildAuthenticatorHelpRow(title: ResourceStr, description: ResourceStr): void {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(14)
        .fontColor([SteamArkTheme.accent(this.isDarkMode)])
      Column({ space: 2 }) {
        Text(title)
          .width('100%')
          .fontSize(12)
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
    .padding({ top: 4 })
    .alignItems(VerticalAlign.Top)
  }

  private async refreshAccounts(snapshot: SteamArkStateSnapshot): Promise<void> {
    if (!this.isPageActive || !snapshot.initialized) {
      return;
    }
    this.loading = true;
    this.refreshGeneration += 1;
    const currentRefresh: number = this.refreshGeneration;
    const nextRows: Array<SteamArkTokenAccount> = [];
    try {
      for (let index: number = 0; index < snapshot.accounts.length; index++) {
        const account: SteamArkAccountSnapshot = snapshot.accounts[index];
        try {
          const credentials: SteamCredentialSet = await steamArkStateService.getCredentials(account.profile.accountId);
          const sharedSecret: string = credentials.sharedSecret.trim();
          let code: string = '';
          if (sharedSecret.length > 0) {
            code = await SteamTotp.generateForTime(sharedSecret, Math.floor(Date.now() / 1000), this.crypto);
          }
          nextRows.push(new SteamArkTokenAccount(
            account,
            code,
            this.secondsRemaining(),
            sharedSecret.length > 0
          ));
        } catch (error) {
          SteamArkLog.warn('TokenPage', 'credential refresh skipped one account; account=' +
            SteamArkLog.accountId(account.profile.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
          nextRows.push(new SteamArkTokenAccount(account, '', this.secondsRemaining(), false));
        }
      }
      if (this.isPageActive && currentRefresh === this.refreshGeneration) {
        this.rows = nextRows;
      }
    } catch (error) {
      SteamArkLog.warn('TokenPage', 'secure credential refresh failed; errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isPageActive && currentRefresh === this.refreshGeneration) {
        this.loading = false;
      }
    }
  }

  private scheduleTokenTick(): void {
    if (!this.isPageActive) {
      return;
    }
    if (this.tokenTimer >= 0) {
      clearTimeout(this.tokenTimer);
      this.tokenTimer = -1;
    }
    const timerGeneration: number = this.generation;
    this.tokenTimer = setTimeout((): void => {
      if (!this.isPageActive || this.generation !== timerGeneration) {
        return;
      }
      if (this.secondsRemaining() <= 1) {
        void this.refreshAccounts(steamArkStateService.getSnapshot());
      } else {
        for (let index = 0; index < this.rows.length; index++) {
          const row = this.rows[index];
          row.secondsRemaining = this.secondsRemaining();
        }
        this.rows = this.rows.slice();
      }
      this.tokenTimer = -1;
      if (this.isPageActive && this.generation === timerGeneration) {
        this.scheduleTokenTick();
      }
    }, 1000);
  }

  private secondsRemaining(): number {
    const now: number = Math.floor(Date.now() / 1000);
    const remainder: number = now % 30;
    return remainder === 0 ? 30 : 30 - remainder;
  }

  private async copyToken(accountId: string, code: string): Promise<void> {
    if (code.length <= 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, code);
      await pasteboard.getSystemPasteboard().setData(data);
      for (let index = 0; index < this.rows.length; index++) {
        const row = this.rows[index];
        if (row.accountId === accountId) {
          row.copied = true;
        }
      }
      this.rows = this.rows.slice();
    } catch (error) {
      SteamArkLog.warn('TokenPage', 'Steam Guard code copy failed; errorType=' + SteamArkLog.errorKind(error));
    }
  }

}
