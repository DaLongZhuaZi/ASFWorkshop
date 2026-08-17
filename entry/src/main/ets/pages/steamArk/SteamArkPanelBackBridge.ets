/**
 * Lets the home page (@Entry) intercept the system back key/gesture while an
 * in-page detail panel (badge / game / inventory) is open inside an embedded
 * tab. Tabs have no route stack, so without interception the back key would
 * leave the app instead of closing the panel. Each panel owner registers a
 * close handler under a stable id (with the tab index it lives in) and
 * reports its visibility; the host page reports the active tab and forwards
 * back events through requestClose(). Route-mode instances do not use this
 * bridge: their NavDestination.onBackPressed already handles the panel first.
 */
export class SteamArkPanelBackBridge {
  static readonly BADGE_PANEL: string = 'badge';
  static readonly GAME_DETAIL_PANEL: string = 'gameDetail';
  static readonly INVENTORY_DETAIL_PANEL: string = 'inventoryDetail';

  /** Tab indexes must match SteamArkHomeTab in SteamArkHomePage.ets. */
  static readonly TAB_FARMING: number = 2;
  static readonly TAB_INVENTORY: number = 3;
  static readonly TAB_LIBRARY: number = 4;

  private static closeHandlers: Map<string, () => void> = new Map<string, () => void>();
  private static panelTabIndexes: Map<string, number> = new Map<string, number>();
  private static visibility: Map<string, boolean> = new Map<string, boolean>();
  private static titleVisibilityListeners: Map<string, (panelVisible: boolean) => void> =
    new Map<string, (panelVisible: boolean) => void>();
  private static activeTab: number = -1;

  static registerCloseHandler(id: string, tabIndex: number, handler: () => void): void {
    SteamArkPanelBackBridge.closeHandlers.set(id, handler);
    SteamArkPanelBackBridge.panelTabIndexes.set(id, tabIndex);
  }

  static unregisterCloseHandler(id: string): void {
    SteamArkPanelBackBridge.closeHandlers.delete(id);
    SteamArkPanelBackBridge.panelTabIndexes.delete(id);
    SteamArkPanelBackBridge.visibility.delete(id);
    SteamArkPanelBackBridge.notifyTitleVisibility();
  }

  static setVisible(id: string, visible: boolean): void {
    SteamArkPanelBackBridge.visibility.set(id, visible);
    SteamArkPanelBackBridge.notifyTitleVisibility();
  }

  static isVisible(id: string): boolean {
    return SteamArkPanelBackBridge.visibility.get(id) === true;
  }

  /** Called by the home page whenever the active tab changes. */
  static setActiveTab(tabIndex: number): void {
    SteamArkPanelBackBridge.activeTab = tabIndex;
    SteamArkPanelBackBridge.notifyTitleVisibility();
  }

  /**
   * Lets the host page hide its own navigation title bar while a detail
   * panel on the active tab is open (the panel draws its own top bar).
   * The listener fires immediately on subscribe and on every visibility
   * or active-tab change.
   */
  static subscribeTitleVisibility(listenerId: string, listener: (panelVisible: boolean) => void): void {
    SteamArkPanelBackBridge.titleVisibilityListeners.set(listenerId, listener);
    listener(SteamArkPanelBackBridge.hasVisiblePanelOnActiveTab());
  }

  static unsubscribeTitleVisibility(listenerId: string): void {
    SteamArkPanelBackBridge.titleVisibilityListeners.delete(listenerId);
  }

  /** True when at least one reported-visible panel lives on the active tab. */
  static hasVisiblePanelOnActiveTab(): boolean {
    let visible: boolean = false;
    SteamArkPanelBackBridge.visibility.forEach((panelVisible: boolean, id: string): void => {
      if (visible || !panelVisible) {
        return;
      }
      const tabIndex: number | undefined = SteamArkPanelBackBridge.panelTabIndexes.get(id);
      if (tabIndex !== undefined && tabIndex === SteamArkPanelBackBridge.activeTab) {
        visible = true;
      }
    });
    return visible;
  }

  private static notifyTitleVisibility(): void {
    const panelVisible: boolean = SteamArkPanelBackBridge.hasVisiblePanelOnActiveTab();
    SteamArkPanelBackBridge.titleVisibilityListeners.forEach(
      (listener: (visible: boolean) => void): void => {
        listener(panelVisible);
      });
  }

  /**
   * Consumes a system back event when a panel on the ACTIVE tab is visible.
   * Returns whether the event was consumed.
   */
  static requestClose(): boolean {
    let consumed: boolean = false;
    SteamArkPanelBackBridge.visibility.forEach((visible: boolean, id: string): void => {
      if (consumed || !visible) {
        return;
      }
      const tabIndex: number | undefined = SteamArkPanelBackBridge.panelTabIndexes.get(id);
      if (tabIndex === undefined || tabIndex !== SteamArkPanelBackBridge.activeTab) {
        return;
      }
      if (SteamArkPanelBackBridge.runHandler(id)) {
        consumed = true;
      }
    });
    return consumed;
  }

  private static runHandler(id: string): boolean {
    let ran: boolean = false;
    SteamArkPanelBackBridge.closeHandlers.forEach((handler: () => void, handlerId: string): void => {
      if (!ran && handlerId === id) {
        ran = true;
        handler();
      }
    });
    return ran;
  }
}
