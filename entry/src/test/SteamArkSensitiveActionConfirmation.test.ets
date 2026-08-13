import { describe, expect, it } from '@ohos/hypium';
import {
  SteamArkAssetConfirmationError,
  SteamArkAssetConfirmationItem,
  SteamArkAssetConfirmationRequest,
  SteamArkAssetConfirmationService,
  SteamArkAssetConfirmationServiceOptions,
  SteamArkAssetConfirmationSnapshot,
  ISteamArkConfirmationClock,
  ISteamArkConfirmationIdGenerator,
  SteamArkSensitiveAction,
  SteamArkSensitiveActionContext
} from '../main/ets/steamServices';

class FixedConfirmationClock implements ISteamArkConfirmationClock {
  readonly value: number;

  constructor(value: number) {
    this.value = value;
  }

  nowEpochSeconds(): number {
    return this.value;
  }
}

class FixedConfirmationIdGenerator implements ISteamArkConfirmationIdGenerator {
  readonly value: string;

  constructor(value: string) {
    this.value = value;
  }

  create(): string {
    return this.value;
  }
}

function createService(): SteamArkAssetConfirmationService {
  return new SteamArkAssetConfirmationService(new SteamArkAssetConfirmationServiceOptions(
    new FixedConfirmationClock(1700000000),
    new FixedConfirmationIdGenerator('confirmation-test-1')
  ));
}

function createItem(assetId: string = '10000000000000001'): SteamArkAssetConfirmationItem {
  return new SteamArkAssetConfirmationItem(assetId, '753', '6', 1, 'Trading Card', 'Trading Card');
}

function createRequest(
  action: SteamArkSensitiveAction = SteamArkSensitiveAction.INVENTORY_WRITE,
  items: Array<SteamArkAssetConfirmationItem> = [createItem()]
): SteamArkAssetConfirmationRequest {
  return new SteamArkAssetConfirmationRequest(
    action,
    new SteamArkSensitiveActionContext('account-confirmation', '76561197960287930'),
    items,
    1700000060
  );
}

export default function steamArkSensitiveActionConfirmationTest(): void {
  describe('SteamArkSensitiveActionConfirmation', () => {
    it('createsBoundedNonExecutableSnapshot', 0, () => {
      const result = createService().create(createRequest());

      expect(result.accepted).assertTrue();
      expect(result.error).assertEqual(SteamArkAssetConfirmationError.NONE);
      expect(result.snapshot !== null).assertTrue();
      if (result.snapshot !== null) {
        expect(result.snapshot.confirmationId).assertEqual('confirmation-test-1');
        expect(result.snapshot.accountId).assertEqual('account-confirmation');
        expect(result.snapshot.steamId64).assertEqual('76561197960287930');
        expect(result.snapshot.items.length).assertEqual(1);
        expect(result.snapshot.isValidAt(1700000059)).assertTrue();
        expect(result.snapshot.isValidAt(1700000060)).assertFalse();
        const serialized: string = JSON.stringify(result.snapshot);
        expect(serialized.includes('password')).assertFalse();
        expect(serialized.includes('refreshToken')).assertFalse();
        expect(serialized.includes('cookie')).assertFalse();
      }
    });

    it('rejectsDuplicateAssetIds', 0, () => {
      const items: Array<SteamArkAssetConfirmationItem> = [createItem(), createItem()];
      const result = createService().create(createRequest(SteamArkSensitiveAction.TRADE_ACCEPT, items));

      expect(result.accepted).assertFalse();
      expect(result.snapshot).assertNull();
      expect(result.error).assertEqual(SteamArkAssetConfirmationError.DUPLICATE_ASSET);
    });

    it('rejectsInvalidAssetAndExpiration', 0, () => {
      const invalidItem: SteamArkAssetConfirmationItem = new SteamArkAssetConfirmationItem(
        'asset-not-decimal',
        '753',
        '6',
        1
      );
      const invalidAsset = createService().create(createRequest(
        SteamArkSensitiveAction.INVENTORY_WRITE,
        [invalidItem]
      ));
      expect(invalidAsset.error).assertEqual(SteamArkAssetConfirmationError.INVALID_ASSET);

      const invalidExpiryRequest = new SteamArkAssetConfirmationRequest(
        SteamArkSensitiveAction.INVENTORY_WRITE,
        new SteamArkSensitiveActionContext('account-confirmation', '76561197960287930'),
        [createItem()],
        1700000000 + SteamArkAssetConfirmationSnapshot.MAX_LIFETIME_SECONDS + 1
      );
      const invalidExpiry = createService().create(invalidExpiryRequest);
      expect(invalidExpiry.error).assertEqual(SteamArkAssetConfirmationError.INVALID_EXPIRATION);
    });

    it('rejectsUnsupportedPrivacyActionAndOversizedList', 0, () => {
      const privacyResult = createService().create(createRequest(SteamArkSensitiveAction.PRIVACY_VERIFICATION));
      expect(privacyResult.error).assertEqual(SteamArkAssetConfirmationError.UNSUPPORTED_ACTION);

      const items: Array<SteamArkAssetConfirmationItem> = [];
      for (let index = 0; index <= SteamArkAssetConfirmationSnapshot.MAX_ASSET_ITEMS; index++) {
        items.push(createItem('100000000000000' + index.toString()));
      }
      const oversized = createService().create(createRequest(SteamArkSensitiveAction.ASSET_TRANSFER, items));
      expect(oversized.error).assertEqual(SteamArkAssetConfirmationError.TOO_MANY_ASSETS);
    });
  });
}
