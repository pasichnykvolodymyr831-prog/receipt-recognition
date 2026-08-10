import React, { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Modal, ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from "react-native";

export interface ExpenseEntryValues {
  date: string; // ISO yyyy-mm-dd
  netBeforeGst: number;
  gst: number;
  description: string;
}

interface Props {
  visible: boolean;
  initialValues: ExpenseEntryValues;
  startInEditMode: boolean;
  notice?: string | null;
  onCancel: () => void;
  onSave: (values: ExpenseEntryValues) => void;
}

/**
 * Shows the 3 recognized fields (date / amount before tax / GST) - always
 * mapped to Date, Materials, and GST respectively; there is no category
 * choice here at all (see findMaterialsCategoryKey in
 * expenseReportSheets.ts for how the destination column is picked).
 * Description is always a required manual field.
 */
export default function ExpenseEntryModal({ visible, initialValues, startInEditMode, notice, onCancel, onSave }: Props) {
  const { t } = useTranslation();
  const [editing, setEditing] = useState(startInEditMode);
  const [date, setDate] = useState(initialValues.date);
  const [netBeforeGst, setNetBeforeGst] = useState(String(initialValues.netBeforeGst));
  const [gst, setGst] = useState(String(initialValues.gst));
  const [description, setDescription] = useState(initialValues.description);

  useEffect(() => {
    if (!visible) return;
    setEditing(startInEditMode);
    setDate(initialValues.date);
    setNetBeforeGst(String(initialValues.netBeforeGst));
    setGst(String(initialValues.gst));
    setDescription(initialValues.description);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visible]);

  const canSave = description.trim().length > 0;

  const buildValues = (): ExpenseEntryValues => ({
    date,
    netBeforeGst: Number(netBeforeGst) || 0,
    gst: Number(gst) || 0,
    description: description.trim(),
  });

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onCancel}>
      <View style={styles.backdrop}>
        <View style={styles.card}>
          <ScrollView>
            <Text style={styles.title}>{startInEditMode ? t("expenses.manualTitle") : t("expenses.confirmTitle")}</Text>
            {notice && <Text style={styles.notice}>{notice}</Text>}

            <Text style={styles.fieldLabel}>{t("expenses.entryDate")}</Text>
            {editing ? (
              <TextInput style={styles.input} value={date} onChangeText={setDate} placeholder="YYYY-MM-DD" />
            ) : (
              <Text style={styles.readValue}>{date}</Text>
            )}

            <Text style={styles.fieldLabel}>{t("expenses.entryNetBeforeGst")}</Text>
            {editing ? (
              <TextInput
                style={styles.input}
                value={netBeforeGst}
                onChangeText={setNetBeforeGst}
                keyboardType="decimal-pad"
              />
            ) : (
              <Text style={styles.readValue}>{netBeforeGst}</Text>
            )}

            <Text style={styles.fieldLabel}>{t("expenses.entryGst")}</Text>
            {editing ? (
              <TextInput style={styles.input} value={gst} onChangeText={setGst} keyboardType="decimal-pad" />
            ) : (
              <Text style={styles.readValue}>{gst}</Text>
            )}

            <Text style={styles.fieldLabel}>{t("expenses.entryDescription")}</Text>
            <TextInput
              style={styles.input}
              value={description}
              onChangeText={setDescription}
              placeholder={t("expenses.entryDescriptionPlaceholder")}
              autoFocus={!startInEditMode}
            />
            {!canSave && <Text style={styles.requiredHint}>{t("expenses.entryDescriptionRequired")}</Text>}

            <View style={styles.actions}>
              <TouchableOpacity style={styles.secondaryButton} onPress={onCancel}>
                <Text style={styles.secondaryButtonText}>{t("common.cancel")}</Text>
              </TouchableOpacity>
              {!editing && (
                <TouchableOpacity style={styles.secondaryButton} onPress={() => setEditing(true)}>
                  <Text style={styles.secondaryButtonText}>{t("common.edit")}</Text>
                </TouchableOpacity>
              )}
              <TouchableOpacity
                style={[styles.primaryButton, !canSave && styles.primaryButtonDisabled]}
                disabled={!canSave}
                onPress={() => onSave(buildValues())}
              >
                <Text style={styles.primaryButtonText}>{editing ? t("common.save") : t("common.add")}</Text>
              </TouchableOpacity>
            </View>
          </ScrollView>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.4)", justifyContent: "flex-end" },
  card: { backgroundColor: "#fff", borderTopLeftRadius: 18, borderTopRightRadius: 18, padding: 20, maxHeight: "85%" },
  title: { fontSize: 18, fontWeight: "700", marginBottom: 6 },
  notice: { fontSize: 13, color: "#b45309", backgroundColor: "#fff4e5", padding: 10, borderRadius: 8, marginBottom: 10 },
  fieldLabel: { fontSize: 13, color: "#555", marginTop: 10, marginBottom: 4 },
  readValue: { fontSize: 16, color: "#222", paddingVertical: 4 },
  input: {
    borderWidth: 1,
    borderColor: "#d0d0d0",
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 15,
  },
  requiredHint: { fontSize: 12, color: "#c0392b", marginTop: 4 },
  actions: { flexDirection: "row", gap: 8, marginTop: 20, justifyContent: "flex-end" },
  secondaryButton: { paddingVertical: 10, paddingHorizontal: 14 },
  secondaryButtonText: { color: "#666", fontSize: 14 },
  primaryButton: { backgroundColor: "#2f6fed", borderRadius: 8, paddingVertical: 10, paddingHorizontal: 20 },
  primaryButtonDisabled: { backgroundColor: "#a9c0f0" },
  primaryButtonText: { color: "#fff", fontWeight: "600", fontSize: 14 },
});
