import XCTest
@testable import MessagesForAIMenu

/// Regression coverage for the setup-walkthrough gating logic extracted into
/// `WalkthroughStepper`. These predicates are the entire substance of the
/// v0.3.3 FDA gate (#17) and the stepper index math — previously untested
/// because they were SwiftUI-view-private.
final class WalkthroughStepperTests: XCTestCase {

    /// Builder with sane defaults; override only the fields a test cares about.
    private func makeStepper(
        imessage: Bool = true,
        whatsapp: Bool = true,
        index: Int = 0,
        fda: ChatDbAccessState = .ok,
        imessageVerified: Bool? = nil,
        whatsappVerified: Bool? = nil
    ) -> WalkthroughStepper {
        WalkthroughStepper(
            imessageEnabled: imessage,
            whatsappEnabled: whatsapp,
            currentStepIndex: index,
            chatDbAccess: fda,
            imessageVerified: imessageVerified,
            whatsappVerified: whatsappVerified
        )
    }

    // MARK: - steps construction

    func test_steps_bothTransports_hasInstallPlusTwoTests() {
        let s = makeStepper(imessage: true, whatsapp: true)
        XCTAssertEqual(s.steps, [.installHealth, .test(.imessage), .test(.whatsapp)])
    }

    func test_steps_imessageOnly() {
        let s = makeStepper(imessage: true, whatsapp: false)
        XCTAssertEqual(s.steps, [.installHealth, .test(.imessage)])
    }

    func test_steps_whatsappOnly() {
        let s = makeStepper(imessage: false, whatsapp: true)
        XCTAssertEqual(s.steps, [.installHealth, .test(.whatsapp)])
    }

    func test_steps_neitherTransport_stillHasInstallStep() {
        let s = makeStepper(imessage: false, whatsapp: false)
        XCTAssertEqual(s.steps, [.installHealth])
    }

    // MARK: - clampedIndex / currentStep / isLastStep

    func test_clampedIndex_clampsAboveRange() {
        // Single step (neither transport) + a wild index → clamps to 0.
        let s = makeStepper(imessage: false, whatsapp: false, index: 99)
        XCTAssertEqual(s.clampedIndex, 0)
        XCTAssertEqual(s.currentStep, .installHealth)
    }

    func test_clampedIndex_clampsNegative() {
        let s = makeStepper(imessage: true, whatsapp: true, index: -5)
        XCTAssertEqual(s.clampedIndex, 0)
    }

    func test_clampedIndex_passesThroughInRange() {
        let s = makeStepper(imessage: true, whatsapp: true, index: 2)
        XCTAssertEqual(s.clampedIndex, 2)
        XCTAssertEqual(s.currentStep, .test(.whatsapp))
        XCTAssertTrue(s.isLastStep)
    }

    func test_isLastStep_falseOnFirstOfMany() {
        let s = makeStepper(imessage: true, whatsapp: true, index: 0)
        XCTAssertFalse(s.isLastStep)
    }

    // MARK: - canAdvance (the install-health FDA gate)

    func test_canAdvance_blockedWhenImessageEnabledAndFdaDenied() {
        let s = makeStepper(imessage: true, index: 0, fda: .permissionDenied)
        XCTAssertFalse(s.canAdvance, "FDA-denied must hold the user on the install step")
    }

    func test_canAdvance_allowedWhenFdaGranted() {
        XCTAssertTrue(makeStepper(imessage: true, index: 0, fda: .ok).canAdvance)
    }

    func test_canAdvance_allowedForNotFoundAndUnknown() {
        // Ambiguous states are non-blocking by design (Messages never set up,
        // or an unexpected errno) — they must not strand the user.
        XCTAssertTrue(makeStepper(imessage: true, index: 0, fda: .notFound).canAdvance)
        XCTAssertTrue(makeStepper(imessage: true, index: 0, fda: .unknown).canAdvance)
    }

    func test_canAdvance_allowedWhenImessageDisabledEvenIfFdaDenied() {
        // No iMessage transport → FDA is irrelevant to advancing.
        let s = makeStepper(imessage: false, whatsapp: true, index: 0, fda: .permissionDenied)
        XCTAssertTrue(s.canAdvance)
    }

    func test_canAdvance_testStepsAreAdvisory_notBlockedByFda() {
        // On a test step (index 1), Next is never blocked — the final
        // "All set" carries the verification + FDA gate instead.
        let s = makeStepper(imessage: true, whatsapp: false, index: 1, fda: .permissionDenied)
        XCTAssertEqual(s.currentStep, .test(.imessage))
        XCTAssertTrue(s.canAdvance)
    }

    // MARK: - allVerifiedOrSkipped (the "All set" completion gate)

    func test_allVerified_trueWhenImessageVerifiedAndFdaOk() {
        let s = makeStepper(imessage: true, whatsapp: false, fda: .ok, imessageVerified: true)
        XCTAssertTrue(s.allVerifiedOrSkipped)
    }

    func test_allVerified_falseWhenImessageNotVerified() {
        let s = makeStepper(imessage: true, whatsapp: false, fda: .ok, imessageVerified: nil)
        XCTAssertFalse(s.allVerifiedOrSkipped)
    }

    func test_allVerified_blockedByFdaDeniedEvenIfVerified() {
        // The core #17 invariant: a green test does NOT let you finish while
        // FDA is denied, because every real iMessage tool call would still fail.
        let s = makeStepper(imessage: true, whatsapp: false, fda: .permissionDenied, imessageVerified: true)
        XCTAssertFalse(s.allVerifiedOrSkipped)
    }

    func test_allVerified_bothTransports_requiresBoth() {
        let onlyOne = makeStepper(imessage: true, whatsapp: true, fda: .ok,
                                  imessageVerified: true, whatsappVerified: nil)
        XCTAssertFalse(onlyOne.allVerifiedOrSkipped)

        let both = makeStepper(imessage: true, whatsapp: true, fda: .ok,
                               imessageVerified: true, whatsappVerified: true)
        XCTAssertTrue(both.allVerifiedOrSkipped)
    }

    func test_allVerified_whatsappOnly_ignoresFda() {
        // WhatsApp reads its own non-TCC-protected files; FDA never gates it.
        let s = makeStepper(imessage: false, whatsapp: true, fda: .permissionDenied,
                            whatsappVerified: true)
        XCTAssertTrue(s.allVerifiedOrSkipped)
    }

    func test_allVerified_neitherTransport_trivallyTrue() {
        XCTAssertTrue(makeStepper(imessage: false, whatsapp: false).allVerifiedOrSkipped)
    }
}
