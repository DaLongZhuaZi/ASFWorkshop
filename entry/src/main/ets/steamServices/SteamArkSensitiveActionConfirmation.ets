import {
  SteamArkSensitiveAction,
  SteamArkSensitiveActionAuditEntry,
  SteamArkSensitiveActionContext
} from './SteamArkSensitiveActionAudit';
import { SteamArkLog } from './SteamArkLogger';

const TAG: string = 'SteamArkSensitiveActionConfirmation';
const MAX_ASSET_ID_LENGTH: number = 20;
const MAX_CONTEXT_ID_LENGTH: number = 20;
const MAX_APP_ID_LENGTH: number = 20;
const MAX_DISPLAY_TEXT_LENGTH: number = 256;

/** A non-secret inventory line used only to render a human review snapshot. */
export class SteamArkAssetConfirmationItem {
  readonly assetId: string;
  readonly appId: string;
  readonly contextId: string;
  readonly amount: number;
  readonly displayName: string;
  readonly marketHashName: string;

  constructor(
    assetId: string,
    appId: string,
    contextId: string,
    amount: number = 1,
    displayName: string = '',
    marketHashName: string = ''
  ) {
    this.assetId = SteamArkAssetConfirmationItem.normalizeDecimalIdentifier(assetId, MAX_ASSET_ID_LENGTH);
    this.appId = SteamArkAssetConfirmationItem.normalizeDecimalIdentifier(appId, MAX_APP_ID_LENGTH);
    this.contextId = SteamArkAssetConfirmationItem.normalizeDecimalIdentifier(contextId, MAX_CONTEXT_ID_LENGTH);
    this.amount = Number.isSafeInteger(amount) && amount > 0 && amount <= 1000000 ? amount : -1;
    this.displayName = SteamArkAssetConfirmationItem.normalizeDisplayText(displayName);
    this.marketHashName = SteamArkAssetConfirmationItem.normalizeDisplayText(marketHashName);
  }

  isValid(): boolean {
    return this.assetId.length > 0 &&
      this.appId.length > 0 &&
      this.contextId.length > 0 &&
      this.amount > 0 &&
      this.displayName.length <= MAX_DISPLAY_TEXT_LENGTH &&
      this.marketHashName.length <= MAX_DISPLAY_TEXT_LENGTH;
  }

  private static normalizeDecimalIdentifier(value: string, maxLength: number): string {
    const trimmed: string = value.trim();
    if (trimmed.length <= 0 || trimmed.length > maxLength) {
      return '';
    }
    for (let index = 0; index < trimmed.length; index++) {
      const code: number = trimmed.charCodeAt(index);
      if (code < 48 || code > 57) {
        return '';
      }
    }
    return trimmed;
  }

  private static normalizeDisplayText(value: string): string {
    const trimmed: string = value.trim();
    if (trimmed.length > MAX_DISPLAY_TEXT_LENGTH) {
      return '';
    }
    for (let index = 0; index < trimmed.length; index++) {
      if (trimmed.charCodeAt(index) < 32) {
        return '';
      }
    }
    return trimmed;
  }
}

/** Only these actions may be paired with a concrete asset review. */
export class SteamArkAssetConfirmationPolicy {
  static requiresConfirmation(action: SteamArkSensitiveAction): boolean {
    switch (action) {
      case SteamArkSensitiveAction.INVENTORY_WRITE:
      case SteamArkSensitiveAction.BADGE_CRAFT:
      case SteamArkSensitiveAction.TRADE_PREVIEW:
      case SteamArkSensitiveAction.TRADE_ACCEPT:
      case SteamArkSensitiveAction.TRADE_DECLINE:
      case SteamArkSensitiveAction.TRADE_CANCEL:
      case SteamArkSensitiveAction.MOBILE_CONFIRM:
      case SteamArkSensitiveAction.REDEEM:
      case SteamArkSensitiveAction.ASSET_TRANSFER:
        return true;
      case SteamArkSensitiveAction.PRIVACY_VERIFICATION:
      default:
        return false;
    }
  }

  static isKnownAction(action: SteamArkSensitiveAction): boolean {
    return action === SteamArkSensitiveAction.PRIVACY_VERIFICATION ||
      SteamArkAssetConfirmationPolicy.requiresConfirmation(action);
  }
}

/** Input to the confirmation builder. It cannot execute an inventory operation. */
export class SteamArkAssetConfirmationRequest {
  readonly action: SteamArkSensitiveAction;
  readonly context: SteamArkSensitiveActionContext;
  readonly items: Array<SteamArkAssetConfirmationItem>;
  readonly expiresAtEpochSeconds: number;

  constructor(
    action: SteamArkSensitiveAction,
    context: SteamArkSensitiveActionContext,
    items: Array<SteamArkAssetConfirmationItem>,
    expiresAtEpochSeconds: number
  ) {
    this.action = action;
    this.context = context;
    this.items = items.slice();
    this.expiresAtEpochSeconds = expiresAtEpochSeconds;
  }
}

/** Short-lived review data. It is deliberately not persisted or executable. */
export class SteamArkAssetConfirmationSnapshot {
  static readonly MAX_ASSET_ITEMS: number = 500;
  static readonly MAX_LIFETIME_SECONDS: number = 120;
  readonly confirmationId: string;
  readonly action: SteamArkSensitiveAction;
  readonly accountId: string;
  readonly steamId64: string;
  readonly items: Array<SteamArkAssetConfirmationItem>;
  readonly createdAtEpochSeconds: number;
  readonly expiresAtEpochSeconds: number;

  constructor(
    confirmationId: string,
    action: SteamArkSensitiveAction,
    context: SteamArkSensitiveActionContext,
    items: Array<SteamArkAssetConfirmationItem>,
    createdAtEpochSeconds: number,
    expiresAtEpochSeconds: number
  ) {
    this.confirmationId = SteamArkSensitiveActionAuditEntry.normalizeIdentifier(confirmationId, 96);
    this.action = action;
    this.accountId = context.accountId;
    this.steamId64 = context.steamId64;
    this.items = items.slice();
    this.createdAtEpochSeconds = createdAtEpochSeconds;
    this.expiresAtEpochSeconds = expiresAtEpochSeconds;
  }

  isValidAt(nowEpochSeconds: number): boolean {
    if (!SteamArkAssetConfirmationPolicy.requiresConfirmation(this.action)) {
      return false;
    }
    if (this.confirmationId.length <= 0 || this.accountId.length <= 0 || this.steamId64.length <= 0) {
      return false;
    }
    if (!Number.isSafeInteger(this.createdAtEpochSeconds) || this.createdAtEpochSeconds <= 0) {
      return false;
    }
    if (!Number.isSafeInteger(this.expiresAtEpochSeconds) ||
      this.expiresAtEpochSeconds <= this.createdAtEpochSeconds) {
      return false;
    }
    if (this.expiresAtEpochSeconds - this.createdAtEpochSeconds > SteamArkAssetConfirmationSnapshot.MAX_LIFETIME_SECONDS) {
      return false;
    }
    if (!Number.isSafeInteger(nowEpochSeconds) || nowEpochSeconds < this.createdAtEpochSeconds) {
      return false;
    }
    if (nowEpochSeconds >= this.expiresAtEpochSeconds) {
      return false;
    }
    if (this.items.length <= 0 || this.items.length > SteamArkAssetConfirmationSnapshot.MAX_ASSET_ITEMS) {
      return false;
    }
    const assetIds: Set<string> = new Set<string>();
    for (let index = 0; index < this.items.length; index++) {
      const item: SteamArkAssetConfirmationItem = this.items[index];
      if (!item.isValid() || assetIds.has(item.assetId)) {
        return false;
      }
      assetIds.add(item.assetId);
    }
    return true;
  }

  matches(action: SteamArkSensitiveAction, context: SteamArkSensitiveActionContext): boolean {
    return this.action === action &&
      this.accountId === context.accountId &&
      this.steamId64 === context.steamId64;
  }
}

export enum SteamArkAssetConfirmationError {
  NONE = 'none',
  UNSUPPORTED_ACTION = 'unsupported_action',
  INVALID_CONTEXT = 'invalid_context',
  EMPTY_ASSET_LIST = 'empty_asset_list',
  TOO_MANY_ASSETS = 'too_many_assets',
  INVALID_ASSET = 'invalid_asset',
  DUPLICATE_ASSET = 'duplicate_asset',
  INVALID_EXPIRATION = 'invalid_expiration',
  INVALID_CONFIRMATION_ID = 'invalid_confirmation_id'
}

export class SteamArkAssetConfirmationResult {
  readonly snapshot: SteamArkAssetConfirmationSnapshot | null;
  readonly error: SteamArkAssetConfirmationError;
  readonly accepted: boolean;

  constructor(
    snapshot: SteamArkAssetConfirmationSnapshot | null,
    error: SteamArkAssetConfirmationError
  ) {
    this.snapshot = snapshot;
    this.error = error;
    this.accepted = snapshot !== null && error === SteamArkAssetConfirmationError.NONE;
  }
}

export interface ISteamArkConfirmationClock {
  nowEpochSeconds(): number;
}

export interface ISteamArkConfirmationIdGenerator {
  create(): string;
}

class SteamArkSystemConfirmationClock implements ISteamArkConfirmationClock {
  nowEpochSeconds(): number {
    return Math.floor(Date.now() / 1000);
  }
}

class SteamArkConfirmationIdGenerator implements ISteamArkConfirmationIdGenerator {
  private sequence: number = 0;

  create(): string {
    this.sequence += 1;
    return 'sac-' + Date.now().toString() + '-' + this.sequence.toString();
  }
}

export class SteamArkAssetConfirmationServiceOptions {
  readonly clock: ISteamArkConfirmationClock;
  readonly idGenerator: ISteamArkConfirmationIdGenerator;

  constructor(
    clock: ISteamArkConfirmationClock = new SteamArkSystemConfirmationClock(),
    idGenerator: ISteamArkConfirmationIdGenerator = new SteamArkConfirmationIdGenerator()
  ) {
    this.clock = clock;
    this.idGenerator = idGenerator;
  }
}

export class SteamArkAssetConfirmationService {
  private readonly clock: ISteamArkConfirmationClock;
  private readonly idGenerator: ISteamArkConfirmationIdGenerator;

  constructor(options: SteamArkAssetConfirmationServiceOptions = new SteamArkAssetConfirmationServiceOptions()) {
    this.clock = options.clock;
    this.idGenerator = options.idGenerator;
    SteamArkLog.debug(TAG, 'asset confirmation service constructed');
  }

  /** Builds review data only. No caller can use this object to perform a write. */
  create(request: SteamArkAssetConfirmationRequest): SteamArkAssetConfirmationResult {
    const nowEpochSeconds: number = this.clock.nowEpochSeconds();
    SteamArkLog.info(TAG, 'asset confirmation creation started; action=' + String(request.action) +
      ', account=' + SteamArkLog.accountId(request.context.accountId) +
      ', assetCount=' + request.items.length.toString());
    if (!SteamArkAssetConfirmationPolicy.requiresConfirmation(request.action)) {
      SteamArkLog.warn(TAG, 'asset confirmation rejected; reason=unsupported_action; action=' +
        String(request.action));
      return new SteamArkAssetConfirmationResult(null, SteamArkAssetConfirmationError.UNSUPPORTED_ACTION);
    }
    if (request.context.accountId.length <= 0 || request.context.steamId64.length <= 0) {
      SteamArkLog.warn(TAG, 'asset confirmation rejected; reason=invalid_context; action=' +
        String(request.action));
      return new SteamArkAssetConfirmationResult(null, SteamArkAssetConfirmationError.INVALID_CONTEXT);
    }
    if (request.items.length <= 0) {
      SteamArkLog.warn(TAG, 'asset confirmation rejected; reason=empty_asset_list; action=' +
        String(request.action));
      return new SteamArkAssetConfirmationResult(null, SteamArkAssetConfirmationError.EMPTY_ASSET_LIST);
    }
    if (request.items.length > SteamArkAssetConfirmationSnapshot.MAX_ASSET_ITEMS) {
      SteamArkLog.warn(TAG, 'asset confirmation rejected; reason=too_many_assets; count=' +
        request.items.length.toString());
      return new SteamArkAssetConfirmationResult(null, SteamArkAssetConfirmationError.TOO_MANY_ASSETS);
    }
    const assetIds: Set<string> = new Set<string>();
    for (let index = 0; index < request.items.length; index++) {
      const item: SteamArkAssetConfirmationItem = request.items[index];
      if (!item.isValid()) {
        SteamArkLog.warn(TAG, 'asset confirmation rejected; reason=invalid_asset; index=' + index.toString());
        return new SteamArkAssetConfirmationResult(null, SteamArkAssetConfirmationError.INVALID_ASSET);
      }
      if (assetIds.has(item.assetId)) {
        SteamArkLog.warn(TAG, 'asset confirmation rejected; reason=duplicate_asset; index=' + index.toString());
        return new SteamArkAssetConfirmationResult(null, SteamArkAssetConfirmationError.DUPLICATE_ASSET);
      }
      assetIds.add(item.assetId);
    }
    if (!Number.isSafeInteger(nowEpochSeconds) || nowEpochSeconds <= 0 ||
      !Number.isSafeInteger(request.expiresAtEpochSeconds) ||
      request.expiresAtEpochSeconds <= nowEpochSeconds ||
      request.expiresAtEpochSeconds - nowEpochSeconds > SteamArkAssetConfirmationSnapshot.MAX_LIFETIME_SECONDS) {
      SteamArkLog.warn(TAG, 'asset confirmation rejected; reason=invalid_expiration; action=' +
        String(request.action));
      return new SteamArkAssetConfirmationResult(null, SteamArkAssetConfirmationError.INVALID_EXPIRATION);
    }
    const confirmationId: string = SteamArkSensitiveActionAuditEntry.normalizeIdentifier(
      this.idGenerator.create(),
      96
    );
    if (confirmationId.length <= 0) {
      SteamArkLog.error(TAG, 'asset confirmation rejected; reason=invalid_confirmation_id');
      return new SteamArkAssetConfirmationResult(null, SteamArkAssetConfirmationError.INVALID_CONFIRMATION_ID);
    }
    const snapshot = new SteamArkAssetConfirmationSnapshot(
      confirmationId,
      request.action,
      request.context,
      request.items,
      nowEpochSeconds,
      request.expiresAtEpochSeconds
    );
    if (!snapshot.isValidAt(nowEpochSeconds)) {
      SteamArkLog.warn(TAG, 'asset confirmation rejected; reason=snapshot_validation_failed; action=' +
        String(request.action));
      return new SteamArkAssetConfirmationResult(null, SteamArkAssetConfirmationError.INVALID_EXPIRATION);
    }
    SteamArkLog.info(TAG, 'asset confirmation creation completed; action=' + String(request.action) +
      ', confirmation=' + SteamArkLog.accountId(confirmationId) + ', assetCount=' + request.items.length.toString());
    return new SteamArkAssetConfirmationResult(snapshot, SteamArkAssetConfirmationError.NONE);
  }
}

export const steamArkAssetConfirmationService: SteamArkAssetConfirmationService =
  new SteamArkAssetConfirmationService();
