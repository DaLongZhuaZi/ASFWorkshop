import { logger } from 'ngf_framework';
import { SteamAuthError, SteamAuthErrorSupport } from 'steam_core';

const ROOT_TAG: string = 'SteamArk';

/**
 * SteamArk logging boundary. Callers must pass only non-secret context.
 * Credentials, tokens, cookies, challenge values and full inventory data are
 * intentionally not accepted by this helper's convenience methods.
 */
export class SteamArkLog {
  static debug(scope: string, message: string): void {
    logger.debug(SteamArkLog.tag(scope), message);
  }

  static info(scope: string, message: string): void {
    logger.info(SteamArkLog.tag(scope), message);
  }

  static warn(scope: string, message: string): void {
    logger.warn(SteamArkLog.tag(scope), message);
  }

  static error(scope: string, message: string): void {
    logger.error(SteamArkLog.tag(scope), message);
  }

  static lifecycle(scope: string, event: string, details: string = ''): void {
    logger.lifecycle(SteamArkLog.tag(scope), event, details);
  }

  static startup(scope: string, step: string, details: string = ''): void {
    logger.startup(SteamArkLog.tag(scope), step, details);
  }

  static state(scope: string, from: string, to: string, details: string = ''): void {
    logger.stateChange(SteamArkLog.tag(scope), from, to, details);
  }

  static performance(scope: string, metric: string, startedAt: number): void {
    const elapsed: number = Math.max(0, Date.now() - startedAt);
    logger.performance(SteamArkLog.tag(scope), metric, elapsed, 'ms');
  }

  static accountId(accountId: string): string {
    return SteamArkLog.mask(accountId, 2, 2);
  }

  static steamId64(steamId64: string): string {
    return SteamArkLog.mask(steamId64, 3, 3);
  }

  static opaqueId(value: string): string {
    return SteamArkLog.mask(value, 2, 2);
  }

  static errorKind(error: Error | Object | string | number | boolean | null | undefined): string {
    if (error instanceof SteamAuthError) {
      return SteamAuthErrorSupport.diagnosticLabel(error);
    }
    if (error instanceof Error && error.name.length > 0) {
      return error.name;
    }
    return 'NonError';
  }

  private static tag(scope: string): string {
    const normalized: string = scope.trim();
    return normalized.length > 0 ? ROOT_TAG + '.' + normalized : ROOT_TAG;
  }

  private static mask(value: string, prefixLength: number, suffixLength: number): string {
    const normalized: string = value.trim();
    if (normalized.length <= prefixLength + suffixLength) {
      return '****';
    }
    return normalized.substring(0, prefixLength) + '****' +
      normalized.substring(normalized.length - suffixLength);
  }
}
