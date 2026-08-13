import { SteamArkTheme } from './SteamArkTheme';

@Component
export struct SteamArkProfileBackground {
  @StorageProp('steam_ark_profile_background_url') private imageUrl: string = '';
  @StorageProp('steam_ark_profile_background_tiled') private tiled: boolean = false;
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;

  build(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column() {}
        .width('100%')
        .height('100%')
        .backgroundColor(SteamArkTheme.background(this.isDarkMode))

      if (this.imageUrl.length > 0) {
        if (this.tiled) {
          Image(this.imageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.None)
            .objectRepeat(ImageRepeat.XY)
        } else {
          Image(this.imageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .interpolation(ImageInterpolation.High)
        }

        Column() {}
          .width('100%')
          .height('100%')
          .backgroundColor(this.isDarkMode ? Color.Black : Color.White)
          // Keep the profile artwork visible. Content surfaces provide their own
          // contrast, so the page-wide veil only needs to separate text from the image.
          .opacity(this.isDarkMode ? 0.32 : 0.18)
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .hitTestBehavior(HitTestMode.None)
  }
}
