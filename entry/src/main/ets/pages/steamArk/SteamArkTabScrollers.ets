/** Stable scroll bindings shared by the HDS navigation shell and embedded tab pages. */
class SteamArkTabScrollerRegistry {
  readonly accounts: Scroller = new Scroller();
  readonly workspace: Scroller = new Scroller();
  readonly inventory: Scroller = new Scroller();
  readonly messages: Scroller = new Scroller();
  readonly tokens: Scroller = new Scroller();
  readonly settings: Scroller = new Scroller();
}

export const steamArkTabScrollers: SteamArkTabScrollerRegistry = new SteamArkTabScrollerRegistry();
