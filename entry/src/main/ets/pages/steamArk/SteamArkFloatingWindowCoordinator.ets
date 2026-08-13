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

const TAG: string = 'FloatingWindowCoordinator';
const STATUS_WINDOW_NAME: string = 'steam_ark_status_ball';
const FRIENDS_WINDOW_NAME: string = 'steam_ark_friends_float';
const CHAT_WINDOW_NAME: string = 'steam_ark_chat_float';
const STATE_LISTENER_ID: string = 'SteamArkFloatingWindowCoordinator';
const POSITION_PREFIX: string = 'steam_ark_float_position_v1_';
const INVALID_POSITION: number = -1;
const STATUS_EDGE: number = 24;
const PANEL_EDGE: number = 24;

enum SteamArkFloatingWindowKind {
  STATUS = 'status',
  FRIENDS = 'friends',
  CHAT = 'chat'
}

type SteamArkFloatingWindowOperation = () => Promise<void>;

class SteamArkFloatingWindowCoordinator {
  private statusPrepared: boolean = false;
  private friendsPrepared: boolean = false;
  private chatPrepared: boolean = false;
  private statusWindow: window.Window | null = null;
  private friendsWindow: window.Window | null = null;
  private chatWindow: window.Window | null = null;
  private friendsAccountId: string = '';
  private chatAccountId: string = '';
  private chatFriendSteamId64: string = '';
  private selectedAccountId: string = '';
  private accountScopeGeneration: number = 0;
  private stateListenerRegistered: boolean = false;
  private windowOperationTail: Promise<void> = Promise.resolve();
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    this.applySelectedAccountScope(snapshot.selectedAccountId);
  };

  async showStatusBall(): Promise<void> {
    this.ensureStateListener();
    try {
      const target: window.Window = await ngfPlatformWindowManagerFacade.createSubWindow(STATUS_WINDOW_NAME);
      this.statusWindow = target;
      if (!this.statusPrepared) {
        await target.setUIContent('pages/steamArk/SteamArkStatusBallPage');
        this.applyTransparentBackground(target, SteamArkFloatingWindowKind.STATUS);
        this.statusPrepared = true;
      }
      await target.resize(176, 176);
      await this.restoreOrAnchor(target, SteamArkFloatingWindowKind.STATUS, 176, 176, STATUS_EDGE);
      await target.showWindow();
      SteamArkLog.info(TAG, 'global status ball shown');
    } catch (error) {
      this.statusPrepared = false;
      SteamArkLog.warn(TAG, 'global status ball unavailable; errorType=' + SteamArkLog.errorKind(error));
    }
  }

  async repositionStatusBall(): Promise<void> {
    try {
      const target: window.Window = await ngfPlatformWindowManagerFacade.createSubWindow(STATUS_WINDOW_NAME);
      this.statusWindow = target;
      await this.restoreOrAnchor(target, SteamArkFloatingWindowKind.STATUS, 176, 176, STATUS_EDGE);
    } catch (error) {
      SteamArkLog.warn(TAG, 'status ball reposition failed; errorType=' + SteamArkLog.errorKind(error));
    }
  }

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
      await this.closeFriendsInternal();
    });
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
    this.friendsPrepared = false;
    this.friendsWindow = null;
    this.friendsAccountId = '';
    try {
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
    this.statusPrepared = false;
    this.friendsPrepared = false;
    this.chatPrepared = false;
    this.statusWindow = null;
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

  startStatusBallDrag(): void {
    this.startDrag(this.statusWindow, SteamArkFloatingWindowKind.STATUS);
  }

  finishStatusBallDrag(): void {
    void this.finishDrag(this.statusWindow, SteamArkFloatingWindowKind.STATUS, STATUS_EDGE);
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
