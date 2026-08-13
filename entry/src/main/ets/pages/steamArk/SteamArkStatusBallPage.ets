import {
  NGFMaterialSurfaceTokens,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import { SteamSessionState } from 'steam_core';
import {
  SteamArkSocialConnectionState,
  SteamArkChatSession,
  SteamArkSocialSnapshot,
  SteamArkSocialSnapshotListener,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkSocialService,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { steamArkFloatingWindowCoordinator } from './SteamArkFloatingWindowCoordinator';

@Entry
@Component
struct SteamArkStatusBallPage {
  @State private accountId: string = '';
  @State private sessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  @State private socialState: SteamArkSocialConnectionState = SteamArkSocialConnectionState.DISCONNECTED;
  @State private unreadCount: number = 0;
  @State private unreadKnown: boolean = false;
  @State private unreadFriendSteamId64: string = '';
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private subscribedAccountId: string = '';
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    this.applyState(snapshot);
  };
  private readonly socialListener: SteamArkSocialSnapshotListener = (snapshot: SteamArkSocialSnapshot): void => {
    this.applySocial(snapshot);
  };

  aboutToAppear(): void {
    steamArkStateService.subscribe('SteamArkStatusBallPage', this.stateListener);
    this.applyState(steamArkStateService.getSnapshot());
    void steamArkStateService.initialize();
  }

  aboutToDisappear(): void {
    steamArkStateService.unsubscribe('SteamArkStatusBallPage');
    this.unsubscribeSocial();
  }

  build(): void {
    Stack({ alignContent: Alignment.Center }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Stack({ alignContent: Alignment.Center }) {
          if (this.isBusy()) {
            LoadingProgress()
              .width(48)
              .height(48)
              .color(SteamArkTheme.accentCyan(this.isDarkMode))
          }
          SymbolGlyph(this.statusSymbol())
            .fontSize(24)
            .fontColor([this.statusColor()])
          if (this.unreadCount > 0) {
            Text(this.unreadLabel())
              .fontSize(9)
              .fontWeight(FontWeight.Bold)
              .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
              .width(20)
              .height(20)
              .textAlign(TextAlign.Center)
              .backgroundColor(SteamArkTheme.error(this.isDarkMode))
              .borderRadius(10)
              .position({ x: 37, y: 1 })
          }
        }
        .width(58)
        .height(58)
      }
      .width(64)
      .height(64)
      .padding(0)
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
      .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
      .border({
        width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
        color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
          SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
      })
      .shadow(NGFMaterialSurfaceTokens.buildMaterialAwareProminentShadow(this.useSysMat))
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
      .accessibilityText($r('app.string.steam_status_ball_open_friends'))
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          steamArkFloatingWindowCoordinator.startStatusBallDrag();
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          steamArkFloatingWindowCoordinator.finishStatusBallDrag();
        }
      })
      .onClick((): void => {
        if (this.unreadFriendSteamId64.length > 0) {
          void steamArkFloatingWindowCoordinator.openChat(this.accountId, this.unreadFriendSteamId64);
        } else {
          void steamArkFloatingWindowCoordinator.openFriends(this.accountId);
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  private applyState(snapshot: SteamArkStateSnapshot): void {
    const selected = steamArkStateService.getSelectedAccount();
    if (snapshot.selectedAccountId !== this.accountId) {
      this.unreadFriendSteamId64 = '';
      this.unreadCount = 0;
      this.unreadKnown = false;
      this.socialState = SteamArkSocialConnectionState.DISCONNECTED;
    }
    this.accountId = snapshot.selectedAccountId;
    this.sessionState = selected === null ? SteamSessionState.DISCONNECTED : selected.session.state;
    if (this.subscribedAccountId !== this.accountId) {
      this.unsubscribeSocial();
      if (this.accountId.length > 0) {
        this.subscribedAccountId = this.accountId;
        steamArkSocialService.subscribe('SteamArkStatusBallPage', this.socialListener);
        this.applySocial(steamArkSocialService.restore(this.accountId));
      }
    }
  }

  private applySocial(snapshot: SteamArkSocialSnapshot): void {
    if (snapshot.accountId !== this.accountId) {
      return;
    }
    this.socialState = snapshot.state;
    this.unreadKnown = snapshot.updatedAtEpochSeconds > 0;
    if (!this.unreadKnown) {
      this.unreadCount = 0;
      this.unreadFriendSteamId64 = '';
      return;
    }
    let unread: number = 0;
    let newestUnread: SteamArkChatSession | null = null;
    for (let index: number = 0; index < snapshot.sessions.length; index++) {
      const session: SteamArkChatSession = snapshot.sessions[index];
      unread += session.unreadCount;
      if (session.unreadCount > 0 && (newestUnread === null ||
        session.lastMessageEpochSeconds > newestUnread.lastMessageEpochSeconds)) {
        newestUnread = session;
      }
    }
    this.unreadCount = unread;
    this.unreadFriendSteamId64 = newestUnread === null ? '' : newestUnread.friendSteamId64;
  }

  private unsubscribeSocial(): void {
    if (this.subscribedAccountId.length > 0) {
      steamArkSocialService.unsubscribe('SteamArkStatusBallPage');
      this.subscribedAccountId = '';
    }
  }

  private isBusy(): boolean {
    return this.sessionState === SteamSessionState.CONNECTING ||
      this.sessionState === SteamSessionState.RECONNECTING ||
      this.socialState === SteamArkSocialConnectionState.CONNECTING;
  }

  private statusSymbol(): Resource {
    if (this.unreadKnown && this.unreadCount > 0) {
      return $r('sys.symbol.message_fill');
    }
    if (!this.unreadKnown) {
      return $r('sys.symbol.arrow_clockwise');
    }
    if (this.sessionState === SteamSessionState.LOGGED_ON) {
      return $r('sys.symbol.person_2_fill');
    }
    return $r('sys.symbol.arrow_clockwise');
  }

  private statusColor(): ResourceColor {
    if (!this.unreadKnown) {
      return SteamArkTheme.warning(this.isDarkMode);
    }
    return this.sessionState === SteamSessionState.LOGGED_ON
      ? SteamArkTheme.accentCyan(this.isDarkMode)
      : SteamArkTheme.warning(this.isDarkMode);
  }

  private unreadLabel(): string {
    return this.unreadCount > 99 ? '99+' : this.unreadCount.toString();
  }
}
