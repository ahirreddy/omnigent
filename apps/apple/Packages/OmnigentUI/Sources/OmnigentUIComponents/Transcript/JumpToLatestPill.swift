import SwiftUI

/// "Jump to latest", with a dot when output arrived while the user was reading.
struct JumpToLatestPill: View {
  let pill: TranscriptFollow.Pill
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Spacing.small) {
        if pill.hasUnseenOutput {
          Circle().fill(Theme.running).frame(width: 6, height: 6).accessibilityHidden(true)
        }
        Label(pill.title, systemImage: "arrow.down")
      }
      .font(Theme.Typography.label)
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
      .frame(minHeight: Theme.Control.target)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassSurface(in: Capsule(), isInteractive: true)
    .glassTransition()
    .accessibilityLabel("Jump to latest message")
    .accessibilityValue(pill.hasUnseenOutput ? "New output" : "")
    .accessibilityIdentifier("jump-to-latest")
  }
}
