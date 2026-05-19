import SwiftUI

// Renders one message in Messages.app-style: outgoing (from_me) on the
// right with a platform-accented bubble, incoming on the left with a
// gray bubble. The from-me bubble color tracks the draft's platform —
// blue for iMessage, green for WhatsApp — matching each platform's
// native UI. Incoming bubbles stay neutral gray on both platforms.
//
// `showSender` controls whether the sender's name appears above an
// incoming bubble — used by the list view to suppress the label for
// consecutive messages from the same sender (matches Apple's grouping).
//
// `platform` is the parent draft's `effectivePlatform`. It exists ONLY
// to drive the from-me bubble color; incoming bubble color and layout
// are platform-independent. Callers pass `.imessage` to get the legacy
// behavior unchanged (this is also the value Draft.swift's
// `effectivePlatform` returns for legacy drafts without the field).
struct ContextBubbleView: View {
  let message: ContextMessage
  let showSender: Bool
  let platform: Platform

  var body: some View {
    HStack(alignment: .bottom, spacing: 0) {
      if message.from_me { Spacer(minLength: 30) }

      VStack(alignment: message.from_me ? .trailing : .leading, spacing: 2) {
        if !message.from_me, showSender {
          Text(message.displayName)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
        }

        Text(message.body ?? "(empty)")
          .font(.system(size: 12))
          .foregroundStyle(message.from_me ? .white : .primary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(message.from_me ? platform.accentColor : Color(nsColor: .quaternaryLabelColor))
          )
          .textSelection(.enabled)

        if let date = message.sentDate {
          Text(timestamp(date))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
        }
      }

      if !message.from_me { Spacer(minLength: 30) }
    }
  }

  // Short timestamp: "3:08 PM" if today, otherwise "Mon 3:08 PM".
  private func timestamp(_ date: Date) -> String {
    let cal = Calendar.current
    let formatter = DateFormatter()
    if cal.isDateInToday(date) {
      formatter.timeStyle = .short
      formatter.dateStyle = .none
    } else {
      formatter.dateFormat = "E h:mm a"
    }
    return formatter.string(from: date)
  }
}
