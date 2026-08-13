import { ISteamCoreLogger } from 'steam_core';
import { SteamArkLog } from './SteamArkLogger';

const TAG_PREFIX: string = 'Core.';

/** Bridges the detachable core observability contract to the app logger. */
export class SteamArkCoreLogger implements ISteamCoreLogger {
  debug(scope: string, message: string): void {
    SteamArkLog.debug(SteamArkCoreLogger.scope(scope), message);
  }

  info(scope: string, message: string): void {
    SteamArkLog.info(SteamArkCoreLogger.scope(scope), message);
  }

  warn(scope: string, message: string): void {
    SteamArkLog.warn(SteamArkCoreLogger.scope(scope), message);
  }

  error(scope: string, message: string): void {
    SteamArkLog.error(SteamArkCoreLogger.scope(scope), message);
  }

  state(scope: string, from: string, to: string, details: string): void {
    SteamArkLog.state(SteamArkCoreLogger.scope(scope), from, to, details);
  }

  private static scope(scope: string): string {
    const normalized: string = scope.trim();
    return normalized.length > 0 ? TAG_PREFIX + normalized : 'Core';
  }
}

export const steamArkCoreLogger: ISteamCoreLogger = new SteamArkCoreLogger();
