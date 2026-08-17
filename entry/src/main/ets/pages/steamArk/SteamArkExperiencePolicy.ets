export class SteamArkExperiencePolicy {
  static readonly CONTENT_ENTER_DURATION: number = 240;
  static readonly CONTENT_REFRESH_DURATION: number = 280;
  static readonly SECTION_EXPAND_DURATION: number = 220;
  static readonly FLOAT_WINDOW_ENTER_DURATION: number = 220;
  static readonly EXPAND_TRANSITION_DURATION: number = 420;
  static readonly SILENT_REFRESH_INTERVAL_MS: number = 60 * 1000;
  static readonly SOCIAL_CACHE_FRESH_MS: number = 5 * 60 * 1000;
  // Shared bottom-bar geometry (Plan A bottom container): the HdsTabs
  // floating bar, the docked friends mini bar and every tab page's bottom
  // clearance consume the same constants, so all three layers track each
  // other instead of hardcoded screen offsets. The bar geometry has no
  // runtime query API per the official HdsTabs declarations.
  static readonly TAB_BAR_HEIGHT: number = 56;
  static readonly TAB_BAR_SIDE_MARGIN: number = 14;
  static readonly TAB_BAR_BUTTON_GAP: number = 8;
  static readonly FRIENDS_BAR_HEIGHT: number = 56;
  /** Extra bottom clearance tab pages reserve for the docked friends mini bar. */
  static readonly FRIENDS_BAR_RESERVE: number =
    SteamArkExperiencePolicy.FRIENDS_BAR_HEIGHT + SteamArkExperiencePolicy.TAB_BAR_BUTTON_GAP;
  /** Content-hugging capsule cap; the pill never grows past this width. */
  static readonly FRIENDS_BAR_MAX_WIDTH: number = 300;
  /** Capsule pop: anchored window expansion/collapse duration and the close settle delay. */
  static readonly FRIENDS_CAPSULE_POP_DURATION: number = 300;
  static readonly FRIENDS_CAPSULE_CLOSE_DELAY_MS: number = 330;

  /**
   * Branch transition for the official 一镜到底 (same-page if/else swap):
   * both sides at duration 0, the exact pattern the official guide prescribes
   * so neither side ghosts. The branches swap in a single frame and ALL visual
   * continuity is carried by the geometryTransition flight, which draws its
   * own floating snapshot above both branches. Any non-zero branch fade makes
   * the framework composite a semi-transparent exiting branch snapshot over
   * the background layer — on close that composite produced a one-frame white
   * flash across the whole background, while the list branch itself (content
   * islands over a transparent background) cannot mask it.
   */
  static seamlessBranchTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 0 }),
      TransitionEffect.OPACITY.animation({ duration: 0 })
    );
  }
}
