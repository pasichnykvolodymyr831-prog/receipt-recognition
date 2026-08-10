import React from "react";
import { useTranslation } from "react-i18next";
import { ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useAppSettingsContext } from "../context/AppSettingsContext";
import type { AppLanguage } from "../types/models";

export default function SettingsScreen() {
  const { t } = useTranslation();
  const { settings, updateSettings, updateEmployee } = useAppSettingsContext();

  if (!settings) {
    return (
      <SafeAreaView style={styles.safeArea}>
        <Text style={styles.loading}>{t("common.loading")}</Text>
      </SafeAreaView>
    );
  }

  const setLanguage = (language: AppLanguage) => updateSettings({ language });

  return (
    <SafeAreaView style={styles.safeArea} edges={["top"]}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>{t("settings.title")}</Text>

        <Text style={styles.sectionLabel}>{t("settings.language")}</Text>
        <View style={styles.languageRow}>
          <LanguageButton
            label={t("settings.languageRussian")}
            active={settings.language === "ru"}
            onPress={() => setLanguage("ru")}
          />
          <LanguageButton
            label={t("settings.languageEnglish")}
            active={settings.language === "en"}
            onPress={() => setLanguage("en")}
          />
        </View>

        <Text style={styles.sectionLabel}>{t("settings.employeeSection")}</Text>
        <Text style={styles.fieldLabel}>{t("settings.fullName")}</Text>
        <TextInput
          style={styles.input}
          value={settings.employee.fullName}
          onChangeText={(fullName) => updateEmployee({ fullName })}
          placeholder={t("settings.fullNamePlaceholder")}
          autoCapitalize="words"
        />

        <Text style={styles.fieldLabel}>{t("settings.phone")}</Text>
        <TextInput
          style={styles.input}
          value={settings.employee.phone}
          onChangeText={(phone) => updateEmployee({ phone })}
          placeholder={t("settings.phonePlaceholder")}
          keyboardType="phone-pad"
        />
      </ScrollView>
    </SafeAreaView>
  );
}

function LanguageButton({ label, active, onPress }: { label: string; active: boolean; onPress: () => void }) {
  return (
    <TouchableOpacity style={[styles.langButton, active && styles.langButtonActive]} onPress={onPress}>
      <Text style={[styles.langButtonText, active && styles.langButtonTextActive]}>{label}</Text>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: "#fff" },
  content: { padding: 20, gap: 8 },
  loading: { padding: 20, fontSize: 16, color: "#666" },
  title: { fontSize: 22, fontWeight: "700", marginBottom: 16 },
  sectionLabel: { fontSize: 13, fontWeight: "600", color: "#666", marginTop: 20, marginBottom: 8, textTransform: "uppercase" },
  languageRow: { flexDirection: "row", gap: 10 },
  langButton: {
    paddingVertical: 10,
    paddingHorizontal: 18,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "#d0d0d0",
    backgroundColor: "#f7f7f7",
  },
  langButtonActive: { backgroundColor: "#2f6fed", borderColor: "#2f6fed" },
  langButtonText: { fontSize: 15, color: "#333" },
  langButtonTextActive: { color: "#fff", fontWeight: "600" },
  fieldLabel: { fontSize: 14, color: "#444", marginBottom: 6, marginTop: 4 },
  input: {
    borderWidth: 1,
    borderColor: "#d0d0d0",
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 16,
    backgroundColor: "#fafafa",
  },
});
