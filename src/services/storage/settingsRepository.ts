import AsyncStorage from "@react-native-async-storage/async-storage";
import { DEFAULT_COMPANY_ID } from "../../config/companies";
import { DEFAULT_RETENTION_POLICY, type AppSettings } from "../../types/models";
import { STORAGE_KEYS } from "./keys";

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
