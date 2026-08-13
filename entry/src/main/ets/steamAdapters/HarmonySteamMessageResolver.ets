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
const PROMOTIONS_URL: string = 'https://store.steampowered.com/api/featuredcategories/?cc=CN&l=schinese';
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

/** Read-only aggregation of authenticated Steam notifications, trades and store promotions. */
export class HarmonySteamMessageResolver implements ISteamArkMessageResolver {
  async resolve(
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    proxyPassword: string = ''
  ): Promise<SteamArkMessageSyncResult> {
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
          this.notificationsUrl(credentials.accessToken),
          proxy,
          'https://steamcommunity.com/my/home/'
        );
        if (notificationResponse.isOk()) {
          this.appendNotifications(notificationResponse.body, now, items);
          successfulSources++;
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
          this.tradeOffersUrl(credentials.accessToken),
          proxy,
          'https://steamcommunity.com/my/tradeoffers/'
        );
        if (tradeOffersResponse.isOk()) {
          this.appendTradeOffers(tradeOffersResponse.body, now, items);
          successfulSources++;
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
          PROMOTIONS_URL,
          proxy,
          'https://store.steampowered.com/'
        );
        if (promotionResponse.isOk()) {
          this.appendPromotions(promotionResponse.body, now, items);
          successfulSources++;
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

  private tradeOffersUrl(accessToken: string): string {
    return TRADE_OFFERS_URL + '?access_token=' + encodeURIComponent(accessToken) +
      '&get_sent_offers=1&get_received_offers=1&get_descriptions=1&active_only=1' +
      '&time_historical_cutoff=4294967295&language=english';
  }

  private notificationsUrl(accessToken: string): string {
    return STEAM_NOTIFICATIONS_URL + '?access_token=' + encodeURIComponent(accessToken) +
      '&include_hidden=false&include_confirmation_count=true&include_pinned_counts=true' +
      '&include_read=true&count_only=false&language=6';
  }

  private appendTradeOffers(body: string, now: number, target: Array<SteamArkMessageItem>): void {
    const root: SteamJsonValue = SteamJsonParser.parse(body, steamArkCoreLogger);
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('Steam trade offer response is not an object');
    }
    const response: SteamJsonValue | null = root.getProperty('response');
    if (response === null || response.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('Steam trade offer response body is missing response');
    }
    const descriptions: SteamJsonValue | null = response.getProperty('descriptions');
    this.appendTradeOfferArray(response.getProperty('trade_offers_received'), descriptions, false, now, target);
    this.appendTradeOfferArray(response.getProperty('trade_offers_sent'), descriptions, true, now, target);
    SteamArkLog.debug(TAG, 'trade offer details parsed; total=' + target.length.toString());
  }

  private appendTradeOfferArray(value: SteamJsonValue | null, descriptions: SteamJsonValue | null,
    sent: boolean, now: number,
    target: Array<SteamArkMessageItem>): void {
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
      const direction: string = sent ? '已发送' : '收到';
      const status: string = this.tradeOfferState(state);
      const body: string = direction + '交易报价，状态：' + status +
        '；对方账户：' + (partner.length > 0 ? partner : '未知') +
        '；我方物品：' + giveCount.toString() + ' 件；对方物品：' + receiveCount.toString() + ' 件';
      target.push(new SteamArkMessageItem(
        'trade-offer-' + offerId,
        SteamArkMessageCategory.TRADE,
        (sent ? '已发送交易报价 #' : '收到交易报价 #') + offerId +
          (visual.name.length > 0 ? ' · ' + visual.name : ''),
        body,
        'https://steamcommunity.com/tradeoffer/' + offerId + '/',
        'Steam 交易',
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

  private arrayLength(value: SteamJsonValue | null): number {
    return value !== null && value.kind === SteamJsonValueKind.ARRAY ? value.items.length : 0;
  }

  private tradeOfferState(state: number): string {
    switch (state) {
      case 1: return '无效';
      case 2: return '待处理';
      case 3: return '已接受';
      case 4: return '已还价';
      case 5: return '已过期';
      case 6: return '已取消';
      case 7: return '已拒绝';
      case 8: return '物品失效';
      case 9: return '等待移动端确认';
      case 10: return '已由移动端取消';
      case 11: return '交易保留中';
      default: return '状态未知';
    }
  }

  private appendNotifications(body: string, now: number, target: Array<SteamArkMessageItem>): void {
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
      notificationCount = this.appendNotificationArray(notifications, now, target);
    }
    this.appendNotificationSummary(response, notificationCount, now, target);
    SteamArkLog.debug(TAG, 'Steam notifications parsed; notifications=' + notificationCount.toString());
  }

  private appendNotificationArray(
    value: SteamJsonValue,
    now: number,
    target: Array<SteamArkMessageItem>
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
        this.resolveNotificationPresentation(notificationType, bodyData);
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
    bodyData: SteamJsonValue | null
  ): SteamNotificationPresentation {
    let category: SteamArkMessageCategory = SteamArkMessageCategory.SYSTEM;
    let title: string = 'Steam notification';
    let fallbackBody: string = 'Open Steam to view this notification';
    let url: string = 'https://steamcommunity.com/my/home/';
    let source: string = 'Steam Community';
    switch (notificationType) {
      case 2:
        title = 'Steam gift';
        fallbackBody = 'A Steam gift is waiting for you';
        url = 'https://steamcommunity.com/my/inventory/#753_1';
        break;
      case 3:
        title = 'Community reply';
        fallbackBody = 'A comment or community reply is waiting';
        url = 'https://steamcommunity.com/my/commentnotifications/';
        break;
      case 4:
        category = SteamArkMessageCategory.INVENTORY;
        title = 'Inventory update';
        fallbackBody = 'Your Steam inventory has new activity';
        url = 'https://steamcommunity.com/my/inventory/';
        break;
      case 5:
        category = SteamArkMessageCategory.FRIEND;
        title = 'Friend invitation';
        fallbackBody = 'You have a pending Steam friend invitation';
        url = 'https://steamcommunity.com/my/friends/pending';
        break;
      case 6:
        category = SteamArkMessageCategory.PROMOTION;
        title = 'Steam sale';
        fallbackBody = 'A major Steam sale is available';
        url = 'https://store.steampowered.com/';
        source = 'Steam Store';
        break;
      case 7:
        category = SteamArkMessageCategory.PROMOTION;
        title = 'Preload available';
        fallbackBody = 'A game is available to preload';
        source = 'Steam Store';
        break;
      case 8:
        category = SteamArkMessageCategory.PROMOTION;
        title = 'Wishlist update';
        fallbackBody = 'A title on your wishlist has new activity';
        url = 'https://store.steampowered.com/wishlist/';
        source = 'Steam Store';
        break;
      case 9:
        category = SteamArkMessageCategory.TRADE;
        title = 'Trade offer';
        fallbackBody = 'A Steam trade offer needs your attention';
        url = 'https://steamcommunity.com/my/tradeoffers/';
        source = 'Steam Trade';
        break;
      case 11:
        title = 'Steam Support';
        fallbackBody = 'Your Steam Support request has an update';
        url = 'https://help.steampowered.com/';
        source = 'Steam Support';
        break;
      case 13:
        category = SteamArkMessageCategory.FRIEND;
        title = 'Friend message';
        fallbackBody = 'You received a Steam chat message';
        url = 'https://steamcommunity.com/chat/';
        source = 'Steam Chat';
        break;
      case 14:
        title = 'Moderator message';
        fallbackBody = 'You received a Steam moderator message';
        break;
      case 16:
        category = SteamArkMessageCategory.FRIEND;
        title = 'Steam Families invitation';
        fallbackBody = 'You have a pending Steam Families invitation';
        url = 'https://store.steampowered.com/account/familymanagement/';
        break;
      case 25:
        title = 'Steam Guard request';
        fallbackBody = 'A Steam Guard sign-in request needs verification';
        url = 'https://store.steampowered.com/twofactor/manage';
        break;
      case 26:
        category = SteamArkMessageCategory.TRADE;
        title = 'Mobile confirmation';
        fallbackBody = 'A Steam action is waiting for mobile confirmation';
        url = 'https://steamcommunity.com/mobileconf/conf';
        source = 'Steam Guard';
        break;
      case 27:
        category = SteamArkMessageCategory.PROMOTION;
        title = 'Game event';
        fallbackBody = 'A game or group you follow has a new event';
        source = 'Steam Events';
        break;
      case 28:
        title = 'Steam Playtest invitation';
        fallbackBody = 'You have received a Steam Playtest invitation';
        break;
      case 29:
        category = SteamArkMessageCategory.TRADE;
        title = 'Trade reversal';
        fallbackBody = 'A Steam trade has been reversed';
        url = 'https://steamcommunity.com/my/tradehistory/';
        source = 'Steam Trade';
        break;
      case 30:
        title = 'Community action';
        fallbackBody = 'Steam has updated the status of reported content';
        break;
      default:
        fallbackBody = 'Steam notification type ' + notificationType.toString();
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
    target: Array<SteamArkMessageItem>
  ): void {
    this.appendPendingCount(response.getProperty('confirmation_count'), 'confirmation',
      SteamArkMessageCategory.TRADE, 'Mobile confirmations',
      'Steam actions waiting for mobile confirmation', 'https://steamcommunity.com/mobileconf/conf', now, target);
    this.appendPendingCount(response.getProperty('pending_gift_count'), 'gift',
      SteamArkMessageCategory.SYSTEM, 'Pending gifts', 'Steam gifts waiting for you',
      'https://steamcommunity.com/my/inventory/#753_1', now, target);
    this.appendPendingCount(response.getProperty('pending_friend_count'), 'friend',
      SteamArkMessageCategory.FRIEND, 'Pending friend invitations', 'Steam friend invitations waiting for you',
      'https://steamcommunity.com/my/friends/pending', now, target);
    this.appendPendingCount(response.getProperty('pending_family_invite_count'), 'family',
      SteamArkMessageCategory.FRIEND, 'Steam Families invitations', 'Steam Families invitations waiting for you',
      'https://store.steampowered.com/account/familymanagement/', now, target);
    if (notificationCount <= 0) {
      this.appendPendingCount(response.getProperty('unread_count'), 'unread',
        SteamArkMessageCategory.SYSTEM, 'Unread Steam notifications', 'Unread notifications reported by Steam',
        'https://steamcommunity.com/my/home/', now, target);
    }
  }

  private appendPendingCount(
    value: SteamJsonValue | null,
    id: string,
    category: SteamArkMessageCategory,
    title: string,
    body: string,
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
      body + ': ' + count.toString(),
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

  private appendPromotions(body: string, now: number, target: Array<SteamArkMessageItem>): void {
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
        'Steam Store discount: ' + discount.toString() + '%',
        'https://store.steampowered.com/app/' + appId.toString() + '/',
        'Steam Store',
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
