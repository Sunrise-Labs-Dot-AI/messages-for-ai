import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, readdirSync, rmSync, chmodSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  _setHomeForTesting,
  writeLastInvocation,
  type WitnessRecord,
} from "./witness.ts";

let tmpDir: string | null = null;

afterEach(() => {
  _setHomeForTesting(null);
  if (tmpDir !== null) {
    rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = null;
  }
});

function setupTmpHome(): string {
  tmpDir = mkdtempSync(join(tmpdir(), "witness-test-"));
  _setHomeForTesting(tmpDir);
  return tmpDir;
}

describe("writeLastInvocation (iMessage)", () => {
  test("writes the witness record with all expected fields", () => {
    const dir = setupTmpHome();
    writeLastInvocation("list_threads");

    const raw = readFileSync(join(dir, "last_invocation_imessage.json"), "utf8");
    const record = JSON.parse(raw) as WitnessRecord;

    expect(record.tool).toBe("list_threads");
    expect(record.pid).toBe(process.pid);
    expect(typeof record.writer_path).toBe("string");
    // ISO-8601 sanity: parses to a valid Date and re-stringifies to the same shape
    expect(Number.isNaN(new Date(record.ts).getTime())).toBe(false);
    expect(record.ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
  });

  test("creates the home directory if it doesn't exist", () => {
    tmpDir = mkdtempSync(join(tmpdir(), "witness-test-parent-"));
    const nestedHome = join(tmpDir, "nested", "messages-mcp-home");
    _setHomeForTesting(nestedHome);

    writeLastInvocation("get_thread");

    const raw = readFileSync(join(nestedHome, "last_invocation_imessage.json"), "utf8");
    expect((JSON.parse(raw) as WitnessRecord).tool).toBe("get_thread");
  });

  test("overwrites prior record without leaving stale temp files behind", () => {
    const dir = setupTmpHome();
    writeLastInvocation("list_threads");
    writeLastInvocation("get_thread");
    writeLastInvocation("search_messages");

    const final = JSON.parse(
      readFileSync(join(dir, "last_invocation_imessage.json"), "utf8"),
    ) as WitnessRecord;
    expect(final.tool).toBe("search_messages");

    // No orphan .tmp.* files left in the directory
    const orphans = readdirSync(dir).filter((f) => f.includes(".tmp."));
    expect(orphans).toEqual([]);
  });

  test("atomic-rename semantics: file is never partially-written at the final path", () => {
    // Stronger guarantee: the final path is created via rename, not as a
    // streaming write target. We can't easily race against the write here,
    // but we can confirm that statting the final path always yields a fully-
    // parseable JSON record after the call returns.
    const dir = setupTmpHome();
    for (let i = 0; i < 50; i++) {
      writeLastInvocation(`tool_${i}`);
      const raw = readFileSync(join(dir, "last_invocation_imessage.json"), "utf8");
      const record = JSON.parse(raw) as WitnessRecord;
      expect(record.tool).toBe(`tool_${i}`);
    }
  });

  test("swallows failure when the target directory is read-only", () => {
    tmpDir = mkdtempSync(join(tmpdir(), "witness-test-ro-"));
    // Create the dir, write into it, then make it read-only to block the
    // atomic-rename's temp-file creation.
    _setHomeForTesting(tmpDir);
    writeLastInvocation("setup");
    chmodSync(tmpDir, 0o500);
    try {
      // Must not throw despite the underlying write failing.
      expect(() => writeLastInvocation("would_fail")).not.toThrow();
    } finally {
      // Restore writable perms so afterEach's rmSync can clean up.
      chmodSync(tmpDir, 0o700);
    }
  });

  test("the final file has a single inode that changes across writes (rename, not in-place)", () => {
    const dir = setupTmpHome();
    const path = join(dir, "last_invocation_imessage.json");
    writeLastInvocation("first");
    const inoBefore = statSync(path).ino;
    writeLastInvocation("second");
    const inoAfter = statSync(path).ino;
    // The rename swaps the inode; an in-place writeFileSync would preserve it.
    // Asserting the change confirms the DispatchSource-friendly write path.
    expect(inoAfter).not.toBe(inoBefore);
  });
});
