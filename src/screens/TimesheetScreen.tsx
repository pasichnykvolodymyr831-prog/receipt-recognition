import React, { useCallback, useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  ActivityIndicator,
  Alert,
  FlatList,
  Modal,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useAppSettingsContext } from "../context/AppSettingsContext";
import { writeTimesheetWorkingCopy } from "../services/excel/timesheetWriter";
import {
  generateDefaultTimesheetRows,
  getCurrentPeriod,
  isStatHoliday,
  isWeekend,
} from "../services/payroll/periodEngine";
import { loadPeriodData, savePeriodData } from "../services/storage/periodDataRepository";
import type { PayPeriod, TimesheetRowEntry } from "../types/models";
import { fromIsoDate } from "../utils/isoDate";

function formatHHMM(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

function parseHHMM(text: string): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(text.trim());
  if (!m) return null;
  const hours = Number(m[1]);
  const minutes = Number(m[2]);
  if (hours > 23 || minutes > 59) return null;
  return hours * 60 + minutes;
}

function computeHours(row: TimesheetRowEntry): number | null {
  if (row.startMinutes === null || row.finishMinutes === null) return null;
  const lunch = row.lunchBreakMinutes ?? 0;
  const coffee = row.coffeeBreakMinutes ?? 0;
  return Math.max(0, (row.finishMinutes - row.startMinutes - lunch - coffee) / 60);
}

function formatDateShort(iso: string, locale: string): string {
  return fromIsoDate(iso).toLocaleDateString(locale, { weekday: "short", day: "2-digit", month: "short" });
}

export default function TimesheetScreen() {
  const { t, i18n } = useTranslation();
  const { settings } = useAppSettingsContext();
  const period: PayPeriod = useMemo(() => getCurrentPeriod(), []);

  const [rows, setRows] = useState<TimesheetRowEntry[] | null>(null);
  const [editingDate, setEditingDate] = useState<string | null>(null);
  const [editStart, setEditStart] = useState("");
  const [editFinish, setEditFinish] = useState("");
  const [editLunch, setEditLunch] = useState("");
  const [editCoffee, setEditCoffee] = useState("");
  const [generating, setGenerating] = useState(false);

  useEffect(() => {
    let cancelled = false;
    loadPeriodData(period.startDate).then((data) => {
      if (cancelled) return;
      setRows(data.timesheet.length > 0 ? data.timesheet : generateDefaultTimesheetRows(period));
    });
    return () => {
      cancelled = true;
    };
  }, [period]);

  const persist = useCallback(
    async (nextRows: TimesheetRowEntry[]) => {
      setRows(nextRows);
      const data = await loadPeriodData(period.startDate);
      await savePeriodData({ ...data, periodKey: period.startDate, timesheet: nextRows });
    },
    [period]
  );

  const openEditor = (row: TimesheetRowEntry) => {
    setEditingDate(row.date);
    setEditStart(row.startMinutes !== null ? formatHHMM(row.startMinutes) : "");
    setEditFinish(row.finishMinutes !== null ? formatHHMM(row.finishMinutes) : "");
    setEditLunch(row.lunchBreakMinutes !== null ? String(row.lunchBreakMinutes) : "");
    setEditCoffee(row.coffeeBreakMinutes !== null ? String(row.coffeeBreakMinutes) : "");
  };

  const saveEditor = () => {
    if (!rows || editingDate === null) return;
    const start = editStart.trim() ? parseHHMM(editStart) : null;
    const finish = editFinish.trim() ? parseHHMM(editFinish) : null;
    if (editStart.trim() && start === null) {
      Alert.alert(t("timesheet.startTime"), "HH:MM");
      return;
    }
    if (editFinish.trim() && finish === null) {
      Alert.alert(t("timesheet.finishTime"), "HH:MM");
      return;
    }
    const lunch = editLunch.trim() ? Number(editLunch) : null;
    const coffee = editCoffee.trim() ? Number(editCoffee) : null;

    const next = rows.map((r) =>
      r.date === editingDate
        ? { ...r, startMinutes: start, finishMinutes: finish, lunchBreakMinutes: lunch, coffeeBreakMinutes: coffee }
        : r
    );
    persist(next);
    setEditingDate(null);
  };

  const clearEditor = () => {
    if (!rows || editingDate === null) return;
    const next = rows.map((r) =>
      r.date === editingDate
        ? { ...r, startMinutes: null, finishMinutes: null, lunchBreakMinutes: null, coffeeBreakMinutes: null }
        : r
    );
    persist(next);
    setEditingDate(null);
  };

  const generateFile = async () => {
    if (!rows || !settings) return;
    setGenerating(true);
    try {
      const uri = await writeTimesheetWorkingCopy({ employee: settings.employee, period, rows });
      Alert.alert(t("timesheet.title"), uri);
    } catch (err) {
      Alert.alert(t("timesheet.title"), err instanceof Error ? err.message : String(err));
    } finally {
      setGenerating(false);
    }
  };

  const totalHours = useMemo(() => (rows ?? []).reduce((sum, r) => sum + (computeHours(r) ?? 0), 0), [rows]);

  if (!rows || !settings) {
    return (
      <SafeAreaView style={styles.safeArea}>
        <ActivityIndicator style={styles.loadingSpinner} />
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.safeArea} edges={["top"]}>
      <View style={styles.header}>
        <Text style={styles.title}>{t("timesheet.title")}</Text>
        {settings.employee.fullName ? (
          <Text style={styles.subtitle}>
            {settings.employee.fullName}
            {settings.employee.phone ? ` · ${settings.employee.phone}` : ""}
          </Text>
        ) : (
          <Text style={styles.warning}>{t("timesheet.fillEmployeeInfoPrompt")}</Text>
        )}
        <Text style={styles.subtitle}>
          {period.startDate} – {period.endDate}
        </Text>
      </View>

      <View style={styles.tableHeaderRow}>
        <Text style={[styles.tableHeaderCell, styles.colDate]}>{t("timesheet.columnDate")}</Text>
        <Text style={[styles.tableHeaderCell, styles.colTime]}>{t("timesheet.columnStart")}</Text>
        <Text style={[styles.tableHeaderCell, styles.colTime]}>{t("timesheet.columnFinish")}</Text>
        <Text style={[styles.tableHeaderCell, styles.colHours]}>{t("timesheet.columnHours")}</Text>
      </View>

      <FlatList
        data={rows}
        keyExtractor={(r) => r.date}
        renderItem={({ item }) => {
          const weekend = isWeekend(item.date);
          const stat = isStatHoliday(item.date, period);
          const blank = item.startMinutes === null;
          const hours = computeHours(item);
          return (
            <TouchableOpacity
              style={[styles.row, (weekend || stat) && styles.rowMuted]}
              onPress={() => openEditor(item)}
            >
              <Text style={[styles.cell, styles.colDate]}>{formatDateShort(item.date, i18n.language)}</Text>
              {blank ? (
                <Text style={[styles.cell, styles.colBlankLabel]}>
                  {stat ? t("timesheet.statHoliday") : weekend ? t("timesheet.weekend") : ""}
                </Text>
              ) : (
                <>
                  <Text style={[styles.cell, styles.colTime]}>{formatHHMM(item.startMinutes as number)}</Text>
                  <Text style={[styles.cell, styles.colTime]}>{formatHHMM(item.finishMinutes as number)}</Text>
                  <Text style={[styles.cell, styles.colHours]}>{hours?.toFixed(2)}</Text>
                </>
              )}
            </TouchableOpacity>
          );
        }}
      />

      <View style={styles.footer}>
        <Text style={styles.totalLabel}>
          {t("timesheet.totalHours")}: {totalHours.toFixed(2)} {t("common.hours")}
        </Text>
        <TouchableOpacity style={styles.generateButton} onPress={generateFile} disabled={generating}>
          {generating ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.generateButtonText}>{t("timesheet.generatingFile")}</Text>
          )}
        </TouchableOpacity>
      </View>

      <Modal visible={editingDate !== null} transparent animationType="fade" onRequestClose={() => setEditingDate(null)}>
        <View style={styles.modalBackdrop}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>
              {editingDate ? formatDateShort(editingDate, i18n.language) : ""}
            </Text>

            <Text style={styles.fieldLabel}>{t("timesheet.startTime")}</Text>
            <TextInput style={styles.input} value={editStart} onChangeText={setEditStart} placeholder="08:00" />

            <Text style={styles.fieldLabel}>{t("timesheet.finishTime")}</Text>
            <TextInput style={styles.input} value={editFinish} onChangeText={setEditFinish} placeholder="16:30" />

            <Text style={styles.fieldLabel}>{t("timesheet.lunchBreakMinutes")}</Text>
            <TextInput
              style={styles.input}
              value={editLunch}
              onChangeText={setEditLunch}
              placeholder="30"
              keyboardType="number-pad"
            />

            <Text style={styles.fieldLabel}>{t("timesheet.coffeeBreakMinutes")}</Text>
            <TextInput
              style={styles.input}
              value={editCoffee}
              onChangeText={setEditCoffee}
              placeholder="0"
              keyboardType="number-pad"
            />

            <View style={styles.modalActions}>
              <TouchableOpacity style={styles.modalSecondaryButton} onPress={clearEditor}>
                <Text style={styles.modalSecondaryButtonText}>{t("timesheet.clearRow")}</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.modalSecondaryButton} onPress={() => setEditingDate(null)}>
                <Text style={styles.modalSecondaryButtonText}>{t("common.cancel")}</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.modalPrimaryButton} onPress={saveEditor}>
                <Text style={styles.modalPrimaryButtonText}>{t("common.save")}</Text>
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: "#fff" },
  loadingSpinner: { marginTop: 40 },
  header: { paddingHorizontal: 20, paddingTop: 12, paddingBottom: 8 },
  title: { fontSize: 20, fontWeight: "700" },
  subtitle: { fontSize: 13, color: "#666", marginTop: 2 },
  warning: { fontSize: 13, color: "#b45309", marginTop: 2 },
  tableHeaderRow: {
    flexDirection: "row",
    paddingHorizontal: 20,
    paddingVertical: 6,
    borderBottomWidth: 1,
    borderBottomColor: "#e5e5e5",
  },
  tableHeaderCell: { fontSize: 12, fontWeight: "600", color: "#888" },
  row: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#f0f0f0",
  },
  rowMuted: { backgroundColor: "#fafafa" },
  cell: { fontSize: 14, color: "#222" },
  colBlankLabel: { flex: 1, color: "#999", fontStyle: "italic" },
  colDate: { width: 100 },
  colTime: { width: 70 },
  colHours: { width: 60, textAlign: "right" },
  footer: { padding: 16, borderTopWidth: 1, borderTopColor: "#e5e5e5", gap: 10 },
  totalLabel: { fontSize: 15, fontWeight: "600", textAlign: "center" },
  generateButton: { backgroundColor: "#2f6fed", borderRadius: 10, paddingVertical: 12, alignItems: "center" },
  generateButtonText: { color: "#fff", fontWeight: "600", fontSize: 15 },
  modalBackdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.4)", justifyContent: "center", padding: 24 },
  modalCard: { backgroundColor: "#fff", borderRadius: 14, padding: 20, gap: 4 },
  modalTitle: { fontSize: 17, fontWeight: "700", marginBottom: 8 },
  fieldLabel: { fontSize: 13, color: "#555", marginTop: 8, marginBottom: 4 },
  input: {
    borderWidth: 1,
    borderColor: "#d0d0d0",
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 15,
  },
  modalActions: { flexDirection: "row", gap: 8, marginTop: 16, justifyContent: "flex-end" },
  modalSecondaryButton: { paddingVertical: 10, paddingHorizontal: 14 },
  modalSecondaryButtonText: { color: "#666", fontSize: 14 },
  modalPrimaryButton: { backgroundColor: "#2f6fed", borderRadius: 8, paddingVertical: 10, paddingHorizontal: 18 },
  modalPrimaryButtonText: { color: "#fff", fontWeight: "600", fontSize: 14 },
});
