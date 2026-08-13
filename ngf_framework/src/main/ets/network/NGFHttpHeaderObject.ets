/**
 * NetworkKit expects request headers as an enumerable object rather than a
 * serialized header block. Reflect.set keeps arbitrary HTTP header names
 * available without coupling the NGF contract to a fixed header list.
 */
export class NGFHttpHeaderObject {
  static fromBlock(rawHeader: string): NGFHttpHeaderObject {
    const result: NGFHttpHeaderObject = new NGFHttpHeaderObject();
    const lines: Array<string> = rawHeader.split(/\r?\n/);
    for (let index = 0; index < lines.length; index++) {
      const line: string = lines[index].trim();
      const separator: number = line.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      result.set(line.substring(0, separator), line.substring(separator + 1).trim());
    }
    return result;
  }

  set(name: string, value: string): void {
    const normalizedName: string = name.trim();
    if (normalizedName.length <= 0) {
      return;
    }
    Reflect.set(this, normalizedName, value);
  }

  asObject(): Object {
    return this;
  }
}
