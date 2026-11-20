public import SwiftUI

/// Settings > General > Composer: the send shortcut and Always steer, read by every composer
/// through ``ComposerPreferences``.
public struct ComposerSettingsSection: View {
  @State private var submitWithCommandReturn = ComposerPreferences.commandReturnSends
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
      .settingsSearchAnchor("settings.submit-with-command-return")
      Toggle(isOn: $alwaysSteer) {
        Text("Always steer")
        Text(
          "Send follow-ups straight into the running turn instead of queuing them. The agent "
            + "folds each one into its current work where the harness supports it.")
      }
      .accessibilityIdentifier("settings.always-steer")
      .settingsSearchAnchor("settings.always-steer")
    } header: {
      Text("Composer")
    }
    .commandReturnPreference($submitWithCommandReturn)
  }
}

/// Settings > General > Sessions: automatic session titles. The connection applies it to the
/// requests that start a session's turns (`SessionPreferences` in OmnigentStores, same key).
public struct SessionSettingsSection: View {
  /// The web's key; on unless turned off.
  public static let backgroundTitlesKey = "omnigent:background-session-titles"

  @AppStorage(Self.backgroundTitlesKey) private var backgroundTitles = true

  /// Creates the section.
  public init() {}

  /// The section.
  public var body: some View {
    Section {
      Toggle(isOn: $backgroundTitles) {
        Text("Automatically name new sessions")
        Text(
          "Generate a concise title in the background after the first message. Turn this off "
            + "to keep the default session name.")
      }
      .accessibilityIdentifier("settings.background-session-titles")
      .settingsSearchAnchor("settings.background-session-titles")
    } header: {
      Text("Sessions")
    }
  }
}

/// Settings > General > Projects: whether a project opens its board of sessions (the web's
/// Kanban board views), where the server offers boards.
public struct ProjectBoardSettingsSection: View {
  @AppStorage(InterfacePreferences.projectBoardKey) private var opensBoard = true

  /// Creates the section.
  public init() {}

  /// The section.
  public var body: some View {
    Section {
      Toggle(isOn: $opensBoard) {
        Text("Kanban board views")
        Text("Monitor a project's agents in one view and respond the moment one needs you.")
      }
      .accessibilityIdentifier("settings.project-kanban-board")
      .settingsSearchAnchor("settings.project-kanban-board")
    } header: {
      Text("Projects")
    }
  }
}
