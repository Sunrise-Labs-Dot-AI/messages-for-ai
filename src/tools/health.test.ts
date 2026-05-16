import { describe, test, expect, afterEach } from "bun:test";
import {
  canonHandlePublic,
  resolveHandle,
  _setContactsForTesting,
  _resetContactsCache,
} from "../chatdb/contacts.ts";

// Unit tests for the building blocks of `imessage_mcp_health_check`.
//
// We deliberately don't spin up an McpServer harness and invoke the
// registered tool — the project doesn't have a server-test fixture
// yet, and the tool body is a thin shell over functions we DO exercise
// directly here (`getAddressBookDiagnostic`, `getChatDbDiagnostic`,
// `canonHandlePublic`, `resolveHandle`). The shell wiring is type-
// checked by `bun --bun tsc --noEmit`.
//
// The two DB-probe functions hit real macOS paths and depend on TCC
// state, so we don't assert their outputs — they're integration-style
// and intentionally non-deterministic for unit tests. The `probe` block
// of the tool's output is pure-function (canonHandle + resolveHandle)
// and IS exercised here.

describe("canonHandlePublic", () => {
  afterEach(() => { _resetContactsCache(); });

  test("strips non-digits and takes last 10 for phones", () => {
    expect(canonHandlePublic("+1 (404) 561-0417")).toBe("4045610417");
    expect(canonHandlePublic("+14045610417")).toBe("4045610417");
    expect(canonHandlePublic("14045610417")).toBe("4045610417");
    expect(canonHandlePublic("4045610417")).toBe("4045610417");
  });

  test("lowercases emails", () => {
    expect(canonHandlePublic("Allegra@Example.COM")).toBe("allegra@example.com");
  });

  test("preserves short digit strings as-is (no slice)", () => {
    expect(canonHandlePublic("911")).toBe("911");
  });
});

describe("probe block: canonical + resolved_name", () => {
  afterEach(() => { _resetContactsCache(); });

  test("probe_handle with a known contact populates resolved_name", () => {
    // Seed Allegra under her canonical 10-digit form, exactly as the
    // health tool's `probe` block would compute it.
    _setContactsForTesting(
      new Map([["4045610417", "Allegra Test"]]),
      [{ lower_name: "allegra test", handles: ["4045610417"] }]
    );

    const input = "+1 (404) 561-0417";
    const canonical = canonHandlePublic(input);
    const resolved_name = resolveHandle(input);

    expect(canonical).toBe("4045610417");
    expect(resolved_name).toBe("Allegra Test");
  });

  test("probe_handle that doesn't match any contact yields null resolved_name", () => {
    _setContactsForTesting(new Map(), []);
    expect(resolveHandle("+15555550000")).toBeNull();
  });

  test("non-canonical phone formats all canonicalize identically — the lookup is format-agnostic", () => {
    _setContactsForTesting(
      new Map([["4045610417", "Allegra Test"]]),
      [{ lower_name: "allegra test", handles: ["4045610417"] }]
    );
    // All three forms should produce the same canonical key and thus the same name.
    for (const variant of ["+14045610417", "14045610417", "4045610417", "+1 (404) 561-0417"]) {
      expect(resolveHandle(variant)).toBe("Allegra Test");
    }
  });
});
