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

    // Full Disk Access state for the iMessage transport. Recomputed in
    // refreshProgrammaticChecks (on appear, every 5s, and on focus return).
    // Seeded to .unknown (not .ok) so the gate fails closed until the first
    // probe runs — a permission gate must never default to "granted".
    @State private var chatDbAccess: ChatDbAccessState = .unknown

    // Stepper position. The walkthrough is presented one step at a time
    // (install checks → test each enabled transport) rather than as one
    // long scroll, so a fresh user has a single clear action per screen.
    @State private var currentStepIndex: Int = 0

    // Memoized codesign-identity lookups, keyed by binary path. The installed
    // inner Mach-Os are immutable for the app's lifetime, but
    // codesignIdentifier(of:) runs a full SecStaticCodeCheckValidity
    // (all-architectures) costing tens-to-hundreds of ms per binary.
    // refreshProgrammaticChecks() runs on appear, on a 5s tick, and on every
    // daemon-status change, so without this cache we'd re-validate every
    // binary on the main thread repeatedly. Caching is safe: the freshness
    // gate in evaluateInvocation (record.ts > walkthroughStartedAt) — not
    // codesign recency — is the temporal security control.
    @State private var codesignCache: [String: String?] = [:]

    @State private var claudeDesktopBundleURL: URL? = nil
    /// Result of the most recent "Add to Claude Desktop config" click.
    /// Drives the inline outcome view; nil means the button hasn't been
    /// clicked yet (default state).
    @State private var wireResult: ClaudeConfigWriteResult? = nil

    // 1s tick for elapsed-time tracking (60s timeout per transport).
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var elapsed: TimeInterval = 0

    private static let bundlePrefix = HealthChecks.defaultBundleBinaryPrefix
    private static let timeoutSeconds: TimeInterval = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    stepContent
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            navigationFooter
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460)
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
        // If a transport is toggled in Settings while the walkthrough is open,
        // `steps` grows/shrinks. clampedIndex protects reads, but re-anchor the
        // stored index too so the user can't land on a stale "All set" for a
        // step that no longer exists.
        .onChange(of: steps) { _, newSteps in
            currentStepIndex = min(max(currentStepIndex, 0), newSteps.count - 1)
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
        // Re-probe the moment the app regains focus — e.g. the user
        // switched to System Settings to grant Full Disk Access and came
        // back. Flips the FDA row green without a manual re-check button.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshProgrammaticChecks()
        }
    }

    // MARK: - Stepper model

    /// Pure, testable model of the step sequence + gating predicates, rebuilt
    /// each render from live settings + @State. The logic lives in
    /// `WalkthroughStepper` (bottom of file) so the FDA gate and index math
    /// have regression coverage independent of SwiftUI.
    private var stepper: WalkthroughStepper {
        WalkthroughStepper(
            imessageEnabled: settings.imessageEnabled,
            whatsappEnabled: settings.whatsappEnabled,
            currentStepIndex: currentStepIndex,
            chatDbAccess: chatDbAccess,
            imessageVerified: imessageVerified,
            whatsappVerified: whatsappVerified
        )
    }

    private var steps: [WalkthroughStepper.Step] { stepper.steps }
    private var clampedIndex: Int { stepper.clampedIndex }
    private var currentStep: WalkthroughStepper.Step { stepper.currentStep }
    private var isLastStep: Bool { stepper.isLastStep }

    // MARK: - Subviews

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                // Iterate the steps array (not a 0..<count integer range):
                // `steps` is dynamic (transports can toggle), and
                // ForEach(0..<count) treats its range as constant data — a
                // mid-walkthrough count change trips SwiftUI's "constant data"
                // runtime warning and can mis-render the dots.
                ForEach(Array(steps.enumerated()), id: \.offset) { index, _ in
                    Capsule()
                        .fill(index <= clampedIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline) {
                Text(stepTitle(currentStep))
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(clampedIndex + 1) of \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // Combine title + counter so VoiceOver reads "Check the install,
            // Step 1 of 3" as one element instead of two separate stops.
            .accessibilityElement(children: .combine)
            Text(stepSubtitle(currentStep))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .installHealth:
            programmaticPane
        case .test(let transport):
            testNowPane(transport: transport)
        }
    }

    private func stepTitle(_ step: WalkthroughStepper.Step) -> String {
        switch step {
        case .installHealth: return "Check the install"
        case .test(let transport): return "Test \(transport.displayName)"
        }
    }

    private func stepSubtitle(_ step: WalkthroughStepper.Step) -> String {
        switch step {
        case .installHealth:
            return "These run automatically. If Full Disk Access is flagged below, grant it before continuing."
        case .test:
            return "Send a test prompt to Claude — we'll watch for the MCP call and confirm it landed."
        }
    }

    private var programmaticPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(programmaticChecks) { check in
                    checkRow(check)
                }
                if settings.imessageEnabled {
                    fdaRow
                }
                claudeConfigRow
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Full Disk Access row. This is the gap that made fresh-install users
    /// finish the walkthrough thinking everything worked: every other row
    /// goes green (the MCP binary IS present, signed, and reachable) but
    /// the iMessage MCP can't read chat.db without FDA, so the first real
    /// tool call returns permission_denied. Rendered only when iMessage is
    /// enabled — WhatsApp reads its own files under ~/.whatsapp-mcp, none
    /// of which are TCC-protected.
    @ViewBuilder
    private var fdaRow: some View {
        let passing: Bool? = {
            switch chatDbAccess {
            case .ok: return true
            case .permissionDenied: return false
            // notFound (Messages never used on this Mac) and unknown are
            // not FDA denials — show neutral and don't block completion.
            case .notFound, .unknown: return nil
            }
        }()
        let label: String = {
            switch chatDbAccess {
            case .ok: return "Full Disk Access granted (Claude can read Messages)"
            case .permissionDenied: return "Full Disk Access needed to read Messages"
            case .notFound: return "No Messages database found on this Mac yet"
            case .unknown: return "Couldn't check Messages access"
            }
        }()

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusBadge(for: passing)
                Text(label).font(.callout)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label), \(Self.statusWord(for: passing))")

            if chatDbAccess == .permissionDenied {
                fdaHelp
            }
        }
    }

    /// Inline remediation for missing Full Disk Access: plain-language
    /// instructions + a one-click deeplink straight to the FDA pane. The
    /// row re-checks automatically on focus return (see the
    /// didBecomeActive observer), so there's no manual re-check button.
    private var fdaHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grant Full Disk Access to Messages for AI in System Settings → Privacy & Security → Full Disk Access, then switch back here — this updates on its own. If it stays red right after granting, quit and reopen Messages for AI.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Open Full Disk Access settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .padding(.leading, 32)
        .padding(.top, 4)
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

    /// Inline remediation block. The menubar is unsandboxed and can
    /// edit `~/Library/Application Support/Claude/claude_desktop_config.json`
    /// directly — no need to ask Claude Desktop (Cowork) to edit its own
    /// config, which its sandbox blocks anyway. One button, atomic
    /// JSON merge, preserves every other key in the existing config.
    @ViewBuilder
    private var claudeConfigHelp: some View {
        if let result = wireResult {
            wireOutcomeView(for: result)
                .padding(.leading, 32)
                .padding(.top, 4)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(claudeConfigState == .parseError
                     ? "Your Claude Desktop config file exists but the JSON is malformed. Open it in Finder, fix the syntax, then come back here."
                     : "We can do this for you — one click adds this app's MCP entries to your Claude Desktop config. The rest of your config is preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if claudeConfigState != .parseError {
                        Button("Add to Claude Desktop config") {
                            applyClaudeConfigWrite(forceOverwrite: false)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Reveal config in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [ClaudeConfigWriter.configPath]
                        )
                    }
                    Spacer()
                }
            }
            .padding(.leading, 32)
            .padding(.top, 4)
        }
    }

    /// Render the outcome of a "Add to Claude Desktop config" click.
    /// Each case has its own affordance — success suggests restarting
    /// Claude Desktop, conflict offers a force-overwrite, parse/IO
    /// errors surface the path so the user can fix manually.
    @ViewBuilder
    private func wireOutcomeView(for result: ClaudeConfigWriteResult) -> some View {
        switch result {
        case .wrote(let keys):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                    Text("Added: \(keys.joined(separator: ", "))").font(.caption.weight(.medium))
                }
                Text("Quit and reopen Claude Desktop so it picks up the new config, then run the test prompt below.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let bundleURL = claudeDesktopBundleURL {
                    Button("Open Claude Desktop") {
                        NSWorkspace.shared.open(bundleURL)
                    }
                    .controlSize(.small)
                }
            }
        case .alreadyWired:
            // Shouldn't normally surface — claudeConfigState would have
            // shown .found and the help block wouldn't have rendered.
            Text("Already wired ✓").font(.caption).foregroundStyle(.secondary)
        case .conflict(let keys):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    Text("Conflicting entries: \(keys.joined(separator: ", "))")
                        .font(.caption.weight(.medium))
                }
                Text("Those names already exist in your config and point at different commands. If those are from a previous install you want to replace, click \"Overwrite\". Otherwise rename or remove them in your config first.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Overwrite") {
                        applyClaudeConfigWrite(forceOverwrite: true)
                    }
                    Button("Reveal config in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [ClaudeConfigWriter.configPath]
                        )
                    }
                }
                .controlSize(.small)
            }
        case .parseError:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                    Text("Config file has a JSON syntax error.").font(.caption.weight(.medium))
                }
                Text("Open it in Finder, fix the JSON, then click \"Add to Claude Desktop config\" again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Reveal config in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [ClaudeConfigWriter.configPath]
                        )
                    }
                    Button("Try again") {
                        wireResult = nil
                    }
                }
                .controlSize(.small)
            }
        case .ioError(let msg):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                    Text("Couldn't write config").font(.caption.weight(.medium))
                }
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    wireResult = nil
                }
                .controlSize(.small)
            }
        }
    }

    /// Run the config writer with the current transport selection and
    /// refresh the programmatic checks so the row above updates from
    /// .notFound → .found in the same render pass.
    private func applyClaudeConfigWrite(forceOverwrite: Bool) {
        var transports: [Platform] = []
        if settings.imessageEnabled { transports.append(.imessage) }
        if settings.whatsappEnabled { transports.append(.whatsapp) }
        wireResult = ClaudeConfigWriter.wire(
            transports: transports,
            forceOverwrite: forceOverwrite
        )
        refreshProgrammaticChecks()
    }

    private func testNowPane(transport: Platform) -> some View {
        let verified = (transport == .imessage) ? imessageVerified : whatsappVerified
        let prompt = Self.testPrompt(for: transport)

        return VStack(alignment: .leading, spacing: 12) {
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

    private var navigationFooter: some View {
        HStack(spacing: 12) {
            Button("Skip for now") {
                settings.walkthroughSkipped = true
                settings.walkthroughComplete = false
                dismissWindow(id: WindowID.setupWalkthrough)
            }
            Spacer()
            if clampedIndex > 0 {
                Button("Back") { goBack() }
            }
            if isLastStep {
                Button("All set") {
                    settings.walkthroughComplete = true
                    settings.walkthroughSkipped = false
                    dismissWindow(id: WindowID.setupWalkthrough)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!allVerifiedOrSkipped)
                .accessibilityHint(allVerifiedOrSkipped
                    ? "Marks setup complete and closes the window."
                    : "Disabled. Run the test prompt for each enabled transport to enable this button.")
            } else {
                Button("Next") { goNext() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
                    .accessibilityHint(canAdvance
                        ? "Go to the next step."
                        : "Disabled. Grant Full Disk Access above before continuing.")
            }
        }
    }

    /// Whether the user may leave the current step — see
    /// `WalkthroughStepper.canAdvance`.
    private var canAdvance: Bool { stepper.canAdvance }

    private func goNext() {
        if clampedIndex < steps.count - 1 {
            currentStepIndex = clampedIndex + 1
            announceStep()
        }
    }

    private func goBack() {
        if clampedIndex > 0 {
            currentStepIndex = clampedIndex - 1
            announceStep()
        }
    }

    /// Announce the new step to VoiceOver after a stepper transition. Without
    /// this, VoiceOver's cursor stays on the Next/Back button and a
    /// screen-reader user gets no signal that the whole content region
    /// changed under them.
    private func announceStep() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Step \(clampedIndex + 1) of \(steps.count): \(stepTitle(currentStep))",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: - Helpers

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

    /// Whether "All set" may complete the walkthrough — see
    /// `WalkthroughStepper.allVerifiedOrSkipped`.
    private var allVerifiedOrSkipped: Bool { stepper.allVerifiedOrSkipped }

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
              cachedCodesignIdentifier(record.writerPath)
                == HealthChecks.expectedSigningIdentifier
        else { return }

        switch transport {
        case .imessage: imessageVerified = true
        case .whatsapp: whatsappVerified = true
        }
    }

    /// Memoized wrapper over `HealthChecks.codesignIdentifier(of:)`. Negative
    /// (nil) results are cached too — a missing/invalid binary won't appear
    /// mid-session. See `codesignCache` for why this is both needed and safe.
    private func cachedCodesignIdentifier(_ path: String) -> String? {
        if let cached = codesignCache[path] { return cached }
        let identifier = checks.codesignIdentifier(of: path)
        codesignCache[path] = identifier
        return identifier
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
            let identifier = cachedCodesignIdentifier(path)
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
        // FDA only gates the iMessage transport; skip the probe entirely
        // for WhatsApp-only setups.
        if settings.imessageEnabled {
            chatDbAccess = checks.chatDbAccessState()
        }
    }
}

private struct ProgrammaticCheck: Identifiable {
    let id = UUID()
    let label: String
    /// nil = neutral / informational; true = green; false = red.
    let passing: Bool?
}

/// Pure, value-type model of the setup walkthrough's step sequence and the
/// gating predicates that decide when the user may advance / finish. Extracted
/// from `SetupWalkthroughView` so the FDA gate (the whole point of #17) and the
/// stepper index math have regression coverage that doesn't require driving
/// SwiftUI. Holds no state of its own — construct one per render from the
/// view's live settings + @State. Covered by `WalkthroughStepperTests`.
struct WalkthroughStepper: Equatable {
    var imessageEnabled: Bool
    var whatsappEnabled: Bool
    /// Free index from the view's @State; always read via `clampedIndex`.
    var currentStepIndex: Int
    var chatDbAccess: ChatDbAccessState
    var imessageVerified: Bool?
    var whatsappVerified: Bool?

    /// One screen of the walkthrough. Built dynamically from the enabled
    /// transports so an iMessage-only user never sees a WhatsApp step.
    enum Step: Equatable {
        case installHealth
        case test(Platform)
    }

    var steps: [Step] {
        var result: [Step] = [.installHealth]
        if imessageEnabled { result.append(.test(.imessage)) }
        if whatsappEnabled { result.append(.test(.whatsapp)) }
        return result
    }

    /// `steps` always has ≥1 element, so clamping is total. Guards against a
    /// settings change that shrinks `steps` mid-walkthrough indexing past end.
    var clampedIndex: Int { min(max(currentStepIndex, 0), steps.count - 1) }
    var currentStep: Step { steps[clampedIndex] }
    var isLastStep: Bool { clampedIndex >= steps.count - 1 }

    /// Whether the user may leave the current step. The install-health step
    /// holds the user until Full Disk Access is granted (the gap #17 closes);
    /// test steps are advisory, so the final "All set" — not Next — carries
    /// the verification gate.
    var canAdvance: Bool {
        switch currentStep {
        case .installHealth:
            return !(imessageEnabled && chatDbAccess == .permissionDenied)
        case .test:
            return true
        }
    }

    /// Whether "All set" may complete the walkthrough. Blocks while iMessage
    /// is enabled but FDA is denied, so a user can't mark setup "done" with the
    /// one permission that makes every iMessage tool call fail still missing.
    var allVerifiedOrSkipped: Bool {
        let imsOK = !imessageEnabled || imessageVerified == true
        let waOK = !whatsappEnabled || whatsappVerified == true
        let fdaOK = !imessageEnabled || chatDbAccess != .permissionDenied
        return imsOK && waOK && fdaOK
    }
}

// Platform.displayName is defined in Views/PlatformStyling.swift and reused here.
