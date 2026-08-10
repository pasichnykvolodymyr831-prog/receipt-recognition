import React, { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Modal, StyleSheet, Text, TextInput, TouchableOpacity, View } from "react-native";
import { toIsoDate } from "../utils/isoDate";

interface Props {
  visible: boolean;
  ratePerKm: number;
  onCancel: () => void;
  onSave: (values: { date: string; km: number }) => void;
}

export default function KilometersModal({ visible, ratePerKm, onCancel, onSave }: Props) {
  const { t } = useTranslation();
  const [date, setDate] = useState(toIsoDate(new Date()));
  const [km, setKm] = useState("");

  useEffect(() => {
    if (visible) {
      setDate(toIsoDate(new Date()));
      setKm("");
    }
  }, [visible]);

  const kmValue = Number(km) || 0;
  const amount = Math.round(kmValue * ratePerKm * 100) / 100;
  const canSave = kmValue > 0;

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onCancel}>
      <View style={styles.backdrop}>
        <View style={styles.card}>
          <Text style={styles.title}>{t("expenses.kilometersTitle")}</Text>

          <Text style={styles.fieldLabel}>{t("expenses.kilometersDate")}</Text>
          <TextInput style={styles.input} value={date} onChangeText={setDate} placeholder="YYYY-MM-DD" />

          <Text style={styles.fieldLabel}>{t("expenses.kilometersCount")}</Text>
          <TextInput style={styles.input} value={km} onChangeText={setKm} keyboardType="decimal-pad" placeholder="0" />

          <Text style={styles.amountText}>
            {t("expenses.kilometersAmount")}: {amount.toFixed(2)}
          </Text>

          <View style={styles.actions}>
            <TouchableOpacity style={styles.secondaryButton} onPress={onCancel}>
              <Text style={styles.secondaryButtonText}>{t("common.cancel")}</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.primaryButton, !canSave && styles.primaryButtonDisabled]}
              disabled={!canSave}
              onPress={() => onSave({ date, km: kmValue })}
            >
              <Text style={styles.primaryButtonText}>{t("common.add")}</Text>
            </TouchableOpacity>
          </View>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.4)", justifyContent: "flex-end" },
  card: { backgroundColor: "#fff", borderTopLeftRadius: 18, borderTopRightRadius: 18, padding: 20 },
  title: { fontSize: 18, fontWeight: "700", marginBottom: 6 },
  fieldLabel: { fontSize: 13, color: "#555", marginTop: 10, marginBottom: 4 },
  input: {
    borderWidth: 1,
    borderColor: "#d0d0d0",
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 15,
  },
  amountText: { fontSize: 15, fontWeight: "600", marginTop: 14 },
  actions: { flexDirection: "row", gap: 8, marginTop: 20, justifyContent: "flex-end" },
  secondaryButton: { paddingVertical: 10, paddingHorizontal: 14 },
  secondaryButtonText: { color: "#666", fontSize: 14 },
  primaryButton: { backgroundColor: "#2f6fed", borderRadius: 8, paddingVertical: 10, paddingHorizontal: 20 },
  primaryButtonDisabled: { backgroundColor: "#a9c0f0" },
  primaryButtonText: { color: "#fff", fontWeight: "600", fontSize: 14 },
});
