// macOS-specific peer-identity lookups via bun:ffi.
//
// Two libc/libproc calls:
//   - getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid_out, &len)
//     → 32-bit PID of the peer process for a connected Unix socket
//   - proc_pidpath(pid, buf, buflen) from libproc
//     → absolute path to the binary the PID was launched as
//
// Returns null on any FFI error. Callers (peer-auth.ts) treat null as
// "couldn't verify" → deny in production mode.
//
// Bun:ffi resolves `null` lib path to the main process's symbol table on
// macOS, which already has libSystem (libc + libproc) loaded. If that
// stops working, fall back to "/usr/lib/libSystem.B.dylib".

import { dlopen, FFIType, ptr } from "bun:ffi";

// macOS sys/un.h:
//   #define SOL_LOCAL     0
//   #define LOCAL_PEERPID 2
const SOL_LOCAL = 0;
const LOCAL_PEERPID = 2;

const PROC_PIDPATHINFO_MAXSIZE = 4096; // From <sys/proc_info.h>

type LibSymbols = {
  getsockopt: (fd: number, level: number, optname: number, optval: number, optlen: number) => number;
  proc_pidpath: (pid: number, buf: number, bufsize: number) => number;
};

let _symbols: LibSymbols | null = null;
let _attempted = false;

function getLib(): LibSymbols | null {
  if (_symbols != null) return _symbols;
  if (_attempted) return null;
  _attempted = true;
  try {
    const handle = dlopen("libSystem.B.dylib", {
      getsockopt: {
        args: [FFIType.i32, FFIType.i32, FFIType.i32, FFIType.ptr, FFIType.ptr],
        returns: FFIType.i32,
      },
      proc_pidpath: {
        args: [FFIType.i32, FFIType.ptr, FFIType.u32],
        returns: FFIType.i32,
      },
    });
    // Cast through unknown — Bun's runtime types are dynamic.
    _symbols = handle.symbols as unknown as LibSymbols;
    return _symbols;
  } catch (e) {
    process.stderr.write(`peer-pid: failed to dlopen libSystem: ${(e as Error).message}\n`);
    return null;
  }
}

/**
 * Get the PID of the process on the other end of a Unix-socket fd.
 * Returns null if the FFI call fails (fd invalid, not a Unix socket, etc.).
 */
export function getPeerPid(fd: number): number | null {
  const lib = getLib();
  if (lib == null) return null;

  const pidBuf = new ArrayBuffer(4);
  const pidView = new DataView(pidBuf);
  const lenBuf = new ArrayBuffer(4);
  const lenView = new DataView(lenBuf);
  lenView.setUint32(0, 4, true); // little-endian on Apple silicon + Intel macs

  const rc = lib.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, Number(ptr(pidBuf)), Number(ptr(lenBuf)));
  if (rc !== 0) return null;
  return pidView.getUint32(0, true);
}

/** Resolve a PID to the absolute path of the binary it was launched as. */
export function pidToPath(pid: number): string | null {
  const lib = getLib();
  if (lib == null) return null;

  const buf = new ArrayBuffer(PROC_PIDPATHINFO_MAXSIZE);
  const written = lib.proc_pidpath(pid, Number(ptr(buf)), PROC_PIDPATHINFO_MAXSIZE);
  if (written <= 0) return null;
  return new TextDecoder().decode(new Uint8Array(buf, 0, written));
}

/**
 * Best-effort fd extraction from a Node net.Socket. Bun stores the fd
 * in different places depending on Bun version; we probe a few.
 * Returns null if we can't find it.
 */
export function socketFd(sock: unknown): number | null {
  const s = sock as { _handle?: { fd?: number }; fd?: number } | null;
  if (s == null) return null;
  if (typeof s.fd === "number") return s.fd;
  if (s._handle != null && typeof s._handle.fd === "number") return s._handle.fd;
  return null;
}
