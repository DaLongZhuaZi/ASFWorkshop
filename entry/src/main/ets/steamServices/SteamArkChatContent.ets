export enum SteamArkChatContentKind {
  TEXT = 'text',
  LINK = 'link'
}

export class SteamArkChatContentSegment {
  readonly id: string;
  readonly kind: SteamArkChatContentKind;
  readonly text: string;
  readonly url: string;

  constructor(id: string, kind: SteamArkChatContentKind, text: string, url: string = '') {
    this.id = id;
    this.kind = kind;
    this.text = text;
    this.url = url;
  }
}

export class SteamArkChatContentParser {
  static parse(content: string): Array<SteamArkChatContentSegment> {
    const segments: Array<SteamArkChatContentSegment> = [];
    let cursor: number = 0;
    let segmentIndex: number = 0;
    while (cursor < content.length) {
      const bbCodeStart: number = SteamArkChatContentParser.findBbCodeUrl(content, cursor);
      const plainUrlStart: number = SteamArkChatContentParser.findPlainUrl(content, cursor);
      const nextStart: number = SteamArkChatContentParser.firstPosition(bbCodeStart, plainUrlStart);
      if (nextStart < 0) {
        SteamArkChatContentParser.appendText(segments, content.substring(cursor), segmentIndex);
        break;
      }
      if (nextStart > cursor) {
        SteamArkChatContentParser.appendText(segments, content.substring(cursor, nextStart), segmentIndex);
        segmentIndex += 1;
      }
      if (nextStart === bbCodeStart) {
        const nextCursor: number = SteamArkChatContentParser.appendBbCodeUrl(
          segments, content, bbCodeStart, segmentIndex);
        if (nextCursor > bbCodeStart) {
          cursor = nextCursor;
          segmentIndex += 1;
          continue;
        }
      } else {
        const nextCursor: number = SteamArkChatContentParser.appendPlainUrl(
          segments, content, plainUrlStart, segmentIndex);
        if (nextCursor > plainUrlStart) {
          cursor = nextCursor;
          segmentIndex += 1;
          continue;
        }
      }
      SteamArkChatContentParser.appendText(segments, content.substring(nextStart, nextStart + 1), segmentIndex);
      segmentIndex += 1;
      cursor = nextStart + 1;
    }
    if (segments.length <= 0) {
      segments.push(new SteamArkChatContentSegment('text-0', SteamArkChatContentKind.TEXT, content));
    }
    return segments;
  }

  static emoticonName(content: string): string {
    const value: string = content.trim();
    const legacyPrefix: string = '[emoticon]';
    const legacySuffix: string = '[/emoticon]';
    let name: string = '';
    if (value.startsWith(legacyPrefix) && value.endsWith(legacySuffix) &&
      value.length > legacyPrefix.length + legacySuffix.length) {
      name = value.substring(legacyPrefix.length, value.length - legacySuffix.length);
    } else if (value.startsWith(':') && value.endsWith(':') && value.length > 2) {
      name = value.substring(1, value.length - 1);
    }
    if (!SteamArkChatContentParser.isSafeEmoticonName(name)) {
      return '';
    }
    return name;
  }

  static emoticonImageUrl(content: string): string {
    const name: string = SteamArkChatContentParser.emoticonName(content);
    if (name.length <= 0) {
      return '';
    }
    return 'https://community.akamai.steamstatic.com/economy/emoticonlarge/' + encodeURIComponent(name);
  }

  private static appendBbCodeUrl(segments: Array<SteamArkChatContentSegment>, content: string,
    start: number, segmentIndex: number): number {
    const headerEnd: number = content.indexOf(']', start + 5);
    if (headerEnd < 0) {
      return start;
    }
    const lowerContent: string = content.toLowerCase();
    const closeTag: string = '[/url]';
    const closeStart: number = lowerContent.indexOf(closeTag, headerEnd + 1);
    if (closeStart < 0) {
      return start;
    }
    const url: string = content.substring(start + 5, headerEnd).trim();
    if (!SteamArkChatContentParser.isSafeWebUrl(url)) {
      return start;
    }
    const rawLabel: string = content.substring(headerEnd + 1, closeStart);
    const label: string = rawLabel.length > 0 ? rawLabel : url;
    segments.push(new SteamArkChatContentSegment('link-' + segmentIndex.toString(),
      SteamArkChatContentKind.LINK, label, url));
    return closeStart + closeTag.length;
  }

  private static appendPlainUrl(segments: Array<SteamArkChatContentSegment>, content: string,
    start: number, segmentIndex: number): number {
    let end: number = start;
    while (end < content.length && !SteamArkChatContentParser.isUrlBoundary(content.charAt(end))) {
      end += 1;
    }
    let urlEnd: number = end;
    while (urlEnd > start && SteamArkChatContentParser.isTrailingPunctuation(content.charAt(urlEnd - 1))) {
      urlEnd -= 1;
    }
    const url: string = content.substring(start, urlEnd);
    if (!SteamArkChatContentParser.isSafeWebUrl(url)) {
      return start;
    }
    segments.push(new SteamArkChatContentSegment('link-' + segmentIndex.toString(),
      SteamArkChatContentKind.LINK, url, url));
    if (urlEnd < end) {
      segments.push(new SteamArkChatContentSegment('text-' + (segmentIndex + 1).toString(),
        SteamArkChatContentKind.TEXT, content.substring(urlEnd, end)));
    }
    return end;
  }

  private static appendText(segments: Array<SteamArkChatContentSegment>, text: string,
    segmentIndex: number): void {
    if (text.length > 0) {
      segments.push(new SteamArkChatContentSegment('text-' + segmentIndex.toString(),
        SteamArkChatContentKind.TEXT, text));
    }
  }

  private static findBbCodeUrl(content: string, from: number): number {
    return content.toLowerCase().indexOf('[url=', from);
  }

  private static findPlainUrl(content: string, from: number): number {
    const lowerContent: string = content.toLowerCase();
    const httpsPosition: number = lowerContent.indexOf('https://', from);
    const httpPosition: number = lowerContent.indexOf('http://', from);
    return SteamArkChatContentParser.firstPosition(httpsPosition, httpPosition);
  }

  private static firstPosition(first: number, second: number): number {
    if (first < 0) {
      return second;
    }
    if (second < 0) {
      return first;
    }
    return Math.min(first, second);
  }

  private static isSafeWebUrl(url: string): boolean {
    const lowerUrl: string = url.trim().toLowerCase();
    return lowerUrl.startsWith('https://') || lowerUrl.startsWith('http://');
  }

  private static isUrlBoundary(character: string): boolean {
    return character === ' ' || character === '\n' || character === '\r' || character === '\t' || character === '<';
  }

  private static isTrailingPunctuation(character: string): boolean {
    return character === '.' || character === ',' || character === ';' || character === '!';
  }

  private static isSafeEmoticonName(name: string): boolean {
    if (name.length <= 0 || name.length > 128) {
      return false;
    }
    for (let index: number = 0; index < name.length; index++) {
      const character: string = name.charAt(index);
      if (character === ':' || character === '[' || character === ']' ||
        character === '/' || character === '\\' || character === ' ' ||
        character === '\n' || character === '\r' || character === '\t') {
        return false;
      }
    }
    return true;
  }
}
