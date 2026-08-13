import { Permissions } from '@kit.AbilityKit';
import { userAuth } from '@kit.UserAuthenticationKit';
import {
  IPermissionManager,
  IUserAuthentication,
  ngfPermissionManagerFacade,
  ngfUserAuthenticationFacade,
  securityToolkit
} from 'ngf_framework';
import {
  ISteamArkSensitiveActionAuditEventPublisher,
  ISteamArkSensitiveActionAuditStore,
  SteamArkSensitiveAction,
  SteamArkSensitiveActionAuditEntry,
  SteamArkSensitiveActionContext,
  SteamArkSensitiveActionOutcome,
  steamArkSensitiveActionAuditEventPublisher,
  steamArkSensitiveActionAuditStore
} from './SteamArkSensitiveActionAudit';
import { SteamArkAssetConfirmationPolicy, SteamArkAssetConfirmationSnapshot } from './SteamArkSensitiveActionConfirmation';
import { SteamArkLog } from './SteamArkLogger';

const TAG: string = 'SteamArkSensitiveActionGate';
const BIOMETRIC_PERMISSION: Permissions = 'ohos.permission.ACCESS_BIOMETRIC';
const CHALLENGE_LENGTH: number = 32;

export class SteamArkSensitiveActionResult {
  readonly action: SteamArkSensitiveAction;
  readonly outcome: SteamArkSensitiveActionOutcome;
  readonly verificationOutcome: SteamArkSensitiveActionOutcome;
  readonly granted: boolean;
  readonly auditPersisted: boolean;
  readonly auditEventId: string;
  readonly confirmationId: string;
  readonly assetCount: number;

  constructor(
    action: SteamArkSensitiveAction,
    outcome: SteamArkSensitiveActionOutcome,
    auditPersisted: boolean = true,
    auditEventId: string = '',
    verificationOutcome: SteamArkSensitiveActionOutcome = outcome,
    confirmationId: string = '',
    assetCount: number = 0
  ) {
    this.action = action;
    this.outcome = outcome;
    this.verificationOutcome = verificationOutcome;
    this.granted = outcome === SteamArkSensitiveActionOutcome.GRANTED && auditPersisted;
    this.auditPersisted = auditPersisted;
    this.auditEventId = auditEventId;
    this.confirmationId = confirmationId;
    this.assetCount = assetCount;
  }
}

/** Binary challenge source kept injectable so the gate can be tested without a device. */
export interface ISteamArkChallengeGenerator {
  generate(length: number): Uint8Array;
}

class SteamArkSecurityChallengeGenerator implements ISteamArkChallengeGenerator {
  generate(length: number): Uint8Array {
    return securityToolkit.generateRandomBytes(length);
  }
}

export class SteamArkSensitiveActionGateOptions {
  readonly permissionManager: IPermissionManager;
  readonly userAuthentication: IUserAuthentication;
  readonly challengeGenerator: ISteamArkChallengeGenerator;
  readonly auditStore: ISteamArkSensitiveActionAuditStore;
  readonly auditEventPublisher: ISteamArkSensitiveActionAuditEventPublisher;

  constructor(
    permissionManager: IPermissionManager = ngfPermissionManagerFacade,
    userAuthentication: IUserAuthentication = ngfUserAuthenticationFacade,
    challengeGenerator: ISteamArkChallengeGenerator = new SteamArkSecurityChallengeGenerator(),
    auditStore: ISteamArkSensitiveActionAuditStore = steamArkSensitiveActionAuditStore,
    auditEventPublisher: ISteamArkSensitiveActionAuditEventPublisher = steamArkSensitiveActionAuditEventPublisher
  ) {
    this.permissionManager = permissionManager;
    this.userAuthentication = userAuthentication;
    this.challengeGenerator = challengeGenerator;
    this.auditStore = auditStore;
    this.auditEventPublisher = auditEventPublisher;
  }
}

export interface ISteamArkSensitiveActionGate {
  /**
   * Verify the user once for the requested action. A granted result is never cached;
   * callers must invoke this immediately before a future mutation or confirmation.
   * All actions other than privacy verification also require a matching active asset snapshot.
   */
  verify(
    action: SteamArkSensitiveAction,
    promptTitle: string,
    context?: SteamArkSensitiveActionContext,
    confirmation?: SteamArkAssetConfirmationSnapshot
  ): Promise<SteamArkSensitiveActionResult>;
}

export class SteamArkSensitiveActionGate implements ISteamArkSensitiveActionGate {
  private readonly permissionManager: IPermissionManager;
  private readonly userAuthentication: IUserAuthentication;
  private readonly challengeGenerator: ISteamArkChallengeGenerator;
  private readonly auditStore: ISteamArkSensitiveActionAuditStore;
  private readonly auditEventPublisher: ISteamArkSensitiveActionAuditEventPublisher;
  private verificationInProgress: boolean = false;
  private auditSequence: number = 0;

  constructor(options: SteamArkSensitiveActionGateOptions = new SteamArkSensitiveActionGateOptions()) {
    this.permissionManager = options.permissionManager;
    this.userAuthentication = options.userAuthentication;
    this.challengeGenerator = options.challengeGenerator;
    this.auditStore = options.auditStore;
    this.auditEventPublisher = options.auditEventPublisher;
    SteamArkLog.debug(TAG, 'sensitive action gate constructed');
  }

  async verify(
    action: SteamArkSensitiveAction,
    promptTitle: string,
    context: SteamArkSensitiveActionContext = new SteamArkSensitiveActionContext(),
    confirmation: SteamArkAssetConfirmationSnapshot | null = null
  ): Promise<SteamArkSensitiveActionResult> {
    SteamArkLog.info(TAG, 'sensitive action verification started; action=' + String(action) +
      ', account=' + SteamArkLog.accountId(context.accountId) +
      ', hasConfirmation=' + String(confirmation !== null) +
      ', assetCount=' + (confirmation === null ? '0' : confirmation.items.length.toString()));
    if (this.verificationInProgress) {
      SteamArkLog.warn(TAG, 'sensitive action verification rejected; reason=busy; action=' + String(action));
      return await this.recordAudit(action, SteamArkSensitiveActionOutcome.BUSY, context, confirmation);
    }
    if (promptTitle.trim().length <= 0) {
      SteamArkLog.warn(TAG, 'sensitive action verification rejected; reason=empty_prompt; action=' + String(action));
      return await this.recordAudit(action, SteamArkSensitiveActionOutcome.INVALID_REQUEST, context, confirmation);
    }
    if (!this.isConfirmationActive(action, context, confirmation, Math.floor(Date.now() / 1000))) {
      SteamArkLog.warn(TAG, 'sensitive action verification rejected; reason=confirmation_invalid; action=' +
        String(action) + ', account=' + SteamArkLog.accountId(context.accountId));
      return await this.recordAudit(action, SteamArkSensitiveActionOutcome.INVALID_REQUEST, context, null);
    }

    this.verificationInProgress = true;
    try {
      if (!this.hasSupportedAuthenticator()) {
        SteamArkLog.warn(TAG, 'sensitive action verification unsupported; action=' + String(action));
        return await this.recordAudit(action, SteamArkSensitiveActionOutcome.UNSUPPORTED, context, confirmation);
      }

      let permissionGranted = this.permissionManager.checkPermission(BIOMETRIC_PERMISSION);
      if (!permissionGranted) {
        permissionGranted = await this.permissionManager.requestPermissions([BIOMETRIC_PERMISSION]);
      }
      if (!permissionGranted) {
        SteamArkLog.warn(TAG, 'sensitive action biometric permission denied; action=' + String(action));
        return await this.recordAudit(action, SteamArkSensitiveActionOutcome.PERMISSION_DENIED, context, confirmation);
      }

      const challenge: Uint8Array = this.challengeGenerator.generate(CHALLENGE_LENGTH);
      if (challenge.length !== CHALLENGE_LENGTH) {
        SteamArkLog.error(TAG, 'sensitive action challenge generation failed; action=' + String(action));
        return await this.recordAudit(action, SteamArkSensitiveActionOutcome.ERROR, context, confirmation);
      }

      const authenticated = await this.userAuthentication.authenticate(challenge, promptTitle);
      SteamArkLog.info(TAG, 'sensitive action device authentication completed; action=' + String(action) +
        ', authenticated=' + String(authenticated));
      if (authenticated && !this.isConfirmationActive(action, context, confirmation, Math.floor(Date.now() / 1000))) {
        return await this.recordAudit(action, SteamArkSensitiveActionOutcome.INVALID_REQUEST, context, null);
      }
      const verificationOutcome: SteamArkSensitiveActionOutcome = authenticated
        ? SteamArkSensitiveActionOutcome.GRANTED
        : SteamArkSensitiveActionOutcome.AUTHENTICATION_FAILED;
      return await this.recordAudit(action, verificationOutcome, context, confirmation);
    } catch (error) {
      SteamArkLog.error(TAG, 'sensitive action verification failed; action=' + String(action) +
        ', errorType=' + SteamArkLog.errorKind(error));
      return await this.recordAudit(action, SteamArkSensitiveActionOutcome.ERROR, context, confirmation);
    } finally {
      this.verificationInProgress = false;
    }
  }

  private async recordAudit(
    action: SteamArkSensitiveAction,
    verificationOutcome: SteamArkSensitiveActionOutcome,
    context: SteamArkSensitiveActionContext,
    confirmation: SteamArkAssetConfirmationSnapshot | null
  ): Promise<SteamArkSensitiveActionResult> {
    const eventId: string = this.createAuditEventId();
    const createdAtEpochSeconds: number = Math.floor(Date.now() / 1000);
    const usableConfirmation: SteamArkAssetConfirmationSnapshot | null = confirmation !== null &&
      SteamArkAssetConfirmationPolicy.requiresConfirmation(action) &&
      confirmation.isValidAt(createdAtEpochSeconds) &&
      confirmation.matches(action, context)
      ? confirmation
      : null;
    const confirmationId: string = usableConfirmation === null ? '' : usableConfirmation.confirmationId;
    const assetCount: number = usableConfirmation === null ? 0 : usableConfirmation.items.length;
    const entry = new SteamArkSensitiveActionAuditEntry(
      eventId,
      action,
      verificationOutcome,
      context.accountId,
      context.steamId64,
      createdAtEpochSeconds,
      confirmationId,
      assetCount
    );
    SteamArkLog.debug(TAG, 'sensitive action audit recording; action=' + String(action) +
      ', verificationOutcome=' + String(verificationOutcome) + ', assetCount=' + assetCount.toString());
    try {
      const persisted: boolean = await this.auditStore.append(entry);
      if (!persisted) {
        SteamArkLog.error(TAG, 'sensitive action audit persistence failed; action=' + String(action) +
          ', account=' + SteamArkLog.accountId(context.accountId));
        return new SteamArkSensitiveActionResult(
          action,
          SteamArkSensitiveActionOutcome.AUDIT_FAILED,
          false,
          '',
          verificationOutcome,
          confirmationId,
          assetCount
        );
      }
      try {
        this.auditEventPublisher.publish(entry);
      } catch (error) {
        SteamArkLog.warn(TAG, 'sensitive action audit event publish failed; errorType=' +
          SteamArkLog.errorKind(error));
      }
      SteamArkLog.info(TAG, 'sensitive action verification completed; action=' + String(action) +
        ', outcome=' + String(verificationOutcome) + ', auditPersisted=true');
      return new SteamArkSensitiveActionResult(
        action,
        verificationOutcome,
        true,
        eventId,
        verificationOutcome,
        confirmationId,
        assetCount
      );
    } catch (error) {
      SteamArkLog.error(TAG, 'sensitive action audit recording failed; action=' + String(action) +
        ', errorType=' + SteamArkLog.errorKind(error));
      return new SteamArkSensitiveActionResult(
        action,
        SteamArkSensitiveActionOutcome.AUDIT_FAILED,
        false,
        '',
        verificationOutcome,
        confirmationId,
        assetCount
      );
    }
  }

  private createAuditEventId(): string {
    this.auditSequence += 1;
    return 'saa-' + Date.now().toString() + '-' + this.auditSequence.toString();
  }

  private isConfirmationActive(
    action: SteamArkSensitiveAction,
    context: SteamArkSensitiveActionContext,
    confirmation: SteamArkAssetConfirmationSnapshot | null,
    nowEpochSeconds: number
  ): boolean {
    if (!SteamArkAssetConfirmationPolicy.requiresConfirmation(action)) {
      return true;
    }
    return confirmation !== null &&
      confirmation.isValidAt(nowEpochSeconds) &&
      confirmation.matches(action, context);
  }

  private hasSupportedAuthenticator(): boolean {
    const supported = this.supports(userAuth.UserAuthType.PIN) ||
      this.supports(userAuth.UserAuthType.FINGERPRINT) ||
      this.supports(userAuth.UserAuthType.FACE);
    SteamArkLog.debug(TAG, 'supported authenticator check completed; supported=' + String(supported));
    return supported;
  }

  private supports(authType: userAuth.UserAuthType): boolean {
    try {
      return this.userAuthentication.checkSupport(authType);
    } catch (error) {
      SteamArkLog.debug(TAG, 'authenticator capability check failed; type=' + String(authType) +
        ', errorType=' + SteamArkLog.errorKind(error));
      return false;
    }
  }
}

export const steamArkSensitiveActionGate: ISteamArkSensitiveActionGate =
  new SteamArkSensitiveActionGate();
