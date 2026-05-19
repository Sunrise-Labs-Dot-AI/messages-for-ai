// Prompt-injection mitigation: wrap WhatsApp message bodies (which can
// contain attacker-controlled text from any sender who has — or guesses —
// your phone number) in delimiters that modern LLMs are trained to treat
// as DATA rather than instructions.
//
// The defense pattern is "spotlighting" / data-tagging. It's a hint, not
// an enforced boundary. The daemon ALSO sanitizes bodies at write time
// (tag-escape + 2 KB truncation in src/storage/messages.ts) so the
// stored body is safe to return to MCP directly. This file is the
// outermost wrapping layer applied at the MCP response boundary.
//
// Applied at the MCP tool response boundary, NOT in the storage layer:
// the menu bar app reads ~/.whatsapp-mcp/drafts/*.json directly and
// would render the delimiter literals as text in bubbles otherwise.

const OPEN = "<untrusted_content>";
const CLOSE = "</untrusted_content>";

export function wrapUntrusted(body: string | null): string | null {
  if (body == null) return null;
  return `${OPEN}\n${body}\n${CLOSE}`;
}

export function wrapBodyInPlace<T extends { body: string | null }>(item: T): T {
  return { ...item, body: wrapUntrusted(item.body) };
}

// Tag-close sequences that should be escaped at WRITE time (in messages.ts)
// so they can never close out the outer <untrusted_content> wrapper or
// trigger MCP tool-call directives in the model. The runtime sanitizer in
// messages.ts uses this list.
export const SANITIZE_TOKENS: ReadonlyArray<RegExp> = [
  /<\/untrusted_content>/gi,
  /<\/tool_use>/gi,
  /<\/function_calls>/gi,
  /<\/tool_result>/gi,
];

export function sanitizeIncomingBody(body: string): string {
  let out = body;
  for (const re of SANITIZE_TOKENS) {
    out = out.replace(re, (m) => `&lt;${m.slice(1)}`);
  }
  return out;
}

// Default truncation cap for tool output. Bodies longer than this are
// truncated; full body retrievable via get_whatsapp_message_full.
export const DEFAULT_BODY_CAP_BYTES = 2048;

export function truncateToBytes(body: string, cap: number = DEFAULT_BODY_CAP_BYTES): { body: string; truncated: boolean } {
  const buf = Buffer.from(body, "utf8");
  if (buf.byteLength <= cap) return { body, truncated: false };
  // Binary-search to a valid UTF-8 boundary so we don't slice mid-codepoint.
  let lo = 0;
  let hi = cap;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    const slice = buf.subarray(0, mid);
    // A truncation is valid if the result is well-formed UTF-8.
    const decoded = new TextDecoder("utf-8", { fatal: false }).decode(slice);
    // Strip the U+FFFD replacement character that fatal:false emits for the
    // dangling partial sequence at the tail.
    if (!decoded.endsWith("�")) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return { body: buf.subarray(0, lo).toString("utf8"), truncated: true };
}
