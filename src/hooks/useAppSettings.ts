import { useCallback, useEffect, useState } from "react";
import { setAppLanguage } from "../i18n";
import { loadSettings, saveSettings } from "../services/storage/settingsRepository";
import { sweepExpiredPeriods } from "../services/storage/retentionSweep";
import type { AppSettings, Employee } from "../types/models";

export interface UseAppSettingsResult {
  settings: AppSettings | null; // null while loading from storage
  updateSettings: (patch: Partial<Omit<AppSettings, "employee">>) => void;
  updateEmployee: (patch: Partial<Employee>) => void;
}

/** Loads Settings once on mount and keeps AsyncStorage + i18next in sync with in-memory state. */
export function useAppSettings(): UseAppSettingsResult {
  const [settings, setSettings] = useState<AppSettings | null>(null);

  useEffect(() => {
    let cancelled = false;
    loadSettings().then((loaded) => {
      if (cancelled) return;
      setAppLanguage(loaded.language);
      setSettings(loaded);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const updateSettings = useCallback((patch: Partial<Omit<AppSettings, "employee">>) => {
    setSettings((prev) => {
      if (!prev) return prev;
      const next: AppSettings = { ...prev, ...patch };
      saveSettings(next);
      if (patch.language) setAppLanguage(patch.language);
      return next;
    });
  }, []);

  const updateEmployee = useCallback((patch: Partial<Employee>) => {
    setSettings((prev) => {
      if (!prev) return prev;
      const next: AppSettings = { ...prev, employee: { ...prev.employee, ...patch } };
      saveSettings(next);
      return next;
    });
  }, []);

  // Runs once at startup, and again immediately whenever the retention
  // policy itself changes, so tightening it takes effect right away
  // instead of waiting for the next app launch.
  useEffect(() => {
    if (!settings) return;
    sweepExpiredPeriods(settings.retentionPolicy);
  }, [settings?.retentionPolicy]);

  return { settings, updateSettings, updateEmployee };
}
