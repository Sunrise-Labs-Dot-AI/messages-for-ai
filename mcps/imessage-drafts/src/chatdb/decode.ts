// Minimal NSKeyedArchiver typedstream decoder for `message.attributedBody`.
//
// On macOS Big Sur+ the `message.text` column is sometimes NULL and the real
// body lives in `attributedBody`, an NSAttributedString serialized via Apple's
// typedstream format. The full format is complex (class hierarchies, object
// graph, multiple runs), but the body string is recoverable with a small,
// well-known heuristic: locate the "NSString" class marker, then read the
// next length-prefixed UTF-8 payload. This handles the overwhelmingly common
// case of a single-run plaintext body. Messages with embedded objects (file
// transfers, tapbacks) will fall back to whatever non-null `text` column
// content the caller can find — or to `null` if neither is available.

const NSSTRING_MARKER = Buffer.from("NSString", "utf8");

export function decodeAttributedBody(blob: Buffer | Uint8Array | null): string | null {
  if (!blob || blob.length === 0) return null;
  const buf = Buffer.isBuffer(blob) ? blob : Buffer.from(blob);

  const markerIdx = buf.indexOf(NSSTRING_MARKER);
  if (markerIdx < 0) return null;

  // After the class name, the encoder writes class metadata bytes, then a
  // length-prefixed UTF-8 string. Scan forward for the first plausible length
  // marker (a byte 0x01 followed by 0x2B `+`, the typedstream signature for
  // "NSString instance, UTF-8, length follows").
  let cursor = markerIdx + NSSTRING_MARKER.length;
  while (cursor < buf.length - 1) {
    if (buf[cursor] === 0x01 && buf[cursor + 1] === 0x2b) {
      cursor += 2;
      break;
    }
    cursor++;
  }
  if (cursor >= buf.length) return null;

  // Variable-length length field:
  //   < 0x80         → single byte
  //   0x81 NN        → one-byte length follows
  //   0x82 NN NN     → big-endian uint16
  //   0x83 NN NN NN NN → big-endian uint32
  let len: number;
  const first = buf[cursor++];
  if (first === undefined) return null;
  if (first < 0x80) {
    len = first;
  } else if (first === 0x81) {
    const v = buf[cursor++];
    if (v === undefined) return null;
    len = v;
  } else if (first === 0x82) {
    if (cursor + 2 > buf.length) return null;
    len = buf.readUInt16BE(cursor);
    cursor += 2;
  } else if (first === 0x83) {
    if (cursor + 4 > buf.length) return null;
    len = buf.readUInt32BE(cursor);
    cursor += 4;
  } else {
    return null;
  }

  if (len <= 0 || cursor + len > buf.length) return null;
  const decoded = buf.toString("utf8", cursor, cursor + len);
  return decoded.length > 0 ? decoded : null;
}

export function bestMessageBody(textCol: string | null, attributedBody: Uint8Array | null): string | null {
  if (textCol && textCol.length > 0) return textCol;
  return decodeAttributedBody(attributedBody);
}

const MAX_BODY_BYTES = 8 * 1024;

export function truncateBody(body: string | null): string | null {
  if (body == null) return null;
  const bytes = Buffer.byteLength(body, "utf8");
  if (bytes <= MAX_BODY_BYTES) return body;
  // Truncate by characters until under the byte budget. Keeps UTF-8 valid.
  let lo = 0;
  let hi = body.length;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (Buffer.byteLength(body.slice(0, mid), "utf8") <= MAX_BODY_BYTES - 64) lo = mid;
    else hi = mid - 1;
  }
  const omitted = body.length - lo;
  return `${body.slice(0, lo)}... [truncated, ${omitted} chars omitted]`;
}
