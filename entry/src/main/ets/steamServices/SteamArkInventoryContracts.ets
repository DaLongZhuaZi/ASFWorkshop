import {
  SteamAccountProfile,
  SteamCredentialSet,
  SteamInventoryPage,
  SteamInventoryQuery,
  SteamSessionSnapshot
} from 'steam_core';

/** Application boundary for one isolated, read-only Steam inventory session. */
export interface ISteamArkInventoryAdapter {
  open(accountId: string, credentials: SteamCredentialSet): Promise<SteamSessionSnapshot>;
  sync(accountId: string, query: SteamInventoryQuery): Promise<SteamInventoryPage>;
  close(accountId: string): Promise<void>;
  readonly session: SteamSessionSnapshot;
}

/** Platform adapter factory kept outside steam_core for fake-host testing and open-source reuse. */
export interface ISteamArkInventoryAdapterFactory {
  create(profile: SteamAccountProfile, proxyPassword?: string): ISteamArkInventoryAdapter;
}
