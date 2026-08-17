import { curves, display, window } from '@kit.ArkUI';
import { NGFMaterialSurfaceTokens, ngfVisualEffectsFacade } from 'ngf_framework';
import {
  SteamArkFriendProfile,
  SteamArkChatSession,
  SteamArkLog,
  SteamArkSocialConnectionState,
  SteamArkSocialSnapshot,
  SteamArkSocialSnapshotListener,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkSocialService,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';
import {
  STEAM_ARK_FLOAT_ACCOUNT_KEY,
  STEAM_ARK_FRIENDS_ANCHOR_X_PX,
  STEAM_ARK_FRIENDS_ANCHOR_Y_PX,
  STEAM_ARK_FRIENDS_WINDOW_NAME,
  steamArkFloatingWindowCoordinator
} from './SteamArkFloatingWindowCoordinator';

class SteamArkFriendGameGroup {
  readonly key: string;
  readonly gameName: string;
  readonly gameAppId: string;
  readonly friends: Array<SteamArkFriendProfile>;

  constructor(key: string, gameName: string, gameAppId: string, friends: Array<SteamArkFriendProfile>) {
    this.key = key;
    this.gameName = gameName;
    this.gameAppId = gameAppId;
    this.friends = friends;
  }
}

@Entry
@Component
struct SteamArkFriendsFloatingPage {
  @State private accountId: string = '';
  @State private friends: Array<SteamArkFriendProfile> = [];
  @State private sessions: Array<SteamArkChatSession> = [];
  @State private searchText: string = '';
  @State private connectionState: SteamArkSocialConnectionState = SteamArkSocialConnectionState.DISCONNECTED;
  @State private unreadCount: number = 0;
  @State private loading: boolean = true;
  @State private contentVisible: boolean = false;
  @State private gameExpanded: boolean = true;
  @State private onlineExpanded: boolean = true;
  @State private offlineExpanded: boolean = false;
  @State private expandedGameKeys: Array<string> = [];
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  /** Capsule anchor offset (vp): the panel's bottom-center starts/ends here. */
  private anchorDeltaX: number = 0;
  private anchorDeltaY: number = 140;
  private refreshTimer: number = -1;
  private closeTimer: number = -1;
  private isPageActive: boolean = false;
  private accountGeneration: number = 0;
  private readonly socialListener: SteamArkSocialSnapshotListener = (snapshot: SteamArkSocialSnapshot): void => {
    this.applySnapshot(snapshot);
  };
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (this.isPageActive && snapshot.selectedAccountId !== this.accountId) {
      this.closeForAccountChange();
    }
  };

  aboutToAppear(): void {
    this.isPageActive = true;
    this.contentVisible = false;
    this.accountId = AppStorage.get<string>(STEAM_ARK_FLOAT_ACCOUNT_KEY) ?? '';
    if (this.accountId.length <= 0) {
      const selected = steamArkStateService.getSelectedAccount();
      this.accountId = selected === null ? '' : selected.profile.accountId;
    }
    steamArkSocialService.subscribe('SteamArkFriendsFloatingPage', this.socialListener);
    steamArkStateService.subscribe('SteamArkFriendsFloatingPage', this.stateListener);
    steamArkFloatingWindowCoordinator.setFriendsPresentHandler((): boolean => {
      return this.playCapsulePop();
    });
    steamArkFloatingWindowCoordinator.setFriendsCollapseHandler((): Promise<void> => {
      return this.playCapsuleCollapse();
    });
    this.applySnapshot(steamArkSocialService.restore(this.accountId));
    this.syncCurrentAccount();
    this.scheduleSilentRefresh();
  }

  /**
   * Capsule pop-in: recompute the anchor, then spring out of the capsule.
   * Returns true when the pop actually played (or is already showing) so the
   * coordinator can retry while the first page load is still settling.
   */
  private playCapsulePop(): boolean {
    if (!this.isPageActive) {
      return false;
    }
    if (this.contentVisible) {
      return true;
    }
    this.prepareCapsuleAnchor();
    try {
      this.getUIContext().animateTo({
        curve: curves.springMotion(0.38, 0.86)
      }, (): void => {
        this.contentVisible = true;
      });
    } catch (_error) {
      // Some form factors reject springMotion at runtime — fall back to a
      // plain curve so the panel never stays hidden behind a dead handler.
      this.getUIContext().animateTo({
        duration: SteamArkExperiencePolicy.FRIENDS_CAPSULE_POP_DURATION,
        curve: Curve.FastOutSlowIn
      }, (): void => {
        this.contentVisible = true;
      });
    }
    return true;
  }

  /** Capsule collapse: shrink back into the capsule, resolving when done. */
  private playCapsuleCollapse(): Promise<void> {
    if (!this.isPageActive || !this.contentVisible) {
      return Promise.resolve();
    }
    this.prepareCapsuleAnchor();
    return new Promise<void>((resolve: () => void): void => {
      this.getUIContext().animateTo({
        duration: SteamArkExperiencePolicy.FRIENDS_CAPSULE_POP_DURATION,
        curve: curves.cubicBezierCurve(0.3, 0, 0.15, 1),
        onFinish: (): void => {
          resolve();
        }
      }, (): void => {
        this.contentVisible = false;
      });
    });
  }

  /**
   * Capsule pop anchor: converts the main-window capsule's screen position
   * into this window's local coordinates, so the entrance/collapse transform
   * grows out of and shrinks back into exactly the capsule on screen.
   */
  private prepareCapsuleAnchor(): void {
    try {
      const target: window.Window = window.findWindow(STEAM_ARK_FRIENDS_WINDOW_NAME);
      const rect = target.getWindowProperties().windowRect;
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const anchorX: number = AppStorage.get<number>(STEAM_ARK_FRIENDS_ANCHOR_X_PX) ?? -1;
      const anchorY: number = AppStorage.get<number>(STEAM_ARK_FRIENDS_ANCHOR_Y_PX) ?? -1;
      if (density <= 0 || rect.width <= 0 || rect.height <= 0 || anchorX <= 0 || anchorY <= 0) {
        return;
      }
      const localXVp: number = (anchorX - rect.left) / density;
      const localYVp: number = (anchorY - rect.top) / density;
      const widthVp: number = rect.width / density;
      const heightVp: number = rect.height / density;
      // The panel's resting bottom-center (content padding 12) is the point
      // that must sit on the capsule at the animation extremes.
      this.anchorDeltaX = localXVp - widthVp / 2;
      this.anchorDeltaY = localYVp - (heightVp - 12);
    } catch (error) {
      SteamArkLog.debug('FriendsFloatingPage', 'capsule anchor fallback applied');
    }
  }

  /** Coordinator asked the window to close: collapse back into the capsule. */
  aboutToDisappear(): void {
    this.isPageActive = false;
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    steamArkSocialService.unsubscribe('SteamArkFriendsFloatingPage');
    steamArkStateService.unsubscribe('SteamArkFriendsFloatingPage');
    steamArkFloatingWindowCoordinator.setFriendsPresentHandler(null);
    steamArkFloatingWindowCoordinator.setFriendsCollapseHandler(null);
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
  }

  build(): void {
    // Transparent hit-test wrapper: the sub-window surface stays mounted
    // during the system show/hide transition (~1-2s on some devices); making
    // the empty root pass touches through removes the invisible "shell"
    // phase entirely, while the panel below keeps normal touch behavior.
    Column() {
      Column() {
        this.buildDragHandle()
      this.buildHeader()
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(17)
          .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
        TextInput({ text: this.searchText, placeholder: $r('app.string.steam_float_friends_search') })
          .layoutWeight(1)
          .height(42)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
          .backgroundColor(Color.Transparent)
          .onChange((value: string): void => {
            this.searchText = value;
            if (value.trim().length > 0) {
              this.gameExpanded = true;
              this.onlineExpanded = true;
              this.offlineExpanded = true;
              this.expandVisibleGameGroups();
            }
          })
        if (this.searchText.length > 0) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(14)
              .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
          }
          .width(32)
          .height(32)
          .padding(0)
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .accessibilityText($r('app.string.steam_float_close'))
          .onClick((): void => {
            this.searchText = '';
          })
        }
      }
      .width('100%')
      .height(48)
      .padding({ left: 12, right: 12 })
      .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
        SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
      .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
      .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
      .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
      .margin({ bottom: 8 })

      if (this.loading && this.friends.length <= 0) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color(SteamArkTheme.accent(this.isDarkMode))
          Text($r('app.string.steam_float_friends_loading'))
            .fontSize(13)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.visibleFriends().length <= 0) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.person_2'))
            .fontSize(34)
            .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
          Text($r('app.string.steam_float_friends_empty'))
            .fontSize(13)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 8 }) {
            this.buildGameSection()
            this.buildFriendSection(1)
            this.buildFriendSection(2)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .height(0)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PROMINENT_RADIUS)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .shadow(NGFMaterialSurfaceTokens.buildMaterialAwareProminentShadow(this.useSysMat))
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
    .clip(true)
    // Visibility (not opacity): material blur layers keep rendering at
    // opacity 0, which was the visible "transparent shell". Hidden removes
    // the whole paint incl. backgroundEffect/systemMaterial.
    .visibility(this.contentVisible ? Visibility.Visible : Visibility.Hidden)
    .scale({
      x: this.contentVisible ? 1 : 0.05,
      y: this.contentVisible ? 1 : 0.05,
      centerX: '50%',
      centerY: '100%'
    })
    .translate({
      x: this.contentVisible ? 0 : this.anchorDeltaX,
      y: this.contentVisible ? 0 : this.anchorDeltaY
    })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  private buildDragHandle(): void {
    Row() {
      Column() {}
        .width(44)
        .height(5)
        .borderRadius(3)
        .backgroundColor(SteamArkTheme.textMuted(this.isDarkMode))
        .opacity(0.72)
    }
    .width('100%')
    .height(22)
    .justifyContent(FlexAlign.Center)
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        steamArkFloatingWindowCoordinator.startFriendsDrag();
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        steamArkFloatingWindowCoordinator.finishFriendsDrag();
      }
    })
  }

  @Builder
  private buildHeader(): void {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text($r('app.string.steam_float_friends_title'))
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text(this.headerSubtitle())
          .fontSize(11)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.unreadCount > 0) {
        Text(this.unreadCount > 99 ? '99+' : this.unreadCount.toString())
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(SteamArkTheme.error(this.isDarkMode))
          .borderRadius(12)
          .onClick((): void => {
            this.openNewestUnreadChat();
          })
      }
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
      }
      .width(40)
      .height(40)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .accessibilityText($r('app.string.steam_float_close'))
      .onClick((): void => {
        this.closeWithAnimation();
      })
    }
    .width('100%')
    .height(60)
  }

  @Builder
  private buildFriend(friend: SteamArkFriendProfile, indent: number = 0): void {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (friend.avatarUrl.length > 0) {
          Image(friend.avatarUrl)
            .width(48)
            .height(48)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
        } else {
          SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
            .fontSize(42)
            .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
        }
        Column() {}
          .width(11)
          .height(11)
          .borderRadius(6)
          .backgroundColor(friend.personaState > 0
            ? SteamArkTheme.success(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode))
          .border({ width: 2, color: SteamArkTheme.surfaceElevated(this.isDarkMode) })
      }
      .width(50)
      .height(50)
      if (friend.gameAppId.length > 0) {
        Image(this.gameLogoUrl(friend.gameAppId))
          .width(44)
          .height(28)
          .objectFit(ImageFit.Cover)
          .borderRadius(4)
      }
      Column({ space: 3 }) {
        Text(friend.displayName.length > 0 ? friend.displayName : friend.steamId64)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .maxLines(1)
        Text(friend.gameName.length > 0 ? friend.gameName : this.personaText(friend.personaState))
          .fontSize(11)
          .fontColor(friend.personaState > 0
            ? SteamArkTheme.success(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.message'))
        .fontSize(19)
        .fontColor([SteamArkTheme.accent(this.isDarkMode)])
    }
    .width('100%')
    .height(68)
    .margin({ left: indent })
    .padding({ left: 8, right: 8 })
    .onClick((): void => {
      void steamArkFloatingWindowCoordinator.openChat(this.accountId, friend.steamId64);
    })
  }

  @Builder
  /**
   * Section builders read the @State filters/expansion DIRECTLY in their
   * bodies: @Builder parameters passed by value never re-render on state
   * changes (official ArkUI rule), which had broken both the section
   * expand/collapse and the search filtering.
   */
  @Builder
  private buildGameSection(): void {
    if (this.gameGroups().length > 0) {
      this.buildSectionHeader(
        $r('app.string.steam_float_friends_in_game'),
        $r('sys.symbol.gamecontroller_fill'),
        0
      )
      if (this.gameExpanded) {
        ForEach(this.gameGroups(), (group: SteamArkFriendGameGroup): void => {
          this.buildGameGroup(group)
        }, (group: SteamArkFriendGameGroup): string => group.key)
      }
    }
  }

  @Builder
  private buildGameGroup(group: SteamArkFriendGameGroup): void {
    Button() {
      Row({ space: 8 }) {
        SymbolGlyph(this.isGameExpanded(group.key)
          ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
        if (group.gameAppId.length > 0) {
          Image(this.gameLogoUrl(group.gameAppId))
            .width(52)
            .height(20)
            .objectFit(ImageFit.Cover)
            .borderRadius(3)
        }
        Text(group.gameName)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .maxLines(1)
        Text(group.friends.length.toString())
          .fontSize(11)
          .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        Blank()
      }
      .width('100%')
      .height(34)
      .padding({ left: 26, right: 8 })
    }
    .width('100%')
    .height(34)
    .padding(0)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
    .onClick((): void => {
      this.toggleGameGroup(group.key);
    })
    if (this.isGameExpanded(group.key)) {
      ForEach(group.friends, (friend: SteamArkFriendProfile): void => {
        this.buildFriend(friend, 12)
      }, (friend: SteamArkFriendProfile): string => 'game-' + group.key + '-' + friend.steamId64)
    }
  }

  @Builder
  private buildFriendSection(section: number): void {
    if ((section === 1 ? this.onlineFriends() : this.offlineFriends()).length > 0) {
      this.buildSectionHeader(
        section === 1
          ? $r('app.string.steam_float_friends_online_group')
          : $r('app.string.steam_float_friends_offline_group'),
        section === 1 ? $r('sys.symbol.circle_fill') : $r('sys.symbol.circle'),
        section
      )
      if (this.sectionExpanded(section)) {
        ForEach(section === 1 ? this.onlineFriends() : this.offlineFriends(),
          (friend: SteamArkFriendProfile) => {
            this.buildFriend(friend, 12)
          }, (friend: SteamArkFriendProfile): string => section.toString() + '-' + friend.steamId64)
      }
    }
  }

  @Builder
  private buildSectionHeader(title: ResourceStr, symbol: Resource, section: number): void {
    Button() {
      Row({ space: 8 }) {
        SymbolGlyph(this.sectionExpanded(section)
          ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
        SymbolGlyph(symbol)
          .fontSize(14)
          .fontColor([section === 2
            ? SteamArkTheme.textMuted(this.isDarkMode) : SteamArkTheme.success(this.isDarkMode)])
        Text(title)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text(this.sectionCount(section).toString())
          .fontSize(11)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        Blank()
      }
      .width('100%')
      .height(44)
      .padding({ left: 10, right: 10 })
    }
    .width('100%')
    .height(44)
    .padding(0)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
    .border({ width: { bottom: 1 }, color: SteamArkTheme.divider(this.isDarkMode) })
    .onClick((): void => {
      this.toggleSection(section);
    })
  }

  private sectionExpanded(section: number): boolean {
    if (section === 0) {
      return this.gameExpanded;
    }
    if (section === 1) {
      return this.onlineExpanded;
    }
    return this.offlineExpanded;
  }

  private sectionCount(section: number): number {
    if (section === 0) {
      return this.totalGroupFriends(this.gameGroups());
    }
    if (section === 1) {
      return this.onlineFriends().length;
    }
    return this.offlineFriends().length;
  }

  private applySnapshot(snapshot: SteamArkSocialSnapshot): void {
    if (snapshot.accountId !== this.accountId) {
      return;
    }
    this.friends = snapshot.friends.slice();
    this.sessions = snapshot.sessions.slice();
    this.connectionState = snapshot.state;
    this.loading = snapshot.state === SteamArkSocialConnectionState.CONNECTING;
    let unread: number = 0;
    for (let index: number = 0; index < snapshot.sessions.length; index++) {
      unread += snapshot.sessions[index].unreadCount;
    }
    this.unreadCount = unread;
  }

  private closeForAccountChange(): void {
    if (!this.isPageActive) {
      return;
    }
    const closingAccountId: string = this.accountId;
    this.isPageActive = false;
    this.accountGeneration++;
    this.contentVisible = false;
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    void steamArkFloatingWindowCoordinator.closeFriendsForAccount(closingAccountId);
  }

  private syncCurrentAccount(): void {
    const accountId: string = this.accountId;
    const generation: number = this.accountGeneration;
    if (accountId.length <= 0) {
      this.loading = false;
      return;
    }
    void steamArkSocialService.connectAndSyncIfStale(
      accountId,
      Math.floor(SteamArkExperiencePolicy.SOCIAL_CACHE_FRESH_MS / 1000)
    ).then((snapshot: SteamArkSocialSnapshot): void => {
      if (this.isPageActive && this.accountId === accountId && this.accountGeneration === generation) {
        this.applySnapshot(snapshot);
      }
    }).catch((): void => {
      if (this.isPageActive && this.accountId === accountId && this.accountGeneration === generation) {
        this.loading = false;
      }
    });
  }

  private visibleFriends(): Array<SteamArkFriendProfile> {
    const query: string = this.searchText.trim().toLowerCase();
    if (query.length <= 0) {
      return this.friends;
    }
    return this.friends.filter((friend: SteamArkFriendProfile): boolean =>
      this.friendMatchesSearch(friend, query));
  }

  private friendMatchesSearch(friend: SteamArkFriendProfile, query: string): boolean {
    return friend.displayName.toLowerCase().includes(query) ||
      friend.gameName.toLowerCase().includes(query) ||
      friend.steamId64.toLowerCase().includes(query) ||
      friend.accountId32.toString().includes(query) ||
      friend.gameAppId.toLowerCase().includes(query) ||
      friend.profileUrl.toLowerCase().includes(query);
  }

  private openNewestUnreadChat(): void {
    let target: SteamArkChatSession | null = null;
    for (let index: number = 0; index < this.sessions.length; index++) {
      const session: SteamArkChatSession = this.sessions[index];
      if (session.unreadCount > 0 && (target === null ||
        session.lastMessageEpochSeconds > target.lastMessageEpochSeconds)) {
        target = session;
      }
    }
    if (target !== null) {
      void steamArkFloatingWindowCoordinator.openChat(this.accountId, target.friendSteamId64);
    }
  }

  private gameGroups(): Array<SteamArkFriendGameGroup> {
    const grouped: Map<string, Array<SteamArkFriendProfile>> = new Map<string, Array<SteamArkFriendProfile>>();
    const visible: Array<SteamArkFriendProfile> = this.visibleFriends();
    for (let index: number = 0; index < visible.length; index++) {
      const friend: SteamArkFriendProfile = visible[index];
      if (friend.gameName.length <= 0) {
        continue;
      }
      const key: string = friend.gameAppId.length > 0 ? friend.gameAppId : friend.gameName.toLowerCase();
      const current: Array<SteamArkFriendProfile> | undefined = grouped.get(key);
      if (current === undefined) {
        grouped.set(key, [friend]);
      } else {
        current.push(friend);
      }
    }
    const result: Array<SteamArkFriendGameGroup> = [];
    grouped.forEach((values: Array<SteamArkFriendProfile>, key: string): void => {
      const first: SteamArkFriendProfile = values[0];
      result.push(new SteamArkFriendGameGroup(key, first.gameName, first.gameAppId, this.sortedFriends(values)));
    });
    return result.sort((left: SteamArkFriendGameGroup, right: SteamArkFriendGameGroup): number =>
      left.gameName.localeCompare(right.gameName));
  }

  private onlineFriends(): Array<SteamArkFriendProfile> {
    return this.sortedFriends(this.visibleFriends().filter((friend: SteamArkFriendProfile): boolean =>
      friend.gameName.length <= 0 && friend.personaState > 0));
  }

  private offlineFriends(): Array<SteamArkFriendProfile> {
    return this.sortedFriends(this.visibleFriends().filter((friend: SteamArkFriendProfile): boolean =>
      friend.gameName.length <= 0 && friend.personaState <= 0));
  }

  private sortedFriends(values: Array<SteamArkFriendProfile>): Array<SteamArkFriendProfile> {
    return values.sort((left: SteamArkFriendProfile, right: SteamArkFriendProfile): number =>
      left.displayName.localeCompare(right.displayName));
  }

  private toggleSection(section: number): void {
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.SECTION_EXPAND_DURATION,
      curve: Curve.EaseOut
    }, (): void => {
      if (section === 0) {
        this.gameExpanded = !this.gameExpanded;
      } else if (section === 1) {
        this.onlineExpanded = !this.onlineExpanded;
      } else {
        this.offlineExpanded = !this.offlineExpanded;
      }
    });
  }

  private toggleGameGroup(key: string): void {
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.SECTION_EXPAND_DURATION,
      curve: Curve.EaseOut
    }, (): void => {
      const next: Array<string> = this.expandedGameKeys.slice();
      const index: number = next.indexOf(key);
      if (index >= 0) {
        next.splice(index, 1);
      } else {
        next.push(key);
      }
      this.expandedGameKeys = next;
    });
  }

  private isGameExpanded(key: string): boolean {
    return this.expandedGameKeys.indexOf(key) >= 0;
  }

  private expandVisibleGameGroups(): void {
    const groups: Array<SteamArkFriendGameGroup> = this.gameGroups();
    const keys: Array<string> = [];
    for (let index: number = 0; index < groups.length; index++) {
      keys.push(groups[index].key);
    }
    this.expandedGameKeys = keys;
  }

  private totalGroupFriends(groups: Array<SteamArkFriendGameGroup>): number {
    let count: number = 0;
    for (let index: number = 0; index < groups.length; index++) {
      count += groups[index].friends.length;
    }
    return count;
  }

  private closeWithAnimation(): void {
    if (this.closeTimer >= 0) {
      return;
    }
    this.closeTimer = 1;
    // User-facing close: collapse into the capsule, then detach the window
    // surface (the window itself stays alive for the next pop-in).
    void this.playCapsuleCollapse().then((): void => {
      this.closeTimer = -1;
      void steamArkFloatingWindowCoordinator.hideFriendsWindow();
    });
  }

  private gameLogoUrl(appId: string): string {
    return 'https://cdn.cloudflare.steamstatic.com/steam/apps/' + appId + '/capsule_231x87.jpg';
  }

  private scheduleSilentRefresh(): void {
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
    }
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      if (!this.isPageActive || this.accountId.length <= 0) {
        return;
      }
      void steamArkSocialService.connectAndSyncIfStale(
        this.accountId,
        Math.floor(SteamArkExperiencePolicy.SOCIAL_CACHE_FRESH_MS / 1000)
      ).finally((): void => {
        if (this.isPageActive) {
          this.scheduleSilentRefresh();
        }
      });
    }, SteamArkExperiencePolicy.SILENT_REFRESH_INTERVAL_MS);
  }

  private headerSubtitle(): ResourceStr {
    if (this.connectionState === SteamArkSocialConnectionState.CONNECTING) {
      return $r('app.string.steam_float_friends_connecting');
    }
    if (this.connectionState === SteamArkSocialConnectionState.ERROR) {
      return $r('app.string.steam_float_friends_error');
    }
    return $r('app.string.steam_float_friends_subtitle');
  }

  private personaText(personaState: number): ResourceStr {
    return personaState > 0
      ? $r('app.string.steam_float_friend_online')
      : $r('app.string.steam_float_friend_offline');
  }
}
