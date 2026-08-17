import { window } from '@kit.ArkUI';
import {
  NGFHoldingUiAnchor,
  NGFWindowRuntimeSnapshot,
  ngfSettingsStoreFacade,
  ngfPlatformWindowManagerFacade
} from 'ngf_framework';
import {
  SteamArkLog,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkStateService
} from '../../steamServices';

export const STEAM_ARK_FLOAT_ACCOUNT_KEY: string = 'steam_ark_float_account_id';
export const STEAM_ARK_FLOAT_FRIEND_KEY: string = 'steam_ark_float_friend_id';
/** Sub-window name shared with the friends page for anchored pop animations. */
export const STEAM_ARK_FRIENDS_WINDOW_NAME: string = 'steam_ark_friends_float';
/** Screen-space capsule anchor (px) the friends window pops out of and into. */
export const STEAM_ARK_FRIENDS_ANCHOR_X_PX: string = 'steam_ark_friends_anchor_x_px';
export const STEAM_ARK_FRIENDS_ANCHOR_Y_PX: string = 'steam_ark_friends_anchor_y_px';

const TAG: string = 'FloatingWindowCoordinator';
const FRIENDS_WINDOW_NAME: string = STEAM_ARK_FRIENDS_WINDOW_NAME;
const CHAT_WINDOW_NAME: string = 'steam_ark_chat_float';
const STATE_LISTENER_ID: string = 'SteamArkFloatingWindowCoordinator';
const POSITION_PREFIX: string = 'steam_ark_float_position_v1_';
const INVALID_POSITION: number = -1;
const PANEL_EDGE: number = 24;

enum SteamArkFloatingWindowKind {
  FRIENDS = 'friends',
  CHAT = 'chat'
}

type SteamArkFloatingWindowOperation = () => Promise<void>;

class SteamArkFloatingWindowCoordinator {
  private friendsPrepared: boolean = false;
  private chatPrepared: boolean = false;
  private friendsWindow: window.Window | null = null;
  private chatWindow: window.Window | null = null;
  private friendsAccountId: string = '';
  private chatAccountId: string = '';
  private chatFriendSteamId64: string = '';
  private selectedAccountId: string = '';
  private accountScopeGeneration: number = 0;
  private stateListenerRegistered: boolean = false;
  private friendsShown: boolean = false;
  /**
   * Direct animation handles registered by the friends page (same process, so
   * plain function references work across windows — reactive AppStorage
   * signalling proved unreliable here). Present plays the capsule pop after
   * showWindow; collapse animates back and resolves when finished.
   */
  private friendsPresentHandler: (() => boolean) | null = null;
  private friendsCollapseHandler: (() => Promise<void>) | null = null;
  private windowOperationTail: Promise<void> = Promise.resolve();
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    this.applySelectedAccountScope(snapshot.selectedAccountId);
  };

  async openFriends(accountId: string): Promise<void> {
    this.ensureStateListener();
    const normalizedAccountId: string = accountId.trim();
    const selectedAccountId: string = steamArkStateService.getSnapshot().selectedAccountId.trim();
    this.applySelectedAccountScope(selectedAccountId);
    if (!this.canOpenForSelectedAccount(normalizedAccountId, selectedAccountId)) {
      return;
    }
    const scopeGeneration: number = this.accountScopeGeneration;
    await this.enqueueWindowOperation(async (): Promise<void> => {
      await this.openFriendsInternal(normalizedAccountId, scopeGeneration);
    });
  }

  private async openFriendsInternal(accountId: string, scopeGeneration: number): Promise<void> {
    if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
      return;
    }
    try {
      if (this.friendsPrepared && this.friendsAccountId !== accountId) {
        await this.closeFriendsInternal();
      }
      if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
        return;
      }
      AppStorage.setOrCreate<string>(STEAM_ARK_FLOAT_ACCOUNT_KEY, accountId);
      AppStorage.setOrCreate<string>(STEAM_ARK_FLOAT_FRIEND_KEY, '');
      const target: window.Window = await ngfPlatformWindowManagerFacade.createSubWindow(FRIENDS_WINDOW_NAME);
      this.friendsWindow = target;
      if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
        await this.closeFriendsInternal();
        return;
      }
      if (!this.friendsPrepared) {
        await target.setUIContent('pages/steamArk/SteamArkFriendsFloatingPage');
        this.applyTransparentBackground(target, SteamArkFloatingWindowKind.FRIENDS);
        this.friendsPrepared = true;
      }
      if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
        await this.closeFriendsInternal();
        return;
      }
      const size: SteamArkFloatingWindowSize = this.friendsWindowSize();
      await target.resize(size.width, size.height);
      await this.restoreOrAnchor(target, SteamArkFloatingWindowKind.FRIENDS, size.width, size.height, PANEL_EDGE);
      await target.showWindow();
      if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
        await this.closeFriendsInternal();
        return;
      }
      this.friendsAccountId = accountId;
      this.friendsShown = true;
      await this.driveFriendsPresent(scopeGeneration);
    } catch (error) {
      this.friendsPrepared = false;
      this.friendsWindow = null;
      this.friendsAccountId = '';
      SteamArkLog.warn(TAG, 'friends floating window failed; errorType=' + SteamArkLog.errorKind(error));
    }
  }

  async openChat(accountId: string, friendSteamId64: string): Promise<void> {
    this.ensureStateListener();
    const normalizedAccountId: string = accountId.trim();
    const normalizedFriendSteamId64: string = friendSteamId64.trim();
    const selectedAccountId: string = steamArkStateService.getSnapshot().selectedAccountId.trim();
    this.applySelectedAccountScope(selectedAccountId);
    if (normalizedFriendSteamId64.length <= 0 ||
      !this.canOpenForSelectedAccount(normalizedAccountId, selectedAccountId)) {
      return;
    }
    const scopeGeneration: number = this.accountScopeGeneration;
    await this.enqueueWindowOperation(async (): Promise<void> => {
      await this.openChatInternal(normalizedAccountId, normalizedFriendSteamId64, scopeGeneration);
    });
  }

  private async openChatInternal(accountId: string, friendSteamId64: string,
    scopeGeneration: number): Promise<void> {
    if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
      return;
    }
    try {
      if (this.chatPrepared) {
        await this.closeChatInternal();
      }
      if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
        return;
      }
      AppStorage.setOrCreate<string>(STEAM_ARK_FLOAT_ACCOUNT_KEY, accountId);
      AppStorage.setOrCreate<string>(STEAM_ARK_FLOAT_FRIEND_KEY, friendSteamId64);
      const target: window.Window = await ngfPlatformWindowManagerFacade.createSubWindow(CHAT_WINDOW_NAME);
      this.chatWindow = target;
      if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
        await this.closeChatInternal();
        return;
      }
      await target.setUIContent('pages/steamArk/SteamArkChatFloatingPage');
      this.applyTransparentBackground(target, SteamArkFloatingWindowKind.CHAT);
      this.chatPrepared = true;
      if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
        await this.closeChatInternal();
        return;
      }
      const size: SteamArkFloatingWindowSize = this.chatWindowSize();
      await target.resize(size.width, size.height);
      await this.restoreOrAnchor(target, SteamArkFloatingWindowKind.CHAT, size.width, size.height, PANEL_EDGE);
      await target.showWindow();
      if (!this.isCurrentAccountScope(accountId, scopeGeneration)) {
        await this.closeChatInternal();
        return;
      }
      this.chatAccountId = accountId;
      this.chatFriendSteamId64 = friendSteamId64;
    } catch (error) {
      this.chatPrepared = false;
      this.chatWindow = null;
      this.chatAccountId = '';
      this.chatFriendSteamId64 = '';
      SteamArkLog.warn(TAG, 'chat floating window failed; errorType=' + SteamArkLog.errorKind(error) +
        ', detail=' + this.errorDetail(error));
      try {
        await ngfPlatformWindowManagerFacade.destroySubWindow(CHAT_WINDOW_NAME);
      } catch (cleanupError) {
        SteamArkLog.warn(TAG, 'chat floating window cleanup failed; errorType=' +
          SteamArkLog.errorKind(cleanupError) + ', detail=' + this.errorDetail(cleanupError));
      }
    }
  }

  async closeFriends(): Promise<void> {
    await this.enqueueWindowOperation(async (): Promise<void> => {
      await this.hideFriendsWindowInternal();
    });
  }

  /** True while the friends window surface is on screen (capsule toggle). */
  isFriendsWindowShown(): boolean {
    return this.friendsShown;
  }

  setFriendsPresentHandler(handler: (() => boolean) | null): void {
    this.friendsPresentHandler = handler;
  }

  setFriendsCollapseHandler(handler: (() => Promise<void>) | null): void {
    this.friendsCollapseHandler = handler;
  }

  /**
   * Drives the capsule pop after showWindow. The first open can race the
   * page's initial load (handler not yet registered or the page not yet
   * active), so the present handle is retried until the page confirms the
   * pop played — never leaving a bare window surface on screen.
   */
  private async driveFriendsPresent(scopeGeneration: number): Promise<void> {
    for (let attempt: number = 0; attempt < 14; attempt++) {
      if (!this.friendsShown || !this.isCurrentAccountScope(this.friendsAccountId, scopeGeneration)) {
        return;
      }
      const handler: (() => boolean) | null = this.friendsPresentHandler;
      if (handler !== null) {
        try {
          if (handler()) {
            return;
          }
        } catch (error) {
          SteamArkLog.debug(TAG, 'friends capsule pop attempt failed; errorType=' +
            SteamArkLog.errorKind(error));
        }
      }
      await this.delayForPresentRetry();
    }
    SteamArkLog.warn(TAG, 'friends capsule pop was not confirmed; window will be hidden');
    await this.hideFriendsWindowInternal();
  }

  private delayForPresentRetry(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 120);
    });
  }
  async hideFriendsWindow(): Promise<void> {
    await this.enqueueWindowOperation(async (): Promise<void> => {
      await this.hideFriendsWindowInternal();
    });
  }

  private async hideFriendsWindowInternal(): Promise<void> {
    if (!this.friendsShown || this.friendsWindow === null) {
      return;
    }
    this.friendsShown = false;
    if (this.friendsCollapseHandler !== null) {
      try {
        await this.friendsCollapseHandler();
      } catch (error) {
        SteamArkLog.debug(TAG, 'friends capsule collapse failed; errorType=' + SteamArkLog.errorKind(error));
      }
    }
    try {
      // API 26 renamed the instance hide call to minimize(); it detaches the
      // window surface (and its touch area) right away.
      await this.friendsWindow.minimize();
    } catch (error) {
      // Minimize can be rejected on some device forms — fall back to a full
      // destroy so the surface never lingers; the next open recreates it.
      SteamArkLog.debug(TAG, 'friends window minimize rejected; falling back to destroy; errorType=' +
        SteamArkLog.errorKind(error));
      await this.closeFriendsInternal();
    }
  }

  async closeFriendsForAccount(accountId: string): Promise<void> {
    const normalizedAccountId: string = accountId.trim();
    await this.enqueueWindowOperation(async (): Promise<void> => {
      if (normalizedAccountId.length <= 0 || this.friendsAccountId !== normalizedAccountId) {
        return;
      }
      await this.closeFriendsInternal();
    });
  }

  private async closeFriendsInternal(): Promise<void> {
    const windowAlive: boolean = this.friendsPrepared || this.friendsWindow !== null;
    const target: window.Window | null = this.friendsWindow;
    this.friendsPrepared = false;
    this.friendsWindow = null;
    this.friendsAccountId = '';
    this.friendsShown = false;
    this.friendsPresentHandler = null;
    this.friendsCollapseHandler = null;
    try {
      if (windowAlive && target !== null) {
        try {
          await target.minimize();
        } catch (hideError) {
          SteamArkLog.debug(TAG, 'friends floating window minimize before destroy failed; errorType=' +
            SteamArkLog.errorKind(hideError));
        }
      }
      await ngfPlatformWindowManagerFacade.destroySubWindow(FRIENDS_WINDOW_NAME);
    } catch (error) {
      SteamArkLog.warn(TAG, 'friends floating window close failed; errorType=' + SteamArkLog.errorKind(error));
    }
  }

  async closeChat(): Promise<void> {
    await this.enqueueWindowOperation(async (): Promise<void> => {
      await this.closeChatInternal();
    });
  }

  async closeChatForConversation(accountId: string, friendSteamId64: string): Promise<void> {
    const normalizedAccountId: string = accountId.trim();
    const normalizedFriendSteamId64: string = friendSteamId64.trim();
    await this.enqueueWindowOperation(async (): Promise<void> => {
      if (normalizedAccountId.length <= 0 || normalizedFriendSteamId64.length <= 0 ||
        this.chatAccountId !== normalizedAccountId || this.chatFriendSteamId64 !== normalizedFriendSteamId64) {
        return;
      }
      await this.closeChatInternal();
    });
  }

  async closeWindowsForAccount(accountId: string): Promise<void> {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId.length <= 0) {
      return;
    }
    await this.enqueueWindowOperation(async (): Promise<void> => {
      if (this.friendsAccountId === normalizedAccountId) {
        await this.closeFriendsInternal();
      }
      if (this.chatAccountId === normalizedAccountId) {
        await this.closeChatInternal();
      }
    });
  }

  /** Releases state and window references that cannot survive an Ability teardown. */
  releaseForAbilityTeardown(): void {
    this.releaseStateListener();
    this.invalidateWindowRuntime();
    SteamArkLog.lifecycle(TAG, 'ability teardown floating runtime released');
  }

  /** Invalidates WindowStage-owned handles while retaining the valid state subscription. */
  onWindowStageDestroyed(): void {
    this.invalidateWindowRuntime();
    SteamArkLog.lifecycle(TAG, 'window stage floating runtime invalidated');
  }

  private async closeChatInternal(): Promise<void> {
    const closingAccountId: string = this.chatAccountId;
    const closingFriendSteamId64: string = this.chatFriendSteamId64;
    this.chatPrepared = false;
    this.chatWindow = null;
    this.chatAccountId = '';
    this.chatFriendSteamId64 = '';
    try {
      await ngfPlatformWindowManagerFacade.destroySubWindow(CHAT_WINDOW_NAME);
    } catch (error) {
      SteamArkLog.warn(TAG, 'chat floating window close failed; errorType=' + SteamArkLog.errorKind(error));
    }
    const storedAccountId: string = AppStorage.get<string>(STEAM_ARK_FLOAT_ACCOUNT_KEY) ?? '';
    const storedFriendSteamId64: string = AppStorage.get<string>(STEAM_ARK_FLOAT_FRIEND_KEY) ?? '';
    if (closingAccountId.length > 0 && storedAccountId === closingAccountId &&
      storedFriendSteamId64 === closingFriendSteamId64) {
      AppStorage.setOrCreate<string>(STEAM_ARK_FLOAT_FRIEND_KEY, '');
    }
  }

  private ensureStateListener(): void {
    if (!this.stateListenerRegistered) {
      this.stateListenerRegistered = steamArkStateService.subscribe(STATE_LISTENER_ID,
        this.stateListener);
    }
    this.applySelectedAccountScope(steamArkStateService.getSnapshot().selectedAccountId);
  }

  private releaseStateListener(): void {
    if (!this.stateListenerRegistered) {
      return;
    }
    steamArkStateService.unsubscribe(STATE_LISTENER_ID);
    this.stateListenerRegistered = false;
  }

  private invalidateWindowRuntime(): void {
    this.accountScopeGeneration++;
    this.friendsPrepared = false;
    this.chatPrepared = false;
    this.friendsWindow = null;
    this.chatWindow = null;
    this.friendsAccountId = '';
    this.chatAccountId = '';
    this.chatFriendSteamId64 = '';
    this.selectedAccountId = '';
    AppStorage.setOrCreate<string>(STEAM_ARK_FLOAT_ACCOUNT_KEY, '');
    AppStorage.setOrCreate<string>(STEAM_ARK_FLOAT_FRIEND_KEY, '');
  }

  private applySelectedAccountScope(accountId: string): void {
    const normalizedAccountId: string = accountId.trim();
    if (normalizedAccountId === this.selectedAccountId) {
      return;
    }
    const previousAccountId: string = this.selectedAccountId;
    this.selectedAccountId = normalizedAccountId;
    this.accountScopeGeneration++;
    AppStorage.setOrCreate<string>(STEAM_ARK_FLOAT_ACCOUNT_KEY, normalizedAccountId);
    AppStorage.setOrCreate<string>(STEAM_ARK_FLOAT_FRIEND_KEY, '');
    const scopeGeneration: number = this.accountScopeGeneration;
    const shouldCloseFriends: boolean = this.friendsPrepared || this.friendsWindow !== null;
    const shouldCloseChat: boolean = this.chatPrepared || this.chatWindow !== null;
    if (shouldCloseFriends || shouldCloseChat) {
      void this.enqueueWindowOperation(async (): Promise<void> => {
        if (scopeGeneration !== this.accountScopeGeneration) {
          return;
        }
        if (shouldCloseFriends) {
          await this.closeFriendsInternal();
        }
        if (shouldCloseChat) {
          await this.closeChatInternal();
        }
      });
    }
    SteamArkLog.state(TAG, SteamArkLog.accountId(previousAccountId), SteamArkLog.accountId(normalizedAccountId),
      'floating account scope changed');
  }

  private canOpenForSelectedAccount(accountId: string, selectedAccountId: string): boolean {
    if (accountId.length > 0 && accountId === selectedAccountId) {
      return true;
    }
    SteamArkLog.warn(TAG, 'floating window request rejected because account is no longer selected; requested=' +
      SteamArkLog.accountId(accountId) + ', selected=' + SteamArkLog.accountId(selectedAccountId));
    return false;
  }

  private isCurrentAccountScope(accountId: string, scopeGeneration: number): boolean {
    return accountId.length > 0 && accountId === this.selectedAccountId &&
      scopeGeneration === this.accountScopeGeneration &&
      steamArkStateService.getSnapshot().selectedAccountId === accountId;
  }

  private enqueueWindowOperation(operation: SteamArkFloatingWindowOperation): Promise<void> {
    const task: Promise<void> = this.windowOperationTail.then(
      (): Promise<void> => operation(),
      (): Promise<void> => operation()
    );
    this.windowOperationTail = task.then(
      (): void => {},
      (): void => {}
    );
    return task;
  }

  private friendsWindowSize(): SteamArkFloatingWindowSize {
    const snapshot: NGFWindowRuntimeSnapshot = ngfPlatformWindowManagerFacade.getCurrentSnapshot();
    const availableWidth: number = this.availableWidth(snapshot);
    const availableHeight: number = this.availableHeight(snapshot);
    return new SteamArkFloatingWindowSize(
      Math.max(640, Math.min(960, availableWidth - 72)),
      Math.max(900, Math.min(1500, availableHeight - 180))
    );
  }

  private chatWindowSize(): SteamArkFloatingWindowSize {
    const snapshot: NGFWindowRuntimeSnapshot = ngfPlatformWindowManagerFacade.getCurrentSnapshot();
    const availableWidth: number = this.availableWidth(snapshot);
    const availableHeight: number = this.availableHeight(snapshot);
    return new SteamArkFloatingWindowSize(
      Math.min(880, Math.max(360, availableWidth - 96)),
      Math.min(1320, Math.max(640, availableHeight - 240))
    );
  }

  startFriendsDrag(): void {
    this.startDrag(this.friendsWindow, SteamArkFloatingWindowKind.FRIENDS);
  }

  finishFriendsDrag(): void {
    void this.finishDrag(this.friendsWindow, SteamArkFloatingWindowKind.FRIENDS, PANEL_EDGE);
  }

  startChatDrag(): void {
    this.startDrag(this.chatWindow, SteamArkFloatingWindowKind.CHAT);
  }

  finishChatDrag(): void {
    void this.finishDrag(this.chatWindow, SteamArkFloatingWindowKind.CHAT, PANEL_EDGE);
  }

  private startDrag(target: window.Window | null, kind: SteamArkFloatingWindowKind): void {
    if (target === null) {
      return;
    }
    void target.startMoving().catch((error: Error): void => {
      SteamArkLog.warn(TAG, 'floating drag start failed; kind=' + kind + ', errorType=' +
        SteamArkLog.errorKind(error));
    });
  }

  private async finishDrag(target: window.Window | null, kind: SteamArkFloatingWindowKind,
    edge: number): Promise<void> {
    if (target === null) {
      return;
    }
    try {
      await target.stopMoving();
    } catch (error) {
      SteamArkLog.warn(TAG, 'floating drag stop was rejected; kind=' + kind + ', errorType=' +
        SteamArkLog.errorKind(error));
    }
    try {
      const rect: window.Rect = target.getWindowProperties().windowRect;
      const position: SteamArkFloatingWindowPosition = this.clampPosition(
        rect.left, rect.top, rect.width, rect.height, edge);
      await target.moveWindowTo(position.x, position.y);
      ngfSettingsStoreFacade.setNumber(this.positionKey(kind, 'x'), position.x);
      ngfSettingsStoreFacade.setNumber(this.positionKey(kind, 'y'), position.y);
    } catch (error) {
      SteamArkLog.warn(TAG, 'floating drag position persistence failed; kind=' + kind + ', errorType=' +
        SteamArkLog.errorKind(error));
    }
  }

  private async restoreOrAnchor(target: window.Window, kind: SteamArkFloatingWindowKind,
    width: number, height: number, edge: number): Promise<void> {
    const savedX: number = ngfSettingsStoreFacade.getNumber(this.positionKey(kind, 'x'), INVALID_POSITION);
    const savedY: number = ngfSettingsStoreFacade.getNumber(this.positionKey(kind, 'y'), INVALID_POSITION);
    if (savedX >= 0 && savedY >= 0) {
      const saved: SteamArkFloatingWindowPosition = this.clampPosition(savedX, savedY, width, height, edge);
      await target.moveWindowTo(saved.x, saved.y);
      return;
    }
    const snapshot: NGFWindowRuntimeSnapshot = ngfPlatformWindowManagerFacade.getCurrentSnapshot();
    const availableWidth: number = this.availableWidth(snapshot);
    const availableHeight: number = this.availableHeight(snapshot);
    const anchor: string = AppStorage.get<string>('ngf_holding_awareness_preferred_anchor') ?? NGFHoldingUiAnchor.RIGHT;
    const x: number = anchor === NGFHoldingUiAnchor.LEFT ? edge : Math.max(edge, availableWidth - width - edge);
    const y: number = Math.max(edge, availableHeight - height - edge);
    await target.moveWindowTo(x, y);
  }

  private clampPosition(x: number, y: number, width: number, height: number,
    edge: number): SteamArkFloatingWindowPosition {
    const snapshot: NGFWindowRuntimeSnapshot = ngfPlatformWindowManagerFacade.getCurrentSnapshot();
    const maxX: number = Math.max(edge, this.availableWidth(snapshot) - width - edge);
    const maxY: number = Math.max(edge, this.availableHeight(snapshot) - height - edge);
    return new SteamArkFloatingWindowPosition(
      Math.max(edge, Math.min(x, maxX)),
      Math.max(edge, Math.min(y, maxY))
    );
  }

  private positionKey(kind: SteamArkFloatingWindowKind, axis: string): string {
    return POSITION_PREFIX + kind + '_' + axis;
  }

  private availableWidth(snapshot: NGFWindowRuntimeSnapshot): number {
    if (snapshot.globalDisplayRect.width > 0) {
      return snapshot.globalDisplayRect.width;
    }
    return snapshot.windowRect.width > 0 ? snapshot.windowRect.width : 1260;
  }

  private availableHeight(snapshot: NGFWindowRuntimeSnapshot): number {
    if (snapshot.globalDisplayRect.height > 0) {
      return snapshot.globalDisplayRect.height;
    }
    return snapshot.windowRect.height > 0 ? snapshot.windowRect.height : 2720;
  }

  private applyTransparentBackground(target: window.Window, kind: SteamArkFloatingWindowKind): void {
    try {
      target.setWindowBackgroundColor('#00000000');
    } catch (backgroundError) {
      SteamArkLog.warn(TAG, 'floating transparent background unavailable; kind=' + kind + ', errorType=' +
        SteamArkLog.errorKind(backgroundError) + ', detail=' + this.errorDetail(backgroundError));
    }
  }

  private errorDetail(error: Error | Object | string | number | boolean | null | undefined): string {
    if (error instanceof Error && error.message.length > 0) {
      return error.message;
    }
    return 'unavailable';
  }
}

class SteamArkFloatingWindowPosition {
  readonly x: number;
  readonly y: number;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

class SteamArkFloatingWindowSize {
  readonly width: number;
  readonly height: number;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

export const steamArkFloatingWindowCoordinator: SteamArkFloatingWindowCoordinator =
  new SteamArkFloatingWindowCoordinator();
