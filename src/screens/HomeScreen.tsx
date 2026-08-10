import React, { useMemo } from "react";
import { useTranslation } from "react-i18next";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import {
  effectiveDueDateTime,
  getCurrentPeriod,
  isDeadlineApproaching,
} from "../services/payroll/periodEngine";

export default function HomeScreen() {
  const { t, i18n } = useTranslation();
  const period = useMemo(() => getCurrentPeriod(), []);
  const dueDateTime = effectiveDueDateTime(period);
  const deadlineSoon = isDeadlineApproaching(period);

  return (
    <SafeAreaView style={styles.safeArea} edges={["top"]}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.sectionLabel}>{t("home.currentPeriod")}</Text>
        <Text style={styles.periodRange}>
          {new Date(period.startDate).toLocaleDateString(i18n.language, { day: "numeric", month: "long" })}
          {" – "}
          {new Date(period.endDate).toLocaleDateString(i18n.language, { day: "numeric", month: "long", year: "numeric" })}
        </Text>

        {dueDateTime && (
          <View style={[styles.card, deadlineSoon && styles.cardWarning]}>
            <Text style={styles.cardLabel}>{t("home.dueBy")}</Text>
            <Text style={styles.cardValue}>
              {new Date(dueDateTime).toLocaleString(i18n.language, {
                day: "numeric",
                month: "long",
                hour: "2-digit",
                minute: "2-digit",
              })}
            </Text>
            {deadlineSoon && <Text style={styles.warningText}>{t("home.deadlineSoon")}</Text>}
          </View>
        )}

        {period.statHolidayDates.length > 0 && (
          <View style={styles.card}>
            <Text style={styles.cardLabel}>{t("home.statHoliday")}</Text>
            {period.statHolidayDates.map((date) => (
              <Text key={date} style={styles.cardValue}>
                {new Date(date).toLocaleDateString(i18n.language, { day: "numeric", month: "long" })}
              </Text>
            ))}
          </View>
        )}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: "#fff" },
  content: { padding: 20, gap: 12 },
  sectionLabel: { fontSize: 13, fontWeight: "600", color: "#888", textTransform: "uppercase" },
  periodRange: { fontSize: 22, fontWeight: "700", marginBottom: 8 },
  card: { backgroundColor: "#f5f7fb", borderRadius: 12, padding: 16, gap: 4 },
  cardWarning: { backgroundColor: "#fff4e5" },
  cardLabel: { fontSize: 13, color: "#666", fontWeight: "600" },
  cardValue: { fontSize: 16, color: "#222" },
  warningText: { fontSize: 13, color: "#b45309", fontWeight: "600", marginTop: 4 },
});
