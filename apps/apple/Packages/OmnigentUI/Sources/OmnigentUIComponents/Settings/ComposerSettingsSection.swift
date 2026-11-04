public import SwiftUI

/// Settings > General > Composer: the send shortcut and Always steer, read by every composer
/// through ``ComposerPreferences``.
public struct ComposerSettingsSection: View {
  @AppStorage(ComposerPreferences.submitWithCommandReturnKey) private var submitWithCommandReturn =
    false
  @AppStorage(ComposerPreferences.alwaysSteerKey) private var alwaysSteer = true

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
      Toggle(isOn: $alwaysSteer) {
        Text("Always steer")
        Text(
          "Send follow-ups straight into the running turn instead of queuing them. The agent "
            + "folds each one into its current work where the harness supports it.")
      }
      .accessibilityIdentifier("settings.always-steer")
    } header: {
      Text("Composer")
    }
  }
}
