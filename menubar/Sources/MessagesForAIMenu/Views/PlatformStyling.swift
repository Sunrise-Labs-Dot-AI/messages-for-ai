import SwiftUI

// Per-platform display attributes — colors, symbols, labels — kept in
// one file so the menubar's WhatsApp green doesn't get sprinkled across
// every view that paints a bubble or a badge. Adding a sibling platform
// (Signal, Slack, …) is a one-extension change here plus an enum case
// in Draft.swift.
//
// Color values match the platforms' canonical brand palettes:
// - iMessage: macOS `.accentColor` (system blue / user-themed accent —
//   the same color iMessage.app paints outgoing bubbles in)
// - WhatsApp: #25D366 — WhatsApp's official primary green
extension Platform {
  /// Color used for badges and the from-me bubble fill.
  var accentColor: Color {
    switch self {
    case .imessage: return .accentColor
    case .whatsapp: return Color(red: 0x25 / 255.0, green: 0xD3 / 255.0, blue: 0x66 / 255.0)
    }
  }

  /// Human-readable label for badges and accessibility text.
  var displayName: String {
    switch self {
    case .imessage: return "iMessage"
    case .whatsapp: return "WhatsApp"
    }
  }

  /// SF Symbol name for the platform badge. iMessage uses the system
  /// message symbol; WhatsApp falls back to a generic filled circle
  /// (the official WhatsApp logo isn't an SF Symbol). A bundled asset
  /// could replace `circle.fill` if/when we add brand artwork.
  var sfSymbol: String {
    switch self {
    case .imessage: return "message.fill"
    case .whatsapp: return "circle.fill"
    }
  }
}

/// Small inline pill that labels a draft's transport. Rendered with a
/// pale tint of the platform's accent color and the platform's symbol +
/// name. Use sparingly — by default we only show this for non-iMessage
/// drafts (iMessage is the unmarked default, matching Apple's UI of
/// labeling only non-iMessage threads with "SMS").
struct PlatformBadge: View {
  let platform: Platform

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: platform.sfSymbol)
        .font(.caption2)
      Text(platform.displayName)
        .font(.caption2.weight(.medium))
    }
    .foregroundStyle(platform.accentColor)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      Capsule()
        .fill(platform.accentColor.opacity(0.12))
    )
    .accessibilityLabel("\(platform.displayName) draft")
  }
}
