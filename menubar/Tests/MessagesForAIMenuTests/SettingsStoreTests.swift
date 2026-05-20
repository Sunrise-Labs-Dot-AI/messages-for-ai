import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Covers SettingsStore's v1→v2 migration, walkthrough field defaults
/// (the v0.3.2 additions), and the daemon-mirror behavior.
///
/// All cases use a tmpdir-backed home so tests never touch the developer's
/// real ~/.messages-mcp/ or ~/.whatsapp-mcp/.
@MainActor
final class SettingsStoreTests: XCTestCase {
    var tmpHome: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("messages-mcp-settings-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tmpHome = base
    }

    override func tearDown() {
        if let tmpHome = tmpHome {
            try? FileManager.default.removeItem(at: tmpHome)
        }
        tmpHome = nil
        super.tearDown()
    }

    // MARK: - Fresh-install defaults

    func test_freshInstall_writesV2Schema() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store.imessageEnabled)
        XCTAssertFalse(store.whatsappEnabled)
        XCTAssertTrue(store.requireApproval)
        XCTAssertFalse(store.firstRunComplete)
        XCTAssertFalse(store.walkthroughComplete)
        XCTAssertFalse(store.walkthroughSkipped)

        // Init wrote the canonical v2 schema back to disk.
        let file = tmpHome.appendingPathComponent(".messages-mcp/settings.json")
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["schema_version"] as? Int, 2)
        XCTAssertEqual(json["first_run_complete"] as? Bool, false)
        XCTAssertEqual(json["walkthrough_complete"] as? Bool, false)
        XCTAssertEqual(json["walkthrough_skipped"] as? Bool, false)
    }

    // MARK: - v1 → v2 migration

    func test_v1Migration_setsFirstRunCompleteAndDefaults() throws {
        // Seed a v1 settings.json — no schema_version key, only flat
        // require_approval. This is what existing v0.2.x users would
        // have on disk pre-upgrade.
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let v1Doc: [String: Any] = ["require_approval": false]
        try JSONSerialization.data(withJSONObject: v1Doc).write(to: file)

        let store = SettingsStore(homeOverride: tmpHome)

        // v1 reader assumes the user has already used the app.
        XCTAssertTrue(store.firstRunComplete)
        XCTAssertTrue(store.imessageEnabled)
        XCTAssertFalse(store.whatsappEnabled)
        XCTAssertFalse(store.requireApproval, "v1 require_approval value preserved")
        // Walkthrough fields default to false — this triggers the
        // upgrade-time walkthrough auto-open in DraftListView.
        XCTAssertFalse(store.walkthroughComplete)
        XCTAssertFalse(store.walkthroughSkipped)
    }

    // MARK: - v2 read path — walkthrough field defaults

    func test_v2Read_absentWalkthroughFields_defaultToFalse() throws {
        // v0.3.0/v0.3.1 settings.json — schema_version=2 but no
        // walkthrough_complete or walkthrough_skipped keys.
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let v2NoWalkthrough: [String: Any] = [
            "schema_version": 2,
            "first_run_complete": true,
            "require_approval": true,
            "transports": [
                "imessage": ["enabled": true, "require_approval": true],
                "whatsapp": ["enabled": true, "require_approval": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: v2NoWalkthrough).write(to: file)

        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store.firstRunComplete, "existing user, onboarding done")
        XCTAssertTrue(store.whatsappEnabled)
        // Both new fields absent in on-disk file → default false → walkthrough
        // fires once on next popover render. This is the resolved Open Q #1
        // from the v0.3.2 plan.
        XCTAssertFalse(store.walkthroughComplete)
        XCTAssertFalse(store.walkthroughSkipped)
    }

    func test_v2Read_preservesWalkthroughComplete() throws {
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let doc: [String: Any] = [
            "schema_version": 2,
            "first_run_complete": true,
            "walkthrough_complete": true,
            "walkthrough_skipped": false,
            "require_approval": true,
            "transports": [
                "imessage": ["enabled": true, "require_approval": true],
                "whatsapp": ["enabled": false, "require_approval": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: file)

        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store.walkthroughComplete)
        XCTAssertFalse(store.walkthroughSkipped)
    }

    // MARK: - Persistence round-trip

    func test_walkthroughCompletePersists() throws {
        let store1 = SettingsStore(homeOverride: tmpHome)
        XCTAssertFalse(store1.walkthroughComplete)
        store1.walkthroughComplete = true

        // New instance reads the persisted value.
        let store2 = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store2.walkthroughComplete)
    }

    func test_walkthroughSkippedPersists() throws {
        let store1 = SettingsStore(homeOverride: tmpHome)
        store1.walkthroughSkipped = true

        let store2 = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store2.walkthroughSkipped)
    }

    // MARK: - Mirror to ~/.whatsapp-mcp/settings.json

    func test_whatsappRequireApprovalMirrorsToDaemonFile() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        store.whatsappRequireApproval = false

        let daemonFile = tmpHome.appendingPathComponent(".whatsapp-mcp/settings.json")
        let data = try Data(contentsOf: daemonFile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["require_approval"] as? Bool, false)
    }

    func test_whatsappMirrorPreservesUnrelatedKeys() throws {
        // Daemon's own file has rate-limit knobs we mustn't clobber.
        let daemonDir = tmpHome.appendingPathComponent(".whatsapp-mcp")
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        let daemonFile = daemonDir.appendingPathComponent("settings.json")
        let preexisting: [String: Any] = [
            "require_approval": true,
            "daily_cap": 200,
            "min_staged_age_ms": 30000,
            "draft_ttl_days": 7,
        ]
        try JSONSerialization.data(withJSONObject: preexisting).write(to: daemonFile)

        let store = SettingsStore(homeOverride: tmpHome)
        store.whatsappRequireApproval = false

        let data = try Data(contentsOf: daemonFile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["require_approval"] as? Bool, false)
        XCTAssertEqual(json["daily_cap"] as? Int, 200)
        XCTAssertEqual(json["min_staged_age_ms"] as? Int, 30000)
        XCTAssertEqual(json["draft_ttl_days"] as? Int, 7)
    }
}
