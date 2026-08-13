import { SteamArkLog } from '../../steamServices/SteamArkLogger';

const TAG: string = 'SteamArkWidget';
let storage = new LocalStorage();

@Entry(storage)
@Component
struct SteamArkWidgetCard {
  @LocalStorageProp('steamSessionState') sessionState: string = 'disconnected';
  @LocalStorageProp('steamFarmingState') farmingState: string = 'disabled';
  @LocalStorageProp('steamAccountCount') accountCount: string = '0';
  @LocalStorageProp('lastUpdate') lastUpdate: string = '--:--:--';

  aboutToAppear(): void {
    SteamArkLog.lifecycle(TAG, 'aboutToAppear');
  }

  aboutToDisappear(): void {
    SteamArkLog.lifecycle(TAG, 'aboutToDisappear');
  }

  build(): void {
    Column() {
      this.buildHeader()
      this.buildStatus()
      this.buildFooter()
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor($r('app.color.steam_ark_background'))
    .borderRadius(8)
  }

  @Builder
  private buildHeader(): void {
    Row() {
      Image($r('app.media.startIcon'))
        .width(20)
        .height(20)
        .margin({ right: 8 })
      Column({ space: 2 }) {
        Text($r('app.string.steam_widget_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.steam_ark_text_primary'))
        Text($r('app.string.steam_widget_desc'))
          .fontSize(9)
          .fontColor($r('app.color.steam_ark_text_muted'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button() {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(16)
          .fontColor([$r('app.color.steam_ark_accent_cyan')])
      }
      .width(32)
      .height(32)
      .padding(0)
      .backgroundColor($r('app.color.steam_ark_surface_control'))
      .borderRadius(8)
      .onClick((): void => {
        SteamArkLog.info(TAG, 'widget refresh requested');
        postCardAction(this, {
          action: 'message',
          params: { message: 'refresh' }
        });
      })
    }
    .width('100%')
    .height(38)
  }

  @Builder
  private buildStatus(): void {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        SymbolGlyph(this.sessionSymbol())
          .fontSize(24)
          .fontColor([this.sessionColor()])
        Column({ space: 3 }) {
          Text($r('app.string.steam_widget_session'))
            .fontSize(10)
            .fontColor($r('app.color.steam_ark_text_muted'))
          Text(this.sessionTitle())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.steam_ark_text_primary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row({ space: 8 }) {
        this.buildMetric($r('sys.symbol.person_2'), $r('app.string.steam_widget_account_count'), true)
        this.buildMetric($r('sys.symbol.play_round_triangle_fill'), $r('app.string.steam_widget_farming'), false)
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private buildMetric(icon: Resource, label: ResourceStr, isAccountMetric: boolean): void {
    Row({ space: 5 }) {
      SymbolGlyph(icon)
        .fontSize(14)
        .fontColor([$r('app.color.steam_ark_accent_cyan')])
      Column({ space: 2 }) {
        if (isAccountMetric) {
          if (this.accountCount === '0') {
            Text($r('app.string.steam_widget_no_accounts'))
              .fontSize(11)
              .fontColor($r('app.color.steam_ark_text_secondary'))
          } else {
            Row({ space: 3 }) {
              Text(this.accountCount)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.steam_ark_text_primary'))
              Text($r('app.string.steam_widget_account_count'))
                .fontSize(10)
                .fontColor($r('app.color.steam_ark_text_secondary'))
            }
          }
        } else {
          Text(this.farmingTitle())
            .fontSize(11)
            .fontColor(this.farmingColor())
        }
        Text(label)
          .fontSize(9)
          .fontColor($r('app.color.steam_ark_text_muted'))
      }
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
  }

  @Builder
  private buildFooter(): void {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        Text($r('app.string.steam_widget_last_update'))
          .fontSize(9)
          .fontColor($r('app.color.steam_ark_text_muted'))
        Text(this.lastUpdate)
          .fontSize(9)
          .fontColor($r('app.color.steam_ark_text_secondary'))
      }
      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.gamecontroller'))
            .fontSize(14)
            .fontColor([$r('app.color.steam_ark_text_primary')])
          Text($r('app.string.steam_widget_open'))
            .fontSize(11)
            .fontColor($r('app.color.steam_ark_text_primary'))
        }
      }
      .width('100%')
      .height(30)
      .padding(0)
      .backgroundColor($r('app.color.steam_ark_accent'))
      .borderRadius(8)
      .onClick((): void => {
        SteamArkLog.info(TAG, 'widget open requested');
        postCardAction(this, {
          action: 'router',
          abilityName: 'EntryAbility',
          params: { source: 'steam_ark_widget' }
        });
      })
    }
    .width('100%')
  }

  private sessionTitle(): ResourceStr {
    if (this.sessionState === 'logged_on') {
      return $r('app.string.steam_widget_session_logged_on');
    }
    if (this.sessionState === 'connected') {
      return $r('app.string.steam_widget_session_connected');
    }
    if (this.sessionState === 'connecting') {
      return $r('app.string.steam_widget_session_connecting');
    }
    if (this.sessionState === 'challenge') {
      return $r('app.string.steam_widget_session_challenge');
    }
    if (this.sessionState === 'error') {
      return $r('app.string.steam_widget_session_error');
    }
    return $r('app.string.steam_widget_session_disconnected');
  }

  private sessionSymbol(): Resource {
    if (this.sessionState === 'logged_on') {
      return $r('sys.symbol.person_badge_checkmark');
    }
    if (this.sessionState === 'connected') {
      return $r('sys.symbol.wifi');
    }
    if (this.sessionState === 'connecting') {
      return $r('sys.symbol.arrow_clockwise');
    }
    if (this.sessionState === 'challenge') {
      return $r('sys.symbol.qrcode');
    }
    if (this.sessionState === 'error') {
      return $r('sys.symbol.exclamationmark_triangle');
    }
    return $r('sys.symbol.info_circle');
  }

  private sessionColor(): ResourceColor {
    if (this.sessionState === 'logged_on') {
      return $r('app.color.steam_ark_success');
    }
    if (this.sessionState === 'connected' || this.sessionState === 'connecting') {
      return $r('app.color.steam_ark_accent_cyan');
    }
    if (this.sessionState === 'error') {
      return $r('app.color.steam_ark_error');
    }
    return $r('app.color.steam_ark_warning');
  }

  private farmingTitle(): ResourceStr {
    if (this.farmingState === 'running') {
      return $r('app.string.steam_widget_farming_running');
    }
    if (this.farmingState === 'idle') {
      return $r('app.string.steam_widget_farming_idle');
    }
    if (this.farmingState === 'paused') {
      return $r('app.string.steam_widget_farming_paused');
    }
    if (this.farmingState === 'error') {
      return $r('app.string.steam_widget_farming_error');
    }
    return $r('app.string.steam_widget_farming_disabled');
  }

  private farmingColor(): ResourceColor {
    if (this.farmingState === 'running') {
      return $r('app.color.steam_ark_success');
    }
    if (this.farmingState === 'error') {
      return $r('app.color.steam_ark_error');
    }
    if (this.farmingState === 'paused') {
      return $r('app.color.steam_ark_warning');
    }
    return $r('app.color.steam_ark_text_secondary');
  }
}
