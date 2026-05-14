import SwiftUI

// A button that fires only after the user holds it for `duration` seconds.
// Renders an in-button progress ring while held. Releasing before the
// threshold cancels (no fire). The label is "Send", "Sending…" or a
// progress ring depending on state.
//
// Rationale: prevents misclick sends from the menu bar popover. A
// confirmation dialog would be more obvious but introduces a modal that
// fights the popover dismissal behavior. Hold-to-fire is a known iOS/
// macOS pattern (delete-on-iPhone, app removal, etc.) and is unambiguous.
//
// `disabled` short-circuits all gesture handling — e.g. when the parent
// is mid-send and shouldn't accept another tap.
struct HoldToFireButton: View {
  let duration: Double
  let isSending: Bool
  let action: () -> Void

  @State private var holdStart: Date? = nil
  @State private var progress: Double = 0
  @State private var timer: Timer? = nil

  // Tick the progress at ~60fps while held; cheaper than relying on
  // SwiftUI Animation for a property we also need to read for the
  // fire-threshold check.
  private let tickInterval: TimeInterval = 1.0 / 60.0

  var body: some View {
    ZStack {
      // Background pill
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(holdStart != nil ? Color.accentColor.opacity(0.7) : Color.accentColor)
        .frame(width: 90, height: 24)

      // Fill that grows with hold progress
      GeometryReader { proxy in
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.white.opacity(0.25))
          .frame(width: proxy.size.width * progress, height: proxy.size.height)
      }
      .frame(width: 90, height: 24)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .allowsHitTesting(false)

      // Label
      if isSending {
        ProgressView().controlSize(.small).colorInvert()
      } else {
        Text(holdStart == nil ? "Hold to Send" : "Keep holding…")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
      }
    }
    .frame(width: 90, height: 24)
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .opacity(isSending ? 0.85 : 1.0)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !isSending else { return }
          if holdStart == nil {
            holdStart = Date()
            startTimer()
          }
        }
        .onEnded { _ in
          // Released early (before the timer reached threshold and fired
          // the action). Silent cancel; user sees the ring collapse.
          stopTimer()
          holdStart = nil
          progress = 0
        }
    )
    .accessibilityLabel("Send (hold to confirm)")
    .accessibilityAddTraits(.isButton)
  }

  private func startTimer() {
    progress = 0
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
      guard let start = holdStart else { return }
      let elapsed = Date().timeIntervalSince(start)
      let p = min(1.0, elapsed / duration)
      // Hop back to main for SwiftUI state mutation.
      DispatchQueue.main.async {
        progress = p
        if p >= 1.0 {
          // Fire on threshold reach. Mirrors the "slide to confirm"
          // pattern: the user's commitment is the gesture, not the
          // release. Clean up state so a subsequent press starts fresh.
          stopTimer()
          holdStart = nil
          action()
        }
      }
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }
}
