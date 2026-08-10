import AsyncStorage from "@react-native-async-storage/async-storage";
import * as SecureStore from "expo-secure-store";
import { DEFAULT_COMPANY_ID } from "../../config/companies";
import { DEFAULT_RETENTION_POLICY, type AppSettings } from "../../types/models";
import { SECURE_STORE_KEYS, STORAGE_KEYS } from "./keys";

export const DEFAULT_SETTINGS: AppSettings = {
  language: "ru",
  employee: { fullName: "", phone: "" },
  retentionPolicy: DEFAULT_RETENTION_POLICY,
  defaultCompanyId: DEFAULT_COMPANY_ID,
};

export async function loadSettings(): Promise<AppSettings> {
  const raw = await AsyncStorage.getItem(STORAGE_KEYS.settings);
  if (!raw) return DEFAULT_SETTINGS;
  try {
    const parsed = JSON.parse(raw);
    return { ...DEFAULT_SETTINGS, ...parsed, employee: { ...DEFAULT_SETTINGS.employee, ...parsed.employee } };
  } catch {
    return DEFAULT_SETTINGS;
  }
}

export async function saveSettings(settings: AppSettings): Promise<void> {
  await AsyncStorage.setItem(STORAGE_KEYS.settings, JSON.stringify(settings));
}

/** The Anthropic API key is a credential, so it lives in SecureStore, not AsyncStorage. */
export async function loadApiKey(): Promise<string | null> {
  return SecureStore.getItemAsync(SECURE_STORE_KEYS.anthropicApiKey);
}

export async function saveApiKey(apiKey: string): Promise<void> {
  await SecureStore.setItemAsync(SECURE_STORE_KEYS.anthropicApiKey, apiKey);
}

export async function clearApiKey(): Promise<void> {
  await SecureStore.deleteItemAsync(SECURE_STORE_KEYS.anthropicApiKey);
}
