import zlib from '@ohos.zlib';
import {
  IClock,
  ISteamCmMultiDecompressor,
  ISteamCmScheduler,
  SteamAuthError,
  SteamAuthErrorKind,
  SteamAuthErrorSupport
} from 'steam_core';
import { SteamArkLog } from '../steamServices/SteamArkLogger';

const TAG: string = 'HarmonySteamCmRuntime';
const MAX_INFLATE_ITERATIONS: number = 8192;
const MAX_STALLED_INFLATE_ITERATIONS: number = 16;
const GZIP_WINDOW_BITS: number = 16;

/** Small test seam around the three zlib calls used by CMsgMulti inflation. */
export interface IHarmonySteamCmInflater {
  inflateInit2(stream: zlib.ZStream, windowBits: number): Promise<zlib.ReturnStatus>;

  inflate(stream: zlib.ZStream, flush: zlib.CompressFlushMode): Promise<zlib.ReturnStatus>;

  inflateEnd(stream: zlib.ZStream): Promise<zlib.ReturnStatus>;
}

/** Creates one native inflater for each isolated CM response. */
export interface IHarmonySteamCmInflaterFactory {
  create(): IHarmonySteamCmInflater;
}

class HarmonySteamCmZlibInflater implements IHarmonySteamCmInflater {
  private readonly zip: zlib.Zip;

  constructor() {
    this.zip = zlib.createZipSync();
  }

  async inflateInit2(stream: zlib.ZStream, windowBits: number): Promise<zlib.ReturnStatus> {
    try {
      return await this.zip.inflateInit2(stream, windowBits);
    } catch (error) {
      throw HarmonySteamCmZlibInflater.toError(error, 'inflateInit2');
    }
  }

  async inflate(stream: zlib.ZStream, flush: zlib.CompressFlushMode): Promise<zlib.ReturnStatus> {
    try {
      return await this.zip.inflate(stream, flush);
    } catch (error) {
      throw HarmonySteamCmZlibInflater.toError(error, 'inflate');
    }
  }

  async inflateEnd(stream: zlib.ZStream): Promise<zlib.ReturnStatus> {
    try {
      return await this.zip.inflateEnd(stream);
    } catch (error) {
      throw HarmonySteamCmZlibInflater.toError(error, 'inflateEnd');
    }
  }

  private static toError(error: Object, operation: string): Error {
    if (error instanceof Error) {
      return error;
    }
    return new Error('HarmonyOS zlib ' + operation + ' failed: ' + String(error));
  }
}

class HarmonySteamCmZlibInflaterFactory implements IHarmonySteamCmInflaterFactory {
  create(): IHarmonySteamCmInflater {
    return new HarmonySteamCmZlibInflater();
  }
}

/** HarmonyOS timer implementation injected into steam_core. */
export class HarmonySteamCmScheduler implements ISteamCmScheduler {
  schedule(delayMilliseconds: number, callback: () => void): number {
    const delay: number = Math.max(0, Math.floor(delayMilliseconds));
    const handle: number = setTimeout(callback, delay);
    SteamArkLog.debug(TAG, 'timer scheduled; delayMs=' + delay.toString());
    return handle;
  }

  cancel(handle: number): void {
    clearTimeout(handle);
    SteamArkLog.debug(TAG, 'timer cancelled; handlePresent=' + String(handle >= 0));
  }
}

/** Wall-clock implementation used only by the host adapter layer. */
export class HarmonySteamClock implements IClock {
  nowEpochSeconds(): number {
    return Math.floor(Date.now() / 1000);
  }
}

/** HarmonyOS gzip implementation for SteamKit2 CMsgMulti envelopes. */
export class HarmonySteamCmMultiDecompressor implements ISteamCmMultiDecompressor {
  private readonly inflaterFactory: IHarmonySteamCmInflaterFactory;

  constructor(inflaterFactory: IHarmonySteamCmInflaterFactory = new HarmonySteamCmZlibInflaterFactory()) {
    this.inflaterFactory = inflaterFactory;
  }

  async decompress(payload: Uint8Array, expectedSize: number): Promise<Uint8Array> {
    if (!Number.isSafeInteger(expectedSize) || expectedSize <= 0 || expectedSize > 67108864) {
      throw new SteamAuthError(
        'Steam CM compressed Multi size is invalid',
        SteamAuthErrorKind.PROTOCOL,
        'cm_decompress'
      );
    }
    const inputBuffer: ArrayBuffer = new ArrayBuffer(payload.length);
    const input: Uint8Array = new Uint8Array(inputBuffer);
    input.set(payload);
    const outputBuffer: ArrayBuffer = new ArrayBuffer(expectedSize);
    const zip: IHarmonySteamCmInflater = this.inflaterFactory.create();
    // The HarmonyOS API validates the buffer fields during initialization.
    // Keep one fully populated stream object for the whole inflate lifecycle.
    const stream: zlib.ZStream = {
      nextIn: inputBuffer,
      availableIn: payload.length,
      nextOut: outputBuffer,
      availableOut: expectedSize
    };
    let initialized = false;
    let lastStatus: zlib.ReturnStatus = zlib.ReturnStatus.OK;
    try {
      // Steam CMsgMulti carries a gzip stream. Keep this aligned with the
      // SteamKit2 reference implementation, which uses the gzip wrapper mode.
      const initStatus: zlib.ReturnStatus = await zip.inflateInit2(stream, GZIP_WINDOW_BITS);
      lastStatus = initStatus;
      if (initStatus !== zlib.ReturnStatus.OK) {
        throw this.failure(
          'Steam CM gzip decompressor initialization failed',
          initStatus
        );
      }
      initialized = true;
      let inflateStatus: zlib.ReturnStatus = zlib.ReturnStatus.OK;
      let completed: boolean = false;
      let stalledIterations: number = 0;
      for (let iteration = 0; iteration < MAX_INFLATE_ITERATIONS; iteration++) {
        const previousAvailableIn: number = stream.availableIn === undefined
          ? -1
          : stream.availableIn;
        const previousAvailableOut: number = stream.availableOut === undefined
          ? -1
          : stream.availableOut;
        // FINISH ends the stream and is intended for final compression output.
        // CM payloads are already complete input, but inflate still needs the
        // normal incremental mode to consume the input and report STREAM_END.
        inflateStatus = await zip.inflate(stream, zlib.CompressFlushMode.NO_FLUSH);
        lastStatus = inflateStatus;
        if (inflateStatus === zlib.ReturnStatus.STREAM_END) {
          completed = true;
          break;
        }
        if (inflateStatus !== zlib.ReturnStatus.OK) {
          break;
        }
        const noInputProgress: boolean = previousAvailableIn >= 0 &&
          stream.availableIn !== undefined && stream.availableIn === previousAvailableIn;
        const noOutputProgress: boolean = previousAvailableOut >= 0 &&
          stream.availableOut !== undefined && stream.availableOut === previousAvailableOut;
        if (noInputProgress && noOutputProgress) {
          stalledIterations++;
          if (stalledIterations >= MAX_STALLED_INFLATE_ITERATIONS) {
            break;
          }
        } else {
          stalledIterations = 0;
        }
      }
      if (!completed) {
        throw this.failure(
          'Steam CM gzip decompression did not reach stream end',
          inflateStatus
        );
      }
      // STREAM_END is the authoritative completion signal. SteamKit2 accepts
      // it without requiring avail_in to reach zero, and the HarmonyOS binding
      // can retain a nonzero availableIn value after a valid gzip completion.
      if (stream.availableIn !== undefined && stream.availableIn > 0) {
        SteamArkLog.debug(TAG, 'CM gzip stream completed with reported remaining input; bytes=' +
          stream.availableIn.toString());
      }
      this.verifyReportedOutput(stream, expectedSize, inflateStatus);
      const result: Uint8Array = new Uint8Array(expectedSize);
      result.set(new Uint8Array(outputBuffer));
      const endStatus: zlib.ReturnStatus = await zip.inflateEnd(stream);
      lastStatus = endStatus;
      if (endStatus !== zlib.ReturnStatus.OK) {
        throw this.failure('Steam CM gzip decompressor cleanup failed', endStatus);
      }
      initialized = false;
      return result;
    } catch (error) {
      if (initialized) {
        try {
          await zip.inflateEnd(stream);
        } catch (_cleanupError) {
          SteamArkLog.warn(TAG, 'CM gzip decompressor cleanup failed');
        }
      }
      if (error instanceof SteamAuthError) {
        throw error;
      }
      const normalized: SteamAuthError = SteamAuthErrorSupport.normalize(
        error,
        SteamAuthErrorKind.PROTOCOL,
        'cm_decompress',
        'Steam CM gzip decompression failed'
      );
      const statusDetail: string = lastStatus === zlib.ReturnStatus.OK
        ? ''
        : '; zlibStatus=' + String(lastStatus);
      const code: number = normalized.code !== 0 ? normalized.code : Number(lastStatus);
      throw new SteamAuthError(
        normalized.message + statusDetail,
        SteamAuthErrorKind.PROTOCOL,
        'cm_decompress',
        code,
        normalized.httpStatusCode,
        normalized.messageType,
        normalized.headerKind,
        normalized.frameBytes,
        normalized.headerBytes,
        normalized.bodyBytes,
        normalized.serverMessage
      );
    }
  }

  private failure(message: string, status: zlib.ReturnStatus): SteamAuthError {
    return new SteamAuthError(
      message + '; zlibStatus=' + String(status),
      SteamAuthErrorKind.PROTOCOL,
      'cm_decompress',
      Number(status)
    );
  }

  private verifyReportedOutput(
    stream: zlib.ZStream,
    expectedSize: number,
    status: zlib.ReturnStatus
  ): void {
    const reportedTotalOut: number | undefined = stream.totalOut;
    const reportedAvailableOut: number | undefined = stream.availableOut;
    const hasReportedTotalOut: boolean = reportedTotalOut !== undefined && reportedTotalOut > 0;
    const hasReportedAvailableOut: boolean = reportedAvailableOut !== undefined &&
      reportedAvailableOut !== expectedSize;

    // API26 can write the output buffer and return STREAM_END without updating
    // either optional counter. Only reject a counter when it demonstrably
    // reports partial output; otherwise the CM frame parser validates bytes.
    if (reportedTotalOut !== undefined && reportedTotalOut > 0 && reportedTotalOut !== expectedSize) {
      throw this.failure(
        'Steam CM gzip decompression size mismatch; expected=' +
          expectedSize.toString() + ', actual=' + reportedTotalOut.toString(),
        status
      );
    }
    if (reportedAvailableOut !== undefined && reportedAvailableOut !== expectedSize &&
      reportedAvailableOut !== 0) {
      throw this.failure(
        'Steam CM gzip decompression output buffer was not filled; availableOut=' +
          reportedAvailableOut.toString(),
        status
      );
    }
    if (!hasReportedTotalOut && !hasReportedAvailableOut) {
      const totalOutDetail: string = reportedTotalOut === undefined
        ? 'unset'
        : reportedTotalOut.toString();
      const availableOutDetail: string = reportedAvailableOut === undefined
        ? 'unset'
        : reportedAvailableOut.toString();
      SteamArkLog.debug(TAG, 'CM gzip stream completed without reliable output counters; totalOut=' +
        totalOutDetail + ', availableOut=' + availableOutDetail);
    }
  }
}
