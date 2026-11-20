import SwiftUI

/// The share sheet's notice that an automation keeps the session's shares (the web's
/// `AutomationCallout`): each of its runs, and each change to its sharing, replaces them. It
/// only informs; nothing in the sheet turns off.
struct ShareManagedNotice: View {
  let automation: String
  let open: (@MainActor () -> Void)?
  /// Closes the sheet before the automation opens.
  let close: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Label("Sharing is managed by an automation", systemImage: "exclamationmark.triangle.fill")
        .font(.callout.weight(.semibold))
        .foregroundStyle(Theme.warning)
      Text(
        "Shares added or removed here are replaced with the automation\u{2019}s list on each run of \u{201C}\(automation)\u{201D} and whenever its sharing changes. General access isn\u{2019}t affected."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let open {
        Button("Open \u{201C}\(automation)\u{201D}") {
          close()
          open()
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("share-managed-open")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("share-managed-by-automation")
  }
}
