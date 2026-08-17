import { SteamArkTheme } from './SteamArkTheme';

/**
 * Derives large cover URLs for the library grid and the game detail header.
 * Small capsule banners are upgraded to the 616x353 capsule and tall tile
 * posters keep their natural poster size; games without artwork fall back to
 * the standard capsule URL derived from the app id. Covers are never cropped:
 * every item sizes its container to the natural aspect ratio of the chosen
 * image, so the full artwork is always visible.
 */
export class SteamArkGameCoverUrl {
  static largeFor(appId: string, logoUrl: string, iconUrl: string): string {
    const logo: string = logoUrl.trim();
    if (logo.length > 0) {
      const wideCapsule: string = SteamArkGameCoverUrl.upgradeCapsule(logo);
      if (wideCapsule.length > 0) {
        return wideCapsule;
      }
      return logo;
    }
    if (iconUrl.trim().length > 0) {
      return iconUrl.trim();
    }
    return 'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/' +
      appId + '/capsule_616x353.jpg';
  }

  /**
   * Natural aspect ratio (width / height) of the cover URL chosen by
   * {@link largeFor}, used by the waterfall so the container exactly matches
   * the artwork and nothing needs to be cropped or letterboxed.
   */
  static aspectFor(appId: string, logoUrl: string, iconUrl: string): number {
    const logo: string = logoUrl.trim();
    if (logo.length > 0) {
      if (logo.indexOf('library_600x900.jpg') >= 0) {
        return 600 / 900;
      }
      if (logo.indexOf('capsule_616x353.jpg') >= 0) {
        return 616 / 353;
      }
      if (logo.indexOf('capsule_') >= 0) {
        return 616 / 353;
      }
      return 616 / 353;
    }
    if (iconUrl.trim().length > 0) {
      return 1;
    }
    return 616 / 353;
  }

  static upgradeCapsule(logo: string): string {
    const small: Array<string> = ['capsule_231x87.jpg', 'capsule_184x69.jpg', 'capsule_192x91.jpg'];
    for (let index = 0; index < small.length; index++) {
      const at: number = logo.indexOf(small[index]);
      if (at >= 0) {
        return logo.substring(0, at) + 'capsule_616x353.jpg' +
          logo.substring(at + small[index].length);
      }
    }
    if (logo.indexOf('capsule_616x353.jpg') >= 0) {
      return logo;
    }
    return '';
  }
}

/**
 * Large game cover with a graceful image chain: the derived cover is tried
 * first, then the original logo, then the icon, and finally a neutral
 * placeholder. The container matches the artwork's natural aspect ratio and
 * the image is fitted without cropping.
 */
@Component
export struct SteamArkGameCover {
  @Prop appId: string = '';
  @Prop primaryUrl: string = '';
  @Prop fallbackUrl: string = '';
  @Prop iconUrl: string = '';
  @Prop isDarkMode: boolean = false;
  @Prop cornerRadius: number = 10;
  @Prop coverAspectRatio: number = 616 / 353;
  @State currentUrl: string = '';

  aboutToAppear(): void {
    this.currentUrl = this.primaryUrl;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.currentUrl.length > 0) {
        Image(this.currentUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .onError((): void => {
            this.applyNextFallback();
          })
      } else {
        Column({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.gamecontroller'))
            .fontSize(26)
            .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
          Text(this.appId)
            .fontSize(9)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .aspectRatio(this.coverAspectRatio)
    .borderRadius(this.cornerRadius)
    .clip(true)
  }

  private applyNextFallback(): void {
    if (this.currentUrl === this.primaryUrl) {
      this.currentUrl = this.fallbackUrl.length > 0 ? this.fallbackUrl : this.iconUrl;
    } else if (this.currentUrl === this.fallbackUrl) {
      this.currentUrl = this.iconUrl;
    } else {
      this.currentUrl = '';
    }
  }
}
