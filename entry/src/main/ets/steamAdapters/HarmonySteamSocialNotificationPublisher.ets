import {
  NGFNotificationRequest,
  NGFNotificationSlotType,
  NGFNotificationType,
  ngfSystem,
  ngfI18nManagerFacade
} from 'ngf_framework';
import {
  ISteamArkSocialNotificationPublisher,
  SteamArkChatMessage
} from '../steamServices/SteamArkSocialContracts';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkNotificationNavigation } from '../steamServices/SteamArkNotificationNavigation';
import { SteamArkLog } from '../steamServices/SteamArkLogger';

const TAG: string = 'HarmonySteamSocialNotificationPublisher';
const NOTIFICATION_ID_BASE: number = 10000;
const NOTIFICATION_ID_RANGE: number = 2000000000;

export class HarmonySteamSocialNotificationPublisher implements ISteamArkSocialNotificationPublisher {
  async publishIncomingMessage(
    accountId: string,
    friendSteamId64: string,
    senderDisplayName: string,
    message: SteamArkChatMessage
  ): Promise<void> {
    const content: string = message.message.trim();
    if (content.length <= 0 || message.outgoing) {
      return;
    }
    const fallbackTitle: string = ASFWorkshopProductIdentity.notificationTitle(
      ngfI18nManagerFacade.getCurrentLocale());
    const title: string = senderDisplayName.trim().length > 0
      ? senderDisplayName.trim()
      : fallbackTitle;
    const request: NGFNotificationRequest = new NGFNotificationRequest(
      this.conversationNotificationId(accountId, friendSteamId64),
      title,
      content,
      NGFNotificationType.BASIC,
      0,
      0,
      false,
      NGFNotificationSlotType.SOCIAL_COMMUNICATION
    );
    request.wantParameters = SteamArkNotificationNavigation.createOpenChatParameters(accountId, friendSteamId64);
    await ngfSystem.publishNotification(request);
    SteamArkLog.debug(TAG, 'incoming chat notification dispatched through NGF; account=' +
      SteamArkLog.accountId(accountId) + ', friend=' + SteamArkLog.steamId64(friendSteamId64));
  }

  private conversationNotificationId(accountId: string, friendSteamId64: string): number {
    const source: string = accountId.trim() + '|' + friendSteamId64.trim();
    let hash: number = 17;
    for (let index: number = 0; index < source.length; index++) {
      hash = (hash * 31 + source.charCodeAt(index)) % NOTIFICATION_ID_RANGE;
    }
    return NOTIFICATION_ID_BASE + hash;
  }
}
