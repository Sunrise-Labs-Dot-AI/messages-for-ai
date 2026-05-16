import { describe, expect, test } from "bun:test";

import { verifyBinary, verifyAgainstAllowlist } from "./codesign.ts";

describe("codesign verification", () => {
  test("verifies an Apple-signed system binary (/usr/bin/codesign itself)", () => {
    const r = verifyBinary("/usr/bin/codesign");
    expect(r.valid).toBe(true);
    expect(r.requirement).not.toBeNull();
    expect(r.requirement!).toContain("anchor apple");
  });

  test("rejects a missing binary", () => {
    const r = verifyBinary("/nonexistent/binary/path");
    expect(r.valid).toBe(false);
    expect(r.error).not.toBeNull();
  });

  test("allowlist match returns ok:true", () => {
    const v = verifyBinary("/usr/bin/codesign");
    const r = verifyAgainstAllowlist("/usr/bin/codesign", [v.requirement!]);
    expect(r.ok).toBe(true);
  });

  test("allowlist mismatch returns ok:false with reason", () => {
    const r = verifyAgainstAllowlist("/usr/bin/codesign", [`identifier "fake.id"`]);
    expect(r.ok).toBe(false);
    expect(r.reason).toContain("not in allowlist");
  });

  test("missing binary fails closed in allowlist check", () => {
    const r = verifyAgainstAllowlist("/nope", ["whatever"]);
    expect(r.ok).toBe(false);
    expect(r.reason).toContain("codesign --verify failed");
  });
});
