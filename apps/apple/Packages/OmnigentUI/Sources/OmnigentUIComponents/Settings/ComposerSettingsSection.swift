public import SwiftUI

/// Settings > General > Composer: the send shortcut, read by every composer through
/// ``ComposerPreferences/submitWithCommandReturnKey``.
public struct ComposerSettingsSection: View {
  @AppStorage(ComposerPreferences.submitWithCommandReturnKey) private var submitWithCommandReturn =
    false

  /// Creates the section.
  public init() {}

  /// The section.
  public var body: some View {
    Section {
      Toggle(isOn: $submitWithCommandReturn) {
        Text("Send with Command-Return")
        Text(
          submitWithCommandReturn
            ? "Return inserts a new line; Command-Return sends."
            : "Return sends; Shift-Return or Option-Return inserts a new line.")
      }
      .accessibilityIdentifier("settings.submit-with-command-return")
    } header: {
      Text("Composer")
    }
  }
}
