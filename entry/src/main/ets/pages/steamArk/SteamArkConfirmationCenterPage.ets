import { HdsNavDestination } from '@kit.UIDesignKit';
import { NGFControlStyleTokens, NGFHdsTitleBarOptionsFactory, NGFMaterialSurfaceTokens, ngfVisualEffectsFacade } from 'ngf_framework';
import { SteamConfirmationEntry, SteamConfirmationKind, SteamSessionState } from 'steam_core';
import {
  SteamArkConfirmationSnapshot,
  SteamArkConfirmationState,
  steamArkConfirmationService,
  SteamArkLog,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkStateUnavailableCard } from './SteamArkStateUnavailableCard';
import { SteamArkBrowserRequest, SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';

/**
 * Read-only Steam confirmation center: trades, market listings and login
 * approvals are listed for review. Accepting or rejecting stays in the
 * logged-in Steam browser handoff (M5 capability gate).
 */
@Component
export struct SteamArkConfirmationCenterPage {
  @Prop embedded: boolean = false;
  @Prop contentTopInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private topInsetVp: number = SteamArkTheme.CONTENT_TOP_INSET;
  @State private snapshot: SteamArkConfirmationSnapshot = new SteamArkConfirmationSnapshot();
  @State private loading: boolean = false;
  @State private stateReady: boolean = false;
  @State private selectedAccountId: string = '';
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private isPageActive: boolean = false;
  private generation: number = 0;
  private fetchGeneration: number = 0;
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (!this.isPageActive) {
      return;
    }
    this.stateReady = snapshot.initialized;
    this.selectedAccountId = snapshot.selectedAccountId;
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
      SteamArkPageWindowSupport.apply(SteamArkPageWindowName.SETTINGS);
    }
    steamArkStateService.subscribe('SteamArkConfirmationPage', this.stateListener);
    const snapshot: SteamArkStateSnapshot = steamArkStateService.getSnapshot();
    this.stateReady = snapshot.initialized;
    this.selectedAccountId = snapshot.selectedAccountId;
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.generation += 1;
    this.fetchGeneration += 1;
    steamArkStateService.unsubscribe('SteamArkConfirmationPage');
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
          $r('app.string.steam_confirmation_title'),
          $r('app.string.steam_confirmation_subtitle'),
          $r('app.color.background_transparent'),
          SteamArkTheme.textPrimary(this.isDarkMode),
          SteamArkTheme.textSecondary(this.isDarkMode),
          true,
          false
        ))
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
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
    Column() {
      if (!this.stateReady || this.selectedAccountId.length <= 0) {
        SteamArkStateUnavailableCard({
          isDarkMode: this.isDarkMode,
          useSysMat: this.useSysMat
        })
      } else {
        Scroll() {
          Column({ space: 12 }) {
            this.buildHeaderCard()
            if (this.loading) {
              LoadingProgress()
                .width(28)
                .height(28)
                .color(SteamArkTheme.accent(this.isDarkMode))
            } else if (this.snapshot.state === SteamArkConfirmationState.ERROR ||
              this.snapshot.state === SteamArkConfirmationState.UNAVAILABLE) {
              Text(this.snapshot.errorMessage)
                .width('100%')
                .fontSize(12)
                .fontColor(SteamArkTheme.error(this.isDarkMode))
            } else if (this.snapshot.entries.length <= 0) {
              Text($r('app.string.steam_confirmation_empty'))
                .width('100%')
                .fontSize(12)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            } else {
              this.buildEntries()
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: this.topInsetVp, bottom: 24 })
        }
        .scrollBar(BarState.Auto)
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private buildHeaderCard(): void {
    Column({ space: 10 }) {
      Text($r('app.string.steam_confirmation_notice'))
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontColor(SteamArkTheme.warning(this.isDarkMode))
      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(16)
            .fontColor([SteamArkTheme.buttonForeground(this.isDarkMode)])
          Text($r('app.string.steam_confirmation_refresh'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .fontColor(SteamArkTheme.buttonForeground(this.isDarkMode))
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
      .padding(0)
      .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
      .backgroundColor(this.canFetch() ? SteamArkTheme.accent(this.isDarkMode)
        : SteamArkTheme.buttonDisabled(this.isDarkMode))
      .enabled(this.canFetch())
      .id('steam-ark-confirmation-refresh')
      .onClick((): void => {
        this.refresh();
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildEntries(): void {
    Column({ space: 8 }) {
      ForEach(this.snapshot.entries, (entry: SteamConfirmationEntry) => {
        Row({ space: 12 }) {
          SymbolGlyph(this.kindSymbol(entry.kind))
            .fontSize(20)
            .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
          Column({ space: 3 }) {
            Text(entry.title.length > 0 ? entry.title : $r('app.string.steam_confirmation_kind_unknown'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.kindLabel(entry.kind))
              .fontSize(11)
              .fontColor(SteamArkTheme.accentCyan(this.isDarkMode))
            if (entry.summary.length > 0) {
              Text(entry.summary)
                .fontSize(12)
                .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (entry.createdTimeText.length > 0) {
              Text(entry.createdTimeText)
                .fontSize(11)
                .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button($r('app.string.steam_confirmation_open'))
            .fontSize(NGFControlStyleTokens.DENSE_BUTTON_FONT_SIZE)
            .height(NGFControlStyleTokens.DENSE_BUTTON_HEIGHT)
            .padding({ left: 12, right: 12 })
            .backgroundColor(this.canOpen(entry) ? SteamArkTheme.accent(this.isDarkMode)
              : SteamArkTheme.buttonDisabled(this.isDarkMode))
            .enabled(this.canOpen(entry))
            .id('steam-ark-confirmation-open-' + entry.confirmationId)
            .onClick((): void => {
              this.openConfirmation(entry);
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
        .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
      }, (entry: SteamConfirmationEntry) => entry.confirmationId + '|' + entry.nonce)
    }
    .width('100%')
  }

  private canFetch(): boolean {
    return !this.loading && this.selectedAccountId.length > 0;
  }

  private canOpen(entry: SteamConfirmationEntry): boolean {
    return entry.kind === SteamConfirmationKind.TRADE && entry.creatorId.length > 0 &&
      entry.creatorId !== '0';
  }

  private kindSymbol(kind: SteamConfirmationKind): Resource {
    if (kind === SteamConfirmationKind.TRADE) {
      return $r('sys.symbol.arrow_left_arrow_right');
    }
    if (kind === SteamConfirmationKind.MARKET) {
      return $r('sys.symbol.list_bullet');
    }
    if (kind === SteamConfirmationKind.LOGIN) {
      return $r('sys.symbol.lock_shield');
    }
    return $r('sys.symbol.bell');
  }

  private kindLabel(kind: SteamConfirmationKind): ResourceStr {
    if (kind === SteamConfirmationKind.TRADE) {
      return $r('app.string.steam_confirmation_kind_trade');
    }
    if (kind === SteamConfirmationKind.MARKET) {
      return $r('app.string.steam_confirmation_kind_market');
    }
    if (kind === SteamConfirmationKind.LOGIN) {
      return $r('app.string.steam_confirmation_kind_login');
    }
    return $r('app.string.steam_confirmation_kind_unknown');
  }

  private refresh(): void {
    if (!this.canFetch()) {
      return;
    }
    const account = steamArkStateService.getSelectedAccount();
    if (account === null || account.session.state !== SteamSessionState.LOGGED_ON) {
      return;
    }
    this.fetchGeneration += 1;
    const fetchGeneration: number = this.fetchGeneration;
    this.loading = true;
    void steamArkConfirmationService.fetch(this.selectedAccountId)
      .then((snapshot: SteamArkConfirmationSnapshot): void => {
        if (!this.isPageActive || this.fetchGeneration !== fetchGeneration) {
          return;
        }
        this.snapshot = snapshot;
        this.loading = false;
      })
      .catch((): void => {
        if (this.isPageActive && this.fetchGeneration === fetchGeneration) {
          this.loading = false;
        }
      });
  }

  /** Only trade confirmations deep-link to the trade page; others stay informational. */
  private openConfirmation(entry: SteamConfirmationEntry): void {
    if (!this.canOpen(entry)) {
      return;
    }
    const url: string = 'https://steamcommunity.com/tradeoffer/' + entry.creatorId + '/';
    SteamArkLog.debug('ConfirmationPage', 'confirmation opened in browser; conf=' +
      SteamArkLog.opaqueId(entry.confirmationId));
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(url, entry.title, 'steamcommunity.com'));
  }
}
