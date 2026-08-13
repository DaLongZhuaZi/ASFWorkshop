import { SteamArkHomePage } from '../steamArk/SteamArkHomePage';
import { SteamArkLog } from '../../steamServices';

const TAG: string = 'MainMenuPage';

/**
 * Compatibility page for stale deep links. Product navigation starts at SteamArkHomePage;
 * this legacy path intentionally renders the same product shell instead of NGF demos.
 */
@Entry
@Component
export struct NGFStarterMainMenuPage {
  aboutToAppear(): void {
    SteamArkLog.lifecycle(TAG, 'aboutToAppear');
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle(TAG, 'aboutToDisappear');
  }

  build(): void {
    SteamArkHomePage()
  }
}
