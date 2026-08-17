import { HdsNavDestination } from '@kit.UIDesignKit';
import { NGFHdsTitleBarOptionsFactory } from 'ngf_framework';
import { SteamArkGameDetailRequest } from './SteamArkRoutes';
import { SteamArkGameDetailPage } from './SteamArkGameDetailPage';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkTheme } from './SteamArkTheme';
import { SteamArkLog } from '../../steamServices';

/**
 * Routed host for the game detail page so other panels (inventory detail,
 * badge detail) can open it through the home navigation stack. The embedded
 * SteamArkGameDetailPage stays unchanged; this host only supplies the
 * NavDestination chrome and the back behavior.
 */
@Component
export struct SteamArkGameDetailHostPage {
  @Prop request: SteamArkGameDetailRequest = new SteamArkGameDetailRequest();
  @State private pathStack: NavPathStack = new NavPathStack();
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  private generation: number = 0;

  aboutToAppear(): void {
    this.generation += 1;
    const currentGeneration: number = this.generation;
    SteamArkPageWindowSupport.loadDynamicTopInset(
      this.getUIContext(),
      108,
      SteamArkTheme.CONTENT_TOP_INSET,
      (inset: number): void => {
        if (this.generation === currentGeneration) {
          SteamArkLog.debug('GameDetailHost', 'top inset applied');
        }
      }
    );
    SteamArkPageWindowSupport.apply(SteamArkPageWindowName.SETTINGS);
  }

  aboutToDisappear(): void {
    this.generation += 1;
    SteamArkPageWindowSupport.restoreHome();
  }

  build() {
    HdsNavDestination() {
      SteamArkGameDetailPage({ request: this.request })
    }
      .titleBar(NGFHdsTitleBarOptionsFactory.buildOverContentWithTitleColors(
        this.request.name.length > 0 ? this.request.name : $r('app.string.steam_game_detail_host_title'),
        $r('app.string.steam_game_detail_host_subtitle'),
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
      })
  }
}
