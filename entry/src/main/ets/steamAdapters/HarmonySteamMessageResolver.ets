import {
  NGFHttpMethod,
  NGFHttpSession,
  NGFHttpSessionRequest,
  NGFHttpSessionResponse,
  NGFProxyConfiguration
} from 'ngf_framework';
import {
  SteamAccountProfile,
  SteamCredentialSet,
  SteamJsonParser,
  SteamJsonValue,
  SteamJsonValueKind,
  SteamProxyKind
} from 'steam_core';
import {
  ISteamArkMessageResolver,
  SteamArkMessageCategory,
  SteamArkMessageItem,
  SteamArkMessageSyncResult
} from '../steamServices/SteamArkMessageContracts';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { SteamArkContentLocale, SteamArkRegionPolicy } from '../steamServices/SteamArkRegionPolicy';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';

const TAG: string = 'HarmonySteamMessageResolver';
const STEAM_NOTIFICATIONS_URL: string =
  'https://api.steampowered.com/ISteamNotificationService/GetSteamNotifications/v1/';
const TRADE_OFFERS_URL: string = 'https://api.steampowered.com/IEconService/GetTradeOffers/v1/';
const MARK_NOTIFICATIONS_READ_URL: string =
  'https://api.steampowered.com/ISteamNotificationService/MarkNotificationsRead/v1/';
const HIDE_NOTIFICATION_URL: string =
  'https://api.steampowered.com/ISteamNotificationService/HideNotification/v1/';
const PROMOTIONS_BASE_URL: string = 'https://store.steampowered.com/api/featuredcategories/';
const MAX_PROMOTIONS: number = 12;
const MAX_TRADE_OFFERS: number = 30;

class SteamTradeVisual {
  readonly name: string;
  readonly imageUrl: string;

  constructor(name: string = '', imageUrl: string = '') {
    this.name = name;
    this.imageUrl = imageUrl;
  }
}

class SteamNotificationPresentation {
  readonly category: SteamArkMessageCategory;
  readonly title: string;
  readonly body: string;
  readonly url: string;
  readonly source: string;
  readonly imageUrl: string;

  constructor(
    category: SteamArkMessageCategory,
    title: string,
    body: string,
    url: string,
    source: string = 'Steam',
    imageUrl: string = ''
  ) {
    this.category = category;
    this.title = title;
    this.body = body;
    this.url = url;
    this.source = source;
    this.imageUrl = imageUrl;
  }
}

/**
 * Locale-aware user-visible message strings. Simplified and traditional Chinese
 * are fully localized; other languages fall back to English until a dedicated
 * table is added.
 */
class SteamMessageStrings {
  private static readonly en: Map<string, string> = SteamMessageStrings.buildEn();
  private static readonly zhCn: Map<string, string> = SteamMessageStrings.buildZhCn();
  private static readonly zhTw: Map<string, string> = SteamMessageStrings.buildZhTw();

  static text(locale: SteamArkContentLocale, key: string): string {
    const table: Map<string, string> = SteamMessageStrings.tableFor(locale.steamLanguage);
    const value: string | undefined = table.get(key);
    if (value !== undefined && value.length > 0) {
      return value;
    }
    const fallback: string | undefined = SteamMessageStrings.en.get(key);
    return fallback !== undefined && fallback.length > 0 ? fallback : key;
  }

  static format(template: string, key: string, value: string): string {
    let result: string = template;
    const marker: string = '{' + key + '}';
    let index: number = result.indexOf(marker);
    while (index >= 0) {
      result = result.substring(0, index) + value + result.substring(index + marker.length);
      index = result.indexOf(marker);
    }
    return result;
  }

  private static tableFor(language: string): Map<string, string> {
    if (language === 'schinese') {
      return SteamMessageStrings.zhCn;
    }
    if (language === 'tchinese') {
      return SteamMessageStrings.zhTw;
    }
    return SteamMessageStrings.en;
  }

  private static buildEn(): Map<string, string> {
    const t: Map<string, string> = new Map<string, string>();
    t.set('direction.sent', 'Sent');
    t.set('direction.received', 'Received');
    t.set('trade.body', '{direction} trade offer, status: {status}; partner: {partner}; our items: {give}{giveNames}; their items: {receive}{receiveNames}');
    t.set('trade.title.sent', 'Sent trade offer #');
    t.set('trade.title.received', 'Received trade offer #');
    t.set('trade.source', 'Steam Trade');
    t.set('trade.partner.unknown', 'Unknown');
    t.set('trade.names.open', ' (');
    t.set('trade.names.close', ')');
    t.set('trade.names.separator', ', ');
    t.set('trade.names.more', '...');
    t.set('trade.state.invalid', 'Invalid');
    t.set('trade.state.pending', 'Pending');
    t.set('trade.state.accepted', 'Accepted');
    t.set('trade.state.countered', 'Countered');
    t.set('trade.state.expired', 'Expired');
    t.set('trade.state.canceled', 'Canceled');
    t.set('trade.state.declined', 'Declined');
    t.set('trade.state.invalidItems', 'Invalid items');
    t.set('trade.state.needsConfirmation', 'Pending mobile confirmation');
    t.set('trade.state.canceledByMobile', 'Canceled by mobile');
    t.set('trade.state.held', 'Held');
    t.set('trade.state.unknown', 'Unknown');
    t.set('notif.default.title', 'Steam notification');
    t.set('notif.default.body', 'Open Steam to view this notification');
    t.set('notif.unknown.body', 'Steam notification type {type}');
    t.set('notif.type2.title', 'Steam gift');
    t.set('notif.type2.body', 'A Steam gift is waiting for you');
    t.set('notif.type3.title', 'Community reply');
    t.set('notif.type3.body', 'A comment or community reply is waiting');
    t.set('notif.type4.title', 'Inventory update');
    t.set('notif.type4.body', 'Your Steam inventory has new activity');
    t.set('notif.type5.title', 'Friend invitation');
    t.set('notif.type5.body', 'You have a pending Steam friend invitation');
    t.set('notif.type6.title', 'Steam sale');
    t.set('notif.type6.body', 'A major Steam sale is available');
    t.set('notif.type7.title', 'Preload available');
    t.set('notif.type7.body', 'A game is available to preload');
    t.set('notif.type8.title', 'Wishlist update');
    t.set('notif.type8.body', 'A title on your wishlist has new activity');
    t.set('notif.type9.title', 'Trade offer');
    t.set('notif.type9.body', 'A Steam trade offer needs your attention');
    t.set('notif.type11.title', 'Steam Support');
    t.set('notif.type11.body', 'Your Steam Support request has an update');
    t.set('notif.type13.title', 'Friend message');
    t.set('notif.type13.body', 'You received a Steam chat message');
    t.set('notif.type14.title', 'Moderator message');
    t.set('notif.type14.body', 'You received a Steam moderator message');
    t.set('notif.type16.title', 'Steam Families invitation');
    t.set('notif.type16.body', 'You have a pending Steam Families invitation');
    t.set('notif.type25.title', 'Steam Guard request');
    t.set('notif.type25.body', 'A Steam Guard sign-in request needs verification');
    t.set('notif.type26.title', 'Mobile confirmation');
    t.set('notif.type26.body', 'A Steam action is waiting for mobile confirmation');
    t.set('notif.type27.title', 'Game event');
    t.set('notif.type27.body', 'A game or group you follow has a new event');
    t.set('notif.type28.title', 'Steam Playtest invitation');
    t.set('notif.type28.body', 'You have received a Steam Playtest invitation');
    t.set('notif.type29.title', 'Trade reversal');
    t.set('notif.type29.body', 'A Steam trade has been reversed');
    t.set('notif.type30.title', 'Community action');
    t.set('notif.type30.body', 'Steam has updated the status of reported content');
    t.set('notif.source.community', 'Steam Community');
    t.set('notif.source.store', 'Steam Store');
    t.set('notif.source.trade', 'Steam Trade');
    t.set('notif.source.support', 'Steam Support');
    t.set('notif.source.chat', 'Steam Chat');
    t.set('notif.source.guard', 'Steam Guard');
    t.set('notif.source.events', 'Steam Events');
    t.set('summary.confirmations.title', 'Mobile confirmations');
    t.set('summary.confirmations.body', 'Steam actions waiting for mobile confirmation: {count}');
    t.set('summary.gifts.title', 'Pending gifts');
    t.set('summary.gifts.body', 'Steam gifts waiting for you: {count}');
    t.set('summary.friends.title', 'Pending friend invitations');
    t.set('summary.friends.body', 'Steam friend invitations waiting for you: {count}');
    t.set('summary.family.title', 'Steam Families invitations');
    t.set('summary.family.body', 'Steam Families invitations waiting for you: {count}');
    t.set('summary.unread.title', 'Unread Steam notifications');
    t.set('summary.unread.body', 'Unread notifications reported by Steam: {count}');
    t.set('promotion.body', 'Steam Store discount: {discount}%');
    return t;
  }

  private static buildZhCn(): Map<string, string> {
    const t: Map<string, string> = new Map<string, string>();
    t.set('direction.sent', '已发送');
    t.set('direction.received', '收到');
    t.set('trade.body', '{direction}交易报价，状态：{status}；对方账户：{partner}；我方物品：{give} 件{giveNames}；对方物品：{receive} 件{receiveNames}');
    t.set('trade.title.sent', '已发送交易报价 #');
    t.set('trade.title.received', '收到交易报价 #');
    t.set('trade.source', 'Steam 交易');
    t.set('trade.partner.unknown', '未知');
    t.set('trade.names.open', '（');
    t.set('trade.names.close', '）');
    t.set('trade.names.separator', '、');
    t.set('trade.names.more', ' 等');
    t.set('trade.state.invalid', '无效');
    t.set('trade.state.pending', '待处理');
    t.set('trade.state.accepted', '已接受');
    t.set('trade.state.countered', '已还价');
    t.set('trade.state.expired', '已过期');
    t.set('trade.state.canceled', '已取消');
    t.set('trade.state.declined', '已拒绝');
    t.set('trade.state.invalidItems', '物品失效');
    t.set('trade.state.needsConfirmation', '等待移动端确认');
    t.set('trade.state.canceledByMobile', '已由移动端取消');
    t.set('trade.state.held', '交易保留中');
    t.set('trade.state.unknown', '状态未知');
    t.set('notif.default.title', 'Steam 通知');
    t.set('notif.default.body', '打开 Steam 查看此通知');
    t.set('notif.unknown.body', 'Steam 通知类型 {type}');
    t.set('notif.type2.title', 'Steam 礼物');
    t.set('notif.type2.body', '有一份 Steam 礼物在等待你');
    t.set('notif.type3.title', '社区回复');
    t.set('notif.type3.body', '有新的评论或社区回复');
    t.set('notif.type4.title', '库存更新');
    t.set('notif.type4.body', '你的 Steam 库存有新动态');
    t.set('notif.type5.title', '好友邀请');
    t.set('notif.type5.body', '你有一条待处理的好友邀请');
    t.set('notif.type6.title', 'Steam 特惠');
    t.set('notif.type6.body', 'Steam 大型特惠正在进行');
    t.set('notif.type7.title', '预载已开放');
    t.set('notif.type7.body', '有游戏可以预载了');
    t.set('notif.type8.title', '愿望单更新');
    t.set('notif.type8.body', '你愿望单中的游戏有新动态');
    t.set('notif.type9.title', '交易报价');
    t.set('notif.type9.body', '有一份 Steam 交易报价需要你处理');
    t.set('notif.type11.title', 'Steam 客服');
    t.set('notif.type11.body', '你的 Steam 客服工单有更新');
    t.set('notif.type13.title', '好友消息');
    t.set('notif.type13.body', '你收到了一条 Steam 聊天消息');
    t.set('notif.type14.title', '版主消息');
    t.set('notif.type14.body', '你收到了一条版主消息');
    t.set('notif.type16.title', 'Steam 家庭邀请');
    t.set('notif.type16.body', '你有一条待处理的 Steam 家庭邀请');
    t.set('notif.type25.title', 'Steam 令牌请求');
    t.set('notif.type25.body', '有一条 Steam 令牌登录请求待验证');
    t.set('notif.type26.title', '移动端确认');
    t.set('notif.type26.body', '有一个 Steam 操作等待移动端确认');
    t.set('notif.type27.title', '游戏活动');
    t.set('notif.type27.body', '你关注的游戏或群组有新活动');
    t.set('notif.type28.title', 'Steam 试玩版邀请');
    t.set('notif.type28.body', '你收到了一个 Steam 试玩版邀请');
    t.set('notif.type29.title', '交易撤销');
    t.set('notif.type29.body', '有一笔 Steam 交易被撤销');
    t.set('notif.type30.title', '社区处理结果');
    t.set('notif.type30.body', 'Steam 已更新被举报内容的状态');
    t.set('notif.source.community', 'Steam 社区');
    t.set('notif.source.store', 'Steam 商店');
    t.set('notif.source.trade', 'Steam 交易');
    t.set('notif.source.support', 'Steam 客服');
    t.set('notif.source.chat', 'Steam 聊天');
    t.set('notif.source.guard', 'Steam 令牌');
    t.set('notif.source.events', 'Steam 活动');
    t.set('summary.confirmations.title', '移动端确认');
    t.set('summary.confirmations.body', '有 Steam 操作等待移动端确认：{count}');
    t.set('summary.gifts.title', '待领取礼物');
    t.set('summary.gifts.body', '有 Steam 礼物等待领取：{count}');
    t.set('summary.friends.title', '待处理好友邀请');
    t.set('summary.friends.body', '有 Steam 好友邀请等待处理：{count}');
    t.set('summary.family.title', 'Steam 家庭邀请');
    t.set('summary.family.body', '有 Steam 家庭邀请等待处理：{count}');
    t.set('summary.unread.title', '未读 Steam 通知');
    t.set('summary.unread.body', 'Steam 报告的未读通知：{count}');
    t.set('promotion.body', 'Steam 商店折扣：{discount}%');
    return t;
  }

  private static buildZhTw(): Map<string, string> {
    const t: Map<string, string> = new Map<string, string>();
    t.set('direction.sent', '已傳送');
    t.set('direction.received', '收到');
    t.set('trade.body', '{direction}交易報價，狀態：{status}；對方帳戶：{partner}；我方物品：{give} 件{giveNames}；對方物品：{receive} 件{receiveNames}');
    t.set('trade.title.sent', '已傳送交易報價 #');
    t.set('trade.title.received', '收到交易報價 #');
    t.set('trade.source', 'Steam 交易');
    t.set('trade.partner.unknown', '未知');
    t.set('trade.names.open', '（');
    t.set('trade.names.close', '）');
    t.set('trade.names.separator', '、');
    t.set('trade.names.more', ' 等');
    t.set('trade.state.invalid', '無效');
    t.set('trade.state.pending', '待處理');
    t.set('trade.state.accepted', '已接受');
    t.set('trade.state.countered', '已還價');
    t.set('trade.state.expired', '已過期');
    t.set('trade.state.canceled', '已取消');
    t.set('trade.state.declined', '已拒絕');
    t.set('trade.state.invalidItems', '物品失效');
    t.set('trade.state.needsConfirmation', '等待行動裝置確認');
    t.set('trade.state.canceledByMobile', '已由行動裝置取消');
    t.set('trade.state.held', '交易保留中');
    t.set('trade.state.unknown', '狀態未知');
    t.set('notif.default.title', 'Steam 通知');
    t.set('notif.default.body', '開啟 Steam 查看此通知');
    t.set('notif.unknown.body', 'Steam 通知類型 {type}');
    t.set('notif.type2.title', 'Steam 禮物');
    t.set('notif.type2.body', '有一份 Steam 禮物在等你');
    t.set('notif.type3.title', '社群回覆');
    t.set('notif.type3.body', '有新的評論或社群回覆');
    t.set('notif.type4.title', '庫存更新');
    t.set('notif.type4.body', '你的 Steam 庫存有新動態');
    t.set('notif.type5.title', '好友邀請');
    t.set('notif.type5.body', '你有一條待處理的好友邀請');
    t.set('notif.type6.title', 'Steam 特惠');
    t.set('notif.type6.body', 'Steam 大型特惠正在進行');
    t.set('notif.type7.title', '預載已開放');
    t.set('notif.type7.body', '有遊戲可以預載了');
    t.set('notif.type8.title', '願望單更新');
    t.set('notif.type8.body', '你願望單中的遊戲有新動態');
    t.set('notif.type9.title', '交易報價');
    t.set('notif.type9.body', '有一份 Steam 交易報價需要你處理');
    t.set('notif.type11.title', 'Steam 客服');
    t.set('notif.type11.body', '你的 Steam 客服工單有更新');
    t.set('notif.type13.title', '好友訊息');
    t.set('notif.type13.body', '你收到了一條 Steam 聊天訊息');
    t.set('notif.type14.title', '版主訊息');
    t.set('notif.type14.body', '你收到了一條版主訊息');
    t.set('notif.type16.title', 'Steam 家庭邀請');
    t.set('notif.type16.body', '你有一條待處理的 Steam 家庭邀請');
    t.set('notif.type25.title', 'Steam 令牌請求');
    t.set('notif.type25.body', '有一條 Steam 令牌登入請求待驗證');
    t.set('notif.type26.title', '行動裝置確認');
    t.set('notif.type26.body', '有一個 Steam 操作等待行動裝置確認');
    t.set('notif.type27.title', '遊戲活動');
    t.set('notif.type27.body', '你關注的遊戲或群組有新活動');
    t.set('notif.type28.title', 'Steam 試玩版邀請');
    t.set('notif.type28.body', '你收到了一個 Steam 試玩版邀請');
    t.set('notif.type29.title', '交易撤銷');
    t.set('notif.type29.body', '有一筆 Steam 交易被撤銷');
    t.set('notif.type30.title', '社群處理結果');
    t.set('notif.type30.body', 'Steam 已更新被檢舉內容的狀態');
    t.set('notif.source.community', 'Steam 社群');
    t.set('notif.source.store', 'Steam 商店');
    t.set('notif.source.trade', 'Steam 交易');
    t.set('notif.source.support', 'Steam 客服');
    t.set('notif.source.chat', 'Steam 聊天');
    t.set('notif.source.guard', 'Steam 令牌');
    t.set('notif.source.events', 'Steam 活動');
    t.set('summary.confirmations.title', '行動裝置確認');
    t.set('summary.confirmations.body', '有 Steam 操作等待行動裝置確認：{count}');
    t.set('summary.gifts.title', '待領取禮物');
    t.set('summary.gifts.body', '有 Steam 禮物等待領取：{count}');
    t.set('summary.friends.title', '待處理好友邀請');
    t.set('summary.friends.body', '有 Steam 好友邀請等待處理：{count}');
    t.set('summary.family.title', 'Steam 家庭邀請');
    t.set('summary.family.body', '有 Steam 家庭邀請等待處理：{count}');
    t.set('summary.unread.title', '未讀 Steam 通知');
    t.set('summary.unread.body', 'Steam 回報的未讀通知：{count}');
    t.set('promotion.body', 'Steam 商店折扣：{discount}%');
    return t;
  }
}

/** Read-only aggregation of authenticated Steam notifications, trades and store promotions. */
export class HarmonySteamMessageResolver implements ISteamArkMessageResolver {
  async resolve(
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    proxyPassword: string = '',
    locale: SteamArkContentLocale | null = null
  ): Promise<SteamArkMessageSyncResult> {
    const contentLocale: SteamArkContentLocale = locale !== null ? locale : SteamArkRegionPolicy.defaultLocale();
    SteamArkLog.debug(TAG, 'message sync locale probe; region=' + contentLocale.region +
      ', steamLanguage=' + contentLocale.steamLanguage +
      ', country=' + contentLocale.storeCountryCode +
      ', currencyId=' + contentLocale.currencyId.toString() +
      ', notificationLanguageId=' + contentLocale.notificationLanguageId.toString());
    if (profile.steamId64.length <= 0 || credentials.accessToken.length <= 0) {
      throw new Error('Steam message synchronization requires an authenticated account');
    }
    const session: NGFHttpSession = new NGFHttpSession();
    const now: number = Math.floor(Date.now() / 1000);
    const items: Array<SteamArkMessageItem> = [];
    const proxy: NGFProxyConfiguration = HarmonySteamMessageResolver.toProxy(profile, proxyPassword);
    try {
      let sourceWarning: string = '';
      let successfulSources: number = 0;
      try {
        const notificationResponse: NGFHttpSessionResponse = await this.get(
          session,
          this.notificationsUrl(credentials.accessToken, contentLocale),
          proxy,
          'https://steamcommunity.com/my/home/'
        );
        if (notificationResponse.isOk()) {
          this.appendNotifications(notificationResponse.body, now, items, contentLocale);
          successfulSources++;
          SteamArkLog.debug(TAG, 'notification source probe; url=' +
            HarmonySteamMessageResolver.sanitizeUrl(this.notificationsUrl(credentials.accessToken, contentLocale)));
        } else {
          sourceWarning = 'Steam notification source returned HTTP ' + notificationResponse.statusCode.toString();
          SteamArkLog.warn(TAG, 'notification service unavailable; status=' +
            notificationResponse.statusCode.toString() +
            ', bodyBytes=' + notificationResponse.body.length.toString());
        }
      } catch (error) {
        sourceWarning = 'Steam notification source unavailable';
        SteamArkLog.warn(TAG, 'notification request failed; errorType=' + SteamArkLog.errorKind(error));
      }
      try {
        const tradeOffersResponse: NGFHttpSessionResponse = await this.get(
          session,
          this.tradeOffersUrl(credentials.accessToken, contentLocale),
          proxy,
          'https://steamcommunity.com/my/tradeoffers/'
        );
        if (tradeOffersResponse.isOk()) {
          this.appendTradeOffers(tradeOffersResponse.body, now, items, contentLocale);
          successfulSources++;
          SteamArkLog.debug(TAG, 'trade offer source probe; url=' +
            HarmonySteamMessageResolver.sanitizeUrl(this.tradeOffersUrl(credentials.accessToken, contentLocale)));
        } else {
          sourceWarning = this.appendWarning(sourceWarning,
            'Steam trade offer source returned HTTP ' + tradeOffersResponse.statusCode.toString());
          SteamArkLog.warn(TAG, 'trade offer request returned HTTP ' + tradeOffersResponse.statusCode.toString());
        }
      } catch (error) {
        sourceWarning = this.appendWarning(sourceWarning, 'Steam trade offer source unavailable');
        SteamArkLog.warn(TAG, 'trade offer request failed; errorType=' + SteamArkLog.errorKind(error));
      }
      try {
        const promotionResponse: NGFHttpSessionResponse = await this.get(
          session,
          this.promotionsUrl(contentLocale),
          proxy,
          'https://store.steampowered.com/'
        );
        if (promotionResponse.isOk()) {
          this.appendPromotions(promotionResponse.body, now, items, contentLocale);
          successfulSources++;
          SteamArkLog.debug(TAG, 'promotion source probe; url=' +
            HarmonySteamMessageResolver.sanitizeUrl(this.promotionsUrl(contentLocale)));
        } else {
          sourceWarning = this.appendWarning(sourceWarning,
            'Steam promotion source returned HTTP ' + promotionResponse.statusCode.toString());
          SteamArkLog.warn(TAG, 'promotion request returned HTTP ' + promotionResponse.statusCode.toString());
        }
      } catch (error) {
        sourceWarning = this.appendWarning(sourceWarning, 'Steam promotion source unavailable');
        SteamArkLog.warn(TAG, 'promotion request failed; errorType=' + SteamArkLog.errorKind(error));
      }
      if (successfulSources <= 0) {
        throw new Error(sourceWarning.length > 0 ? sourceWarning : 'All Steam message sources are unavailable');
      }
      for (let index: number = 0; index < items.length && index < 3; index++) {
        const sample: SteamArkMessageItem = items[index];
        const sampleBody: string = sample.body.length > 120 ? sample.body.substring(0, 120) : sample.body;
        SteamArkLog.debug(TAG, 'message sample probe; category=' + String(sample.category) +
          ', title=' + sample.title + ', body=' + sampleBody);
      }
      SteamArkLog.info(TAG, 'message synchronization completed; account=' +
        SteamArkLog.accountId(profile.accountId) + ', items=' + items.length.toString());
      return new SteamArkMessageSyncResult(items, now, sourceWarning);
    } finally {
      session.clear();
    }
  }

  async markRead(profile: SteamAccountProfile, credentials: SteamCredentialSet,
    proxyPassword: string, item: SteamArkMessageItem): Promise<void> {
    if (item.remoteId.length <= 0 || item.notificationType <= 0) {
      return;
    }
    const fields: string = 'access_token=' + encodeURIComponent(credentials.accessToken) +
      '&timestamp=' + Math.max(0, item.createdAtEpochSeconds).toString() +
      '&notification_type=' + item.notificationType.toString() +
      '&notification_ids%5B0%5D=' + encodeURIComponent(item.remoteId) + '&mark_all_read=false';
    await this.postAction(profile, proxyPassword, MARK_NOTIFICATIONS_READ_URL, fields);
  }

  async markAllRead(profile: SteamAccountProfile, credentials: SteamCredentialSet,
    proxyPassword: string): Promise<void> {
    const fields: string = 'access_token=' + encodeURIComponent(credentials.accessToken) +
      '&timestamp=' + Math.floor(Date.now() / 1000).toString() +
      '&notification_type=0&mark_all_read=true';
    await this.postAction(profile, proxyPassword, MARK_NOTIFICATIONS_READ_URL, fields);
  }

  async hide(profile: SteamAccountProfile, credentials: SteamCredentialSet,
    proxyPassword: string, item: SteamArkMessageItem): Promise<void> {
    if (item.remoteId.length <= 0) {
      return;
    }
    const fields: string = 'access_token=' + encodeURIComponent(credentials.accessToken) +
      '&notification_ids%5B0%5D=' + encodeURIComponent(item.remoteId);
    await this.postAction(profile, proxyPassword, HIDE_NOTIFICATION_URL, fields);
  }

  private static sanitizeUrl(url: string): string {
    const tokenStart: number = url.indexOf('access_token=');
    if (tokenStart < 0) {
      return url;
    }
    const tokenEnd: number = url.indexOf('&', tokenStart);
    return url.substring(0, tokenStart + 'access_token='.length) + '***' +
      (tokenEnd >= 0 ? url.substring(tokenEnd) : '');
  }

  private async get(
    session: NGFHttpSession,
    url: string,
    proxy: NGFProxyConfiguration,
    referer: string
  ): Promise<NGFHttpSessionResponse> {
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('MessageCenter'));
    headers.set('Referer', referer);
    headers.set('X-Requested-With', 'XMLHttpRequest');
    return await session.request(new NGFHttpSessionRequest(
      NGFHttpMethod.GET,
      url,
      headers,
      '',
      20000,
      false,
      proxy
    ));
  }

  private async postAction(profile: SteamAccountProfile, proxyPassword: string,
    url: string, body: string): Promise<void> {
    const session: NGFHttpSession = new NGFHttpSession();
    try {
      const headers: Map<string, string> = new Map<string, string>();
      headers.set('Accept', 'application/json');
      headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('MessageCenter'));
      const response: NGFHttpSessionResponse = await session.request(new NGFHttpSessionRequest(
        NGFHttpMethod.POST, url, headers, body, 20000, false,
        HarmonySteamMessageResolver.toProxy(profile, proxyPassword)));
      if (!response.isOk()) {
        throw new Error('Steam message action returned HTTP ' + response.statusCode.toString());
      }
    } finally {
      session.clear();
    }
  }

  private tradeOffersUrl(accessToken: string, locale: SteamArkContentLocale): string {
    return TRADE_OFFERS_URL + '?access_token=' + encodeURIComponent(accessToken) +
      '&get_sent_offers=1&get_received_offers=1&get_descriptions=1&active_only=1' +
      '&time_historical_cutoff=4294967295&language=' + encodeURIComponent(locale.steamLanguage);
  }

  private notificationsUrl(accessToken: string, locale: SteamArkContentLocale): string {
    return STEAM_NOTIFICATIONS_URL + '?access_token=' + encodeURIComponent(accessToken) +
      '&include_hidden=false&include_confirmation_count=true&include_pinned_counts=true' +
      '&include_read=true&count_only=false&language=' + locale.notificationLanguageId.toString();
  }

  private promotionsUrl(locale: SteamArkContentLocale): string {
    return PROMOTIONS_BASE_URL + '?cc=' + encodeURIComponent(locale.storeCountryCode) +
      '&l=' + encodeURIComponent(locale.steamLanguage);
  }

  private appendTradeOffers(body: string, now: number, target: Array<SteamArkMessageItem>,
    contentLocale: SteamArkContentLocale): void {
    const root: SteamJsonValue = SteamJsonParser.parse(body, steamArkCoreLogger);
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('Steam trade offer response is not an object');
    }
    const response: SteamJsonValue | null = root.getProperty('response');
    if (response === null || response.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('Steam trade offer response body is missing response');
    }
    const descriptions: SteamJsonValue | null = response.getProperty('descriptions');
    this.appendTradeOfferArray(response.getProperty('trade_offers_received'), descriptions, false, now, target, contentLocale);
    this.appendTradeOfferArray(response.getProperty('trade_offers_sent'), descriptions, true, now, target, contentLocale);
    SteamArkLog.debug(TAG, 'trade offer details parsed; total=' + target.length.toString());
  }

  private appendTradeOfferArray(value: SteamJsonValue | null, descriptions: SteamJsonValue | null,
    sent: boolean, now: number,
    target: Array<SteamArkMessageItem>, contentLocale: SteamArkContentLocale): void {
    if (value === null || value.kind !== SteamJsonValueKind.ARRAY) {
      return;
    }
    const limit: number = Math.min(value.items.length, MAX_TRADE_OFFERS);
    for (let index = 0; index < limit; index++) {
      const offer: SteamJsonValue = value.items[index];
      if (offer.kind !== SteamJsonValueKind.OBJECT) {
        continue;
      }
      const offerId: string = this.readScalarText(offer.getProperty('tradeofferid'));
      if (offerId.length <= 0) {
        continue;
      }
      const state: number = this.readInteger(offer.getProperty('trade_offer_state'));
      const giveCount: number = this.arrayLength(offer.getProperty('items_to_give'));
      const receiveCount: number = this.arrayLength(offer.getProperty('items_to_receive'));
      const partner: string = this.readScalarText(offer.getProperty('accountid_other'));
      const visual: SteamTradeVisual = this.resolveTradeVisual(offer, descriptions, sent);
      const direction: string = SteamMessageStrings.text(contentLocale,
        sent ? 'direction.sent' : 'direction.received');
      const status: string = this.tradeOfferState(state, contentLocale);
      const giveNames: string = this.tradeItemNames(offer.getProperty('items_to_give'), descriptions, contentLocale);
      const receiveNames: string = this.tradeItemNames(offer.getProperty('items_to_receive'), descriptions, contentLocale);
      let body: string = SteamMessageStrings.text(contentLocale, 'trade.body');
      body = SteamMessageStrings.format(body, 'direction', direction);
      body = SteamMessageStrings.format(body, 'status', status);
      body = SteamMessageStrings.format(body, 'partner', partner.length > 0
        ? partner : SteamMessageStrings.text(contentLocale, 'trade.partner.unknown'));
      body = SteamMessageStrings.format(body, 'give', giveCount.toString());
      body = SteamMessageStrings.format(body, 'receive', receiveCount.toString());
      body = SteamMessageStrings.format(body, 'giveNames', giveNames);
      body = SteamMessageStrings.format(body, 'receiveNames', receiveNames);
      target.push(new SteamArkMessageItem(
        'trade-offer-' + offerId,
        SteamArkMessageCategory.TRADE,
        SteamMessageStrings.text(contentLocale, sent ? 'trade.title.sent' : 'trade.title.received') +
          offerId + (visual.name.length > 0 ? ' · ' + visual.name : ''),
        body,
        'https://steamcommunity.com/tradeoffer/' + offerId + '/',
        SteamMessageStrings.text(contentLocale, 'trade.source'),
        now,
        !sent && state === 2,
        visual.imageUrl,
        '',
        0,
        offerId,
        sent
      ));
    }
  }

  private resolveTradeVisual(offer: SteamJsonValue, descriptions: SteamJsonValue | null,
    sent: boolean): SteamTradeVisual {
    if (descriptions === null || descriptions.kind !== SteamJsonValueKind.ARRAY) {
      return new SteamTradeVisual();
    }
    let offeredItems: SteamJsonValue | null = sent
      ? offer.getProperty('items_to_give')
      : offer.getProperty('items_to_receive');
    if (offeredItems === null || offeredItems.kind !== SteamJsonValueKind.ARRAY || offeredItems.items.length <= 0) {
      offeredItems = sent ? offer.getProperty('items_to_receive') : offer.getProperty('items_to_give');
    }
    if (offeredItems === null || offeredItems.kind !== SteamJsonValueKind.ARRAY || offeredItems.items.length <= 0) {
      return new SteamTradeVisual();
    }
    const firstItem: SteamJsonValue = offeredItems.items[0];
    if (firstItem.kind !== SteamJsonValueKind.OBJECT) {
      return new SteamTradeVisual();
    }
    const classId: string = this.readScalarText(firstItem.getProperty('classid'));
    const instanceId: string = this.readScalarText(firstItem.getProperty('instanceid'));
    for (let index: number = 0; index < descriptions.items.length; index++) {
      const description: SteamJsonValue = descriptions.items[index];
      if (description.kind !== SteamJsonValueKind.OBJECT ||
        this.readScalarText(description.getProperty('classid')) !== classId ||
        this.readScalarText(description.getProperty('instanceid')) !== instanceId) {
        continue;
      }
      const name: string = this.readString(description.getProperty('name'));
      const iconPath: string = this.readString(description.getProperty('icon_url'));
      const imageUrl: string = iconPath.length > 0
        ? 'https://community.cloudflare.steamstatic.com/economy/image/' + iconPath
        : '';
      return new SteamTradeVisual(name, imageUrl);
    }
    return new SteamTradeVisual();
  }

  /** Composes a compact localized item-name appendix such as "（AK-47 | Redline、M4A4 等）". */
  private tradeItemNames(value: SteamJsonValue | null, descriptions: SteamJsonValue | null,
    contentLocale: SteamArkContentLocale): string {
    if (value === null || value.kind !== SteamJsonValueKind.ARRAY || descriptions === null ||
      descriptions.kind !== SteamJsonValueKind.ARRAY) {
      return '';
    }
    const names: Array<string> = [];
    for (let index = 0; index < value.items.length && names.length <= 3; index++) {
      const item: SteamJsonValue = value.items[index];
      if (item.kind !== SteamJsonValueKind.OBJECT) {
        continue;
      }
      const classId: string = this.readScalarText(item.getProperty('classid'));
      const instanceId: string = this.readScalarText(item.getProperty('instanceid'));
      for (let descriptionIndex = 0; descriptionIndex < descriptions.items.length; descriptionIndex++) {
        const description: SteamJsonValue = descriptions.items[descriptionIndex];
        if (description.kind !== SteamJsonValueKind.OBJECT ||
          this.readScalarText(description.getProperty('classid')) !== classId ||
          this.readScalarText(description.getProperty('instanceid')) !== instanceId) {
          continue;
        }
        const name: string = this.readString(description.getProperty('name'));
        if (name.length > 0 && !names.includes(name)) {
          names.push(name);
        }
        break;
      }
    }
    if (names.length <= 0) {
      return '';
    }
    const visible: Array<string> = names.length > 2 ? names.slice(0, 2) : names;
    let text: string = SteamMessageStrings.text(contentLocale, 'trade.names.open');
    for (let index = 0; index < visible.length; index++) {
      if (index > 0) {
        text += SteamMessageStrings.text(contentLocale, 'trade.names.separator');
      }
      text += visible[index];
    }
    if (names.length > visible.length) {
      text += SteamMessageStrings.text(contentLocale, 'trade.names.more');
    }
    text += SteamMessageStrings.text(contentLocale, 'trade.names.close');
    return text;
  }

  private arrayLength(value: SteamJsonValue | null): number {
    return value !== null && value.kind === SteamJsonValueKind.ARRAY ? value.items.length : 0;
  }

  private tradeOfferState(state: number, contentLocale: SteamArkContentLocale): string {
    switch (state) {
      case 1: return SteamMessageStrings.text(contentLocale, 'trade.state.invalid');
      case 2: return SteamMessageStrings.text(contentLocale, 'trade.state.pending');
      case 3: return SteamMessageStrings.text(contentLocale, 'trade.state.accepted');
      case 4: return SteamMessageStrings.text(contentLocale, 'trade.state.countered');
      case 5: return SteamMessageStrings.text(contentLocale, 'trade.state.expired');
      case 6: return SteamMessageStrings.text(contentLocale, 'trade.state.canceled');
      case 7: return SteamMessageStrings.text(contentLocale, 'trade.state.declined');
      case 8: return SteamMessageStrings.text(contentLocale, 'trade.state.invalidItems');
      case 9: return SteamMessageStrings.text(contentLocale, 'trade.state.needsConfirmation');
      case 10: return SteamMessageStrings.text(contentLocale, 'trade.state.canceledByMobile');
      case 11: return SteamMessageStrings.text(contentLocale, 'trade.state.held');
      default: return SteamMessageStrings.text(contentLocale, 'trade.state.unknown');
    }
  }

  private appendNotifications(body: string, now: number, target: Array<SteamArkMessageItem>,
    contentLocale: SteamArkContentLocale): void {
    const root: SteamJsonValue = SteamJsonParser.parse(body, steamArkCoreLogger);
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('Steam notification response is not an object');
    }
    const response: SteamJsonValue | null = root.getProperty('response');
    if (response === null || response.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('Steam notification response body is missing response');
    }
    const notifications: SteamJsonValue | null = response.getProperty('notifications');
    let notificationCount: number = 0;
    if (notifications !== null && notifications.kind === SteamJsonValueKind.ARRAY) {
      notificationCount = this.appendNotificationArray(notifications, now, target, contentLocale);
    }
    this.appendNotificationSummary(response, notificationCount, now, target, contentLocale);
    SteamArkLog.debug(TAG, 'Steam notifications parsed; notifications=' + notificationCount.toString());
  }

  private appendNotificationArray(
    value: SteamJsonValue,
    now: number,
    target: Array<SteamArkMessageItem>,
    contentLocale: SteamArkContentLocale
  ): number {
    if (value.kind !== SteamJsonValueKind.ARRAY) {
      return 0;
    }
    let appended: number = 0;
    for (let index: number = 0; index < value.items.length; index++) {
      const notification: SteamJsonValue = value.items[index];
      if (notification.kind !== SteamJsonValueKind.OBJECT) {
        continue;
      }
      const notificationType: number = this.readInteger(notification.getProperty('notification_type'));
      if (notificationType <= 0) {
        continue;
      }
      const notificationId: string = this.readScalarText(notification.getProperty('notification_id'));
      const bodyData: SteamJsonValue | null = this.parseNotificationBody(
        this.readString(notification.getProperty('body_data'))
      );
      const presentation: SteamNotificationPresentation =
        this.resolveNotificationPresentation(notificationType, bodyData, contentLocale);
      const tradeOfferId: string = bodyData === null ? '' :
        this.readScalarText(bodyData.getProperty('tradeofferid'));
      const timestamp: number = this.readInteger(notification.getProperty('timestamp'));
      const isRead: boolean = this.readBoolean(notification.getProperty('read'), false);
      target.push(new SteamArkMessageItem(
        notificationId.length > 0 ? 'steam-notification-' + notificationId :
          'steam-notification-' + notificationType.toString() + '-' + index.toString(),
        presentation.category,
        presentation.title,
        presentation.body,
        presentation.url,
        presentation.source,
        timestamp > 0 ? timestamp : now,
        !isRead,
        presentation.imageUrl,
        notificationId,
        notificationType,
        tradeOfferId,
        false
      ));
      appended++;
    }
    return appended;
  }

  private parseNotificationBody(bodyData: string): SteamJsonValue | null {
    if (bodyData.length <= 0) {
      return null;
    }
    try {
      const parsed: SteamJsonValue = SteamJsonParser.parse(bodyData, steamArkCoreLogger);
      return parsed.kind === SteamJsonValueKind.OBJECT ? parsed : null;
    } catch (error) {
      SteamArkLog.warn(TAG, 'notification body_data parse failed; errorType=' + SteamArkLog.errorKind(error));
      return null;
    }
  }

  private resolveNotificationPresentation(
    notificationType: number,
    bodyData: SteamJsonValue | null,
    contentLocale: SteamArkContentLocale
  ): SteamNotificationPresentation {
    let category: SteamArkMessageCategory = SteamArkMessageCategory.SYSTEM;
    let title: string = SteamMessageStrings.text(contentLocale, 'notif.default.title');
    let fallbackBody: string = SteamMessageStrings.text(contentLocale, 'notif.default.body');
    let url: string = 'https://steamcommunity.com/my/home/';
    let source: string = SteamMessageStrings.text(contentLocale, 'notif.source.community');
    switch (notificationType) {
      case 2:
        title = SteamMessageStrings.text(contentLocale, 'notif.type2.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type2.body');
        url = 'https://steamcommunity.com/my/inventory/#753_1';
        break;
      case 3:
        title = SteamMessageStrings.text(contentLocale, 'notif.type3.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type3.body');
        url = 'https://steamcommunity.com/my/commentnotifications/';
        break;
      case 4:
        category = SteamArkMessageCategory.INVENTORY;
        title = SteamMessageStrings.text(contentLocale, 'notif.type4.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type4.body');
        url = 'https://steamcommunity.com/my/inventory/';
        break;
      case 5:
        category = SteamArkMessageCategory.FRIEND;
        title = SteamMessageStrings.text(contentLocale, 'notif.type5.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type5.body');
        url = 'https://steamcommunity.com/my/friends/pending';
        break;
      case 6:
        category = SteamArkMessageCategory.PROMOTION;
        title = SteamMessageStrings.text(contentLocale, 'notif.type6.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type6.body');
        url = 'https://store.steampowered.com/';
        source = SteamMessageStrings.text(contentLocale, 'notif.source.store');
        break;
      case 7:
        category = SteamArkMessageCategory.PROMOTION;
        title = SteamMessageStrings.text(contentLocale, 'notif.type7.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type7.body');
        source = SteamMessageStrings.text(contentLocale, 'notif.source.store');
        break;
      case 8:
        category = SteamArkMessageCategory.PROMOTION;
        title = SteamMessageStrings.text(contentLocale, 'notif.type8.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type8.body');
        url = 'https://store.steampowered.com/wishlist/';
        source = SteamMessageStrings.text(contentLocale, 'notif.source.store');
        break;
      case 9:
        category = SteamArkMessageCategory.TRADE;
        title = SteamMessageStrings.text(contentLocale, 'notif.type9.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type9.body');
        url = 'https://steamcommunity.com/my/tradeoffers/';
        source = SteamMessageStrings.text(contentLocale, 'notif.source.trade');
        break;
      case 11:
        title = SteamMessageStrings.text(contentLocale, 'notif.type11.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type11.body');
        url = 'https://help.steampowered.com/';
        source = SteamMessageStrings.text(contentLocale, 'notif.source.support');
        break;
      case 13:
        category = SteamArkMessageCategory.FRIEND;
        title = SteamMessageStrings.text(contentLocale, 'notif.type13.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type13.body');
        url = 'https://steamcommunity.com/chat/';
        source = SteamMessageStrings.text(contentLocale, 'notif.source.chat');
        break;
      case 14:
        title = SteamMessageStrings.text(contentLocale, 'notif.type14.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type14.body');
        break;
      case 16:
        category = SteamArkMessageCategory.FRIEND;
        title = SteamMessageStrings.text(contentLocale, 'notif.type16.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type16.body');
        url = 'https://store.steampowered.com/account/familymanagement/';
        break;
      case 25:
        title = SteamMessageStrings.text(contentLocale, 'notif.type25.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type25.body');
        url = 'https://store.steampowered.com/twofactor/manage';
        break;
      case 26:
        category = SteamArkMessageCategory.TRADE;
        title = SteamMessageStrings.text(contentLocale, 'notif.type26.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type26.body');
        url = 'https://steamcommunity.com/mobileconf/conf';
        source = SteamMessageStrings.text(contentLocale, 'notif.source.guard');
        break;
      case 27:
        category = SteamArkMessageCategory.PROMOTION;
        title = SteamMessageStrings.text(contentLocale, 'notif.type27.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type27.body');
        source = SteamMessageStrings.text(contentLocale, 'notif.source.events');
        break;
      case 28:
        title = SteamMessageStrings.text(contentLocale, 'notif.type28.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type28.body');
        break;
      case 29:
        category = SteamArkMessageCategory.TRADE;
        title = SteamMessageStrings.text(contentLocale, 'notif.type29.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type29.body');
        url = 'https://steamcommunity.com/my/tradehistory/';
        source = SteamMessageStrings.text(contentLocale, 'notif.source.trade');
        break;
      case 30:
        title = SteamMessageStrings.text(contentLocale, 'notif.type30.title');
        fallbackBody = SteamMessageStrings.text(contentLocale, 'notif.type30.body');
        break;
      default:
        fallbackBody = SteamMessageStrings.format(
          SteamMessageStrings.text(contentLocale, 'notif.unknown.body'),
          'type', notificationType.toString());
        break;
    }
    if (bodyData === null) {
      return new SteamNotificationPresentation(category, title, fallbackBody, url, source);
    }
    const bodyTitle: string = this.firstText(bodyData.getProperty('title'), bodyData.getProperty('headline'),
      bodyData.getProperty('app_name'));
    const bodyText: string = this.firstText(bodyData.getProperty('body'), bodyData.getProperty('message'),
      bodyData.getProperty('description'));
    const commentText: string = this.readString(bodyData.getProperty('comment'));
    const appId: string = this.readScalarText(bodyData.getProperty('appid'));
    const tradeOfferId: string = this.readScalarText(bodyData.getProperty('tradeofferid'));
    const senderSteamId: string = this.firstText(bodyData.getProperty('steamid_sender'),
      bodyData.getProperty('sender_steamid'), bodyData.getProperty('steamid'));
    const bodyUrl: string = this.firstText(bodyData.getProperty('url'), bodyData.getProperty('link'),
      bodyData.getProperty('target_url'));
    let imageUrl: string = this.firstText(bodyData.getProperty('image_url'), bodyData.getProperty('image'),
      bodyData.getProperty('icon_url'));
    if (tradeOfferId.length > 0) {
      url = 'https://steamcommunity.com/tradeoffer/' + tradeOfferId + '/';
    } else if (bodyUrl.length > 0) {
      url = this.normalizeSteamUrl(bodyUrl);
    } else if (notificationType === 13 && senderSteamId.length > 0) {
      url = 'https://steamcommunity.com/chat/';
    } else if (appId.length > 0) {
      url = 'https://store.steampowered.com/app/' + appId + '/';
    }
    if (imageUrl.startsWith('//')) {
      imageUrl = 'https:' + imageUrl;
    } else if (imageUrl.length <= 0 && appId.length > 0) {
      imageUrl = 'https://cdn.cloudflare.steamstatic.com/steam/apps/' + appId + '/header.jpg';
    }
    return new SteamNotificationPresentation(
      category,
      bodyTitle.length > 0 ? bodyTitle : title,
      bodyText.length > 0 ? bodyText : (commentText.length > 0 ? commentText : fallbackBody),
      url,
      source,
      imageUrl
    );
  }

  private appendNotificationSummary(
    response: SteamJsonValue,
    notificationCount: number,
    now: number,
    target: Array<SteamArkMessageItem>,
    contentLocale: SteamArkContentLocale
  ): void {
    this.appendPendingCount(response.getProperty('confirmation_count'), 'confirmation',
      SteamArkMessageCategory.TRADE,
      SteamMessageStrings.text(contentLocale, 'summary.confirmations.title'),
      SteamMessageStrings.text(contentLocale, 'summary.confirmations.body'),
      'https://steamcommunity.com/mobileconf/conf', now, target);
    this.appendPendingCount(response.getProperty('pending_gift_count'), 'gift',
      SteamArkMessageCategory.SYSTEM,
      SteamMessageStrings.text(contentLocale, 'summary.gifts.title'),
      SteamMessageStrings.text(contentLocale, 'summary.gifts.body'),
      'https://steamcommunity.com/my/inventory/#753_1', now, target);
    this.appendPendingCount(response.getProperty('pending_friend_count'), 'friend',
      SteamArkMessageCategory.FRIEND,
      SteamMessageStrings.text(contentLocale, 'summary.friends.title'),
      SteamMessageStrings.text(contentLocale, 'summary.friends.body'),
      'https://steamcommunity.com/my/friends/pending', now, target);
    this.appendPendingCount(response.getProperty('pending_family_invite_count'), 'family',
      SteamArkMessageCategory.FRIEND,
      SteamMessageStrings.text(contentLocale, 'summary.family.title'),
      SteamMessageStrings.text(contentLocale, 'summary.family.body'),
      'https://store.steampowered.com/account/familymanagement/', now, target);
    if (notificationCount <= 0) {
      this.appendPendingCount(response.getProperty('unread_count'), 'unread',
        SteamArkMessageCategory.SYSTEM,
        SteamMessageStrings.text(contentLocale, 'summary.unread.title'),
        SteamMessageStrings.text(contentLocale, 'summary.unread.body'),
        'https://steamcommunity.com/my/home/', now, target);
    }
  }

  private appendPendingCount(
    value: SteamJsonValue | null,
    id: string,
    category: SteamArkMessageCategory,
    title: string,
    bodyTemplate: string,
    url: string,
    now: number,
    target: Array<SteamArkMessageItem>
  ): void {
    const count: number = this.readInteger(value);
    if (count <= 0) {
      return;
    }
    target.push(new SteamArkMessageItem(
      'notification-' + id,
      category,
      title,
      SteamMessageStrings.format(bodyTemplate, 'count', count.toString()),
      url,
      'Steam',
      now,
      true
    ));
  }

  private firstText(
    first: SteamJsonValue | null,
    second: SteamJsonValue | null,
    third: SteamJsonValue | null
  ): string {
    const firstText: string = this.readScalarText(first);
    if (firstText.length > 0) {
      return firstText;
    }
    const secondText: string = this.readScalarText(second);
    return secondText.length > 0 ? secondText : this.readScalarText(third);
  }

  private normalizeSteamUrl(value: string): string {
    if (value.startsWith('https://') || value.startsWith('http://')) {
      return value;
    }
    return value.startsWith('/') ? 'https://steamcommunity.com' + value :
      'https://steamcommunity.com/' + value;
  }

  private appendPromotions(body: string, now: number, target: Array<SteamArkMessageItem>,
    contentLocale: SteamArkContentLocale): void {
    const root: SteamJsonValue = SteamJsonParser.parse(body, steamArkCoreLogger);
    const specials: SteamJsonValue | null = root.getProperty('specials');
    const values: SteamJsonValue | null = specials === null ? null : specials.getProperty('items');
    if (values === null || values.kind !== SteamJsonValueKind.ARRAY) {
      return;
    }
    const limit: number = Math.min(values.items.length, MAX_PROMOTIONS);
    for (let index: number = 0; index < limit; index++) {
      const item: SteamJsonValue = values.items[index];
      if (item.kind !== SteamJsonValueKind.OBJECT) {
        continue;
      }
      const appId: number = this.readInteger(item.getProperty('id'));
      const name: string = this.readString(item.getProperty('name'));
      const discount: number = this.readInteger(item.getProperty('discount_percent'));
      const headerImage: string = this.readString(item.getProperty('header_image'));
      const tinyImage: string = this.readString(item.getProperty('tiny_image'));
      if (appId <= 0 || name.length <= 0 || discount <= 0) {
        continue;
      }
      target.push(new SteamArkMessageItem(
        'promotion-' + appId.toString(),
        SteamArkMessageCategory.PROMOTION,
        name,
        SteamMessageStrings.format(
          SteamMessageStrings.text(contentLocale, 'promotion.body'), 'discount', discount.toString()),
        'https://store.steampowered.com/app/' + appId.toString() + '/',
        SteamMessageStrings.text(contentLocale, 'notif.source.store'),
        now,
        false,
        headerImage.length > 0 ? headerImage : tinyImage
      ));
    }
  }

  private readInteger(value: SteamJsonValue | null): number {
    if (value === null || value.kind !== SteamJsonValueKind.NUMBER) {
      return 0;
    }
    const result: number = Number(value.numberValue);
    return Number.isSafeInteger(result) && result > 0 ? result : 0;
  }

  private readScalarText(value: SteamJsonValue | null): string {
    if (value === null) {
      return '';
    }
    if (value.kind === SteamJsonValueKind.STRING) {
      return value.stringValue.trim();
    }
    if (value.kind === SteamJsonValueKind.NUMBER) {
      return value.numberValue.trim();
    }
    return '';
  }

  private readString(value: SteamJsonValue | null): string {
    return value !== null && value.kind === SteamJsonValueKind.STRING ? value.stringValue.trim() : '';
  }

  private readBoolean(value: SteamJsonValue | null, fallback: boolean): boolean {
    return value !== null && value.kind === SteamJsonValueKind.BOOLEAN ? value.booleanValue : fallback;
  }

  private appendWarning(existing: string, warning: string): string {
    return existing.length > 0 ? existing + '; ' + warning : warning;
  }

  private static toProxy(profile: SteamAccountProfile, password: string): NGFProxyConfiguration {
    if (profile.proxy.kind === SteamProxyKind.DIRECT) {
      return NGFProxyConfiguration.direct();
    }
    if (profile.proxy.kind === SteamProxyKind.HTTP) {
      return NGFProxyConfiguration.http(profile.proxy.host, profile.proxy.port, profile.proxy.username, password);
    }
    if (profile.proxy.kind === SteamProxyKind.SOCKS5) {
      return NGFProxyConfiguration.socks5(profile.proxy.host, profile.proxy.port, profile.proxy.username, password);
    }
    return NGFProxyConfiguration.system();
  }
}
