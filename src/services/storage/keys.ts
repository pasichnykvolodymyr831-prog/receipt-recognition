export const STORAGE_KEYS = {
  settings: "settings/v1",
  periodDataPrefix: "period-data/v1/", // + periodKey (startDate)
} as const;

export const SECURE_STORE_KEYS = {
  anthropicApiKey: "anthropic-api-key",
} as const;

export function periodDataKey(periodKey: string): string {
  return `${STORAGE_KEYS.periodDataPrefix}${periodKey}`;
}

export function periodKeyFromStorageKey(storageKey: string): string | null {
  return storageKey.startsWith(STORAGE_KEYS.periodDataPrefix)
    ? storageKey.slice(STORAGE_KEYS.periodDataPrefix.length)
    : null;
}
