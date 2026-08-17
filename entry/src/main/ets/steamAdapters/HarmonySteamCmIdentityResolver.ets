import {
  ISteamCmIdentityResolver,
  SteamCmClient,
  SteamCmClientOptions,
  SteamCmEvent,
  SteamCmEventType,
  SteamCredentialSet,
  SteamJwt
} from 'steam_core';
import {
  HarmonySteamCmClientFactory
} from './HarmonySteamCmClientFactory';
import {
  HarmonySteamCmWireTransportOptions
} from './HarmonySteamCmWireTransport';
import {
  HarmonySteamCmMultiDecompressor
} from './HarmonySteamCmRuntime';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';

const TAG: string = 'HarmonySteamCmIdentityResolver';
const IDENTITY_RESOLUTION_TIMEOUT_MILLISECONDS: number = 30000;

/**
 * Completes the one CM logon step that QR token polling cannot provide.
 * Steam's QR poll response contains tokens and account_name, but the
 * authoritative SteamID64 arrives in CMsgClientLogonResponse.
 */
export class HarmonySteamCmIdentityResolver implements ISteamCmIdentityResolver {
  private readonly server: string;
  private readonly wireOptions: HarmonySteamCmWireTransportOptions;

  constructor(server: string, wireOptions: HarmonySteamCmWireTransportOptions) {
    this.server = server;
    this.wireOptions = wireOptions;
  }

  resolveSteamId64(accountId: string, credentials: SteamCredentialSet): Promise<string> {
    SteamArkLog.info(TAG, 'CM identity resolution started; account=' + SteamArkLog.accountId(accountId) +
      ', credentialFieldsPresent=' + String(credentials.accessToken.length > 0 || credentials.refreshToken.length > 0));
    // The refresh token is a Steam-issued JWT whose "sub" claim is the
    // SteamID64: read it offline before paying for a full CM logon.
    const jwtSteamId64: string = SteamJwt.subjectClaim(credentials.refreshToken);
    if (jwtSteamId64.length > 0 && jwtSteamId64 !== '0') {
      SteamArkLog.info(TAG, 'CM identity resolved from refresh token subject; account=' +
        SteamArkLog.accountId(accountId) + ', steamId64=' + SteamArkLog.steamId64(jwtSteamId64));
      return Promise.resolve(jwtSteamId64);
    }
    const options = new SteamCmClientOptions(
      this.server,
      '',
      ASFWorkshopProductIdentity.DEVICE_FRIENDLY_NAME,
      65581,
      1771,
      'english',
      0,
      30,
      2,
      30,
      1,
      32,
      '',
      '',
      true,
      false,
      steamArkCoreLogger,
      IDENTITY_RESOLUTION_TIMEOUT_MILLISECONDS,
      // Real CM servers frequently wrap ClientLogonResponse in a CMsgMulti
      // gzip envelope; without a decompressor the logon decode fails and the
      // identity resolution times out. Every other factory path injects one.
      new HarmonySteamCmMultiDecompressor()
    );
    const client: SteamCmClient = HarmonySteamCmClientFactory.create(
      accountId,
      credentials,
      options,
      this.wireOptions
    );

    return new Promise<string>((resolve: (value: string) => void,
      reject: (error: Error) => void): void => {
      let settled: boolean = false;
      let timeoutHandle: number = -1;
      const finish = (error: Error | null, steamId64: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timeoutHandle >= 0) {
          clearTimeout(timeoutHandle);
          timeoutHandle = -1;
        }
        client.dispose();
        void client.disconnect().catch((_closeError: Error): void => {
          return;
        });
        if (error !== null) {
          SteamArkLog.warn(TAG, 'CM identity resolution failed; account=' + SteamArkLog.accountId(accountId) +
            ', errorType=' + SteamArkLog.errorKind(error));
          reject(error);
          return;
        }
        SteamArkLog.info(TAG, 'CM identity resolution completed; account=' + SteamArkLog.accountId(accountId) +
          ', steamId64=' + SteamArkLog.steamId64(steamId64));
        resolve(steamId64);
      };
      const listener = (event: SteamCmEvent): void => {
        SteamArkLog.debug(TAG, 'CM identity event received; account=' + SteamArkLog.accountId(accountId) +
          ', type=' + String(event.type));
        if (event.type === SteamCmEventType.LOGGED_ON) {
          const session = event.session;
          const steamId64 = session === null ? '' : session.steamId64.trim();
          if (steamId64.length > 0 && steamId64 !== '0') {
            finish(null, steamId64);
            return;
          }
          finish(new Error('Steam CM logon response did not contain SteamID64'), '');
          return;
        }
        if (event.type === SteamCmEventType.AUTH_CHALLENGE ||
          event.type === SteamCmEventType.EXPIRED ||
          event.type === SteamCmEventType.ERROR) {
          const message = event.message.length > 0
            ? event.message
            : 'Steam CM identity logon failed';
          finish(new Error(message), '');
        }
      };

      client.addEventListener(listener);
      timeoutHandle = setTimeout((): void => {
        SteamArkLog.warn(TAG, 'CM identity resolution timed out; account=' + SteamArkLog.accountId(accountId));
        finish(new Error('Steam CM identity logon timed out'), '');
      }, IDENTITY_RESOLUTION_TIMEOUT_MILLISECONDS);
      client.connect().catch((error: Error): void => {
        SteamArkLog.warn(TAG, 'CM identity client connect failed; account=' + SteamArkLog.accountId(accountId) +
          ', errorType=' + SteamArkLog.errorKind(error));
        finish(error, '');
      });
    });
  }
}
