import {
  ISteamAuthService,
  SteamAccountProfile
} from 'steam_core';

/** Host factory for one account's isolated modern Steam authentication session. */
export interface ISteamArkAuthServiceFactory {
  create(profile: SteamAccountProfile, proxyPassword?: string): ISteamAuthService;
}
