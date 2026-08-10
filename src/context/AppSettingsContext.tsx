import React, { createContext, useContext } from "react";
import { useAppSettings, type UseAppSettingsResult } from "../hooks/useAppSettings";

const AppSettingsContext = createContext<UseAppSettingsResult | null>(null);

export function AppSettingsProvider({ children }: { children: React.ReactNode }) {
  const value = useAppSettings();
  return <AppSettingsContext.Provider value={value}>{children}</AppSettingsContext.Provider>;
}

/** Shared, app-wide Settings state so edits in the Settings screen are immediately visible everywhere else. */
export function useAppSettingsContext(): UseAppSettingsResult {
  const ctx = useContext(AppSettingsContext);
  if (!ctx) throw new Error("useAppSettingsContext must be used within an AppSettingsProvider");
  return ctx;
}
