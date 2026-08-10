import { Asset } from "expo-asset";
import { Paths } from "expo-file-system";
import { XlsxDocument } from "./xlsxDocument";

const WORKING_COPY_DIR = `${Paths.document.uri}periods/`;

/** Opens a bundled template asset (see src/assets/templates.ts) as an editable XlsxDocument. */
export async function openTemplateDocument(templateModuleId: number): Promise<XlsxDocument> {
  const asset = Asset.fromModule(templateModuleId);
  if (!asset.localUri) {
    await asset.downloadAsync();
  }
  const uri = asset.localUri ?? asset.uri;
  return XlsxDocument.openFromUri(uri);
}

/**
 * Where a period's regenerated working copy of a given document (Timesheet,
 * Expense Report, ...) is written to on-device, so it can be reopened for
 * viewing/sharing/saving (Phase 7) and cleaned up by the retention sweep.
 * Parent directories are created on demand by XlsxDocument.saveToUri.
 */
export function workingCopyUri(periodKey: string, fileBaseName: string): string {
  return `${WORKING_COPY_DIR}${periodKey}/${fileBaseName}.xlsx`;
}

export function periodsRootDir(): string {
  return WORKING_COPY_DIR;
}
