import {
  IClock,
  SteamCmClient,
  SteamCmClientOptions,
  SteamCredentialSet
} from 'steam_core';
import { IWebSocketClient, WebSocketClientFacade } from 'ngf_framework';
import {
  HarmonySteamClock,
  HarmonySteamCmScheduler
} from './HarmonySteamCmRuntime';
import { HarmonySteamCmWireTransport, HarmonySteamCmWireTransportOptions } from './HarmonySteamCmWireTransport';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';

const TAG: string = 'HarmonySteamCmClientFactory';

/**
 * Composition root for a HarmonyOS Steam CM session. No platform object is
 * passed into steam_core beyond its explicit transport and clock contracts.
 */
export class HarmonySteamCmClientFactory {
  static create(
    accountId: string,
    credentials: SteamCredentialSet,
    options: SteamCmClientOptions,
    wireOptions: HarmonySteamCmWireTransportOptions = new HarmonySteamCmWireTransportOptions()
  ): SteamCmClient {
    SteamArkLog.info(TAG, 'CM client creation started; account=' + SteamArkLog.accountId(accountId) +
      ', maxGames=' + options.maxGamesPlayedConcurrently.toString());
    const client: IWebSocketClient = new WebSocketClientFacade();
    const wire: HarmonySteamCmWireTransport = new HarmonySteamCmWireTransport(client, wireOptions);
    const scheduler: HarmonySteamCmScheduler = new HarmonySteamCmScheduler();
    const clock: IClock = new HarmonySteamClock();
    const cmClient = new SteamCmClient(accountId, credentials, wire, scheduler, clock, options, steamArkCoreLogger);
    SteamArkLog.info(TAG, 'CM client creation completed; account=' + SteamArkLog.accountId(accountId));
    return cmClient;
  }
}
