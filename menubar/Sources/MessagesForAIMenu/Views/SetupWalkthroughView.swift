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
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
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
    }

    private func statusBadge(for value: Bool?) -> some View {
        let (symbol, color): (String, Color) = {
            switch value {
            case true: return ("checkmark.circle.fill", .green)
            case false: return ("xmark.circle.fill", .red)
            case nil: return ("circle.dotted", .secondary)
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
    }

    private func statusText(for verified: Bool?, transport: Platform) -> String {
        switch verified {
        case true: return "Claude reached \(transport.displayName) ✓"
        case false: return "Didn't see Claude reach \(transport.displayName)"
        case nil: return "Waiting for Claude to call \(transport.displayName)…"
        }
    }

    private func statusSubtitle(for verified: Bool?) -> String {
        switch verified {
        case true: return "Setup verified. You can close this window."
        case false: return "Try running the prompt again. If it keeps failing, check Settings → Status."
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
    /// freshness gate + pid identity check. Only flips the per-transport
    /// flag to true when both pass; never reverses an already-green state
    /// inside this session.
    private func evaluateInvocation(_ transport: Platform, record: WitnessRecord?) {
        guard let record = record else { return }
        // Freshness: must have been written after this view appeared.
        guard record.ts > walkthroughStartedAt else { return }
        // Identity: pid must currently belong to a process signed with
        // our expected identifier. If the pid has already exited (the
        // MCP is short-lived stdio) we treat that as failed verification
        // and keep waiting — the next invocation will be picked up.
        guard HealthChecks.verifyRunningPid(record.pid) else { return }

        switch transport {
        case .imessage: imessageVerified = true
        case .whatsapp: whatsappVerified = true
        }
    }

    private func refreshProgrammaticChecks() {
        var rows: [ProgrammaticCheck] = []

        let bins: [(String, String)] = [
            ("iMessage MCP binary", "imessage-drafts-mcp"),
            ("WhatsApp MCP binary", "whatsapp-drafts-mcp"),
            ("WhatsApp daemon binary", "whatsapp-drafts-daemon"),
        ]
        for (label, name) in bins {
            let path = Self.bundlePrefix + name
            let exists = checks.binaryExists(at: path)
            rows.append(ProgrammaticCheck(label: "\(label) present", passing: exists))
            let identifier = checks.codesignIdentifier(of: path)
            let signed = identifier == HealthChecks.expectedSigningIdentifier
            rows.append(ProgrammaticCheck(label: "\(label) signature valid", passing: signed))
        }

        if settings.whatsappEnabled {
            let running: Bool = {
                if case .running = whatsappDaemon.status { return true }
                return false
            }()
            rows.append(ProgrammaticCheck(label: "WhatsApp daemon running", passing: running))
            let paired = whatsappDaemon.baileysState == "connected"
            rows.append(ProgrammaticCheck(label: "WhatsApp paired (Baileys connected)", passing: paired))
        }

        // Claude Desktop config — only surface the case, never raw strings.
        let configState = checks.claudeDesktopConfigState()
        let configLabel: String
        let configPass: Bool?
        switch configState {
        case .found:
            configLabel = "Claude Desktop config references this app"
            configPass = true
        case .notFound:
            configLabel = "Claude Desktop config doesn't reference this app yet"
            configPass = false
        case .fileAbsent:
            // Not a failure — Claude Desktop may simply not be installed.
            configLabel = "Claude Desktop not detected (Claude Code-only setup is fine)"
            configPass = nil
        case .parseError:
            configLabel = "Claude Desktop config exists but can't be parsed"
            configPass = false
        }
        rows.append(ProgrammaticCheck(label: configLabel, passing: configPass))

        programmaticChecks = rows
    }
}

private struct ProgrammaticCheck: Identifiable {
    let id = UUID()
    let label: String
    /// nil = neutral / informational; true = green; false = red.
    let passing: Bool?
}

// Platform.displayName is defined in Views/PlatformStyling.swift and reused here.
