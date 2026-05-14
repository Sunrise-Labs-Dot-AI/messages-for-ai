import SwiftUI

// A button that fires only after the user holds it for `duration` seconds.
// Visible progress fills the button background during the hold. Releasing
// early cancels silently; reaching the threshold fires `action`.
//
// Implementation notes (this is the second cut — first used NSTimer and
// didn't fire reliably inside SwiftUI gesture closures):
//
// - Uses `Task.sleep(for:)` for the timeout, which is the modern Swift
//   structured-concurrency pattern. Cancelling the Task on release stops
//   the in-flight sleep cleanly.
// - Progress is animated by SwiftUI's implicit animation around the
//   `progress` state — when we set it to 1.0 with a `.linear(duration:)`
//   animation, SwiftUI interpolates the visual fill over the hold time.
//   When we set it back to 0 (on cancel), SwiftUI snaps back.
// - DragGesture with `minimumDistance: 0` doubles as a "press detector":
//   onChanged fires on touch, onEnded fires on release. Robust against
//   the no-movement case where LongPressGesture alone is ambiguous.
struct HoldToFireButton: View {
  let duration: Double
  let isSending: Bool
  let action: () -> Void

  @State private var holding = false
  @State private var progress: Double = 0
  @State private var fireTask: Task<Void, Never>? = nil

  var body: some View {
    ZStack {
      // Background pill
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.accentColor)
        .frame(width: 110, height: 26)

      // Progress fill — animated via SwiftUI implicit animation
      GeometryReader { proxy in
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.white.opacity(0.28))
          .frame(width: proxy.size.width * progress, height: proxy.size.height)
      }
      .frame(width: 110, height: 26)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .allowsHitTesting(false)

      // Label
      if isSending {
        ProgressView().controlSize(.small).colorInvert()
      } else {
        Text(holding ? "Keep holding…" : "Hold to Send")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
      }
    }
    .frame(width: 110, height: 26)
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .opacity(isSending ? 0.85 : 1.0)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !isSending, !holding else { return }
          beginHold()
        }
        .onEnded { _ in
          cancelHold()
        }
    )
    .accessibilityLabel("Send (press and hold to confirm)")
    .accessibilityAddTraits(.isButton)
  }

  private func beginHold() {
    holding = true
    // Animate the fill linearly over the hold duration.
    withAnimation(.linear(duration: duration)) {
      progress = 1.0
    }
    // Schedule the actual fire.
    fireTask?.cancel()
    fireTask = Task { @MainActor in
      let nanos = UInt64(duration * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      guard !Task.isCancelled else { return }
      // Threshold reached AND not cancelled by release. Fire.
      holding = false
      progress = 0
      action()
    }
  }

  private func cancelHold() {
    fireTask?.cancel()
    fireTask = nil
    holding = false
    // Snap the ring back to empty (no animation, just reset).
    withAnimation(.easeOut(duration: 0.12)) {
      progress = 0
    }
  }
}
