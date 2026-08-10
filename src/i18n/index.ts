import i18next from "i18next";
import { initReactI18next } from "react-i18next";
import type { AppLanguage } from "../types/models";
import en from "./locales/en.json";
import ru from "./locales/ru.json";

// Starts in Russian (the app's default per spec) synchronously, so the
// first frame renders with real copy. Settings (loaded async from
// storage) may then switch it to the user's saved language - see
// src/hooks/useAppSettings.ts.
i18next.use(initReactI18next).init({
  compatibilityJSON: "v4",
  resources: {
    ru: { translation: ru },
    en: { translation: en },
  },
  lng: "ru",
  fallbackLng: "ru",
  interpolation: { escapeValue: false },
});

export function setAppLanguage(language: AppLanguage): void {
  if (i18next.language !== language) {
    i18next.changeLanguage(language);
  }
}

export default i18next;
