import { HdsNavDestination } from '@kit.UIDesignKit';
import {
  NGFControlStyleTokens,
  NGFHdsTitleBarOptionsFactory,
  NGFMaterialSurfaceTokens,
  ngfVisualEffectsFacade,
  resolveResourceString
} from 'ngf_framework';
import { SteamSessionState } from 'steam_core';
import {
  SteamArkChatMessage,
  SteamArkChatContentKind,
  SteamArkChatContentParser,
  SteamArkChatContentSegment,
  SteamArkChatReaction,
  SteamArkChatSession,
  SteamArkAccountSnapshot,
  SteamArkMessageCacheReadResult,
  SteamArkMessageCacheStore,
  SteamArkFriendProfile,
  SteamArkLog,
  SteamArkMessageCategory,
  SteamArkMessageItem,
  SteamArkSocialConnectionState,
  SteamArkSocialSnapshot,
  SteamArkSocialSnapshotListener,
  SteamArkSyncSnapshot,
  SteamArkSyncSnapshotListener,
  SteamArkStateListener,
  SteamArkStateSnapshot,
  steamArkSocialService,
  steamArkStateService,
  steamArkSyncCoordinator
} from '../../steamServices';
import { SteamArkBrowserRequest, SteamArkRouteName } from './SteamArkRoutes';
import { SteamArkNavigationBridge } from './SteamArkNavigationBridge';
import { SteamArkPageWindowName, SteamArkPageWindowSupport } from './SteamArkPageWindowSupport';
import { SteamArkProfileBackground } from './SteamArkProfileBackground';
import { SteamArkExperiencePolicy } from './SteamArkExperiencePolicy';
import { SteamArkTheme } from './SteamArkTheme';

const STEAM_ID64_BASE: string = '76561197960265728';
const SOCIAL_SILENT_REFRESH_INTERVAL_MS: number = 5 * 60 * 1000;

class SteamSocialSection {
  static readonly FRIENDS: number = 0;
  static readonly CHAT: number = 1;
  static readonly TRADES: number = 2;
}

@Component
export struct SteamArkSocialPage {
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private selectedSection: number = SteamSocialSection.FRIENDS;
  @State private selectedAccountId: string = '';
  @State private selectedAccountName: string = '';
  @State private sessionState: SteamSessionState = SteamSessionState.DISCONNECTED;
  @State private socialState: SteamArkSocialConnectionState = SteamArkSocialConnectionState.DISCONNECTED;
  @State private socialMetricsKnown: boolean = false;
  @State private friends: Array<SteamArkFriendProfile> = [];
  @State private sessions: Array<SteamArkChatSession> = [];
  @State private messages: Array<SteamArkChatMessage> = [];
  @State private trades: Array<SteamArkMessageItem> = [];
  @State private selectedFriendId: string = '';
  @State private searchText: string = '';
  @State private messageDraft: string = '';
  @State private stateReady: boolean = false;
  @State private syncing: boolean = false;
  @State private sending: boolean = false;
  @State private actionItemId: string = '';
  @State private statusMessage: ResourceStr = $r('app.string.steam_social_status_idle');
  @StorageProp('ngf_is_dark_mode') private isDarkMode: boolean = false;
  @StorageProp('steam_ark_profile_background_url') private profileBackgroundUrl: string = '';
  @StorageProp('ngf_visual_effects_should_use_system_material_surface') private useSysMat: boolean = true;
  private isPageActive: boolean = false;
  private lifecycleGeneration: number = 0;
  private accountScopeGeneration: number = 0;
  private refreshTimer: number = -1;
  private tradeCacheSyncAtEpochSeconds: number = 0;
  private readonly scroller: Scroller = new Scroller();
  private readonly stateListener: SteamArkStateListener = (snapshot: SteamArkStateSnapshot): void => {
    if (this.isPageActive) {
      this.applyStateSnapshot(snapshot);
    }
  };
  private readonly socialListener: SteamArkSocialSnapshotListener = (snapshot: SteamArkSocialSnapshot): void => {
    if (this.isPageActive && snapshot.accountId === this.selectedAccountId) {
      this.applySocialSnapshot(snapshot);
    }
  };
  private readonly syncListener: SteamArkSyncSnapshotListener = (_snapshot: SteamArkSyncSnapshot): void => {
    if (this.isPageActive && this.selectedSection === SteamSocialSection.TRADES &&
      this.selectedAccountId.length > 0) {
      this.applyCachedTrades(this.selectedAccountId);
    }
  };

  aboutToAppear(): void {
    this.isPageActive = true;
    this.lifecycleGeneration++;
    SteamArkPageWindowSupport.apply(SteamArkPageWindowName.HOME);
    steamArkStateService.subscribe('SteamArkSocialPage', this.stateListener);
    steamArkSocialService.subscribe('SteamArkSocialPage', this.socialListener);
    steamArkSyncCoordinator.subscribe('SteamArkSocialPage', this.syncListener);
    this.applyStateSnapshot(steamArkStateService.getSnapshot());
    this.startSilentRefreshTimer();
    void this.initialize();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.lifecycleGeneration++;
    steamArkStateService.unsubscribe('SteamArkSocialPage');
    steamArkSocialService.unsubscribe('SteamArkSocialPage');
    steamArkSyncCoordinator.unsubscribe('SteamArkSocialPage');
    this.stopSilentRefreshTimer();
    SteamArkPageWindowSupport.restoreHome();
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        SteamArkProfileBackground()
        Scroll(this.scroller) {
          Column({ space: 12 }) {
            this.buildHeaderCard()
            this.buildSectionTabs()
            if (!this.canUseSocial()) {
              this.buildUnavailableCard()
            } else if (this.selectedSection === SteamSocialSection.FRIENDS) {
              this.buildFriendsSection()
            } else if (this.selectedSection === SteamSocialSection.CHAT) {
              if (this.selectedFriendId.length > 0) {
                this.buildConversation()
              } else {
                this.buildSessionsSection()
              }
            } else {
              this.buildTradesSection()
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: SteamArkTheme.CONTENT_TOP_INSET, bottom: 92 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(SteamArkTheme.background(this.isDarkMode))
    }
    .titleBar(NGFHdsTitleBarOptionsFactory.buildOverContentWithTitleColors(
      $r('app.string.steam_social_title'),
      $r('app.string.steam_social_subtitle'),
      $r('app.color.background_transparent'),
      SteamArkTheme.textPrimary(this.isDarkMode),
      SteamArkTheme.textSecondary(this.isDarkMode),
      true,
      false
    ))
    .backgroundImage(this.profileBackgroundUrl)
    .backgroundImageSize(ImageSize.Cover)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.scroller])
    .onReady((context: NavDestinationContext): void => {
      this.pathStack = context.pathStack;
    });
  }

  @Builder
  private buildHeaderCard(): void {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.person_2'))
          .fontSize(24)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        Column({ space: 3 }) {
          Text(this.selectedAccountName.length > 0
            ? this.selectedAccountName : $r('app.string.steam_social_account_empty'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text(this.statusMessage)
            .fontSize(11)
            .fontColor(this.socialState === SteamArkSocialConnectionState.ERROR
              ? SteamArkTheme.error(this.isDarkMode) : SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.syncing) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(SteamArkTheme.accent(this.isDarkMode))
        } else {
          Button() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(18)
              .fontColor([SteamArkTheme.accent(this.isDarkMode)])
          }
          .width(40)
          .height(40)
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(this.canUseSocial())
          .onClick((): void => {
            void this.refreshAll(false);
          })
        }
      }
      .width('100%')
      Row({ space: 14 }) {
        this.buildMetric($r('app.string.steam_social_metric_friends'), this.friends.length,
          this.socialMetricsKnown)
        this.buildMetric($r('app.string.steam_social_metric_sessions'), this.sessions.length,
          this.socialMetricsKnown)
        this.buildMetric($r('app.string.steam_social_metric_unread'), this.unreadCount(),
          this.socialMetricsKnown)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwarePanelBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.PANEL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForPanel())
  }

  @Builder
  private buildMetric(label: ResourceStr, value: number, isKnown: boolean): void {
    Column({ space: 2 }) {
      Text(isKnown ? value.toString() : '--')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
      Text(label)
        .fontSize(10)
        .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
    }
    .layoutWeight(1)
  }

  @Builder
  private buildSectionTabs(): void {
    Row({ space: 4 }) {
      this.buildSectionTab($r('app.string.steam_social_tab_friends'), SteamSocialSection.FRIENDS)
      this.buildSectionTab($r('app.string.steam_social_tab_chat'), SteamSocialSection.CHAT)
      this.buildSectionTab($r('app.string.steam_social_tab_trades'), SteamSocialSection.TRADES)
    }
    .width('100%')
    .height(44)
  }

  @Builder
  private buildSectionTab(title: ResourceStr, section: number): void {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(this.selectedSection === section ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selectedSection === section
          ? SteamArkTheme.accent(this.isDarkMode) : SteamArkTheme.textSecondary(this.isDarkMode))
      Column() {}
        .width(this.selectedSection === section ? 34 : 8)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.selectedSection === section
          ? SteamArkTheme.accent(this.isDarkMode) : $r('app.color.background_transparent'))
        .animation({ duration: 220, curve: Curve.EaseOut })
    }
    .layoutWeight(1)
    .height(42)
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, (): void => {
        this.selectedSection = section;
        if (section !== SteamSocialSection.CHAT) {
          this.selectedFriendId = '';
          this.messages = [];
        }
      });
      if (section === SteamSocialSection.TRADES && this.trades.length <= 0) {
        void this.refreshTrades();
      }
    })
  }

  @Builder
  private buildFriendsSection(): void {
    Column({ space: 10 }) {
      TextInput({ text: this.searchText, placeholder: $r('app.string.steam_social_search_friends') })
        .width('100%')
        .height(NGFControlStyleTokens.NORMAL_BUTTON_HEIGHT)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
        .backgroundColor(SteamArkTheme.surface(this.isDarkMode))
        .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
        .onChange((value: string): void => {
          this.searchText = value;
        })
      if (this.visibleFriends().length > 0) {
        ForEach(this.visibleFriends(), (friend: SteamArkFriendProfile) => {
          this.buildFriendCard(friend)
        }, (friend: SteamArkFriendProfile): string => friend.steamId64)
      } else {
        this.buildEmptyCard($r('sys.symbol.person_2'), $r('app.string.steam_social_friends_empty'))
      }
    }
    .width('100%')
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: '8%' })))
  }

  @Builder
  private buildFriendCard(friend: SteamArkFriendProfile): void {
    Button() {
      Row({ space: 12 }) {
        this.buildAvatar(friend)
        Column({ space: 3 }) {
          Text(friend.displayName.length > 0 ? friend.displayName : friend.steamId64)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(1)
          Text(friend.gameName.length > 0 ? friend.gameName : this.personaLabel(friend.personaState))
            .fontSize(11)
            .fontColor(friend.gameName.length > 0 || friend.personaState > 0
              ? SteamArkTheme.success(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.message'))
          .fontSize(18)
          .fontColor([SteamArkTheme.accent(this.isDarkMode)])
      }
      .width('100%')
    }
    .width('100%')
    .height(68)
    .padding({ left: 12, right: 12 })
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
    .onClick((): void => {
      this.openConversation(friend.steamId64)
    })
  }

  @Builder
  private buildAvatar(friend: SteamArkFriendProfile): void {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (friend.avatarUrl.length > 0) {
        Image(friend.avatarUrl)
          .width(44)
          .height(44)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
      } else {
        SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
          .fontSize(38)
          .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
      }
      Column() {}
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor(friend.personaState > 0
          ? SteamArkTheme.success(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode))
        .border({ width: 2, color: SteamArkTheme.surface(this.isDarkMode) })
    }
    .width(46)
    .height(46)
  }

  @Builder
  private buildSessionsSection(): void {
    Column({ space: 10 }) {
      if (this.sessions.length > 0) {
        ForEach(this.sessions, (session: SteamArkChatSession) => {
          this.buildSessionCard(session)
        }, (session: SteamArkChatSession): string => session.friendSteamId64)
      } else {
        this.buildEmptyCard($r('sys.symbol.message'), $r('app.string.steam_social_sessions_empty'))
      }
    }
    .width('100%')
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: '8%' })))
  }

  @Builder
  private buildSessionCard(session: SteamArkChatSession): void {
    Row({ space: 12 }) {
      this.buildAvatar(this.friendForId(session.friendSteamId64))
      Column({ space: 4 }) {
        Text(this.friendName(session.friendSteamId64))
          .fontSize(14)
          .fontWeight(session.unreadCount > 0 ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Row({ space: 6 }) {
          Text(this.lastMessagePreview(session.friendSteamId64))
            .layoutWeight(1)
            .fontSize(11)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (session.unreadCount > 0) {
            Text(session.unreadCount.toString())
              .fontSize(10)
              .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
              .borderRadius(10)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(17)
        .fontColor([SteamArkTheme.textMuted(this.isDarkMode)])
    }
    .width('100%')
    .padding(12)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
    .onClick((): void => {
      this.openConversation(session.friendSteamId64)
    })
  }

  @Builder
  private buildConversation(): void {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(18)
            .fontColor([SteamArkTheme.textPrimary(this.isDarkMode)])
        }
        .width(40)
        .height(40)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .onClick((): void => {
          this.selectedFriendId = '';
          this.messages = [];
        })
        this.buildAvatar(this.friendForId(this.selectedFriendId))
        Column({ space: 2 }) {
          Text(this.friendName(this.selectedFriendId))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          Text(this.personaLabel(this.friendForId(this.selectedFriendId).personaState))
            .fontSize(10)
            .fontColor(SteamArkTheme.textMuted(this.isDarkMode))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button() {
          SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
            .fontSize(18)
            .fontColor([SteamArkTheme.accent(this.isDarkMode)])
        }
        .width(40)
        .height(40)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .onClick((): void => {
          this.openProfile(this.selectedFriendId)
        })
      }
      .width('100%')
      if (this.isSelectedSessionSuspicious()) {
        this.buildSuspiciousSessionNotice()
      }
      if (this.messages.length >= 100) {
        Button($r('app.string.steam_social_load_older'))
          .width('100%')
          .height(36)
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => {
            void this.loadConversation(true)
          })
      }
      if (this.messages.length > 0) {
        ForEach(this.messages, (message: SteamArkChatMessage) => {
          this.buildMessageBubble(message)
        }, (message: SteamArkChatMessage): string => message.id)
      } else if (this.syncing) {
        this.buildEmptyCard($r('sys.symbol.message'), $r('app.string.steam_social_loading_messages'))
      } else {
        this.buildEmptyCard($r('sys.symbol.message'), $r('app.string.steam_social_messages_empty'))
      }
      Row({ space: 8 }) {
        TextInput({ text: this.messageDraft, placeholder: $r('app.string.steam_social_message_placeholder') })
          .layoutWeight(1)
          .height(44)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
          .placeholderColor(SteamArkTheme.textMuted(this.isDarkMode))
          .backgroundColor(SteamArkTheme.surface(this.isDarkMode))
          .borderRadius(NGFControlStyleTokens.FORM_CONTROL_RADIUS)
          .onChange((value: string): void => {
            this.messageDraft = value;
          })
          .onSubmit((): void => {
            void this.sendMessage();
          })
        Button() {
          if (this.sending) {
            LoadingProgress().width(18).height(18).color(SteamArkTheme.onAccent(this.isDarkMode))
          } else {
            SymbolGlyph($r('sys.symbol.arrow_up'))
              .fontSize(18)
              .fontColor([SteamArkTheme.onAccent(this.isDarkMode)])
          }
        }
        .width(44)
        .height(44)
        .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
        .enabled(this.messageDraft.trim().length > 0 && !this.sending)
        .onClick((): void => {
          void this.sendMessage();
        })
      }
      .width('100%')
    }
    .width('100%')
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: '8%' })))
  }

  @Builder
  private buildMessageBubble(message: SteamArkChatMessage): void {
    Row() {
      if (message.outgoing) {
        Blank().layoutWeight(1)
      }
      Column({ space: 3 }) {
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
                    .fontColor(message.outgoing
                      ? SteamArkTheme.onAccent(this.isDarkMode) : SteamArkTheme.accentCyan(this.isDarkMode))
                    .decoration({ type: TextDecorationType.Underline })
                    .onClick((): void => {
                      this.openUrl(segment.url)
                    })
                } else {
                  Span(segment.text)
                    .fontColor(message.outgoing
                      ? SteamArkTheme.onAccent(this.isDarkMode) : SteamArkTheme.textPrimary(this.isDarkMode))
                }
              }, (segment: SteamArkChatContentSegment): string => segment.id)
          }
            .fontSize(13)
            .lineHeight(18)
            .fontColor(message.outgoing
              ? SteamArkTheme.onAccent(this.isDarkMode) : SteamArkTheme.textPrimary(this.isDarkMode))
        }
        Text(this.formatTime(message.timestamp))
          .fontSize(9)
          .fontColor(message.outgoing
            ? SteamArkTheme.onAccent(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode))
          .opacity(0.72)
        if (message.reactions.length > 0) {
          Row({ space: 4 }) {
            ForEach(message.reactions, (reaction: SteamArkChatReaction) => {
              this.buildReactionChip(message, reaction)
            }, (reaction: SteamArkChatReaction): string =>
              reaction.reactionType.toString() + ':' + reaction.reaction)
          }
        }
        if (!message.outgoing) {
          Button($r('app.string.steam_social_report_message'))
            .height(28)
            .fontSize(10)
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontColor(message.outgoing
              ? SteamArkTheme.onAccent(this.isDarkMode) : SteamArkTheme.textMuted(this.isDarkMode))
            .onClick((): void => {
              this.confirmReportMessage(message)
            })
        }
      }
      .alignItems(message.outgoing ? HorizontalAlign.End : HorizontalAlign.Start)
      .constraintSize({ maxWidth: '78%' })
      .padding({ left: 12, right: 12, top: 8, bottom: 7 })
      .backgroundColor(message.outgoing
        ? SteamArkTheme.accent(this.isDarkMode) : SteamArkTheme.surface(this.isDarkMode))
      .borderRadius(8)
      if (!message.outgoing) {
        Blank().layoutWeight(1)
      }
    }
    .width('100%')
  }

  @Builder
  private buildReactionChip(message: SteamArkChatMessage, reaction: SteamArkChatReaction): void {
    Button(this.reactionLabel(reaction))
      .height(28)
      .padding({ left: 8, right: 8 })
      .fontSize(10)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .fontColor(this.hasCurrentUserReacted(reaction)
        ? SteamArkTheme.accent(this.isDarkMode) : SteamArkTheme.textSecondary(this.isDarkMode))
      .backgroundColor(SteamArkTheme.surfaceElevated(this.isDarkMode))
      .borderRadius(8)
      .onClick((): void => {
        void this.toggleReaction(message, reaction)
      })
  }

  @Builder
  private buildSuspiciousSessionNotice(): void {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(20)
        .fontColor([SteamArkTheme.warning(this.isDarkMode)])
      Column({ space: 3 }) {
        Text($r('app.string.steam_social_suspicious_title'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        Text($r('app.string.steam_social_suspicious_message'))
          .fontSize(10)
          .lineHeight(15)
          .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button($r('app.string.steam_social_suspicious_dismiss'))
        .height(34)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .onClick((): void => {
          void this.dismissSuspiciousSessionNotice()
        })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surfaceElevated(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildTradesSection(): void {
    Column({ space: 10 }) {
      if (this.trades.length > 0) {
        ForEach(this.trades, (item: SteamArkMessageItem) => {
          this.buildTradeCard(item)
        }, (item: SteamArkMessageItem): string => item.id)
      } else if (this.syncing) {
        this.buildEmptyCard($r('sys.symbol.arrow_left_arrow_right'),
          $r('app.string.steam_social_loading_trades'))
      } else {
        this.buildEmptyCard($r('sys.symbol.arrow_left_arrow_right'),
          $r('app.string.steam_social_trades_empty'))
      }
    }
    .width('100%')
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: '8%' })))
  }

  @Builder
  private buildTradeCard(item: SteamArkMessageItem): void {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        if (item.imageUrl.length > 0) {
          Image(item.imageUrl)
            .width(58)
            .height(58)
            .borderRadius(6)
            .objectFit(ImageFit.Contain)
        } else {
          SymbolGlyph($r('sys.symbol.arrow_left_arrow_right'))
            .fontSize(25)
            .fontColor([SteamArkTheme.success(this.isDarkMode)])
        }
        Column({ space: 4 }) {
          Text(item.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
            .maxLines(2)
          Text(item.body)
            .fontSize(11)
            .lineHeight(16)
            .fontColor(SteamArkTheme.textSecondary(this.isDarkMode))
            .maxLines(3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      Row({ space: 8 }) {
        Button($r('app.string.steam_social_trade_view'))
          .layoutWeight(1)
          .height(36)
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => {
            this.openUrl(item.url, item.title)
          })
        if (item.tradeOfferId.length > 0) {
          Button($r('app.string.steam_trade_open_in_browser'))
            .layoutWeight(1)
            .height(36)
            .enabled(this.actionItemId.length <= 0)
            .backgroundColor(SteamArkTheme.accent(this.isDarkMode))
            .fontColor(SteamArkTheme.onAccent(this.isDarkMode))
            .onClick((): void => {
              this.confirmTradeAction(item)
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  @Builder
  private buildUnavailableCard(): void {
    this.buildEmptyCard($r('sys.symbol.exclamationmark_circle'),
      this.stateReady ? $r('app.string.steam_social_session_required') :
        $r('app.string.steam_social_state_loading'))
  }

  @Builder
  private buildEmptyCard(icon: Resource, message: ResourceStr): void {
    Column({ space: 8 }) {
      if (this.syncing) {
        LoadingProgress()
          .width(30)
          .height(30)
          .color(SteamArkTheme.accent(this.isDarkMode))
      } else {
        SymbolGlyph(icon)
          .fontSize(28)
          .fontColor([SteamArkTheme.textSecondary(this.isDarkMode)])
      }
      Text(message)
        .fontSize(14)
        .lineHeight(20)
        .fontColor(SteamArkTheme.textPrimary(this.isDarkMode))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(24)
    .backgroundColor(NGFMaterialSurfaceTokens.buildMaterialAwareSurfaceBackground(
      SteamArkTheme.surface(this.isDarkMode), this.useSysMat))
    .backgroundEffect(NGFMaterialSurfaceTokens.buildMaterialAwareControlBackgroundEffect(this.useSysMat))
    .borderRadius(NGFMaterialSurfaceTokens.CONTROL_RADIUS)
    .systemMaterial(ngfVisualEffectsFacade.buildSystemMaterialForLightEffectControl())
  }

  private async initialize(): Promise<void> {
    const generation: number = this.lifecycleGeneration;
    try {
      await steamArkStateService.initialize();
      if (this.isPageActive && this.lifecycleGeneration === generation) {
        this.applyStateSnapshot(steamArkStateService.getSnapshot());
      }
    } catch (error) {
      SteamArkLog.warn('SocialPage', 'state initialization failed; errorType=' + SteamArkLog.errorKind(error));
    }
  }

  private startSilentRefreshTimer(): void {
    this.stopSilentRefreshTimer();
    this.refreshTimer = setInterval((): void => {
      if (this.isPageActive && this.canUseSocial() && !this.syncing) {
        void this.refreshAll(true);
      }
    }, SOCIAL_SILENT_REFRESH_INTERVAL_MS);
  }

  private stopSilentRefreshTimer(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private applyStateSnapshot(snapshot: SteamArkStateSnapshot): void {
    this.stateReady = snapshot.initialized;
    const previousId: string = this.selectedAccountId;
    const selected = steamArkStateService.getSelectedAccount();
    const nextAccountId: string = selected === null ? '' : selected.profile.accountId;
    const accountChanged: boolean = previousId !== nextAccountId;
    if (accountChanged) {
      this.accountScopeGeneration++;
      this.clearAccountScopedState();
    }
    if (selected === null) {
      this.selectedAccountId = '';
      this.selectedAccountName = '';
      this.sessionState = SteamSessionState.DISCONNECTED;
      return;
    }
    this.selectedAccountId = nextAccountId;
    this.selectedAccountName = selected.profile.displayName.length > 0
      ? selected.profile.displayName : selected.profile.accountId;
    this.sessionState = selected.session.state;
    if (accountChanged) {
      this.applySocialSnapshot(steamArkSocialService.restore(this.selectedAccountId));
    }
    if (this.canUseSocial() && (accountChanged ||
      this.socialState === SteamArkSocialConnectionState.DISCONNECTED)) {
      void this.refreshAll(true);
    }
  }

  private applySocialSnapshot(snapshot: SteamArkSocialSnapshot): void {
    if (snapshot.accountId !== this.selectedAccountId) {
      return;
    }
    this.socialState = snapshot.state;
    this.socialMetricsKnown = snapshot.updatedAtEpochSeconds > 0;
    this.friends = snapshot.friends.slice();
    this.sessions = snapshot.sessions.slice();
    if (this.selectedFriendId.length > 0) {
      this.messages = steamArkSocialService.getMessages(this.selectedAccountId, this.selectedFriendId);
    }
    if (snapshot.state === SteamArkSocialConnectionState.CONNECTING) {
      this.statusMessage = $r('app.string.steam_social_status_connecting');
    } else if (snapshot.state === SteamArkSocialConnectionState.CONNECTED) {
      this.statusMessage = snapshot.errorMessage.length > 0
        ? snapshot.errorMessage : $r('app.string.steam_social_status_connected');
    } else if (snapshot.state === SteamArkSocialConnectionState.ERROR) {
      this.statusMessage = snapshot.errorMessage.length > 0
        ? snapshot.errorMessage : $r('app.string.steam_social_status_failed');
    }
  }

  private async refreshAll(silent: boolean): Promise<void> {
    if (!this.canUseSocial() || this.syncing) {
      return;
    }
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    const accountId: string = this.selectedAccountId;
    this.syncing = true;
    if (!silent) {
      this.statusMessage = $r('app.string.steam_social_status_connecting');
    }
    try {
      const snapshot: SteamArkSocialSnapshot = silent
        ? await steamArkSocialService.connectAndSyncIfStale(
          accountId,
          Math.floor(SteamArkExperiencePolicy.SOCIAL_CACHE_FRESH_MS / 1000)
        )
        : await steamArkSocialService.connectAndSync(accountId);
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.applySocialSnapshot(snapshot);
        if (this.selectedSection === SteamSocialSection.TRADES) {
          await this.refreshTradesForScope(accountId, lifecycleGeneration, accountScopeGeneration);
        }
      }
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.statusMessage = error instanceof Error ? error.message :
          $r('app.string.steam_social_status_failed');
      }
      SteamArkLog.warn('SocialPage', 'social refresh failed; account=' + SteamArkLog.accountId(accountId) +
        ', errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.syncing = false;
      }
    }
  }

  private async refreshTrades(): Promise<void> {
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    const accountId: string = this.selectedAccountId;
    await this.refreshTradesForScope(accountId, lifecycleGeneration, accountScopeGeneration);
  }

  private async refreshTradesForScope(accountId: string, lifecycleGeneration: number,
    accountScopeGeneration: number): Promise<void> {
    if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration) || !this.canUseSocial()) {
      return;
    }
    const ownsSyncIndicator: boolean = !this.syncing;
    if (ownsSyncIndicator) {
      this.syncing = true;
    }
    this.applyCachedTrades(accountId);
    try {
      await steamArkSyncCoordinator.requestAccountSync(accountId, 'social_trades');
      if (!this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        return;
      }
      this.applyCachedTrades(accountId);
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.statusMessage = $r('app.string.steam_social_status_failed');
      }
      SteamArkLog.warn('SocialPage', 'trade refresh failed; errorType=' + SteamArkLog.errorKind(error));
    } finally {
      if (ownsSyncIndicator && this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.syncing = false;
      }
    }
  }

  private applyCachedTrades(accountId: string): void {
    const cached: SteamArkMessageCacheReadResult = SteamArkMessageCacheStore.readMessages(accountId);
    if (!cached.valid || cached.syncedAtEpochSeconds <= this.tradeCacheSyncAtEpochSeconds) {
      return;
    }
    const values: Array<SteamArkMessageItem> = [];
    for (let index: number = 0; index < cached.items.length; index++) {
      const item: SteamArkMessageItem = cached.items[index];
      // Trade notifications share the message feed; only real offers belong here.
      if (item.category === SteamArkMessageCategory.TRADE && item.tradeOfferId.length > 0) {
        values.push(item);
      }
    }
    this.trades = values;
    this.tradeCacheSyncAtEpochSeconds = cached.syncedAtEpochSeconds;
  }

  private openConversation(friendSteamId64: string): void {
    this.selectedSection = SteamSocialSection.CHAT;
    this.selectedFriendId = friendSteamId64;
    this.messages = steamArkSocialService.getMessages(this.selectedAccountId, friendSteamId64);
    void this.loadConversation(false);
  }

  private async loadConversation(loadOlder: boolean): Promise<void> {
    if (this.selectedFriendId.length <= 0 || this.syncing) {
      return;
    }
    const friendSteamId64: string = this.selectedFriendId;
    const accountId: string = this.selectedAccountId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    this.syncing = true;
    try {
      const values: Array<SteamArkChatMessage> = await steamArkSocialService.loadConversation(
        accountId, friendSteamId64, loadOlder);
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration) &&
        this.selectedFriendId === friendSteamId64) {
        this.messages = values;
        if (values.length > 0) {
          await steamArkSocialService.acknowledge(accountId, friendSteamId64,
            values[values.length - 1].timestamp);
        }
      }
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.statusMessage = error instanceof Error ? error.message :
          $r('app.string.steam_social_status_failed');
      }
    } finally {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.syncing = false;
      }
    }
  }

  private async sendMessage(): Promise<void> {
    const content: string = this.messageDraft.trim();
    if (content.length <= 0 || this.selectedFriendId.length <= 0 || this.sending) {
      return;
    }
    const accountId: string = this.selectedAccountId;
    const friendSteamId64: string = this.selectedFriendId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    this.sending = true;
    try {
      await steamArkSocialService.sendMessage(accountId, friendSteamId64, content);
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration) &&
        this.selectedFriendId === friendSteamId64) {
        this.messageDraft = '';
        this.messages = steamArkSocialService.getMessages(accountId, friendSteamId64);
      }
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.statusMessage = error instanceof Error ? error.message :
          $r('app.string.steam_social_send_failed');
      }
    } finally {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration)) {
        this.sending = false;
      }
    }
  }

  private async toggleReaction(message: SteamArkChatMessage, reaction: SteamArkChatReaction): Promise<void> {
    if (this.selectedAccountId.length <= 0 || this.selectedFriendId.length <= 0) {
      return;
    }
    const accountId: string = this.selectedAccountId;
    const friendSteamId64: string = this.selectedFriendId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    try {
      await steamArkSocialService.updateReaction(accountId, friendSteamId64,
        message.timestamp, message.ordinal, reaction.reactionType, reaction.reaction,
        !this.hasCurrentUserReacted(reaction));
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration) &&
        this.selectedFriendId === friendSteamId64) {
        this.statusMessage = $r('app.string.steam_social_reaction_updated');
      }
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration) &&
        this.selectedFriendId === friendSteamId64) {
        this.statusMessage = error instanceof Error ? error.message :
          $r('app.string.steam_social_reaction_failed');
      }
    }
  }

  private async dismissSuspiciousSessionNotice(): Promise<void> {
    if (this.selectedAccountId.length <= 0 || this.selectedFriendId.length <= 0) {
      return;
    }
    const accountId: string = this.selectedAccountId;
    const friendSteamId64: string = this.selectedFriendId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    try {
      await steamArkSocialService.dismissSessionNotice(accountId, friendSteamId64, 1);
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration) &&
        this.selectedFriendId === friendSteamId64) {
        this.sessions = steamArkSocialService.getSnapshot(accountId).sessions;
        this.statusMessage = $r('app.string.steam_social_suspicious_dismissed');
      }
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration) &&
        this.selectedFriendId === friendSteamId64) {
        this.statusMessage = error instanceof Error ? error.message :
          $r('app.string.steam_social_status_failed');
      }
    }
  }

  private confirmReportMessage(message: SteamArkChatMessage): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.steam_social_report_title'),
      message: $r('app.string.steam_social_report_confirm'),
      primaryButton: {
        value: $r('app.string.steam_social_report_message'),
        action: (): void => {
          void this.performReportMessage(message);
        }
      },
      secondaryButton: {
        value: $r('app.string.steam_accounts_cancel'),
        action: (): void => {}
      }
    });
  }

  private async performReportMessage(message: SteamArkChatMessage): Promise<void> {
    const account: SteamArkAccountSnapshot | null = steamArkStateService.getSelectedAccount();
    if (account === null || this.selectedFriendId.length <= 0) {
      return;
    }
    const accountId: string = this.selectedAccountId;
    const friendSteamId64: string = this.selectedFriendId;
    const lifecycleGeneration: number = this.lifecycleGeneration;
    const accountScopeGeneration: number = this.accountScopeGeneration;
    if (account.profile.accountId !== accountId) {
      return;
    }
    try {
      await steamArkSocialService.reportMessage(accountId, friendSteamId64,
        account.profile.steamId64, message.timestamp, message.ordinal, 2, '');
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration) &&
        this.selectedFriendId === friendSteamId64) {
        this.statusMessage = $r('app.string.steam_social_report_success');
      }
    } catch (error) {
      if (this.isCurrent(lifecycleGeneration, accountId, accountScopeGeneration) &&
        this.selectedFriendId === friendSteamId64) {
        this.statusMessage = error instanceof Error ? error.message :
          $r('app.string.steam_social_report_failed');
      }
    }
  }

  private confirmTradeAction(item: SteamArkMessageItem): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.steam_trade_browser_handoff_title'),
      message: $r('app.string.steam_trade_browser_handoff_message'),
      primaryButton: {
        value: $r('app.string.steam_trade_open_in_browser'),
        action: (): void => {
          void this.performTradeAction(item);
        }
      },
      secondaryButton: {
        value: $r('app.string.steam_accounts_cancel'),
        action: (): void => {}
      }
    });
  }

  private async performTradeAction(item: SteamArkMessageItem): Promise<void> {
    const offerId: string = item.tradeOfferId.trim();
    const itemUrl: string = item.url.trim();
    const url: string = itemUrl.length > 0 ? itemUrl : offerId.length > 0
      ? 'https://steamcommunity.com/tradeoffer/' + offerId + '/'
      : 'https://steamcommunity.com/my/tradeoffers/';
    this.openUrl(url, 'Steam');
  }

  private visibleFriends(): Array<SteamArkFriendProfile> {
    const query: string = this.searchText.trim().toLowerCase();
    if (query.length <= 0) {
      return this.friends;
    }
    const values: Array<SteamArkFriendProfile> = [];
    for (let index: number = 0; index < this.friends.length; index++) {
      const friend: SteamArkFriendProfile = this.friends[index];
      if (friend.displayName.toLowerCase().includes(query) || friend.steamId64.includes(query)) {
        values.push(friend);
      }
    }
    return values;
  }

  private friendForId(steamId64: string): SteamArkFriendProfile {
    for (let index: number = 0; index < this.friends.length; index++) {
      if (this.friends[index].steamId64 === steamId64) {
        return this.friends[index];
      }
    }
    return new SteamArkFriendProfile(steamId64, 0, steamId64, '',
      'https://steamcommunity.com/profiles/' + steamId64 + '/', 0, '', '', 0, 0);
  }

  private friendName(steamId64: string): string {
    return this.friendForId(steamId64).displayName;
  }

  private isSelectedSessionSuspicious(): boolean {
    for (let index: number = 0; index < this.sessions.length; index++) {
      if (this.sessions[index].friendSteamId64 === this.selectedFriendId) {
        return this.sessions[index].suspicious;
      }
    }
    return false;
  }

  private reactionLabel(reaction: SteamArkChatReaction): string {
    const name: string = reaction.reaction.length > 0
      ? reaction.reaction : reaction.reactionType.toString();
    return name + ' ' + reaction.reactorAccountIds.length.toString();
  }

  private hasCurrentUserReacted(reaction: SteamArkChatReaction): boolean {
    const account: SteamArkAccountSnapshot | null = steamArkStateService.getSelectedAccount();
    if (account === null) {
      return false;
    }
    const accountId32: number = this.steamId64ToAccountId(account.profile.steamId64);
    return reaction.reactorAccountIds.includes(accountId32);
  }

  private steamId64ToAccountId(steamId64: string): number {
    if (steamId64.length !== STEAM_ID64_BASE.length || steamId64 < STEAM_ID64_BASE) {
      return 0;
    }
    let borrow: number = 0;
    let result: string = '';
    for (let index: number = steamId64.length - 1; index >= 0; index--) {
      let digit: number = steamId64.charCodeAt(index) - 48 -
        (STEAM_ID64_BASE.charCodeAt(index) - 48) - borrow;
      if (digit < 0) {
        digit += 10;
        borrow = 1;
      } else {
        borrow = 0;
      }
      result = String(digit) + result;
    }
    const parsed: number = Number(result);
    return Number.isSafeInteger(parsed) && parsed >= 0 && parsed <= 4294967295 ? parsed : 0;
  }

  private lastMessagePreview(friendSteamId64: string): ResourceStr {
    const values: Array<SteamArkChatMessage> = steamArkSocialService.getMessages(
      this.selectedAccountId, friendSteamId64);
    return values.length > 0 ? values[values.length - 1].message :
      $r('app.string.steam_social_open_conversation');
  }

  private personaLabel(state: number): ResourceStr {
    if (state === 1) return $r('app.string.steam_social_persona_online');
    if (state === 2) return $r('app.string.steam_social_persona_busy');
    if (state === 3) return $r('app.string.steam_social_persona_away');
    if (state === 4) return $r('app.string.steam_social_persona_snooze');
    if (state === 5) return $r('app.string.steam_social_persona_trade');
    if (state === 6) return $r('app.string.steam_social_persona_play');
    return $r('app.string.steam_social_persona_offline');
  }

  private unreadCount(): number {
    let total: number = 0;
    for (let index: number = 0; index < this.sessions.length; index++) {
      total += this.sessions[index].unreadCount;
    }
    return total;
  }

  private formatTime(epochSeconds: number): string {
    if (epochSeconds <= 0) {
      return '';
    }
    const date: Date = new Date(epochSeconds * 1000);
    const hours: string = date.getHours().toString().padStart(2, '0');
    const minutes: string = date.getMinutes().toString().padStart(2, '0');
    return hours + ':' + minutes;
  }

  private canUseSocial(): boolean {
    return this.stateReady && this.selectedAccountId.length > 0 &&
      this.sessionState === SteamSessionState.LOGGED_ON;
  }

  private isCurrent(lifecycleGeneration: number, accountId: string, accountScopeGeneration: number): boolean {
    return this.isPageActive && this.lifecycleGeneration === lifecycleGeneration &&
      this.accountScopeGeneration === accountScopeGeneration && this.selectedAccountId === accountId;
  }

  private clearAccountScopedState(): void {
    this.syncing = false;
    this.sending = false;
    this.actionItemId = '';
    this.searchText = '';
    this.messageDraft = '';
    this.clearSocialState();
  }

  private clearSocialState(): void {
    this.socialState = SteamArkSocialConnectionState.DISCONNECTED;
    this.socialMetricsKnown = false;
    this.friends = [];
    this.sessions = [];
    this.messages = [];
    this.trades = [];
    this.tradeCacheSyncAtEpochSeconds = 0;
    this.selectedFriendId = '';
    this.statusMessage = $r('app.string.steam_social_status_idle');
  }

  private openProfile(steamId64: string): void {
    const friend: SteamArkFriendProfile = this.friendForId(steamId64);
    this.openUrl(friend.profileUrl.length > 0 ? friend.profileUrl :
      'https://steamcommunity.com/profiles/' + steamId64 + '/', friend.displayName);
  }

  private openUrl(url: string, title: string = ''): void {
    const resolvedTitle: string = title.length > 0 ? title : resolveResourceString(
      this.getUIContext().getHostContext(), $r('app.string.steam_browser_title'));
    SteamArkNavigationBridge.pushHomeRoute(SteamArkRouteName.BROWSER,
      new SteamArkBrowserRequest(url, resolvedTitle, 'Steam'));
  }
}
