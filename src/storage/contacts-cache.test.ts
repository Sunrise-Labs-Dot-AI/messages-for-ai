import { describe, test, expect, beforeAll, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  readContactsSidecar,
  getContactsSidecarDiagnostic,
  contactsCachePath,
  _setSidecarPathForTesting,
  CONTACTS_CACHE_SCHEMA_VERSION,
} from "./contacts-cache.ts";

// Tests use a tmp file so they don't read or trample the user's real
// ~/.imessage-mcp/contacts-cache.json. The seam is _setSidecarPathForTesting,
// reset in afterAll.
const tmpRoot = mkdtempSync(join(tmpdir(), "imessage-mcp-contacts-cache-test-"));
const tmpSidecar = join(tmpRoot, "contacts-cache.json");

beforeAll(() => {
  _setSidecarPathForTesting(tmpSidecar);
});

afterAll(() => {
  _setSidecarPathForTesting(null);
  rmSync(tmpRoot, { recursive: true, force: true });
});

beforeEach(() => {
  rmSync(tmpSidecar, { force: true });
});

function writeSidecar(payload: unknown) {
  mkdirSync(tmpRoot, { recursive: true });
  writeFileSync(tmpSidecar, JSON.stringify(payload, null, 2));
}

describe("readContactsSidecar", () => {
  test("returns null when sidecar is missing", () => {
    expect(readContactsSidecar()).toBeNull();
  });

  test("parses a well-formed sidecar", () => {
    writeSidecar({
      version: CONTACTS_CACHE_SCHEMA_VERSION,
      generated_at: "2026-05-15T12:00:00Z",
      source: "menubar-cnContactStore",
      permission_status: "granted",
      count: 2,
      handles: {
        "4045610417": "Allegra Test",
        "alice@example.com": "Alice Smith",
      },
    });
    const got = readContactsSidecar();
    expect(got).not.toBeNull();
    expect(got!.count).toBe(2);
    expect(got!.permission_status).toBe("granted");
    expect(got!.handles["4045610417"]).toBe("Allegra Test");
  });

  test("returns null on stale schema version (forward-compat guard)", () => {
    writeSidecar({
      version: 99,
      generated_at: "2099-01-01T00:00:00Z",
      source: "future-format",
      permission_status: "granted",
      count: 0,
      handles: {},
    });
    expect(readContactsSidecar()).toBeNull();
  });

  test("returns null on malformed JSON (atomic-write race tolerance)", () => {
    mkdirSync(tmpRoot, { recursive: true });
    writeFileSync(tmpSidecar, "{ not valid json");
    expect(readContactsSidecar()).toBeNull();
  });

  test("returns null when handles field is missing", () => {
    writeSidecar({
      version: CONTACTS_CACHE_SCHEMA_VERSION,
      generated_at: "2026-05-15T12:00:00Z",
      source: "menubar-cnContactStore",
      permission_status: "granted",
      count: 0,
    });
    expect(readContactsSidecar()).toBeNull();
  });
});

describe("getContactsSidecarDiagnostic", () => {
  test("reports missing when sidecar is absent", () => {
    const d = getContactsSidecarDiagnostic();
    expect(d.exists).toBe(false);
    expect(d.read_status).toBe("missing");
    expect(d.path).toBe(tmpSidecar);
  });

  test("reports stale_schema with the version mismatch error", () => {
    writeSidecar({ version: 99, handles: {} });
    const d = getContactsSidecarDiagnostic();
    expect(d.exists).toBe(true);
    expect(d.read_status).toBe("stale_schema");
    expect(d.read_error).toContain("expected version");
  });

  test("reports parse_error on malformed JSON", () => {
    mkdirSync(tmpRoot, { recursive: true });
    writeFileSync(tmpSidecar, "not json at all");
    const d = getContactsSidecarDiagnostic();
    expect(d.read_status).toBe("parse_error");
  });

  test("reports ok with metadata when sidecar is valid", () => {
    writeSidecar({
      version: CONTACTS_CACHE_SCHEMA_VERSION,
      generated_at: "2026-05-15T12:00:00Z",
      source: "menubar-cnContactStore",
      permission_status: "granted",
      count: 42,
      handles: { "4045610417": "Allegra Test" },
    });
    const d = getContactsSidecarDiagnostic();
    expect(d.read_status).toBe("ok");
    expect(d.count).toBe(42);
    expect(d.source).toBe("menubar-cnContactStore");
    expect(d.permission_status).toBe("granted");
    expect(typeof d.age_seconds).toBe("number");
    expect(d.age_seconds!).toBeGreaterThanOrEqual(0);
  });
});

describe("contactsCachePath honors the test seam", () => {
  test("returns the override path while seam is set", () => {
    expect(contactsCachePath()).toBe(tmpSidecar);
  });
});
