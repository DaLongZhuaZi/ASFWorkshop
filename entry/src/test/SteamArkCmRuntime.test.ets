import { describe, expect, it } from '@ohos/hypium';
import zlib from '@ohos.zlib';
import {
  HarmonySteamCmMultiDecompressor,
  IHarmonySteamCmInflater,
  IHarmonySteamCmInflaterFactory
} from '../main/ets/steamAdapters/HarmonySteamCmRuntime';

class FakeSteamCmInflater implements IHarmonySteamCmInflater {
  readonly output: Uint8Array;
  readonly remainingInput: number;
  readonly totalOut: number;
  readonly availableOut: number;
  readonly reportOutputCounters: boolean;
  initWindowBits: number = 0;
  inflateCalls: number = 0;
  endCalls: number = 0;

  constructor(
    output: Uint8Array,
    remainingInput: number,
    totalOut: number,
    availableOut: number,
    reportOutputCounters: boolean = true
  ) {
    this.output = output.slice();
    this.remainingInput = remainingInput;
    this.totalOut = totalOut;
    this.availableOut = availableOut;
    this.reportOutputCounters = reportOutputCounters;
  }

  async inflateInit2(_stream: zlib.ZStream, windowBits: number): Promise<zlib.ReturnStatus> {
    this.initWindowBits = windowBits;
    return zlib.ReturnStatus.OK;
  }

  async inflate(stream: zlib.ZStream, _flush: zlib.CompressFlushMode): Promise<zlib.ReturnStatus> {
    this.inflateCalls++;
    const outputBuffer: ArrayBuffer | undefined = stream.nextOut;
    if (outputBuffer === undefined) {
      throw new Error('fake inflater requires an output buffer');
    }
    const output: Uint8Array = new Uint8Array(outputBuffer);
    output.set(this.output);
    stream.availableIn = this.remainingInput;
    if (this.reportOutputCounters) {
      stream.totalOut = this.totalOut;
      stream.availableOut = this.availableOut;
    }
    return zlib.ReturnStatus.STREAM_END;
  }

  async inflateEnd(_stream: zlib.ZStream): Promise<zlib.ReturnStatus> {
    this.endCalls++;
    return zlib.ReturnStatus.OK;
  }
}

class FakeSteamCmInflaterFactory implements IHarmonySteamCmInflaterFactory {
  readonly inflater: FakeSteamCmInflater;

  constructor(inflater: FakeSteamCmInflater) {
    this.inflater = inflater;
  }

  create(): IHarmonySteamCmInflater {
    return this.inflater;
  }
}

export default function steamArkCmRuntimeTest(): void {
  describe('SteamArkCmRuntime', () => {
    it('acceptsReportedRemainingInputAfterACompleteGzipStream', 0, async () => {
      const expected: Uint8Array = new Uint8Array([4, 8, 15, 16]);
      const inflater = new FakeSteamCmInflater(expected, 744, expected.length, 0);
      const decompressor = new HarmonySteamCmMultiDecompressor(new FakeSteamCmInflaterFactory(inflater));

      const result: Uint8Array = await decompressor.decompress(new Uint8Array([31, 139, 8]), expected.length);

      expect(result.length).assertEqual(expected.length);
      expect(result[0]).assertEqual(4);
      expect(result[3]).assertEqual(16);
      expect(inflater.initWindowBits).assertEqual(16);
      expect(inflater.inflateCalls).assertEqual(1);
      expect(inflater.endCalls).assertEqual(1);
    });

    it('rejectsACompleteStreamWhenItsOutputSizeIsIncomplete', 0, async () => {
      const inflater = new FakeSteamCmInflater(new Uint8Array([1, 2, 3]), 0, 3, 1);
      const decompressor = new HarmonySteamCmMultiDecompressor(new FakeSteamCmInflaterFactory(inflater));
      let rejected: boolean = false;

      try {
        await decompressor.decompress(new Uint8Array([31, 139, 8]), 4);
      } catch (error) {
        rejected = true;
        expect(error instanceof Error).assertTrue();
        if (error instanceof Error) {
          expect(error.message.indexOf('size mismatch') >= 0).assertTrue();
        }
      }

      expect(rejected).assertTrue();
      expect(inflater.endCalls).assertEqual(1);
    });

    it('acceptsACompleteStreamWhenNativeOutputCountersAreNotWritten', 0, async () => {
      const expected: Uint8Array = new Uint8Array([21, 34, 55, 89]);
      const inflater = new FakeSteamCmInflater(expected, 754, 0, expected.length, false);
      const decompressor = new HarmonySteamCmMultiDecompressor(new FakeSteamCmInflaterFactory(inflater));

      const result: Uint8Array = await decompressor.decompress(new Uint8Array([31, 139, 8]), expected.length);

      expect(result.length).assertEqual(expected.length);
      expect(result[0]).assertEqual(21);
      expect(result[3]).assertEqual(89);
      expect(inflater.inflateCalls).assertEqual(1);
      expect(inflater.endCalls).assertEqual(1);
    });

  });
}
