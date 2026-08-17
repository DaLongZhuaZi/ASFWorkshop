import {
  NGFNotificationRequest,
  NGFNotificationSlotType,
  NGFNotificationType,
  ngfSystem,
  ngfI18nManagerFacade
} from 'ngf_framework';
import {
  ISteamArkFarmingNotificationPublisher
} from '../steamServices/SteamArkFarmingContracts';
import {
  SteamCardDropEvent,
  SteamFarmSnapshot,
  SteamGameDrop
} from 'steam_core';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkNotificationNavigation } from '../steamServices/SteamArkNotificationNavigation';
import { SteamArkLog } from '../steamServices/SteamArkLogger';

const TAG: string = 'HarmonySteamFarmingNotificationPublisher';
const NOTIFICATION_ID_BASE: number = 30000;
const NOTIFICATION_ID_RANGE: number = 2000000000;

export class HarmonySteamFarmingNotificationPublisher implements ISteamArkFarmingNotificationPublisher {
  async publishCardDrop(
    accountId: string,
    drop: SteamCardDropEvent,
    snapshot: SteamFarmSnapshot
  ): Promise<void> {
    const game: SteamGameDrop | null = this.findGame(snapshot, drop.appId);
    const fallbackTitle: string = ASFWorkshopProductIdentity.notificationTitle(
      ngfI18nManagerFacade.getCurrentLocale());
    const title: string = ngfI18nManagerFacade.resolveStringWithArgs(
      $r('app.string.steam_farm_card_drop_title'), []);
    const gameName: string = game !== null ? game.name.trim() : '';
    const remaining: number = game !== null ? game.cardsRemaining : 0;
    const lines: Array<string> = [];
    lines.push(gameName.length > 0
      ? gameName
      : ngfI18nManagerFacade.resolveStringWithArgs(
        $r('app.string.steam_farm_card_drop_app_id'), [drop.appId]));
    if (game !== null && remaining > 0) {
      lines.push(ngfI18nManagerFacade.resolveStringWithArgs(
        $r('app.string.steam_farm_card_drop_remaining'), [remaining.toString()]));
    }
    const content: string = lines.length > 0
      ? lines.join('\n')
      : fallbackTitle;
    const request: NGFNotificationRequest = new NGFNotificationRequest(
      this.cardDropNotificationId(accountId, drop),
      title,
      content,
      NGFNotificationType.LONG_TEXT,
      0,
      0,
      false,
      NGFNotificationSlotType.SERVICE_INFORMATION
    );
    request.wantParameters = SteamArkNotificationNavigation.createOpenFarmingParameters(accountId);
    await ngfSystem.publishNotification(request);
    SteamArkLog.debug(TAG, 'card drop notification dispatched through NGF; account=' +
      SteamArkLog.accountId(accountId) + ', app=' + drop.appId);
  }

  async publishFarmFinished(accountId: string, snapshot: SteamFarmSnapshot): Promise<void> {
    let remaining: number = 0;
    for (let index: number = 0; index < snapshot.games.length; index++) {
      remaining += snapshot.games[index].cardsRemaining;
    }
    const title: string = ngfI18nManagerFacade.resolveStringWithArgs(
      $r('app.string.steam_farm_finished_title'), []);
    const content: string = ngfI18nManagerFacade.resolveStringWithArgs(
      $r('app.string.steam_farm_finished_message'), [remaining.toString()]);
    const request: NGFNotificationRequest = new NGFNotificationRequest(
      this.farmFinishedNotificationId(accountId),
      title,
      content,
      NGFNotificationType.BASIC,
      0,
      0,
      false,
      NGFNotificationSlotType.SERVICE_INFORMATION
    );
    request.wantParameters = SteamArkNotificationNavigation.createOpenFarmingParameters(accountId);
    await ngfSystem.publishNotification(request);
    SteamArkLog.debug(TAG, 'farm finished notification dispatched through NGF; account=' +
      SteamArkLog.accountId(accountId));
  }

  private findGame(snapshot: SteamFarmSnapshot, appId: string): SteamGameDrop | null {
    for (let index: number = 0; index < snapshot.games.length; index++) {
      const game: SteamGameDrop = snapshot.games[index];
      if (game.appId === appId) {
        return game;
      }
    }
    return null;
  }

  private cardDropNotificationId(accountId: string, drop: SteamCardDropEvent): number {
    const source: string = accountId.trim() + '|card|' + drop.appId + '|' +
      drop.assetId + '|' + drop.receivedAtEpochSeconds.toString();
    let hash: number = 19;
    for (let index: number = 0; index < source.length; index++) {
      hash = (hash * 31 + source.charCodeAt(index)) % NOTIFICATION_ID_RANGE;
    }
    return NOTIFICATION_ID_BASE + hash;
  }

  private farmFinishedNotificationId(accountId: string): number {
    const source: string = accountId.trim() + '|farm-finished';
    let hash: number = 23;
    for (let index: number = 0; index < source.length; index++) {
      hash = (hash * 31 + source.charCodeAt(index)) % NOTIFICATION_ID_RANGE;
    }
    return NOTIFICATION_ID_BASE + hash;
  }
}
