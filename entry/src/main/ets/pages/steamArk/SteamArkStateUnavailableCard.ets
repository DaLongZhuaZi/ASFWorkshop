import {
  NGFMaterialSurfaceTokens,
  ngfVisualEffectsFacade
} from 'ngf_framework';
import { SteamArkTheme } from './SteamArkTheme';

@Component
export struct SteamArkStateUnavailableCard {
  @Prop isDarkMode: boolean = false;
  @Prop useSysMat: boolean = true;

  build(): void {
    Row({ space: 12 }) {
      LoadingProgress()
        .width(26)
        .height(26)
        .color(SteamArkTheme.accent(this.isDarkMode));
      Column({ space: 6 }) {
        Text($r('app.string.steam_state_unavailable_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode));
        Text($r('app.string.steam_state_unavailable_desc'))
          .width('100%')
          .fontSize(13)
          .lineHeight(19)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode),
      this.useSysMat
    ))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .border({
      width: 1,
      color: SteamArkTheme.warning(this.isDarkMode)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel());
  }
}
