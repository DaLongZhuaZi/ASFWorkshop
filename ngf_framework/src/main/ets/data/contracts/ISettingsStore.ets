export interface ISettingsStore {
  getString(key: string, defaultValue: string): string;
  getNumber(key: string, defaultValue: number): number;
  getBoolean(key: string, defaultValue: boolean): boolean;
  setString(key: string, value: string): void;
  setStringAsync(key: string, value: string): Promise<boolean>;
  setNumber(key: string, value: number): void;
  setBoolean(key: string, value: boolean): void;
  waitUntilReady(): Promise<boolean>;
}
