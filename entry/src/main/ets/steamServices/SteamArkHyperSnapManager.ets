import { hyperSnapManager } from '@kit.AbilityKit';
import { SteamArkLog } from './SteamArkLogger';

const TAG: string = 'SteamArkHyperSnapManager';

/**
 * Preference key persisted through the settings store so the settings page
 * can restore the draft switch state across sessions. The system itself also
 * persists the enable flag across reboots.
 */
export const STEAM_ARK_HYPER_SNAP_ENABLED_STORAGE_KEY: string = 'steam_ark_hyper_snap_enabled';

export enum SteamArkHyperSnapFailureKind {
  NONE = 0,
  SERVICE_UNAVAILABLE = 1,
  UNKNOWN = 2
}

export class SteamArkHyperSnapResult {
  readonly applied: boolean;
  readonly failureKind: SteamArkHyperSnapFailureKind;

  constructor(applied: boolean, failureKind: SteamArkHyperSnapFailureKind) {
    this.applied = applied;
    this.failureKind = failureKind;
  }
}

/**
 * Product-layer facade over the Hyper Snap quick launch API (since API 24).
 *
 * Wraps the system calls with failure classification and structured logging so
 * pages and the recovery coordinator never touch @kit.AbilityKit directly.
 * The system ultimately decides whether to create or use snapshots based on
 * application compatibility, resource availability and system policies.
 */
export class SteamArkHyperSnapManager {
  /**
   * Declares the application's compatibility with Hyper Snap optimization.
   * BusinessError 16000150 means the system service could not process the
   * request (e.g. the device system does not provide the HyperSnap service).
   */
  setEnabled(enabled: boolean): SteamArkHyperSnapResult {
    try {
      hyperSnapManager.setHyperSnapEnabled(enabled);
      SteamArkLog.info(TAG, 'hyper snap enable flag applied; enabled=' + String(enabled));
      return new SteamArkHyperSnapResult(true, SteamArkHyperSnapFailureKind.NONE);
    } catch (error) {
      const failureKind: SteamArkHyperSnapFailureKind =
        SteamArkHyperSnapManager.classifyFailure(error);
      SteamArkLog.warn(TAG, 'hyper snap enable flag rejected; errorType=' + SteamArkLog.errorKind(error) +
        ', failureKind=' + SteamArkHyperSnapManager.failureKindLabel(failureKind) +
        ', detail=' + SteamArkHyperSnapManager.errorDetail(error));
      return new SteamArkHyperSnapResult(false, failureKind);
    }
  }

  /**
   * Requests recreation of the Hyper Snap process snapshot. The system
   * discards the current snapshot and recreates it during an idle period.
   */
  rebuildSnapshot(): SteamArkHyperSnapResult {
    try {
      hyperSnapManager.requestRebuildHyperSnap();
      SteamArkLog.info(TAG, 'hyper snap rebuild request accepted');
      return new SteamArkHyperSnapResult(true, SteamArkHyperSnapFailureKind.NONE);
    } catch (error) {
      const failureKind: SteamArkHyperSnapFailureKind =
        SteamArkHyperSnapManager.classifyFailure(error);
      SteamArkLog.warn(TAG, 'hyper snap rebuild request rejected; errorType=' + SteamArkLog.errorKind(error) +
        ', failureKind=' + SteamArkHyperSnapManager.failureKindLabel(failureKind) +
        ', detail=' + SteamArkHyperSnapManager.errorDetail(error));
      return new SteamArkHyperSnapResult(false, failureKind);
    }
  }

  private static classifyFailure(error: Object): SteamArkHyperSnapFailureKind {
    if (error instanceof Error) {
      const message: string = error.message;
      if (message.indexOf('system service') >= 0 || message.indexOf('16000150') >= 0) {
        return SteamArkHyperSnapFailureKind.SERVICE_UNAVAILABLE;
      }
    }
    return SteamArkHyperSnapFailureKind.UNKNOWN;
  }

  private static failureKindLabel(kind: SteamArkHyperSnapFailureKind): string {
    switch (kind) {
      case SteamArkHyperSnapFailureKind.SERVICE_UNAVAILABLE:
        return 'service_unavailable';
      case SteamArkHyperSnapFailureKind.UNKNOWN:
        return 'unknown';
      case SteamArkHyperSnapFailureKind.NONE:
      default:
        return 'none';
    }
  }

  private static errorDetail(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return String(error);
  }
}

export const steamArkHyperSnapManager: SteamArkHyperSnapManager = new SteamArkHyperSnapManager();
