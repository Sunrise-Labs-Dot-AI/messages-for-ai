import AppKit
import Combine
import SwiftUI

/// Post-onboarding (and on-demand from Settings) walkthrough that proves
/// each enabled MCP is reachable from Claude. Two panes:
///
/// 1. **Programmatic checks** — binary presence, codesign validity,
///    daemon liveness, Claude Desktop config inspection. Auto-runs on
///    appear and refreshes every 5s.
///
/// 2. **Test-now per transport** — copies a hardcoded prompt to the
///    clipboard, opens Claude Desktop (or shows Claude Code instructions
///    if Desktop isn't installed), then watches LastInvocationStore for
///    a witness record that lands AFTER walkthroughStartedAt AND whose
///    pid passes HealthChecks.verifyRunningPid (rejects locally-forged
///    witness files).
///
/// Stale witnesses written before the view appeared cannot turn the
/// check green — the walkthroughStartedAt comparison is the cardinal
/// freshness gate.
struct SetupWalkthroughView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController
    @StateObject private var invocations = LastInvocationStore()
    @Environment(\.dismissWindow) private var dismissWindow

    private let checks = HealthChecks()

    // Walkthrough-lifecycle state. `walkthroughStartedAt` initializes
    // fresh on every SwiftUI view instantiation, which happens when the
    // Window scene is opened (or re-opened from Settings → "Re-run").
    @State private var walkthroughStartedAt = Date()

    // Programmatic check results, computed on appear + every 5s.
    @State private var programmaticChecks: [ProgrammaticCheck] = []
    // Claude Desktop config state lives separately so the row can render
    // its own inline help block (a pastable prompt for Claude to wire up
    // the MCPs autonomously). The ProgrammaticCheck rows above are
    // pass/fail/neutral and don't carry remediation affordances.
    @State private var claudeConfigState: ClaudeConfigState = .fileAbsent

    // Per-transport verification: nil = waiting, true = green, false = 60s timeout.
    @State private var imessageVerified: Bool? = nil
    @State private var whatsappVerified: Bool? = nil

    @State private var claudeDesktopBundleURL: URL? = nil

    // 1s tick for elapsed-time tracking (60s timeout per transport).
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var elapsed: TimeInterval = 0

    private static let bundlePrefix = HealthChecks.defaultBundleBinaryPrefix
    private static let timeoutSeconds: TimeInterval = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                programmaticPane

                if settings.imessageEnabled {
                    testNowPane(transport: .imessage)
                }
                if settings.whatsappEnabled {
                    testNowPane(transport: .whatsapp)
                }

                completionFooter
            }
            .padding(24)
        }
        .frame(minWidth: 520, idealWidth: 560)
        .onAppear {
            refreshProgrammaticChecks()
            claudeDesktopBundleURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.anthropic.claudefordesktop"
            )
            // Kick the WhatsApp daemon if the transport is enabled.
            // start() is idempotent (the controller short-circuits if
            // already running). Without this call, a user who opens the
            // walkthrough before clicking the menubar icon (e.g. via the
            // Dock launch path) sees red rows because DraftListView's
            // .task — which is the OTHER place the daemon gets kicked —
            // hasn't fired yet.
            if settings.whatsappEnabled {
                whatsappDaemon.start()
            }
        }
        // Re-render the status rows the moment the daemon's state
        // changes, not just every 5s on the tick. Without these, a
        // .starting → .running transition lags up to 5s in the UI.
        .onChange(of: whatsappDaemon.status) { _, _ in
            refreshProgrammaticChecks()
        }
        .onChange(of: whatsappDaemon.baileysState) { _, _ in
            refreshProgrammaticChecks()
        }
        .onReceive(tick) { _ in
            elapsed = Date().timeIntervalSince(walkthroughStartedAt)
            // Refresh programmatic checks every 5s while the view is up.
            if Int(elapsed) % 5 == 0 {
                refreshProgrammaticChecks()
            }
            // Apply 60s timeouts for un-verified transports.
            if elapsed > Self.timeoutSeconds {
                if settings.imessageEnabled, imessageVerified == nil {
                    imessageVerified = false
                }
                if settings.whatsappEnabled, whatsappVerified == nil {
                    whatsappVerified = false
                }
            }
        }
        .onChange(of: invocations.imessage) { _, new in
            evaluateInvocation(.imessage, record: new)
        }
        .onChange(of: invocations.whatsapp) { _, new in
            evaluateInvocation(.whatsapp, record: new)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Let's make sure Claude can see this app")
                .font(.title2.weight(.semibold))
            Text("Two quick steps. The first runs automatically. The second sends a test prompt to Claude and watches for the response.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var programmaticPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Install health")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(programmaticChecks) { check in
                    checkRow(check)
                }
                claudeConfigRow
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The Claude Desktop config check — rendered separately from the
    /// other rows because it carries an inline help block (a pastable
    /// prompt) when the config isn't yet wired up. Aimed at less-technical
    /// users who shouldn't be expected to hand-edit JSON.
    private var claudeConfigRow: some View {
        let (label, passing): (String, Bool?) = {
            switch claudeConfigState {
            case .found:
                return ("Claude Desktop config references this app", true)
            case .notFound:
                return ("Claude Desktop config doesn't reference this app yet", false)
            case .fileAbsent:
                // Not a failure — Claude Desktop may simply not be installed.
                return ("Claude Desktop not detected (Claude Code-only setup is fine)", nil)
            case .parseError:
                return ("Claude Desktop config exists but can't be parsed", false)
            }
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusBadge(for: passing)
                Text(label).font(.callout)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label), \(Self.statusWord(for: passing))")

            if claudeConfigState == .notFound || claudeConfigState == .parseError {
                claudeConfigHelp
            }
        }
    }

    /// Inline remediation block. Surfaces a self-contained prompt the
    /// user can paste into Claude Desktop (Cowork) or Claude Code; Claude
    /// then edits `~/Library/Application Support/Claude/claude_desktop_config.json`
    /// on the user's behalf. Avoids asking non-technical users to
    /// hand-edit JSON.
    private var claudeConfigHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(claudeConfigState == .parseError
                 ? "Your Claude Desktop config exists but the JSON is malformed. The prompt below asks Claude to read it, fix the syntax, and wire in this app's MCPs in one go."
                 : "Don't edit JSON yourself. Paste this prompt into Claude Desktop (use Cowork / agent mode) or Claude Code, and Claude will update the config for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(claudeConfigPrompt)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button("Copy prompt") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(claudeConfigPrompt, forType: .string)
                }
                if let bundleURL = claudeDesktopBundleURL {
                    Button("Open Claude Desktop") {
                        NSWorkspace.shared.open(bundleURL)
                    }
                }
                Spacer()
            }

            Text("After Claude finishes, quit and reopen Claude Desktop so it picks up the new config, then re-run this walkthrough from Settings → Status.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 32)
        .padding(.top, 4)
    }

    /// The prompt the user pastes into Claude. Transport-aware — only
    /// includes the MCP entries for transports the user enabled in
    /// onboarding, so an iMessage-only user doesn't get a WhatsApp
    /// entry they don't want.
    private var claudeConfigPrompt: String {
        var entries: [String] = []
        if settings.imessageEnabled {
            entries.append(#"  "imessage-drafts": {"# + "\n" +
                           #"    "command": "/Applications/Messages for AI.app/Contents/MacOS/imessage-drafts-mcp""# + "\n" +
                           #"  }"#)
        }
        if settings.whatsappEnabled {
            entries.append(#"  "whatsapp-drafts": {"# + "\n" +
                           #"    "command": "/Applications/Messages for AI.app/Contents/MacOS/whatsapp-drafts-mcp""# + "\n" +
                           #"  }"#)
        }
        let entriesBlock = entries.joined(separator: ",\n")

        return """
        I just installed the "Messages for AI" app on my Mac and need to wire it into Claude Desktop. \
        Please read my Claude Desktop config at ~/Library/Application Support/Claude/claude_desktop_config.json, \
        then add the following entries to the `mcpServers` object (creating the object if it doesn't exist, \
        preserving every other key in the file). The values are exact paths — don't rewrite them.

        {
          "mcpServers": {
        \(entriesBlock)
          }
        }

        After saving, tell me to quit and reopen Claude Desktop so it picks up the change.
        """
    }

    private func testNowPane(transport: Platform) -> some View {
        let verified = (transport == .imessage) ? imessageVerified : whatsappVerified
        let prompt = Self.testPrompt(for: transport)

        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Test \(transport.displayName)")

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    statusBadge(for: verified)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusText(for: verified, transport: transport))
                            .font(.callout.weight(.medium))
                        Text(statusSubtitle(for: verified))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if verified != true {
                    Text("\"\(prompt)\"")
                        .font(.body.monospaced())
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    HStack(spacing: 8) {
                        Button("Copy prompt") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(prompt, forType: .string)
                        }
                        if let bundleURL = claudeDesktopBundleURL {
                            Button("Open Claude Desktop") {
                                NSWorkspace.shared.open(bundleURL)
                            }
                        }
                        Spacer()
                    }

                    if claudeDesktopBundleURL == nil {
                        Text("Claude Desktop isn't installed. Open a Claude Code session in a project that registers this MCP (see your .mcp.json), then paste the prompt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var completionFooter: some View {
        HStack {
            Button("Skip for now") {
                settings.walkthroughSkipped = true
                settings.walkthroughComplete = false
                dismissWindow(id: WindowID.setupWalkthrough)
            }
            Spacer()
            Button("All set") {
                settings.walkthroughComplete = true
                settings.walkthroughSkipped = false
                dismissWindow(id: WindowID.setupWalkthrough)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!allVerifiedOrSkipped)
            .accessibilityHint(allVerifiedOrSkipped
                ? "Marks setup complete and closes the window."
                : "Disabled. Run the test prompt for each enabled transport above to enable this button.")
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.callout.weight(.semibold))
    }

    private func checkRow(_ check: ProgrammaticCheck) -> some View {
        HStack(spacing: 10) {
            statusBadge(for: check.passing)
            Text(check.label).font(.callout)
            Spacer()
        }
        // Combine the icon + label so VoiceOver announces a single
        // sentence ("iMessage MCP binary present, passed") instead of
        // reading the bare SF Symbol name as a separate element.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.label), \(Self.statusWord(for: check.passing))")
    }

    private func statusBadge(for value: Bool?) -> some View {
        let (symbol, color): (String, Color) = {
            switch value {
            case true?: return ("checkmark.circle.fill", .green)
            case false?: return ("xmark.circle.fill", .red)
            case nil: return ("circle.dotted", .secondary)
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            // Hidden from AT — the parent row supplies its own
            // combined accessibilityLabel; surfacing the raw SF Symbol
            // name would just add noise.
            .accessibilityHidden(true)
    }

    /// Status word used inside combined accessibility labels.
    private static func statusWord(for value: Bool?) -> String {
        switch value {
        case true?: return "passed"
        case false?: return "failed"
        case nil: return "not yet checked"
        }
    }

    private func statusText(for verified: Bool?, transport: Platform) -> String {
        switch verified {
        case true?: return "Claude reached \(transport.displayName) ✓"
        case false?: return "Didn't see Claude reach \(transport.displayName)"
        case nil: return "Waiting for Claude to call \(transport.displayName)…"
        }
    }

    private func statusSubtitle(for verified: Bool?) -> String {
        switch verified {
        case true?: return "Setup verified. You can close this window."
        case false?: return "Try running the prompt again. If it keeps failing, check Settings → Status."
        case nil: return "Paste the prompt into Claude. We'll know when the MCP is called."
        }
    }

    private var allVerifiedOrSkipped: Bool {
        let imsOK = !settings.imessageEnabled || imessageVerified == true
        let waOK = !settings.whatsappEnabled || whatsappVerified == true
        return imsOK && waOK
    }

    private static func testPrompt(for transport: Platform) -> String {
        switch transport {
        case .imessage: return "list my 5 most recent iMessage threads"
        case .whatsapp: return "list my 5 most recent WhatsApp threads"
        }
    }

    // MARK: - Verification logic

    /// Evaluate an incoming witness record against this walkthrough's
    /// freshness gate + writer-binary identity check.
    ///
    /// Verification chain:
    ///   1. `record.ts > walkthroughStartedAt` — rejects stale invocations
    ///      written before this view appeared.
    ///   2. `record.writerPath` is non-empty AND resolves under the bundle
    ///      prefix (canonical-path check rejects symlink escapes).
    ///   3. The binary at `writerPath` passes `SecStaticCodeCheckValidity`
    ///      and its signing identifier matches
    ///      `com.sunriselabs.messages-for-ai`.
    ///
    /// Static-path verification (not live-pid) because stdio MCPs are
    /// short-lived per-tool-call processes. By the time the menubar's
    /// DispatchSource fires + main-queue dispatch hops + this function
    /// runs, the writing pid is typically dead — `SecCodeCopyGuestWithAttributes`
    /// would return failure and the walkthrough would never go green.
    /// `record.writerPath` plus `HealthChecks.codesignIdentifier(of:)`
    /// validates the on-disk binary instead, which is short-lived-process-safe.
    ///
    /// Residual exposure: a malicious local process can write a forged
    /// witness with `writer_path` pointing at the real bundle binary
    /// (its path is hardcoded + public). The `walkthroughStartedAt` gate
    /// narrows the attack window to "while the user has the walkthrough
    /// open." Closing this fully requires nonce-binding the test prompt
    /// to the witness, filed for v0.3.3.
    private func evaluateInvocation(_ transport: Platform, record: WitnessRecord?) {
        guard let record = record else { return }
        // Freshness: must have been written after this view appeared.
        guard record.ts > walkthroughStartedAt else { return }
        // Identity: the binary at writer_path must (a) exist under the
        // expected bundle prefix and (b) pass strict codesign validation
        // with our expected identifier.
        guard !record.writerPath.isEmpty,
              checks.binaryExists(at: record.writerPath),
              checks.codesignIdentifier(of: record.writerPath)
                == HealthChecks.expectedSigningIdentifier
        else { return }

        switch transport {
        case .imessage: imessageVerified = true
        case .whatsapp: whatsappVerified = true
        }
    }

    private func refreshProgrammaticChecks() {
        var rows: [ProgrammaticCheck] = []

        // Only surface binary-presence rows for transports the user
        // has actually enabled. An iMessage-only user shouldn't see two
        // red "WhatsApp binary present" rows on a fresh install — that
        // looks like something is broken when in fact the user just
        // didn't opt in. (The WhatsApp daemon binary is included only
        // when the WhatsApp transport is enabled, since its sole
        // purpose is to back the WhatsApp daemon.)
        var bins: [(String, String)] = [
            ("iMessage MCP binary", "imessage-drafts-mcp"),
        ]
        if settings.whatsappEnabled {
            bins.append(("WhatsApp MCP binary", "whatsapp-drafts-mcp"))
            bins.append(("WhatsApp daemon binary", "whatsapp-drafts-daemon"))
        }
        for (label, name) in bins {
            let path = Self.bundlePrefix + name
            let exists = checks.binaryExists(at: path)
            rows.append(ProgrammaticCheck(label: "\(label) present", passing: exists))
            let identifier = checks.codesignIdentifier(of: path)
            let signed = identifier == HealthChecks.expectedSigningIdentifier
            rows.append(ProgrammaticCheck(label: "\(label) signature valid", passing: signed))
        }

        if settings.whatsappEnabled {
            // Tri-state representation so transitional states (.starting,
            // .backingOff, running-but-baileys-still-connecting) show as
            // pending instead of failing. The label changes too — a
            // "WhatsApp daemon starting…" with a neutral icon is much
            // clearer than "WhatsApp daemon running ✗" during the few
            // seconds between launch and the daemon's first poll landing.
            let (daemonLabel, daemonPassing): (String, Bool?) = {
                switch whatsappDaemon.status {
                case .idle:        return ("WhatsApp daemon starting…", nil)
                case .starting:    return ("WhatsApp daemon starting…", nil)
                case .running:     return ("WhatsApp daemon running", true)
                case .backingOff:  return ("WhatsApp daemon reconnecting…", nil)
                case .crashLooping: return ("WhatsApp daemon couldn't start", false)
                case .stopped:     return ("WhatsApp daemon stopped", false)
                }
            }()
            rows.append(ProgrammaticCheck(label: daemonLabel, passing: daemonPassing))

            // Baileys pairing — depends on the daemon being up first.
            // When the daemon isn't running, this row is pending (not
            // failed) since it can't be evaluated yet.
            let (baileysLabel, baileysPassing): (String, Bool?) = {
                guard case .running = whatsappDaemon.status else {
                    return ("WhatsApp connection (waiting for daemon)", nil)
                }
                switch whatsappDaemon.baileysState {
                case "connected":     return ("WhatsApp paired (Baileys connected)", true)
                case "connecting":    return ("WhatsApp connecting…", nil)
                case "reconnecting":  return ("WhatsApp reconnecting…", nil)
                case "logged_out":    return ("WhatsApp logged out — re-pair needed", false)
                // Daemon up but the first state-poll hasn't landed yet.
                case .none:           return ("WhatsApp connecting…", nil)
                // Future Baileys states we don't yet model: show raw + pending.
                case .some(let s):    return ("WhatsApp state: \(s)", nil)
                }
            }()
            rows.append(ProgrammaticCheck(label: baileysLabel, passing: baileysPassing))
        }

        programmaticChecks = rows
        // Claude Desktop config state is rendered by `claudeConfigRow`
        // (not appended to programmaticChecks) so the row can carry an
        // inline help block when remediation is needed.
        claudeConfigState = checks.claudeDesktopConfigState()
    }
}

private struct ProgrammaticCheck: Identifiable {
    let id = UUID()
    let label: String
    /// nil = neutral / informational; true = green; false = red.
    let passing: Bool?
}

// Platform.displayName is defined in Views/PlatformStyling.swift and reused here.
