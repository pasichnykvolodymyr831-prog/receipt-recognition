import JSZip from "jszip";
import * as FileSystem from "expo-file-system";

/**
 * Wraps a single .xlsx (zip/OOXML) file loaded into memory, and exposes
 * per-sheet XML text so callers can run the pure ooxml.ts cell-surgery
 * functions on it. Only sheets that are actually read/written are ever
 * touched; every other zip entry is carried through untouched on save.
 */
export class XlsxDocument {
  private zip: JSZip;
  private sheetPathByName: Map<string, string>;
  private dirtySheetXml: Map<string, string> = new Map();

  private constructor(zip: JSZip, sheetPathByName: Map<string, string>) {
    this.zip = zip;
    this.sheetPathByName = sheetPathByName;
  }

  static async openFromUri(fileUri: string): Promise<XlsxDocument> {
    const base64 = await FileSystem.readAsStringAsync(fileUri, {
      encoding: FileSystem.EncodingType.Base64,
    });
    return XlsxDocument.openFromBase64(base64);
  }

  static async openFromBase64(base64: string): Promise<XlsxDocument> {
    const zip = await JSZip.loadAsync(base64, { base64: true });
    const sheetPathByName = await resolveSheetPaths(zip);
    return new XlsxDocument(zip, sheetPathByName);
  }

  listSheetNames(): string[] {
    return [...this.sheetPathByName.keys()];
  }

  async getSheetXml(sheetName: string): Promise<string> {
    const cached = this.dirtySheetXml.get(sheetName);
    if (cached !== undefined) return cached;

    const path = this.requirePath(sheetName);
    const file = this.zip.file(path);
    if (!file) {
      throw new Error(`Worksheet part missing for sheet "${sheetName}" (expected ${path})`);
    }
    return file.async("text");
  }

  /** Stages new XML for a sheet in memory; call save() to persist. */
  setSheetXml(sheetName: string, xml: string): void {
    this.requirePath(sheetName);
    this.dirtySheetXml.set(sheetName, xml);
  }

  private requirePath(sheetName: string): string {
    const path = this.sheetPathByName.get(sheetName);
    if (!path) {
      throw new Error(
        `Unknown sheet "${sheetName}". Known sheets: ${[...this.sheetPathByName.keys()].join(", ")}`
      );
    }
    return path;
  }

  async saveToUri(destUri: string): Promise<void> {
    for (const [sheetName, xml] of this.dirtySheetXml) {
      const path = this.requirePath(sheetName);
      this.zip.file(path, xml);
    }
    const base64 = await this.zip.generateAsync({ type: "base64", compression: "DEFLATE" });
    await FileSystem.writeAsStringAsync(destUri, base64, {
      encoding: FileSystem.EncodingType.Base64,
    });
  }
}

/**
 * OOXML indirection: workbook.xml lists <sheet name="X" r:id="rIdY"/>, and
 * xl/_rels/workbook.xml.rels maps rIdY -> the actual worksheets/sheetN.xml
 * target. Sheet display order/name is not guaranteed to match its file
 * number, so both files must be read to build the name -> path map.
 */
async function resolveSheetPaths(zip: JSZip): Promise<Map<string, string>> {
  const workbookXmlFile = zip.file("xl/workbook.xml");
  const relsFile = zip.file("xl/_rels/workbook.xml.rels");
  if (!workbookXmlFile || !relsFile) {
    throw new Error("Not a valid .xlsx file: missing xl/workbook.xml or its rels part.");
  }
  const workbookXml = await workbookXmlFile.async("text");
  const relsXml = await relsFile.async("text");

  const attr = (tag: string, name: string): string | undefined =>
    new RegExp(`\\b${name}="([^"]*)"`).exec(tag)?.[1];

  const ridToTarget = new Map<string, string>();
  for (const tag of relsXml.match(/<Relationship\b[^>]*\/?>/g) ?? []) {
    const id = attr(tag, "Id");
    const target = attr(tag, "Target");
    if (id && target) ridToTarget.set(id, target);
  }

  const sheetPathByName = new Map<string, string>();
  for (const tag of workbookXml.match(/<sheet\b[^>]*\/?>/g) ?? []) {
    const name = attr(tag, "name");
    const rid = attr(tag, "r:id");
    if (!name || !rid) continue;
    const target = ridToTarget.get(rid);
    if (!target) continue;
    const normalized = target.startsWith("/") ? target.slice(1) : `xl/${target}`;
    sheetPathByName.set(name, normalized);
  }
  return sheetPathByName;
}
