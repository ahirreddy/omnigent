import SwiftUI

/// The session's Browser design tool requests that aren't sent yet, above the field like its
/// queued messages (web `DesignOutboxStrip`): each says where it stands, a failure says why,
/// with Retry and Remove.
struct DesignRequestStrip: View {
  let rows: [DesignRequestRow]
  let actions: DesignRequestActions?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      ForEach(rows) { row in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
          Image(systemName: row.tool.systemImage)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            Text(row.label).font(.callout).lineLimit(1)
            stateLabel(row.state)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          ViewThatFits(in: .horizontal) {
            buttons(row).labelStyle(.titleAndIcon)
            buttons(row).labelStyle(.iconOnly)
          }
          .fixedSize()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .tint(.secondary)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .cardSurface(cornerRadius: Theme.Radius.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("design-request-\(row.id.uuidString)")
      }
    }
  }

  @ViewBuilder
  private func buttons(_ row: DesignRequestRow) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      if let actions, case .failed(_, true) = row.state {
        Button("Retry", systemImage: "arrow.clockwise") { actions.retry(row.id) }
          .help("Send this request again")
          .accessibilityIdentifier("design-request-retry")
      }
      if let actions, row.state != .sending, row.state != .slow {
        Button("Remove", systemImage: "xmark") { actions.remove(row.id) }
          .help("Remove this request")
          .accessibilityIdentifier("design-request-remove")
      }
    }
  }

  /// The web's note for a send the server is slow to answer.
  static let slowNote = "The server hasn\u{2019}t answered yet; it\u{2019}s still trying"

  @ViewBuilder
  private func stateLabel(_ state: DesignRequestRow.State) -> some View {
    switch state {
    case .waiting:
      Text("Waiting for the agent").font(.caption).foregroundStyle(.secondary)
    case .sending, .slow:
      HStack(spacing: Theme.Spacing.extraSmall) {
        ProgressView().controlSize(.mini)
        Text(state == .slow ? Self.slowNote : "Sending\u{2026}")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    case .failed(let message, _):
      Label(message, systemImage: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
