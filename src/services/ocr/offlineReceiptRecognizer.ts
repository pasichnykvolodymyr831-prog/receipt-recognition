import TextRecognition from "@react-native-ml-kit/text-recognition";
import { parseReceiptText, type OfflineReceiptFields } from "./offlineReceiptParser";

/**
 * Runs on-device OCR (Google ML Kit on Android, Apple Vision via ML Kit on
 * iOS - no network call) and extracts the fields the app cares about with
 * the pure parser in offlineReceiptParser.ts. Requires a custom dev client
 * (native module) - does not run in Expo Go.
 */
export async function recognizeReceiptOffline(imageUri: string): Promise<OfflineReceiptFields> {
  const result = await TextRecognition.recognize(imageUri);
  return parseReceiptText(result.text);
}
