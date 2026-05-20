import Foundation
import Security

/// Result of inspecting the Claude Desktop MCP config for one of our binaries.
/// Raw extracted command strings are NEVER surfaced to the UI — the enum case
/// is the only thing callers see. Reason: claude_desktop_config.json is
/// writable by any local process / Claude Desktop plugin; a crafted entry's
/// `command` value could be malicious, so we expose only the boolean
/// did-we-find-our-prefix outcome.
enum ClaudeConfigState: Equatable {
    /// File parses and at least one mcpServers entry's `command` is under the
    /// expected `.app` bundle prefix.
    case found
    /// File parses but no entry references our bundle.
    case notFound
    /// `~/Library/Application Support/Claude/claude_desktop_config.json` does
    /// not exist (Claude Desktop not installed, or never opened, or moved).
    case fileAbsent
    /// File exists but JSON parse failed.
    case parseError
}

/// Pure health-check primitives used by the SetupWalkthrough + Status pane.
/// All functions are deterministic given filesystem state; testable via the
/// injectable `bundleBinaryPrefix` + `claudeDesktopConfigPath` fields.
struct HealthChecks {
    /// Where the .app installs its inner Mach-Os in production.
    static let defaultBundleBinaryPrefix = "/Applications/Messages for AI.app/Contents/MacOS/"

    /// The codesign Identifier every inner Mach-O shares (set by
    /// dev-install.sh / build-release.sh — see SECURITY.md).
    static let expectedSigningIdentifier = "com.sunriselabs.messages-for-ai"

    /// Expected prefix for binary paths. Tests inject a tmpdir prefix.
    var bundleBinaryPrefix: String = HealthChecks.defaultBundleBinaryPrefix

    /// Override the Claude Desktop config location for tests. Nil = system path.
    var claudeDesktopConfigPath: URL? = nil

    // MARK: - Binary presence + codesign

    /// True iff a regular file exists at `path`, the canonicalized (symlink-
    /// resolved) path lies under `bundleBinaryPrefix`, and the path component
    /// after the prefix doesn't traverse outside the bundle (no "../" escape).
    /// Symlink-substitution defense: an attacker replacing
    /// `/Applications/Messages for AI.app/Contents/MacOS/imessage-drafts-mcp`
    /// with a symlink to `~/evil` causes this to return false.
    func binaryExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue
        else { return false }

        let canonical = (path as NSString).resolvingSymlinksInPath
        return canonical.hasPrefix(bundleBinaryPrefix)
    }

    /// Returns the codesign Identifier for the binary at `path`, or nil if:
    /// - the canonical path escapes `bundleBinaryPrefix` (symlink defense),
    /// - SecStaticCodeCreateWithPath fails,
    /// - SecStaticCodeCheckValidity fails (modified-in-place binary —
    ///   Gatekeeper would refuse to launch it),
    /// - SecCodeCopySigningInformation fails or returns no Identifier.
    ///
    /// The validity gate is essential. Without it, SecCodeCopySigningInformation
    /// returns the identifier embedded in the on-disk signature blob even when
    /// the binary's text has been tampered with — that would make this function
    /// a paper diagnostic rather than a real one.
    func codesignIdentifier(of path: String) -> String? {
        // Symlink/canonical-path defense.
        let canonical = (path as NSString).resolvingSymlinksInPath
        guard canonical.hasPrefix(bundleBinaryPrefix) else { return nil }

        let url = URL(fileURLWithPath: canonical) as CFURL
        var staticCodeRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCodeRef) == errSecSuccess,
              let staticCode = staticCodeRef
        else { return nil }

        // Validity gate BEFORE reading signing info.
        let strictFlags = UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures)
        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: strictFlags),
            nil
        )
        guard validityStatus == errSecSuccess else { return nil }

        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any]
        else { return nil }

        return info[kSecCodeInfoIdentifier as String] as? String
    }

    // MARK: - Running-process identity

    /// True iff the process with the given pid is signed with the expected
    /// codesign Identifier. Used by LastInvocationStore to verify a witness
    /// file's `pid` field references a trusted writer.
    ///
    /// Returns false if the pid has already exited, if SecCode lookup fails,
    /// or if the running process's identifier doesn't match.
    static func verifyRunningPid(
        _ pid: pid_t,
        expectedIdentifier: String = HealthChecks.expectedSigningIdentifier
    ) -> Bool {
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var codeRef: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef
        else { return false }

        // SecCodeCopySigningInformation's Swift overload requires SecStaticCode;
        // convert from the live SecCode via SecCodeCopyStaticCode. Same
        // underlying CFTypeRef in C, but the Swift bridge is strict.
        var staticCodeRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCodeRef) == errSecSuccess,
              let staticCode = staticCodeRef
        else { return false }

        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String
        else { return false }

        return identifier == expectedIdentifier
    }

    // MARK: - Claude Desktop config inspection

    /// Inspect Claude Desktop's MCP config to see whether it registers any
    /// of our binaries. Returns an enum so the UI can distinguish
    /// "Claude Desktop not installed" from "config exists but doesn't
    /// reference us" from "JSON parse failed" — only the case, never raw
    /// command strings.
    func claudeDesktopConfigState() -> ClaudeConfigState {
        let configURL = claudeDesktopConfigPath ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

        guard let data = try? Data(contentsOf: configURL) else {
            return .fileAbsent
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any]
        else {
            return .parseError
        }
        guard let servers = obj["mcpServers"] as? [String: Any] else {
            return .notFound
        }
        for (_, value) in servers {
            guard let entry = value as? [String: Any],
                  let command = entry["command"] as? String
            else { continue }
            if command.hasPrefix(bundleBinaryPrefix) {
                return .found
            }
        }
        return .notFound
    }
}
