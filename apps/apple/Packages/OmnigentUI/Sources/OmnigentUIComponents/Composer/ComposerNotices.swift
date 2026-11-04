import SwiftUI

/// The output of a local command (`/help`, a usage line): monospaced, selectable, dismissable.
struct CommandNoticeView: View {
  let text: String
  let dismiss: (@MainActor () -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      Text(text)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let dismiss {
        Button("Dismiss", systemImage: "xmark", action: dismiss)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Dismiss")
          .accessibilityIdentifier("composer-command-notice-dismiss")
      }
    }
    .padding(Theme.Spacing.medium)
    .cardSurface(cornerRadius: Theme.Radius.medium)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-command-notice")
  }
}

/// The stream's state under the composer while it is not live, with one-click Reconnect (the
/// web's connection indicator).
struct ConnectionNoticeRow: View {
  let notice: ComposerConnectionNotice
  let reconnect: (@MainActor () -> Void)?

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      if notice.isFailure {
        Image(systemName: "wifi.slash")
          .foregroundStyle(Theme.failure)
          .accessibilityHidden(true)
      } else {
        ProgressView().controlSize(.small)
      }
      Text(notice.message)
        .font(.callout)
        .foregroundStyle(
          notice.isFailure ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.secondary)
        )
        .lineLimit(2)
      if let reconnect {
        Button("Reconnect", action: reconnect)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("composer-reconnect")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, Theme.Spacing.medium)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("composer-connection")
  }
}
