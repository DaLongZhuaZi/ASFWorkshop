import { NGFMaterialSurfaceTokens, ngfI18nManagerFacade, ngfVisualEffectsFacade } from 'ngf_framework';
import {
  SteamArkChatMessage,
  SteamArkChatContentKind,
  SteamArkChatContentParser,
  SteamArkChatContentSegment,
  SteamArkEmoticon,
  SteamArkFriendProfile,
  SteamArkLog,
  SteamArkSocialSnapshot,
  SteamArkSocialSnapshotListener,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkSocialService,
  steamArkStateService
} from '../../steamServices';
import { SteamArkTheme } from './SteamArkTheme';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';
import { SteamArkBrowserRequest, SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import {
  STEAM_ARK_FLOAT_ACCOUNT_KEY,
  STEAM_ARK_FLOAT_FRIEND_KEY,
  steamArkFloatingWindowCoordinator
} from './SteamArkFloatingWindowCoordinator';

@Entry
@Component
struct SteamArkChatFloatingPage {
  @State private accountId: string = '';
  @State private friendSteamId64: string = '';
  @State private friend: SteamArkFriendProfile | null = null;
  @State private messages: Array<SteamArkChatMessage> = [];
  @State private draft: string = '';
  @State private loading: boolean = true;
  @State private sending: boolean = false;
  @State private sendFailed: boolean = false;
  @State private contentVisible: boolean = false;
  @State private emoticons: Array<SteamArkEmoticon> = [];
  @State private pickerVisible: boolean = false;
  @State private pickerTab: string = 'emoticons';
  @State private toolNoticeVisible: boolean = false;
  @State private toolNotice: ResourceStr = $r('app.string.steam_float_chat_tool_notice');
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private closeTimer: number = -1;
  private lifecycleGeneration: number = 0;
  private isPageActive: boolean = false;
  private readonly socialListener: SteamArkSocialSnapshotListener = (snapshot: SteamArkSocialSnapshot): void => {
    if (snapshot.accountId === this.accountId) {
      this.resolveFriend(snapshot);
      this.messages = steamArkSocialService.getMessages(this.accountId, this.friendSteamId64);
    }
  };
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (this.isPageActive && snapshot.selectedAccountId !== this.accountId) {
      this.closeForAccountChange();
    }
  };

  aboutToAppear(): void {
    this.isPageActive = true;
    this.lifecycleGeneration++;
    this.contentVisible = false;
    this.accountId = AppStorage.get<string>(STEAM_ARK_FLOAT_ACCOUNT_KEY) ?? '';
    this.friendSteamId64 = AppStorage.get<string>(STEAM_ARK_FLOAT_FRIEND_KEY) ?? '';
    steamArkSocialService.subscribe('SteamArkChatFloatingPage', this.socialListener);
    steamArkStateService.subscribe('SteamArkChatFloatingPage', this.stateListener);
    this.resolveFriend(steamArkSocialService.restore(this.accountId));
    this.messages = steamArkSocialService.getMessages(this.accountId, this.friendSteamId64);
    this.emoticons = steamArkSocialService.getEmoticons(this.accountId);
    void this.loadConversation();
    void this.refreshEmoticons();
    this.getUIContext().animateTo({
      duration: SteamArkExperiencePolicy.FLOAT_WINDOW_ENTER_DURATION,
      curve: Curve.EaseOut
    }, (): void => {
      this.contentVisible = true;
    });
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.lifecycleGeneration++;
    steamArkSocialService.unsubscribe('SteamArkChatFloatingPage');
    steamArkStateService.unsubscribe('SteamArkChatFloatingPage');
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
  }

  build(): void {
    Column() {
      this.buildDragHandle()
      this.buildHeader()
      if (this.loading && this.messages.length <= 0) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color(SteamArkTheme.accent(this.isDarkMode))
          Text($r('app.string.steam_float_chat_loading'))
            .fontSize(13)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.messages.length <= 0) {
        this.buildEmptyConversation()
      } else {
        List({ space: 6 }) {
          ForEach(this.messages, (message: SteamArkChatMessage) => {
            ListItem() {
              this.buildMessage(message)
            }
          }, (message: SteamArkChatMessage): string => message.id)
        }
        .layoutWeight(1)
        .width('100%')
        .height(0)
        .padding({ left: 4, right: 4, top: 12, bottom: 12 })
        .scrollBar(BarState.Auto)
        .animation({ duration: SteamArkExperiencePolicy.CONTENT_REFRESH_DURATION, curve: Curve.EaseOut })
      }
      this.buildComposer()
      if (this.pickerVisible) {
        this.buildPicker()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareProminentBackgroundEffect(this.useSysMat))
    .borderRadius(24)
    .border({
      width: NGFMaterialSurfaceTokens.buildMaterialAwareBorderWidth(1, this.useSysMat),
      color: NGFMaterialSurfaceTokens.buildMaterialAwareBorderColor(
        SteamArkTheme.divider(this.isDarkMode), this.useSysMat)
    })
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForProminentPanel())
    .clip(true)
    .opacity(this.contentVisible ? 1 : 0.01)
    .translate({ y: this.contentVisible ? 0 : 16 })
    .animation({ duration: SteamArkExperiencePolicy.FLOAT_WINDOW_ENTER_DURATION, curve: Curve.EaseOut })
  }

  @Builder
  private buildDragHandle(): void {
    Row() {
      Column() {}
        .width(44)
        .height(5)
        .borderRadius(3)
        .backgroundColor(SteamArkTheme.textMuted(this.isDarkMode))
        .opacity(0.72)
    }
    .width('100%')
    .height(22)
    .justifyContent(FlexAlign.Center)
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        steamArkFloatingWindowCoordinator.startChatDrag();
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        steamArkFloatingWindowCoordinator.finishChatDrag();
      }
    })
  }

  @Builder
  private buildHeader(): void {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.friend !== null && this.friend.avatarUrl.length > 0) {
          Image(this.friend.avatarUrl)
            .width(48)
            .height(48)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
        } else {
          SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
            .fontSize(44)
            .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
        }
        if (this.friend !== null && this.friend.personaState > 0) {
          Column() {}
            .width(12)
            .height(12)
            .borderRadius(6)
            .backgroundColor(SteamArkTheme.success(this.isDarkMode))
            .border({ width: 2, color: SteamArkTheme.surfaceElevated(this.isDarkMode) })
        }
      }
      .width(48)
      .height(48)
      Column({ space: 2 }) {
        Text(this.friendName())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .maxLines(1)
        Text(this.friend !== null && this.friend.gameName.length > 0
          ? this.friend.gameName : $r('app.string.steam_float_chat_subtitle'))
          .fontSize(12)
          .fontColor(this.friend !== null && this.friend.personaState > 0
            ? SteamArkTheme.success(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
      }
      .width(40)
      .height(40)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .accessibilityText($r('app.string.steam_float_close'))
      .onClick((): void => {
        this.closeWithAnimation();
      })
    }
    .width('100%')
    .height(66)
    .padding({ left: 6, right: 2, bottom: 6 })
    .border({ width: { bottom: 1 }, color: SteamArkTheme.divider(this.isDarkMode) })
  }

  @Builder
  private buildEmptyConversation(): void {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column() {}
          .width(76)
          .height(76)
          .borderRadius(38)
          .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
            SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
          .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
          .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
        SymbolGlyph($r('sys.symbol.topic_message_fill'))
          .fontSize(32)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
      }
      .width(76)
      .height(76)
      Text($r('app.string.steam_float_chat_empty_title'))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text($r('app.string.steam_float_chat_empty_desc'))
        .width('82%')
        .fontSize(12)
        .lineHeight(18)
        .textAlign(TextAlign.Center)
        .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  private closeWithAnimation(): void {
    if (this.closeTimer >= 0) {
      return;
    }
    const closingAccountId: string = this.accountId;
    const closingFriendSteamId64: string = this.friendSteamId64;
    this.contentVisible = false;
    this.closeTimer = setTimeout((): void => {
      this.closeTimer = -1;
      void steamArkFloatingWindowCoordinator.closeChatForConversation(closingAccountId, closingFriendSteamId64);
    }, SteamArkExperiencePolicy.FLOAT_WINDOW_ENTER_DURATION);
  }

  @Builder
  private buildMessage(message: SteamArkChatMessage): void {
    Row() {
      if (message.outgoing) {
        Blank().layoutWeight(1)
      }
      if (message.outgoing) {
        Column({ space: 3 }) {
          this.buildMessageContent(message, true)
        }
        .alignItems(HorizontalAlign.End)
        .constraintSize({ maxWidth: '78%' })
        .padding({ left: 12, right: 12, top: 8, bottom: 7 })
        .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
        .borderRadius({ topLeft: 16, topRight: 5, bottomLeft: 16, bottomRight: 16 })
      } else {
        Column({ space: 3 }) {
          this.buildMessageContent(message, false)
        }
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ maxWidth: '78%' })
        .padding({ left: 12, right: 12, top: 8, bottom: 7 })
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
        .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
        .borderRadius({ topLeft: 5, topRight: 16, bottomLeft: 16, bottomRight: 16 })
        .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
      }
      if (!message.outgoing) {
        Blank().layoutWeight(1)
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  private buildMessageContent(message: SteamArkChatMessage, outgoing: boolean): void {
    if (SteamArkChatContentParser.emoticonName(message.message).length > 0) {
      Image(SteamArkChatContentParser.emoticonImageUrl(message.message))
        .width(44)
        .height(44)
        .objectFit(ImageFit.Contain)
    } else {
      Text() {
        ForEach(SteamArkChatContentParser.parse(message.message),
          (segment: SteamArkChatContentSegment): void => {
            if (segment.kind === SteamArkChatContentKind.LINK) {
              Span(segment.text)
                .fontColor(outgoing
                  ? SteamArkTheme.onAccent(this.isDarkMode) : SteamArkTheme.accentCyan(this.isDarkMode))
                .decoration({ type: TextDecorationType.Underline })
                .onClick((): void => {
                  this.openMessageUrl(segment.url)
                })
            } else {
              Span(segment.text)
                .fontColor(outgoing
                  ? SteamArkTheme.onAccent(this.isDarkMode) : SteamArkTheme.textPrimary(this.isDarkMode))
            }
          }, (segment: SteamArkChatContentSegment): string => segment.id)
      }
        .fontSize(13)
        .lineHeight(19)
        .fontColor(outgoing
          ? SteamArkTheme.onAccent(this.isDarkMode) : SteamArkTheme.textPrimary(this.isDarkMode))
    }
    Text(this.formatTime(message.timestamp))
      .fontSize(10)
      .opacity(0.72)
      .fontColor(outgoing
        ? SteamArkTheme.onAccent(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode))
  }

  @Builder
  private buildComposer(): void {
    Column({ space: 8 }) {
      if (this.sendFailed) {
        Row({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(15)
            .fontColor([SteamArkTheme.error(this.isDarkMode)])
          Text($r('app.string.steam_float_chat_send_failed'))
            .layoutWeight(1)
            .fontSize(12)
            .lineHeight(18)
            .fontColor(SteamArkTheme.error(this.isDarkMode))
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
        .borderRadius(10)
      }
      if (this.toolNoticeVisible) {
        Row({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(15)
            .fontColor([SteamArkTheme.accentCyan(this.isDarkMode)])
          Text(this.toolNotice)
            .layoutWeight(1)
            .fontSize(11)
            .lineHeight(16)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
          SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
        .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
        .borderRadius(10)
      }
      Row({ space: 6 }) {
        this.buildComposerTool($r('sys.symbol.face_smiling'), $r('app.string.steam_float_chat_tool_emoticons'), (): void => {
          this.openPicker('emoticons');
        })
        this.buildComposerTool($r('sys.symbol.stickers'), $r('app.string.steam_float_chat_tool_stickers'), (): void => {
          this.openPicker('stickers');
        })
        this.buildComposerTool($r('sys.symbol.wand_and_stars'), $r('app.string.steam_float_chat_tool_effects'), (): void => {
          this.openPicker('effects');
        })
        this.buildComposerTool($r('sys.symbol.paperclip'), $r('app.string.steam_float_chat_tool_image'), (): void => {
          this.openPicker('images');
        })
        this.buildComposerTool($r('sys.symbol.link'), $r('app.string.steam_float_chat_tool_trade'), (): void => {
          this.insertTradeLink();
        })
      }
      .width('100%')
      .height(34)
      .justifyContent(FlexAlign.Start)
      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: $r('app.string.steam_float_chat_placeholder') })
          .layoutWeight(1)
          .height(50)
          .fontSize(14)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
          .padding({ left: 14, right: 14 })
          .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
            SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
          .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
          .borderRadius(16)
          .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
          .onChange((value: string): void => {
            this.draft = value;
            if (value.trim().length > 0) {
              this.sendFailed = false;
            }
          })
          .onSubmit((): void => {
            void this.sendMessage();
          })
        Button({ type: ButtonType.Circle }) {
          if (this.sending) {
            LoadingProgress()
              .width(19)
              .height(19)
              .color(SteamArkTheme.onAccent(this.isDarkMode))
          } else {
            SymbolGlyph($r('sys.symbol.arrow_up'))
              .fontSize(20)
              .fontColor([this.draft.trim().length > 0
                ? SteamArkTheme.onAccent(this.isDarkMode)
                : SteamArkTheme.textMuted(this.isDarkMode)])
          }
        }
        .width(50)
        .height(50)
        .enabled(this.draft.trim().length > 0 && !this.sending)
        .backgroundColor(this.draft.trim().length > 0
          ? SteamArkTheme.accent(this.isDarkMode)
          : SteamArkTheme.surfaceControl(this.isDarkMode))
        .accessibilityText($r('app.string.steam_float_chat_send'))
        .onClick((): void => {
          void this.sendMessage();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 10, bottom: 2 })
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(16)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForFloatingControl())
  }

  @Builder
  private buildComposerTool(icon: Resource, title: Resource, action: () => void): void {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(icon)
        .fontSize(17)
        .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
    }
    .width(34)
    .height(34)
    .padding(0)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .accessibilityText(title)
    .onClick(action)
  }

  @Builder
  private buildPicker(): void {
    Column({ space: 8 }) {
      Row() {
        Text(this.pickerTitle())
          .layoutWeight(1)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(15)
            .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
        }
        .width(30)
        .height(30)
        .padding(0)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .accessibilityText($r('app.string.steam_float_chat_picker_close'))
        .onClick((): void => {
          this.pickerVisible = false;
        })
      }
      .width('100%')
      if (this.pickerTab === 'emoticons') {
        if (this.emoticons.length > 0) {
          Grid() {
            ForEach(this.emoticons, (emoticon: SteamArkEmoticon) => {
              GridItem() {
                Column({ space: 3 }) {
                  Image(emoticon.imageUrl)
                    .width(36)
                    .height(36)
                    .objectFit(ImageFit.Contain)
                  Text(emoticon.name)
                    .fontSize(9)
                    .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width(58)
                .height(58)
                .justifyContent(FlexAlign.Center)
                .onClick((): void => {
                  this.draft = this.draft + emoticon.toChatToken();
                  this.pickerVisible = false;
                })
              }
            }, (emoticon: SteamArkEmoticon): string => emoticon.name)
          }
          .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
          .rowsGap(5)
          .columnsGap(5)
          .width('100%')
          .height(128)
          .scrollBar(BarState.Auto)
        } else {
          Text($r('app.string.steam_float_chat_emoticons_empty'))
            .fontSize(12)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .width('100%')
            .textAlign(TextAlign.Center)
            .height(46)
        }
      } else {
        Column({ space: 10 }) {
          Text(this.pickerNotice())
            .fontSize(12)
            .lineHeight(18)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          Button($r('app.string.steam_float_chat_continue_in_steam'))
            .height(38)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
            .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
            .onClick((): void => {
              this.openSteamChatHandoff();
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceControl(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(14)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  private openPicker(tab: string): void {
    this.pickerTab = tab;
    this.pickerVisible = true;
    this.toolNoticeVisible = false;
  }

  private pickerTitle(): ResourceStr {
    if (this.pickerTab === 'stickers') {
      return $r('app.string.steam_float_chat_tool_stickers');
    }
    if (this.pickerTab === 'effects') {
      return $r('app.string.steam_float_chat_tool_effects');
    }
    if (this.pickerTab === 'images') {
      return $r('app.string.steam_float_chat_tool_image');
    }
    return $r('app.string.steam_float_chat_tool_emoticons');
  }

  private pickerNotice(): ResourceStr {
    if (this.pickerTab === 'stickers') {
      return $r('app.string.steam_float_chat_stickers_unavailable');
    }
    if (this.pickerTab === 'effects') {
      return $r('app.string.steam_float_chat_effects_unavailable');
    }
    if (this.pickerTab === 'images') {
      return $r('app.string.steam_float_chat_image_unavailable');
    }
    return $r('app.string.steam_float_chat_picker_empty');
  }

  private async refreshEmoticons(): Promise<void> {
    if (this.accountId.length <= 0) {
      return;
    }
    const accountId: string = this.accountId;
    const generation: number = this.lifecycleGeneration;
    try {
      const loaded: Array<SteamArkEmoticon> = await steamArkSocialService.loadEmoticons(accountId, true);
      if (this.isPageActive && this.lifecycleGeneration === generation && this.accountId === accountId) {
        this.emoticons = loaded;
      }
    } catch (error) {
      SteamArkLog.warn('ChatFloatingPage', 'emoticon refresh failed; account=' +
        SteamArkLog.accountId(accountId) + ', errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private insertTradeLink(): void {
    if (this.friend === null || this.friend.accountId32 <= 0) {
      this.toolNotice = $r('app.string.steam_float_chat_picker_empty');
      this.toolNoticeVisible = true;
      return;
    }
    const url: string = 'https://steamcommunity.com/tradeoffer/new/?partner=' +
      this.friend.accountId32.toString();
    const bbCode: string = '[url=' + url + ']' + url + '[/url]';
    if (this.draft.length > 0 && !this.draft.endsWith(' ')) {
      this.draft = this.draft + ' ';
    }
    this.draft = this.draft + bbCode;
    this.pickerVisible = false;
    this.toolNotice = $r('app.string.steam_float_chat_trade_inserted');
    this.toolNoticeVisible = true;
  }

  private openMessageUrl(url: string): void {
    const opened: boolean = SteamArkNavigationBridge.pushHomeRoute(
      SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(url)
    );
    if (opened) {
      this.closeWithAnimation();
    }
  }

  private openSteamChatHandoff(): void {
    const title: string = ngfI18nManagerFacade.resolveString($r('app.string.steam_float_chat_subtitle'));
    const opened: boolean = SteamArkNavigationBridge.pushHomeRoute(
      SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest('https://steamcommunity.com/chat/', title, 'steamcommunity.com')
    );
    if (opened) {
      this.pickerVisible = false;
      this.closeWithAnimation();
      return;
    }
    this.toolNotice = $r('app.string.steam_float_chat_browser_open_failed');
    this.toolNoticeVisible = true;
  }

  private async loadConversation(): Promise<void> {
    if (this.accountId.length <= 0 || this.friendSteamId64.length <= 0) {
      this.loading = false;
      return;
    }
    const accountId: string = this.accountId;
    const friendSteamId64: string = this.friendSteamId64;
    const generation: number = this.lifecycleGeneration;
    this.loading = true;
    try {
      const loaded: Array<SteamArkChatMessage> = await steamArkSocialService.loadConversation(
        accountId, friendSteamId64);
      if (!this.isCurrentConversation(accountId, friendSteamId64, generation)) {
        return;
      }
      this.messages = loaded;
      if (loaded.length > 0) {
        const last: SteamArkChatMessage = loaded[loaded.length - 1];
        await steamArkSocialService.acknowledge(accountId, friendSteamId64, last.timestamp);
      }
    } finally {
      if (this.isCurrentConversation(accountId, friendSteamId64, generation)) {
        this.loading = false;
      }
    }
  }

  private async sendMessage(): Promise<void> {
    const content: string = this.draft.trim();
    if (content.length <= 0 || this.sending) {
      return;
    }
    if (this.accountId.trim().length <= 0 || this.friendSteamId64.trim().length <= 0) {
      this.sendFailed = true;
      return;
    }
    const accountId: string = this.accountId;
    const friendSteamId64: string = this.friendSteamId64;
    const generation: number = this.lifecycleGeneration;
    if (steamArkStateService.getSnapshot().selectedAccountId !== accountId) {
      this.closeForAccountChange();
      return;
    }
    this.sendFailed = false;
    this.sending = true;
    try {
      await steamArkSocialService.sendMessage(accountId, friendSteamId64, content);
      if (!this.isCurrentConversation(accountId, friendSteamId64, generation)) {
        return;
      }
      this.draft = '';
      this.sendFailed = false;
      this.messages = steamArkSocialService.getMessages(accountId, friendSteamId64);
    } catch (error) {
      if (this.isCurrentConversation(accountId, friendSteamId64, generation)) {
        this.draft = content;
        this.sendFailed = true;
        SteamArkLog.warn('ChatFloatingPage', 'chat send failed in active conversation; account=' +
          SteamArkLog.accountId(accountId) + ', friend=' + SteamArkLog.steamId64(friendSteamId64) +
          ', errorType=' + SteamArkLog.errorKind(error));
      }
    } finally {
      if (this.isCurrentConversation(accountId, friendSteamId64, generation)) {
        this.sending = false;
      }
    }
  }

  private isCurrentConversation(accountId: string, friendSteamId64: string, generation: number): boolean {
    return this.isPageActive && this.lifecycleGeneration === generation &&
      this.accountId === accountId && this.friendSteamId64 === friendSteamId64;
  }

  private closeForAccountChange(): void {
    this.isPageActive = false;
    this.lifecycleGeneration++;
    this.contentVisible = false;
    void steamArkFloatingWindowCoordinator.closeChatForConversation(this.accountId, this.friendSteamId64);
  }

  private resolveFriend(snapshot: SteamArkSocialSnapshot): void {
    this.friend = null;
    for (let index: number = 0; index < snapshot.friends.length; index++) {
      if (snapshot.friends[index].steamId64 === this.friendSteamId64) {
        this.friend = snapshot.friends[index];
        return;
      }
    }
  }

  private friendName(): string {
    if (this.friend !== null && this.friend.displayName.length > 0) {
      return this.friend.displayName;
    }
    return this.friendSteamId64;
  }

  private formatTime(epochSeconds: number): string {
    if (epochSeconds <= 0) {
      return '';
    }
    const value: Date = new Date(epochSeconds * 1000);
    const hour: string = value.getHours().toString().padStart(2, '0');
    const minute: string = value.getMinutes().toString().padStart(2, '0');
    return hour + ':' + minute;
  }
}
