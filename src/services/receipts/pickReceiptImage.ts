import * as ImagePicker from "expo-image-picker";

/** null return means the user cancelled or denied permission - not an error. */
export async function captureReceiptFromCamera(): Promise<string | null> {
  const permission = await ImagePicker.requestCameraPermissionsAsync();
  if (!permission.granted) return null;

  const result = await ImagePicker.launchCameraAsync({ quality: 0.8, mediaTypes: ["images"] });
  return result.canceled ? null : (result.assets[0]?.uri ?? null);
}

export async function pickReceiptFromLibrary(): Promise<string | null> {
  const permission = await ImagePicker.requestMediaLibraryPermissionsAsync();
  if (!permission.granted) return null;

  const result = await ImagePicker.launchImageLibraryAsync({ quality: 0.8, mediaTypes: ["images"] });
  return result.canceled ? null : (result.assets[0]?.uri ?? null);
}
