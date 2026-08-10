const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const MODEL = "claude-sonnet-5";

export type OcrFailureReason = "network" | "http_error" | "invalid_response";

export class OcrError extends Error {
  reason: OcrFailureReason;
  constructor(reason: OcrFailureReason, message: string) {
    super(message);
    this.reason = reason;
  }
}

export interface ReceiptOcrResult {
  date: string | null; // best-effort ISO yyyy-mm-dd
  amount: number | null;
  netBeforeGst: number | null;
  gst: number | null;
  suggestedCategoryLabel: string | null;
  vendorNameRaw: string | null;
}

function buildPrompt(categoryLabels: string[]): string {
  return [
    "You are reading a photo of a paper purchase receipt for an employee expense report.",
    "Respond with ONLY a single strict JSON object - no markdown fences, no explanation, no extra text.",
    "Use exactly these fields:",
    "{",
    '  "date": "YYYY-MM-DD" or null if unreadable,',
    '  "amount": number (total amount on the receipt) or null,',
    '  "net_before_gst": number (subtotal before GST/tax) or null,',
    '  "gst": number (GST/tax amount as printed) or null,',
    `  "suggested_category": one of [${categoryLabels.map((l) => JSON.stringify(l)).join(", ")}] that best matches this purchase, or null,`,
    '  "vendor_name_raw": string (store/vendor name as printed) or null',
    "}",
    "If a value cannot be read confidently from the image, use null for it rather than guessing.",
  ].join("\n");
}

function extractJsonObject(text: string): Record<string, unknown> | null {
  const fenced = /```(?:json)?\s*([\s\S]*?)```/.exec(text);
  const candidate = (fenced ? fenced[1] : text).trim();
  try {
    return JSON.parse(candidate);
  } catch {
    const start = candidate.indexOf("{");
    const end = candidate.lastIndexOf("}");
    if (start === -1 || end === -1 || end <= start) return null;
    try {
      return JSON.parse(candidate.slice(start, end + 1));
    } catch {
      return null;
    }
  }
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export async function recognizeReceipt(params: {
  apiKey: string;
  imageBase64: string;
  mediaType: string;
  categoryLabels: string[];
}): Promise<ReceiptOcrResult> {
  const { apiKey, imageBase64, mediaType, categoryLabels } = params;

  let response: Response;
  try {
    response = await fetch(ANTHROPIC_API_URL, {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1024,
        messages: [
          {
            role: "user",
            content: [
              { type: "image", source: { type: "base64", media_type: mediaType, data: imageBase64 } },
              { type: "text", text: buildPrompt(categoryLabels) },
            ],
          },
        ],
      }),
    });
  } catch {
    throw new OcrError("network", "Network request to Anthropic API failed");
  }

  if (!response.ok) {
    throw new OcrError("http_error", `Anthropic API returned HTTP ${response.status}`);
  }

  const json = await response.json().catch(() => null);
  const text = json?.content?.[0]?.text;
  if (typeof text !== "string") {
    throw new OcrError("invalid_response", "Anthropic response had no text content");
  }

  const parsed = extractJsonObject(text);
  if (!parsed) {
    throw new OcrError("invalid_response", "Could not parse JSON out of the model's response");
  }

  return {
    date: stringOrNull(parsed.date),
    amount: numberOrNull(parsed.amount),
    netBeforeGst: numberOrNull(parsed.net_before_gst),
    gst: numberOrNull(parsed.gst),
    suggestedCategoryLabel: stringOrNull(parsed.suggested_category),
    vendorNameRaw: stringOrNull(parsed.vendor_name_raw),
  };
}
