/**
 * Stable scroll bindings shared by the HDS navigation shell and embedded tab
 * pages, plus a scroll-direction signal bus: embedded tab pages report their
 * outer Scroll deltas so the home shell can auto-hide/show the docked friends
 * mini bar exactly like a music app's mini player.
 */
export type SteamArkTabScrollListener = (yOffset: number) => void;

class SteamArkTabScrollerRegistry {
  readonly accounts: Scroller = new Scroller();
  readonly workspace: Scroller = new Scroller();
  readonly inventory: Scroller = new Scroller();
  readonly messages: Scroller = new Scroller();
  readonly tokens: Scroller = new Scroller();
  readonly settings: Scroller = new Scroller();
  readonly library: Scroller = new Scroller();
  private readonly scrollListeners: Map<string, SteamArkTabScrollListener> =
    new Map<string, SteamArkTabScrollListener>();

  addScrollListener(listenerId: string, listener: SteamArkTabScrollListener): void {
    this.scrollListeners.set(listenerId, listener);
  }

  removeScrollListener(listenerId: string): void {
    this.scrollListeners.delete(listenerId);
  }

  /**
   * Reports one outer-scroll delta of an embedded tab page. yOffset > 0 means
   * the user swiped up (content scrolled forward); listener failures never
   * break the scrolling page.
   */
  notifyScrollDelta(yOffset: number): void {
    this.scrollListeners.forEach((listener: SteamArkTabScrollListener): void => {
      try {
        listener(yOffset);
      } catch (_error) {
      }
    });
  }
}

export const steamArkTabScrollers: SteamArkTabScrollerRegistry = new SteamArkTabScrollerRegistry();
