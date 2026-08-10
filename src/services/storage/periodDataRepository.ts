import AsyncStorage from "@react-native-async-storage/async-storage";
import { emptyPeriodData, type PeriodData } from "../../types/models";
import { periodDataKey, periodKeyFromStorageKey } from "./keys";

export async function loadPeriodData(periodKey: string): Promise<PeriodData> {
  const raw = await AsyncStorage.getItem(periodDataKey(periodKey));
  if (!raw) return emptyPeriodData(periodKey);
  try {
    return { ...emptyPeriodData(periodKey), ...JSON.parse(raw) };
  } catch {
    return emptyPeriodData(periodKey);
  }
}

export async function savePeriodData(data: PeriodData): Promise<void> {
  await AsyncStorage.setItem(periodDataKey(data.periodKey), JSON.stringify(data));
}

export async function deletePeriodData(periodKey: string): Promise<void> {
  await AsyncStorage.removeItem(periodDataKey(periodKey));
}

/** All period keys (startDate values) that currently have stored data, oldest first. */
export async function listStoredPeriodKeys(): Promise<string[]> {
  const allKeys = await AsyncStorage.getAllKeys();
  const periodKeys = allKeys
    .map(periodKeyFromStorageKey)
    .filter((k): k is string => k !== null);
  return periodKeys.sort();
}
