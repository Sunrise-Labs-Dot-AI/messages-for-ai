import SwiftUI

// Orange "Full Disk Access is missing" banner shown above the draft list
// when `FDAProbe` reports `.denied`. The two-button action surface ("Open
// Settings" + "Recheck") matches the menu bar app's existing button
// styling pattern from DraftRowView's Send/Discard pair. We deliberately
// keep the banner inline (not a sheet) so users see it the moment they
// open the popover, in the same visual frame as the drafts they came to
// review.
struct FDABanner: View {
  @Binding var state: FDAState

  var body: some View {
    if state == .denied {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "lock.shield")
            .foregroundStyle(.orange)
          Text("Full Disk Access is missing")
            .font(.subheadline.weight(.semibold))
        }
        Text(
          "Contact names and thread context won't load until you grant Full " +
          "Disk Access to the imessage-mcp binary (~/bin/imessage-mcp). " +
          "After granting, quit and reopen Claude Desktop so the MCP child " +
          "process picks up the new permission."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Button("Open Settings") { FDAProbe.openFullDiskAccessPane() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          Button("Recheck") { state = FDAProbe.probe() }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.orange.opacity(0.12))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }
}
