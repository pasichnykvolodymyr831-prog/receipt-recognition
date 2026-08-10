import * as ImagePicker from "expo-image-picker";

export interface PickedReceiptImage {
  base64: string;
  mediaType: string; // "image/jpeg"
}

/** null return means the user cancelled or denied permission - not an error. */
export async function captureReceiptFromCamera(): Promise<PickedReceiptImage | null> {
  const permission = await ImagePicker.requestCameraPermissionsAsync();
  if (!permission.granted) return null;

  const result = await ImagePicker.launchCameraAsync({ base64: true, quality: 0.6, mediaTypes: ["images"] });
  const asset = result.canceled ? null : result.assets[0];
  if (!asset?.base64) return null;
  return { base64: asset.base64, mediaType: "image/jpeg" };
}

export async function pickReceiptFromLibrary(): Promise<PickedReceiptImage | null> {
  const permission = await ImagePicker.requestMediaLibraryPermissionsAsync();
  if (!permission.granted) return null;

  const result = await ImagePicker.launchImageLibraryAsync({ base64: true, quality: 0.6, mediaTypes: ["images"] });
  const asset = result.canceled ? null : result.assets[0];
  if (!asset?.base64) return null;
  return { base64: asset.base64, mediaType: "image/jpeg" };
}
