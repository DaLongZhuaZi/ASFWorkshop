import {
  NGFHttpMethod,
  NGFHttpSession,
  NGFHttpSessionRequest,
  NGFHttpSessionResponse,
  NGFProxyMode,
  NGFProxyConfiguration,
  uiContextManager
} from 'ngf_framework';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import {
  SteamAccountProfile,
  SteamCredentialSet,
  SteamJsonParser,
  SteamJsonValue,
  SteamJsonValueKind,
  SteamProxyKind
} from 'steam_core';
import {
  ISteamArkProfileResolver,
  ISteamArkProfileVisualResolver,
  SteamArkResolvedProfile
} from '../steamServices/SteamArkProfileContracts';
import { ASFWorkshopProductIdentity } from '../steamServices/ASFWorkshopProductIdentity';
import { SteamArkLog } from '../steamServices/SteamArkLogger';
import { steamArkCoreLogger } from '../steamServices/SteamArkCoreLogger';

const TAG: string = 'HarmonySteamProfileResolver';
const PROFILE_ENDPOINT_PREFIX: string = 'https://steamcommunity.com/miniprofile/';
const PROFILE_ENDPOINT_SUFFIX: string = '/json';
const PROFILE_PAGE_PREFIX: string = 'https://steamcommunity.com/profiles/';
const PROFILE_PAGE_SUFFIX: string = '/';
const MAX_PROFILE_NAME_LENGTH: number = 256;
const MAX_AVATAR_URL_LENGTH: number = 2048;
const MAX_BACKGROUND_URL_LENGTH: number = 4096;
const STEAM_ID64_INDIVIDUAL_BASE: string = '76561197960265728';

/** Reads the public Steam mini-profile after CM authentication succeeds. */
export class HarmonySteamProfileResolver implements ISteamArkProfileResolver, ISteamArkProfileVisualResolver {
  async resolve(
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    proxyPassword: string = ''
  ): Promise<SteamArkResolvedProfile> {
    const steamId64 = profile.steamId64.trim();
    if (!HarmonySteamProfileResolver.isSteamId64(steamId64)) {
      throw new Error('Steam profile lookup requires a valid steamId64');
    }
    const accountId32 = HarmonySteamProfileResolver.toAccountId32(steamId64);
    if (accountId32.length <= 0) {
      throw new Error('Steam profile lookup could not derive accountId32');
    }
    const url = PROFILE_ENDPOINT_PREFIX + accountId32 + PROFILE_ENDPOINT_SUFFIX;
    const session = new NGFHttpSession();
    const headers = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('SteamProfile'));
    if (credentials.accessToken.length > 0) {
      const secureValue = steamId64 + '||' + credentials.accessToken;
      session.cookieJar.setFromResponse(url, 'steamLoginSecure=' + HarmonySteamProfileResolver.encodeLoginCookieValue(secureValue) +
        '; Path=/; Secure');
    }
    const request = new NGFHttpSessionRequest(
      NGFHttpMethod.GET,
      url,
      headers,
      '',
      15000,
      false,
      HarmonySteamProfileResolver.toProxy(profile, proxyPassword)
    );
    SteamArkLog.debug(TAG, 'profile lookup started; account=' + SteamArkLog.accountId(profile.accountId) +
      ', steamId64=' + SteamArkLog.steamId64(steamId64));
    try {
      let response: NGFHttpSessionResponse;
      try {
        response = await session.request(request);
      } catch (error) {
        const proxy = HarmonySteamProfileResolver.toProxy(profile, proxyPassword);
        if (proxy.mode !== NGFProxyMode.SYSTEM) {
          throw error instanceof Error ? error : new Error('Steam profile system proxy request failed');
        }
        SteamArkLog.warn(TAG, 'Steam profile system proxy failed; retrying direct once');
        const directRequest = new NGFHttpSessionRequest(
          NGFHttpMethod.GET,
          url,
          headers,
          '',
          15000,
          false,
          NGFProxyConfiguration.direct()
        );
        response = await session.request(directRequest);
      }
      if (!response.isOk()) {
        throw new Error('Steam profile lookup returned HTTP ' + response.statusCode.toString());
      }
      const result: SteamArkResolvedProfile = this.parseProfile(response.body);
      SteamArkLog.info(TAG, 'basic profile lookup completed; account=' + SteamArkLog.accountId(profile.accountId) +
        ', displayNamePresent=' + String(result.displayName.length > 0) +
        ', avatarPresent=' + String(result.avatarUrl.length > 0));
      return result;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam profile lookup failed');
      SteamArkLog.warn(TAG, 'profile lookup failed; account=' + SteamArkLog.accountId(profile.accountId) +
        ', errorType=' + normalized.name);
      throw normalized;
    } finally {
      session.clear();
    }
  }

  async resolveVisuals(
    profile: SteamAccountProfile,
    credentials: SteamCredentialSet,
    baseline: SteamArkResolvedProfile,
    proxyPassword: string = ''
  ): Promise<SteamArkResolvedProfile> {
    const steamId64: string = profile.steamId64.trim();
    if (!HarmonySteamProfileResolver.isSteamId64(steamId64)) {
      throw new Error('Steam profile visual lookup requires a valid steamId64');
    }
    const url: string = PROFILE_PAGE_PREFIX + steamId64 + PROFILE_PAGE_SUFFIX;
    const session = new NGFHttpSession();
    const headers = new Map<string, string>();
    headers.set('Accept', 'text/html,application/xhtml+xml');
    headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('SteamProfile'));
    if (credentials.accessToken.length > 0) {
      const secureValue: string = steamId64 + '||' + credentials.accessToken;
      session.cookieJar.setFromResponse(url, 'steamLoginSecure=' +
        HarmonySteamProfileResolver.encodeLoginCookieValue(secureValue) + '; Path=/; Secure');
    }
    try {
      const pageResolved: SteamArkResolvedProfile = await this.resolveProfilePageBackground(
        baseline,
        session,
        steamId64,
        profile,
        proxyPassword,
        headers
      );
      const result: SteamArkResolvedProfile = await this.ensureStaticBackground(
        pageResolved,
        session,
        profile,
        proxyPassword
      );
      SteamArkLog.info(TAG, 'profile visual lookup completed; account=' + SteamArkLog.accountId(profile.accountId) +
        ', framePresent=' + String(result.avatarFrameUrl.length > 0) +
        ', backgroundPresent=' + String(result.backgroundImageUrl.length > 0));
      return result;
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error('Steam profile visual lookup failed');
      SteamArkLog.warn(TAG, 'profile visual lookup failed; account=' + SteamArkLog.accountId(profile.accountId) +
        ', errorType=' + normalized.name);
      throw normalized;
    } finally {
      session.clear();
    }
  }

  private async resolveProfilePageBackground(
    profile: SteamArkResolvedProfile,
    session: NGFHttpSession,
    steamId64: string,
    account: SteamAccountProfile,
    proxyPassword: string,
    headers: Map<string, string>
  ): Promise<SteamArkResolvedProfile> {
    const url: string = PROFILE_PAGE_PREFIX + steamId64 + PROFILE_PAGE_SUFFIX;
    const request = new NGFHttpSessionRequest(
      NGFHttpMethod.GET,
      url,
      headers,
      '',
      15000,
      false,
      HarmonySteamProfileResolver.toProxy(account, proxyPassword)
    );
    try {
      const response = await session.request(request);
      if (!response.isOk()) {
        SteamArkLog.debug(TAG, 'profile page background lookup returned HTTP ' + response.statusCode.toString());
        return profile;
      }
      const poster: string = this.extractHtmlAttribute(response.body, 'video', 'poster');
      const movieUrl: string = this.extractProfileMovieUrl(response.body);
      const imageUrl: string = this.validBackgroundUrl(poster);
      const validMovieUrl: string = this.validBackgroundUrl(movieUrl);
      const avatarFallback: string = profile.avatarUrl.length > 0
        ? profile.avatarUrl
        : this.extractProfileAvatar(response.body);
      const pageData: SteamArkResolvedProfile = this.extractProfilePageData(response.body, profile);
      if (imageUrl.length <= 0 && validMovieUrl.length <= 0 && avatarFallback.length <= 0 &&
        pageData.displayName.length <= 0 && pageData.summary.length <= 0 && pageData.level <= 0) {
        SteamArkLog.debug(TAG, 'profile page contained no usable background media');
        return profile;
      }
      SteamArkLog.info(TAG, 'profile page background media resolved; animated=' + String(validMovieUrl.length > 0));
      return new SteamArkResolvedProfile(
        pageData.displayName.length > 0 ? pageData.displayName : profile.displayName,
        avatarFallback,
        imageUrl,
        validMovieUrl,
        false,
        pageData.avatarFrameUrl.length > 0 ? pageData.avatarFrameUrl : profile.avatarFrameUrl,
        pageData.summary.length > 0 ? pageData.summary : profile.summary,
        pageData.level > 0 ? pageData.level : profile.level,
        pageData.countryCode.length > 0 ? pageData.countryCode : profile.countryCode,
        profile.walletBalance,
        profile.walletCurrency,
        profile.miniProfileBackgroundImageUrl,
        profile.miniProfileBackgroundMovieUrl
      );
    } catch (error) {
      SteamArkLog.warn(TAG, 'profile page background lookup failed; errorType=' + SteamArkLog.errorKind(error));
      return profile;
    }
  }

  private extractProfileMovieUrl(body: string): string {
    const mp4: string = this.extractHtmlSource(body, 'video/mp4');
    if (mp4.length > 0) {
      return mp4;
    }
    return this.extractHtmlSource(body, 'video/webm');
  }

  private extractProfilePageData(body: string, fallback: SteamArkResolvedProfile): SteamArkResolvedProfile {
    let displayName: string = '';
    let summary: string = '';
    let avatarUrl: string = '';
    let level: number = 0;
    let countryCode: string = '';
    const dataPattern = /g_rgProfileData\s*=\s*(\{[\s\S]*?\});/;
    const dataMatch = dataPattern.exec(body);
    if (dataMatch !== null) {
      try {
        const root = SteamJsonParser.parse(dataMatch[1].replace(/\\\//g, '/'), steamArkCoreLogger);
        if (root.kind === SteamJsonValueKind.OBJECT) {
          displayName = this.readText(root.getProperty('personaname')) ||
            this.readText(root.getProperty('persona_name'));
          summary = this.readText(root.getProperty('summary'));
          avatarUrl = this.validAvatarUrl(this.readAvatarUrl(root.getProperty('avatarfull')));
          level = this.readInteger(root.getProperty('level'));
        }
      } catch (error) {
        SteamArkLog.debug(TAG, 'profile page embedded data parse skipped; errorType=' +
          SteamArkLog.errorKind(error));
      }
    }
    const levelPattern = /friendPlayerLevelNum[^>]*>([0-9]+)</i;
    const levelMatch = levelPattern.exec(body);
    if (level <= 0 && levelMatch !== null) {
      level = this.readIntegerFromText(levelMatch[1]);
    }
    const countryPattern = /countryflags\/([a-z]{2})\.gif/i;
    const countryMatch = countryPattern.exec(body);
    if (countryMatch !== null) {
      countryCode = countryMatch[1].toUpperCase();
    }
    return new SteamArkResolvedProfile(
      displayName,
      avatarUrl,
      fallback.backgroundImageUrl,
      fallback.backgroundMovieUrl,
      fallback.backgroundTiled,
      fallback.avatarFrameUrl,
      summary,
      level,
      countryCode,
      fallback.walletBalance,
      fallback.walletCurrency,
      fallback.miniProfileBackgroundImageUrl,
      fallback.miniProfileBackgroundMovieUrl
    );
  }

  private extractProfileAvatar(body: string): string {
    const propertyPattern = new RegExp('<meta[^>]+property=["\\\']og:image["\\\'][^>]+content=["\\\']([^"\\\']+)["\\\']', 'i');
    const propertyMatch = propertyPattern.exec(body);
    if (propertyMatch !== null) {
      return this.validAvatarUrl(this.decodeHtmlUrl(propertyMatch[1]));
    }
    const contentPattern = new RegExp('<meta[^>]+content=["\\\']([^"\\\']+)["\\\'][^>]+property=["\\\']og:image["\\\']', 'i');
    const contentMatch = contentPattern.exec(body);
    return contentMatch === null ? '' : this.validAvatarUrl(this.decodeHtmlUrl(contentMatch[1]));
  }

  private extractHtmlSource(body: string, type: string): string {
    const sourcePattern = new RegExp('<source[^>]+src=["\\\']([^"\\\']+)["\\\'][^>]+type=["\\\']' + type + '["\\\']', 'i');
    const sourceMatch = sourcePattern.exec(body);
    return sourceMatch === null ? '' : this.decodeHtmlUrl(sourceMatch[1]);
  }

  private extractHtmlAttribute(body: string, tag: string, attribute: string): string {
    const pattern = new RegExp('<' + tag + '[^>]*\\s' + attribute + '=["\\\']([^"\\\']+)["\\\']', 'i');
    const match = pattern.exec(body);
    return match === null ? '' : this.decodeHtmlUrl(match[1]);
  }

  private decodeHtmlUrl(value: string): string {
    return value.replace(/&amp;/g, '&').replace(/&quot;/g, '"').trim();
  }

  private parseProfile(body: string): SteamArkResolvedProfile {
    const root = SteamJsonParser.parse(body, steamArkCoreLogger);
    if (root.kind !== SteamJsonValueKind.OBJECT) {
      throw new Error('Steam profile response is not an object');
    }
    const displayName = this.readText(root.getProperty('personaname')) ||
      this.readText(root.getProperty('persona_name'));
    const avatarUrl = this.validAvatarUrl(
      this.readAvatarUrl(root.getProperty('avatarfull')) ||
      this.readAvatarUrl(root.getProperty('avatar_url_full')) ||
      this.readAvatarUrl(root.getProperty('avatarmedium')) ||
      this.readAvatarUrl(root.getProperty('avatar_url')) ||
      this.readAvatarUrl(root.getProperty('avatar'))
    );
    if (displayName.length <= 0 && avatarUrl.length <= 0) {
      throw new Error('Steam profile response did not contain display name or avatar');
    }
    const backgroundValue: SteamJsonValue | null = root.getProperty('profile_background');
    let miniBackgroundImageUrl: string = '';
    let miniBackgroundMovieUrl: string = '';
    if (backgroundValue !== null && backgroundValue.kind === SteamJsonValueKind.OBJECT) {
      miniBackgroundImageUrl = this.validBackgroundUrl(
        this.readTextValue(backgroundValue.getProperty('image_large')) ||
        this.readTextValue(backgroundValue.getProperty('image_small')) ||
        this.readTextValue(backgroundValue.getProperty('image'))
      );
      miniBackgroundMovieUrl = this.validBackgroundUrl(
        this.readTextValue(backgroundValue.getProperty('video/mp4')) ||
        this.readTextValue(backgroundValue.getProperty('video/webm')) ||
        this.readTextValue(backgroundValue.getProperty('movie_mp4')) ||
        this.readTextValue(backgroundValue.getProperty('movie_webm')) ||
        this.readTextValue(backgroundValue.getProperty('movie_mp4_small')) ||
        this.readTextValue(backgroundValue.getProperty('movie_webm_small'))
      );
    } else if (backgroundValue !== null && backgroundValue.kind === SteamJsonValueKind.STRING) {
      miniBackgroundImageUrl = this.validBackgroundUrl(backgroundValue.stringValue);
    }
    if (miniBackgroundImageUrl.length <= 0) {
      miniBackgroundImageUrl = this.validBackgroundUrl(
        this.readTextValue(root.getProperty('profile_background_image')) ||
        this.readTextValue(root.getProperty('profile_background_image_url')) ||
        this.readTextValue(root.getProperty('profile_background_image_large'))
      );
    }
    const avatarFrameUrl: string = this.readAvatarFrame(root.getProperty('avatar_frame')) ||
      this.readAvatarFrame(root.getProperty('avatar_frame_url'));
    const summary: string = this.readText(root.getProperty('summary')) ||
      this.readText(root.getProperty('real_name'));
    const level: number = this.readInteger(root.getProperty('level')) ||
      this.readInteger(root.getProperty('steam_level'));
    const countryCode: string = this.readText(root.getProperty('loccountrycode')) ||
      this.readText(root.getProperty('country_code'));
    const walletBalance: string = this.readText(root.getProperty('wallet_balance'));
    const walletCurrency: string = this.readText(root.getProperty('wallet_currency'));
    return new SteamArkResolvedProfile(
      displayName,
      avatarUrl,
      '',
      '',
      false,
      avatarFrameUrl,
      summary,
      level,
      countryCode,
      walletBalance,
      walletCurrency,
      miniBackgroundImageUrl,
      miniBackgroundMovieUrl
    );
  }

  private async ensureStaticBackground(
    resolved: SteamArkResolvedProfile,
    session: NGFHttpSession,
    profile: SteamAccountProfile,
    proxyPassword: string
  ): Promise<SteamArkResolvedProfile> {
    if (resolved.backgroundMovieUrl.length <= 0 &&
      (resolved.miniProfileBackgroundMovieUrl.length <= 0 ||
        resolved.miniProfileBackgroundImageUrl.length > 0)) {
      return resolved;
    }
    let profileFramePath: string = resolved.backgroundImageUrl;
    if (resolved.backgroundMovieUrl.length > 0) {
      const extractedProfileFrame: string = await this.extractBackgroundFrame(
        resolved.backgroundMovieUrl, session, profile, proxyPassword, 'profile'
      );
      if (extractedProfileFrame.length > 0) {
        profileFramePath = extractedProfileFrame;
      }
    }
    let miniFramePath: string = resolved.miniProfileBackgroundImageUrl;
    if (miniFramePath.length <= 0 && resolved.miniProfileBackgroundMovieUrl.length > 0) {
      miniFramePath = await this.extractBackgroundFrame(
        resolved.miniProfileBackgroundMovieUrl, session, profile, proxyPassword, 'mini'
      );
    }
    if (profileFramePath.length <= 0 && miniFramePath.length <= 0) {
      SteamArkLog.warn(TAG, 'animated profile background frame extraction returned empty; keeping poster');
      return resolved;
    }
    return new SteamArkResolvedProfile(
      resolved.displayName,
      resolved.avatarUrl,
      profileFramePath,
      resolved.backgroundMovieUrl,
      resolved.backgroundTiled,
      resolved.avatarFrameUrl,
      resolved.summary,
      resolved.level,
      resolved.countryCode,
      resolved.walletBalance,
      resolved.walletCurrency,
      miniFramePath,
      resolved.miniProfileBackgroundMovieUrl
    );
  }

  private async extractBackgroundFrame(
    movieUrl: string,
    session: NGFHttpSession,
    profile: SteamAccountProfile,
    proxyPassword: string,
    fileKind: string
  ): Promise<string> {
    const context = uiContextManager.getAbilityContext();
    if (context === null || context.filesDir.length <= 0) {
      return '';
    }
    const directory: string = context.filesDir + '/steam-profile-background';
    const safeAccountId: string = profile.accountId.replace(/[^a-zA-Z0-9._-]/g, '_');
    const safeFileKind: string = fileKind.replace(/[^a-zA-Z0-9._-]/g, '_');
    const moviePath: string = directory + '/' + safeAccountId + '-' + safeFileKind + '.mp4';
    const framePath: string = directory + '/' + safeAccountId + '-' + safeFileKind + '.jpg';
    try {
      fs.mkdirSync(directory, true);
      const headers = new Map<string, string>();
      headers.set('Accept', 'video/mp4,video/webm');
      headers.set('User-Agent', ASFWorkshopProductIdentity.userAgent('SteamProfileBackground'));
      const response: NGFHttpSessionResponse = await session.request(new NGFHttpSessionRequest(
        NGFHttpMethod.GET,
        movieUrl,
        headers,
        '',
        30000,
        true,
        HarmonySteamProfileResolver.toProxy(profile, proxyPassword)
      ));
      if (!response.isOk() || response.bodyBytes.length <= 0) {
        return '';
      }
      let movieFile: fs.File | null = null;
      let sourceFile: fs.File | null = null;
      let frameFile: fs.File | null = null;
      let generator: media.AVImageGenerator | null = null;
      let pixelMap: image.PixelMap | null = null;
      let packer: image.ImagePacker | null = null;
      try {
        movieFile = fs.openSync(moviePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(movieFile.fd, response.bodyBytes);
        fs.closeSync(movieFile);
        movieFile = null;
        sourceFile = fs.openSync(moviePath, fs.OpenMode.READ_ONLY);
        generator = await media.createAVImageGenerator();
        generator.fdSrc = { fd: sourceFile.fd, offset: 0, length: response.bodyBytes.length };
        pixelMap = await generator.fetchFrameByTime(
          0,
          media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC,
          { width: 1920, height: 1080 }
        );
        packer = image.createImagePacker();
        const packed: ArrayBuffer = await packer.packToData(
          pixelMap,
          { format: 'image/jpeg', quality: 88 }
        );
        frameFile = fs.openSync(framePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(frameFile.fd, new Uint8Array(packed));
        fs.closeSync(frameFile);
        frameFile = null;
        SteamArkLog.info(TAG, 'animated profile background frame extracted; account=' +
          SteamArkLog.accountId(profile.accountId));
        return 'file://' + framePath;
      } finally {
        if (packer !== null) {
          await this.releaseImagePacker(packer);
        }
        if (pixelMap !== null) {
          this.releasePixelMap(pixelMap);
        }
        if (generator !== null) {
          await this.releaseImageGenerator(generator);
        }
        this.closeFile(frameFile);
        this.closeFile(sourceFile);
        this.closeFile(movieFile);
        this.removeFile(moviePath);
      }
    } catch (error) {
      SteamArkLog.warn(TAG, 'animated profile background frame extraction failed; account=' +
        SteamArkLog.accountId(profile.accountId) + ', errorType=' + SteamArkLog.errorKind(error));
      return '';
    }
  }

  private closeFile(file: fs.File | null): void {
    if (file === null) {
      return;
    }
    try {
      fs.closeSync(file);
    } catch {
      return;
    }
  }

  private removeFile(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch {
      return;
    }
  }

  private async releaseImageGenerator(generator: media.AVImageGenerator): Promise<void> {
    try {
      await generator.release();
    } catch {
      return;
    }
  }

  private async releaseImagePacker(packer: image.ImagePacker): Promise<void> {
    try {
      await packer.release();
    } catch {
      return;
    }
  }

  private releasePixelMap(pixelMap: image.PixelMap): void {
    try {
      pixelMap.release();
    } catch {
      return;
    }
  }

  private readText(value: SteamJsonValue | null): string {
    if (value === null) {
      return '';
    }
    if (value.kind === SteamJsonValueKind.STRING) {
      const normalized = value.stringValue.trim();
      return normalized.length > MAX_PROFILE_NAME_LENGTH ?
        normalized.substring(0, MAX_PROFILE_NAME_LENGTH) : normalized;
    }
    return '';
  }

  private validAvatarUrl(value: string): string {
    if (value.length <= 0 || value.length > MAX_AVATAR_URL_LENGTH || !value.startsWith('https://')) {
      return '';
    }
    return value;
  }

  private validBackgroundUrl(value: string): string {
    const normalized: string = value.trim();
    if (normalized.length <= 0 || normalized.length > MAX_BACKGROUND_URL_LENGTH ||
      !normalized.startsWith('https://')) {
      return '';
    }
    return normalized;
  }

  private readTextValue(value: SteamJsonValue | null): string {
    return value !== null && value.kind === SteamJsonValueKind.STRING ? value.stringValue.trim() : '';
  }

  private readBoolean(value: SteamJsonValue | null): boolean {
    if (value === null) {
      return false;
    }
    if (value.kind === SteamJsonValueKind.BOOLEAN) {
      return value.booleanValue;
    }
    return value.kind === SteamJsonValueKind.NUMBER && value.numberValue === '1';
  }

  private readAvatarUrl(value: SteamJsonValue | null): string {
    if (value === null || value.kind !== SteamJsonValueKind.STRING) {
      return '';
    }
    const normalized = value.stringValue.trim();
    return normalized.length > MAX_AVATAR_URL_LENGTH ? '' : normalized;
  }

  private readAvatarFrame(value: SteamJsonValue | null): string {
    if (value === null) {
      return '';
    }
    if (value.kind === SteamJsonValueKind.STRING) {
      return this.validAvatarUrl(value.stringValue.trim());
    }
    if (value.kind !== SteamJsonValueKind.OBJECT) {
      return '';
    }
    return this.validAvatarUrl(
      this.readTextValue(value.getProperty('image_large')) ||
      this.readTextValue(value.getProperty('image_small')) ||
      this.readTextValue(value.getProperty('image'))
    );
  }

  private readInteger(value: SteamJsonValue | null): number {
    if (value === null) {
      return 0;
    }
    const text: string = value.kind === SteamJsonValueKind.NUMBER
      ? value.numberValue
      : (value.kind === SteamJsonValueKind.STRING ? value.stringValue : '');
    const parsed: number = Number(text);
    return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
  }

  private readIntegerFromText(value: string): number {
    const parsed: number = Number(value.trim());
    return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
  }

  private static isSteamId64(value: string): boolean {
    if (value.length !== 17) {
      return false;
    }
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      if (code < 48 || code > 57) {
        return false;
      }
    }
    return true;
  }

  private static toAccountId32(steamId64: string): string {
    if (!HarmonySteamProfileResolver.isSteamId64(steamId64) ||
      HarmonySteamProfileResolver.compareDecimalStrings(steamId64, STEAM_ID64_INDIVIDUAL_BASE) < 0) {
      return '';
    }
    let borrow: number = 0;
    let result: string = '';
    let rightIndex: number = STEAM_ID64_INDIVIDUAL_BASE.length - 1;
    for (let leftIndex: number = steamId64.length - 1; leftIndex >= 0; leftIndex--) {
      const leftDigit: number = steamId64.charCodeAt(leftIndex) - 48;
      const rightDigit: number = rightIndex >= 0
        ? STEAM_ID64_INDIVIDUAL_BASE.charCodeAt(rightIndex) - 48
        : 0;
      let digit: number = leftDigit - rightDigit - borrow;
      if (digit < 0) {
        digit += 10;
        borrow = 1;
      } else {
        borrow = 0;
      }
      result = String(digit) + result;
      rightIndex--;
    }
    let firstNonZero: number = 0;
    while (firstNonZero < result.length - 1 && result.charAt(firstNonZero) === '0') {
      firstNonZero++;
    }
    const normalized: string = result.substring(firstNonZero);
    const numeric: number = Number(normalized);
    return Number.isInteger(numeric) && numeric >= 0 && numeric <= 4294967295 ? normalized : '';
  }

  private static compareDecimalStrings(left: string, right: string): number {
    if (left.length !== right.length) {
      return left.length > right.length ? 1 : -1;
    }
    if (left === right) {
      return 0;
    }
    return left > right ? 1 : -1;
  }

  private static encodeLoginCookieValue(value: string): string {
    return value.replace(/\|\|/g, '%7C%7C');
  }

  private static toProxy(profile: SteamAccountProfile, password: string): NGFProxyConfiguration {
    if (profile.proxy.kind === SteamProxyKind.DIRECT) {
      return NGFProxyConfiguration.direct();
    }
    if (profile.proxy.kind === SteamProxyKind.HTTP) {
      return NGFProxyConfiguration.http(profile.proxy.host, profile.proxy.port, profile.proxy.username, password);
    }
    if (profile.proxy.kind === SteamProxyKind.SOCKS5) {
      return NGFProxyConfiguration.socks5(profile.proxy.host, profile.proxy.port, profile.proxy.username, password);
    }
    return NGFProxyConfiguration.system();
  }
}
