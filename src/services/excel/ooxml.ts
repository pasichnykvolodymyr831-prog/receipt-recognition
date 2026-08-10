/**
 * Low-level, dependency-free OOXML cell surgery.
 *
 * Every function here operates on the raw XML text of a single
 * xl/worksheets/sheetN.xml and touches only the <c r="..."> node(s) it is
 * told to touch, by string search-and-replace - never a full parse/reserialize
 * of the sheet. This is what lets us guarantee the rest of the sheet
 * (merges, styles, other cells, other sheets) stays byte-for-byte identical
 * to the template. It has no React Native / Node dependency so it can run
 * both on-device and in the plain-Node verification script.
 */

export interface CellMatch {
  /** Full matched <c ...>...</c> or <c .../> tag */
  full: string;
  /** Everything between r="REF" and the end of the opening tag attributes, e.g. ' s="18" t="s"' */
  attrs: string;
  /** Style id, if present */
  styleId: string | undefined;
  /** True if the tag was self-closing (empty cell) */
  selfClosing: boolean;
  start: number;
  end: number;
}

function escapeRefForRegex(ref: string): string {
  return ref.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function escapeXmlText(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Finds the <c r="REF" ...>...</c> node for a given cell reference (e.g. "G11"). */
export function findCell(sheetXml: string, ref: string): CellMatch | null {
  const escaped = escapeRefForRegex(ref);
  const re = new RegExp(`<c r="${escaped}"([^>]*?)(/>|>([\\s\\S]*?)</c>)`);
  const m = re.exec(sheetXml);
  if (!m) return null;
  const attrs = m[1] ?? "";
  const selfClosing = m[2].startsWith("/>");
  const styleMatch = /\bs="([^"]*)"/.exec(attrs);
  return {
    full: m[0],
    attrs,
    styleId: styleMatch ? styleMatch[1] : undefined,
    selfClosing,
    start: m.index,
    end: m.index + m[0].length,
  };
}

export function cellExists(sheetXml: string, ref: string): boolean {
  return findCell(sheetXml, ref) !== null;
}

export function getCellStyleId(sheetXml: string, ref: string): string | undefined {
  return findCell(sheetXml, ref)?.styleId;
}

function replaceCell(sheetXml: string, ref: string, newTag: string): string {
  const cell = findCell(sheetXml, ref);
  if (!cell) {
    throw new Error(
      `Cell ${ref} does not exist in this sheet - the app only writes into cells the template already defines.`
    );
  }
  return sheetXml.slice(0, cell.start) + newTag + sheetXml.slice(cell.end);
}

function styleAttr(styleId: string | undefined): string {
  return styleId !== undefined ? ` s="${styleId}"` : "";
}

export interface WriteOptions {
  /** Override the style index instead of keeping the template's original one. */
  styleId?: string;
}

/** Writes a plain number (or Excel date/time serial, which is also a number) into a cell. */
export function setCellNumber(sheetXml: string, ref: string, value: number, opts: WriteOptions = {}): string {
  const existing = findCell(sheetXml, ref);
  const styleId = opts.styleId ?? existing?.styleId;
  const tag = `<c r="${ref}"${styleAttr(styleId)}><v>${value}</v></c>`;
  return replaceCell(sheetXml, ref, tag);
}

/** Writes a text value as an inline string - avoids touching sharedStrings.xml entirely. */
export function setCellInlineString(sheetXml: string, ref: string, text: string, opts: WriteOptions = {}): string {
  const existing = findCell(sheetXml, ref);
  const styleId = opts.styleId ?? existing?.styleId;
  const tag = `<c r="${ref}"${styleAttr(styleId)} t="inlineStr"><is><t xml:space="preserve">${escapeXmlText(
    text
  )}</t></is></c>`;
  return replaceCell(sheetXml, ref, tag);
}

/**
 * Writes a formula. `formula` must NOT include the leading "=".
 *
 * `cachedValue`, when given, is written as the cell's cached <v> so the
 * file shows a sensible number immediately in any viewer that doesn't
 * recalculate on open (some quick-look/file-manager previewers, and
 * notably SheetJS's own reader - it does not expose a formula cell at
 * all if it has no cached value). Excel/Google Sheets will still
 * recalculate this formula normally on open (default calc mode); the
 * cached value is only ever a starting display value, never a substitute
 * for the formula.
 */
export function setCellFormula(
  sheetXml: string,
  ref: string,
  formula: string,
  cachedValue?: number,
  opts: WriteOptions = {}
): string {
  const existing = findCell(sheetXml, ref);
  const styleId = opts.styleId ?? existing?.styleId;
  const cleanFormula = formula.startsWith("=") ? formula.slice(1) : formula;
  const cachedTag = cachedValue !== undefined ? `<v>${cachedValue}</v>` : "";
  const tag = `<c r="${ref}"${styleAttr(styleId)}><f>${escapeXmlText(cleanFormula)}</f>${cachedTag}</c>`;
  return replaceCell(sheetXml, ref, tag);
}

/** Resets a cell to empty while keeping its style - used for period-reset (e.g. Driving Details). */
export function clearCell(sheetXml: string, ref: string, opts: WriteOptions = {}): string {
  const existing = findCell(sheetXml, ref);
  const styleId = opts.styleId ?? existing?.styleId;
  const tag = `<c r="${ref}"${styleAttr(styleId)}/>`;
  return replaceCell(sheetXml, ref, tag);
}

export function columnLetterFromIndex(index0: number): string {
  let n = index0 + 1;
  let s = "";
  while (n > 0) {
    const rem = (n - 1) % 26;
    s = String.fromCharCode(65 + rem) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

export function cellRef(column: string, row: number): string {
  return `${column}${row}`;
}
