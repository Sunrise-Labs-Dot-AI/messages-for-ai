import SwiftUI

struct DraftRowView: View {
  let draft: Draft
  @EnvironmentObject var store: DraftStore
  @State private var sending = false
  @State private var lastError: String?
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      bodyBubble
      if let lastError {
        Text(lastError)
          .font(.caption)
          .foregroundStyle(.red)
      }
      actions
      detailsDisclosure
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Sections

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(draft.to_handle)
        .font(.system(.subheadline, design: .rounded).weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Text(relativeStagedAt)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(absoluteStagedAt)
    }
  }

  // The draft body. Always fully visible — no lineLimit. SwiftUI sizes
  // the parent row to fit this text.
  private var bodyBubble: some View {
    Text(draft.body)
      .font(.body)
      .textSelection(.enabled)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
      )
  }

  private var actions: some View {
    HStack(spacing: 8) {
      Button(action: { Task { await send() } }) {
        if sending {
          ProgressView().controlSize(.small).frame(width: 50)
        } else {
          Text("Send").frame(minWidth: 50)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.regular)
      .disabled(sending)
      .keyboardShortcut(.return, modifiers: [.command])

      Button("Discard") {
        do { try store.discard(id: draft.id) }
        catch { lastError = "discard failed: \(error.localizedDescription)" }
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .disabled(sending)

      Spacer()

      if let service = draft.send_service {
        Label(service, systemImage: service == "iMessage" ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // Disclosure-style "Details" toggle. Collapsed by default so the row
  // is compact for the glance-decide-send case. Expanded reveals
  // source, absolute time, and thread context bubbles.
  private var detailsDisclosure: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(.caption2)
          Text(expanded ? "Hide details" : "Details")
            .font(.caption)
        }
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)

      if expanded {
        Divider()
        detailsContent
      }
    }
  }

  @ViewBuilder
  private var detailsContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Source label
      if let source = draft.source, !source.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "person.crop.circle.dashed")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Text(source)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      // Absolute staged time
      HStack(spacing: 6) {
        Image(systemName: "clock")
          .font(.caption)
          .foregroundStyle(.tertiary)
        Text("Staged \(absoluteStagedAt)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // Thread context bubbles (when present) or a diagnostic-aware
      // "why is context empty" message (when absent).
      if let ctx = draft.context_messages, !ctx.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
          Text("Recent thread context")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          contextBubbles(ctx)
        }
      } else {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
          Text("Recent thread context")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Text(contextEmptyReason)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // Human-readable explanation of why context_messages is null/empty.
  // Pulls from the structured `context_diagnostic` when present; falls
  // back to a generic message for older drafts.
  private var contextEmptyReason: String {
    if let diag = draft.context_diagnostic {
      return diag.humanExplanation
    }
    return "No prior thread context attached (this draft predates the context-lookup feature)."
  }

  // Suppress the sender label for consecutive incoming messages from
  // the same handle — matches Apple's Messages.app grouping.
  @ViewBuilder
  private func contextBubbles(_ messages: [ContextMessage]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(messages.enumerated()), id: \.offset) { idx, msg in
        let prev = idx > 0 ? messages[idx - 1] : nil
        let showSender = msg.from_me ? false : (prev?.sender_handle != msg.sender_handle)
        ContextBubbleView(message: msg, showSender: showSender)
      }
    }
  }

  // MARK: - Helpers

  private var relativeStagedAt: String {
    guard let date = draft.stagedDate else { return draft.staged_at }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  private var absoluteStagedAt: String {
    guard let date = draft.stagedDate else { return draft.staged_at }
    let formatter = DateFormatter()
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  private func send() async {
    sending = true
    lastError = nil
    let result = await DraftSender.send(toHandle: draft.to_handle, body: draft.body)
    if result.ok, let service = result.service {
      do {
        try store.markSent(id: draft.id, sentAt: Date(), service: service)
      } catch {
        lastError = "sent ok but failed to update draft file: \(error.localizedDescription)"
      }
    } else {
      lastError = result.error ?? "unknown error"
    }
    sending = false
  }
}
