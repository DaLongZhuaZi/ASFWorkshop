import {
  NGFNotificationRequest,
  NGFNotificationSlotType,
  NGFNotificationType,
  ngfSystem,
  ngfI18nManagerFacade
} from 'ngf_framework';
import {
  ISteamArkMessageNotificationPublisher,
  SteamArkMessageItem
} from '../steamServices/SteamArkMessageContracts';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkNotificationNavigation } from '../steamServices/SteamArkNotificationNavigation';
import { SteamArkLog } from '../steamServices/SteamArkLogger';

const TAG: string = 'HarmonySteamMessageNotificationPublisher';
const NOTIFICATION_ID_BASE: number = 400000000;
const NOTIFICATION_ID_RANGE: number = 1600000000;

/** Bridges new authenticated Steam message-center entries to the NGF notification facade. */
export class HarmonySteamMessageNotificationPublisher implements ISteamArkMessageNotificationPublisher {
  async publishSynchronizedMessage(accountId: string, item: SteamArkMessageItem): Promise<void> {
    if (!item.unread || item.id.trim().length <= 0) {
      return;
    }
    const fallbackTitle: string = ASFWorkshopProductIdentity.notificationTitle(
      ngfI18nManagerFacade.getCurrentLocale());
    const title: string = item.title.trim().length > 0
      ? item.title.trim()
      : fallbackTitle;
    const content: string = item.body.trim().length > 0
      ? item.body.trim()
      : fallbackTitle;
    const request: NGFNotificationRequest = new NGFNotificationRequest(
      this.messageNotificationId(accountId, item.id),
      title,
      content,
      NGFNotificationType.BASIC,
      0,
      0,
      false,
      NGFNotificationSlotType.SOCIAL_COMMUNICATION
    );
    request.wantParameters = SteamArkNotificationNavigation.createOpenMessageParameters(accountId, item.id);
    await ngfSystem.publishNotification(request);
    SteamArkLog.debug(TAG, 'message-center notification dispatched through NGF; account=' +
      SteamArkLog.accountId(accountId) + ', message=' + SteamArkLog.opaqueId(item.id));
  }

  private messageNotificationId(accountId: string, messageId: string): number {
    const source: string = accountId.trim() + '|' + messageId.trim();
    let hash: number = 17;
    for (let index: number = 0; index < source.length; index++) {
      hash = (hash * 31 + source.charCodeAt(index)) % NOTIFICATION_ID_RANGE;
    }
    return NOTIFICATION_ID_BASE + hash;
  }
}
