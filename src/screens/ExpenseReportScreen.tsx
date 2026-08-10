import React, { useCallback, useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  ActivityIndicator,
  Alert,
  FlatList,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import drivingSchema from "../assets/schema/drivingDetails.json";
import ExpenseEntryModal, { type ExpenseEntryValues } from "../components/ExpenseEntryModal";
import KilometersModal from "../components/KilometersModal";
import { useAppSettingsContext } from "../context/AppSettingsContext";
import { COMPANIES, type CompanyId } from "../config/companies";
import { recognizeReceiptOffline } from "../services/ocr/offlineReceiptRecognizer";
import { captureReceiptFromCamera, pickReceiptFromLibrary } from "../services/receipts/pickReceiptImage";
import { findCompanySchema, findMileageCategoryColumn } from "../services/excel/expenseReportSheets";
import { writeExpenseReportWorkingCopy } from "../services/excel/expenseReportWriter";
import { getCurrentPeriod } from "../services/payroll/periodEngine";
import { loadPeriodData, savePeriodData } from "../services/storage/periodDataRepository";
import type { ExpenseEntry, PayPeriod } from "../types/models";
import { toIsoDate } from "../utils/isoDate";

type ModalState =
  | { kind: "none" }
  | { kind: "entry"; startInEditMode: boolean; notice: string | null; initial: ExpenseEntryValues }
  | { kind: "kilometers" };

export default function ExpenseReportScreen() {
  const { t } = useTranslation();
  const { settings, updateSettings } = useAppSettingsContext();
  const period: PayPeriod = useMemo(() => getCurrentPeriod(), []);

  const [companyId, setCompanyId] = useState<CompanyId | null>(null);
  const [entries, setEntries] = useState<ExpenseEntry[] | null>(null);
  const [modal, setModal] = useState<ModalState>({ kind: "none" });
  const [ocrLoading, setOcrLoading] = useState(false);
  const [generating, setGenerating] = useState(false);

  useEffect(() => {
    if (settings && companyId === null) setCompanyId(settings.defaultCompanyId);
  }, [settings, companyId]);

  const companySchema = companyId ? findCompanySchema(COMPANIES.find((c) => c.id === companyId)!.sheetName) : null;

  useEffect(() => {
    if (!companyId) return;
    let cancelled = false;
    loadPeriodData(period.startDate).then((data) => {
      if (cancelled) return;
      setEntries(data.expensesByCompany[companyId] ?? []);
    });
    return () => {
      cancelled = true;
    };
  }, [companyId, period]);

  const selectCompany = (id: CompanyId) => {
    setCompanyId(id);
    setEntries(null);
    updateSettings({ defaultCompanyId: id });
  };

  const persistEntries = useCallback(
    async (nextEntries: ExpenseEntry[]) => {
      if (!companyId) return;
      setEntries(nextEntries);
      const data = await loadPeriodData(period.startDate);
      await savePeriodData({
        ...data,
        periodKey: period.startDate,
        expensesByCompany: { ...data.expensesByCompany, [companyId]: nextEntries },
      });
    },
    [companyId, period]
  );

  const closeModal = () => setModal({ kind: "none" });

  const openManualEntry = (notice: string | null = null) => {
    if (!companySchema) return;
    setModal({
      kind: "entry",
      startInEditMode: true,
      notice,
      initial: {
        date: toIsoDate(new Date()),
        categoryKey: "", // category is never guessed - always a required manual choice
        netBeforeGst: 0,
        gst: 0,
        description: "",
      },
    });
  };

  const runOcr = async (imageUri: string) => {
    if (!companySchema) return;
    setOcrLoading(true);
    try {
      const result = await recognizeReceiptOffline(imageUri);
      const nothingRecognized = !result.date && result.netBeforeGst === null && result.gst === null && !result.vendorNameRaw;
      if (nothingRecognized) {
        openManualEntry(t("expenses.ocrFailedNotice"));
        return;
      }
      setModal({
        kind: "entry",
        startInEditMode: false,
        notice: null,
        initial: {
          date: result.date ?? toIsoDate(new Date()),
          categoryKey: "", // category is never guessed - always a required manual choice
          netBeforeGst: result.netBeforeGst ?? 0,
          gst: result.gst ?? 0,
          // Description stays a required manual field, but the recognized
          // vendor name is a reasonable starting point the user can edit.
          description: result.vendorNameRaw ?? "",
        },
      });
    } catch {
      openManualEntry(t("expenses.ocrFailedNotice"));
    } finally {
      setOcrLoading(false);
    }
  };

  const handleCamera = async () => {
    const uri = await captureReceiptFromCamera();
    if (uri) await runOcr(uri);
  };

  const handleGallery = async () => {
    const uri = await pickReceiptFromLibrary();
    if (uri) await runOcr(uri);
  };

  const saveEntry = (values: ExpenseEntryValues) => {
    if (!entries || !companyId) return;
    const entry: ExpenseEntry = {
      kind: "receipt",
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      companyId,
      date: values.date,
      description: values.description,
      categoryKey: values.categoryKey,
      netBeforeGst: values.netBeforeGst,
      gst: values.gst,
      createdAt: new Date().toISOString(),
    };
    persistEntries([...entries, entry]);
    closeModal();
  };

  const saveKilometers = (values: { date: string; km: number }) => {
    if (!entries || !companyId || !companySchema) return;
    const mileageColumn = findMileageCategoryColumn(companySchema);
    if (!mileageColumn) {
      Alert.alert(t("expenses.title"), t("expenses.kilometersNoColumn"));
      return;
    }
    const rate = drivingSchema.kmPerDollarRate;
    const entry: ExpenseEntry = {
      kind: "kilometers",
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      companyId,
      date: values.date,
      description: `Kilometers (${values.km})`,
      km: values.km,
      ratePerKm: rate,
      amount: Math.round(values.km * rate * 100) / 100,
      createdAt: new Date().toISOString(),
    };
    persistEntries([...entries, entry]);
    closeModal();
  };

  const deleteEntry = (id: string) => {
    if (!entries) return;
    Alert.alert(t("expenses.title"), t("expenses.deleteEntryConfirm"), [
      { text: t("common.cancel"), style: "cancel" },
      { text: t("common.delete"), style: "destructive", onPress: () => persistEntries(entries.filter((e) => e.id !== id)) },
    ]);
  };

  const generateFile = async () => {
    if (!settings) return;
    setGenerating(true);
    try {
      const data = await loadPeriodData(period.startDate);
      const uri = await writeExpenseReportWorkingCopy({
        employee: settings.employee,
        period,
        expensesByCompany: data.expensesByCompany,
        drivingDetails: data.drivingDetails,
      });
      Alert.alert(t("expenses.title"), uri);
    } catch (err) {
      Alert.alert(t("expenses.title"), err instanceof Error ? err.message : String(err));
    } finally {
      setGenerating(false);
    }
  };

  if (!settings || !companyId || !companySchema) {
    return (
      <SafeAreaView style={styles.safeArea}>
        <ActivityIndicator style={styles.loadingSpinner} />
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.safeArea} edges={["top"]}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.companyRow} contentContainerStyle={styles.companyRowContent}>
        {COMPANIES.map((c) => (
          <TouchableOpacity
            key={c.id}
            style={[styles.companyChip, c.id === companyId && styles.companyChipActive]}
            onPress={() => selectCompany(c.id)}
          >
            <Text style={[styles.companyChipText, c.id === companyId && styles.companyChipTextActive]}>{c.displayName}</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>

      <FlatList
        style={styles.list}
        data={entries ?? []}
        keyExtractor={(e) => e.id}
        ListEmptyComponent={<Text style={styles.emptyText}>{t("expenses.noEntries")}</Text>}
        renderItem={({ item }) => (
          <TouchableOpacity style={styles.entryRow} onLongPress={() => deleteEntry(item.id)}>
            <View style={styles.entryTextBlock}>
              <Text style={styles.entryDate}>{item.date}</Text>
              <Text style={styles.entryDescription}>{item.description}</Text>
            </View>
            <Text style={styles.entryAmount}>
              {(item.kind === "receipt" ? item.netBeforeGst + item.gst : item.amount).toFixed(2)}
            </Text>
          </TouchableOpacity>
        )}
      />

      <View style={styles.actionsRow}>
        <ActionButton icon="📷" label={t("expenses.addFromCamera")} onPress={handleCamera} disabled={ocrLoading} />
        <ActionButton icon="🖼" label={t("expenses.addFromGallery")} onPress={handleGallery} disabled={ocrLoading} />
        <ActionButton icon="🚗" label={t("expenses.addKilometers")} onPress={() => setModal({ kind: "kilometers" })} />
        <ActionButton icon="✏️" label={t("expenses.addManually")} onPress={() => openManualEntry()} />
      </View>

      {ocrLoading && (
        <View style={styles.ocrOverlay}>
          <ActivityIndicator color="#fff" />
          <Text style={styles.ocrOverlayText}>{t("expenses.recognizing")}</Text>
        </View>
      )}

      <TouchableOpacity style={styles.generateButton} onPress={generateFile} disabled={generating}>
        {generating ? <ActivityIndicator color="#fff" /> : <Text style={styles.generateButtonText}>{t("expenses.generateFile")}</Text>}
      </TouchableOpacity>

      {modal.kind === "entry" && (
        <ExpenseEntryModal
          visible
          companySchema={companySchema}
          initialValues={modal.initial}
          startInEditMode={modal.startInEditMode}
          notice={modal.notice}
          onCancel={closeModal}
          onSave={saveEntry}
        />
      )}
      {modal.kind === "kilometers" && (
        <KilometersModal visible ratePerKm={drivingSchema.kmPerDollarRate} onCancel={closeModal} onSave={saveKilometers} />
      )}
    </SafeAreaView>
  );
}

function ActionButton({ icon, label, onPress, disabled }: { icon: string; label: string; onPress: () => void; disabled?: boolean }) {
  return (
    <TouchableOpacity style={styles.actionButton} onPress={onPress} disabled={disabled}>
      <Text style={styles.actionIcon}>{icon}</Text>
      <Text style={styles.actionLabel} numberOfLines={2}>
        {label}
      </Text>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: "#fff" },
  loadingSpinner: { marginTop: 40 },
  companyRow: { flexGrow: 0, borderBottomWidth: 1, borderBottomColor: "#e5e5e5" },
  companyRowContent: { paddingHorizontal: 16, paddingVertical: 10, gap: 8 },
  companyChip: {
    paddingVertical: 8,
    paddingHorizontal: 14,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: "#d0d0d0",
    backgroundColor: "#f7f7f7",
    marginRight: 8,
  },
  companyChipActive: { backgroundColor: "#2f6fed", borderColor: "#2f6fed" },
  companyChipText: { fontSize: 13, color: "#333" },
  companyChipTextActive: { color: "#fff", fontWeight: "600" },
  list: { flex: 1 },
  emptyText: { textAlign: "center", color: "#999", marginTop: 30, fontSize: 14 },
  entryRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingVertical: 14,
    borderBottomWidth: 1,
    borderBottomColor: "#f0f0f0",
  },
  entryTextBlock: { flex: 1, marginRight: 10 },
  entryDate: { fontSize: 12, color: "#888" },
  entryDescription: { fontSize: 15, color: "#222", marginTop: 2 },
  entryAmount: { fontSize: 15, fontWeight: "600" },
  actionsRow: { flexDirection: "row", flexWrap: "wrap", padding: 12, gap: 10, justifyContent: "center" },
  actionButton: {
    width: "22%",
    alignItems: "center",
    paddingVertical: 10,
    borderRadius: 10,
    backgroundColor: "#f5f7fb",
  },
  actionIcon: { fontSize: 22 },
  actionLabel: { fontSize: 11, color: "#444", textAlign: "center", marginTop: 4 },
  ocrOverlay: {
    position: "absolute",
    left: 0,
    right: 0,
    top: "45%",
    alignItems: "center",
    gap: 8,
    backgroundColor: "rgba(0,0,0,0.6)",
    marginHorizontal: 40,
    padding: 16,
    borderRadius: 12,
  },
  ocrOverlayText: { color: "#fff", fontSize: 13 },
  generateButton: {
    backgroundColor: "#2f6fed",
    borderRadius: 10,
    paddingVertical: 12,
    alignItems: "center",
    marginHorizontal: 16,
    marginBottom: 16,
  },
  generateButtonText: { color: "#fff", fontWeight: "600", fontSize: 15 },
});
