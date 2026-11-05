public import Foundation

/// Device preferences for links, sub-agents, the new-session picker and the right panel, under
/// the web's keys. Settings writes them; the consumers read them with `@AppStorage` or
/// ``read(_:)``.
nonisolated public enum InterfacePreferences {
  /// `omnigent:open-links-in-app`: web links from chat open in an in-app browser tab.
  public static let openLinksInAppKey = "omnigent:open-links-in-app"
  /// `omnigent:open-subagents-in-panel`: a sub-agent's chat opens beside the chat.
  public static let openSubagentsInPanelKey = "omnigent:open-subagents-in-panel"
  /// `omnigent:hide-unconfigured-harnesses`: the new-session picker hides harnesses that are
  /// not set up on the selected host.
  public static let hideUnconfiguredHarnessesKey = "omnigent:hide-unconfigured-harnesses"
  /// `omnigent:default-workspace-panel`: whether a chat opens with the right panel shown.
  public static let workspacePanelKey = "omnigent:default-workspace-panel"
  /// `omnigent:default-workspace-tab`: the right panel's first tab.
  public static let defaultWorkspaceTabKey = "omnigent:default-workspace-tab"

  /// A Boolean preference; unset reads as `false`, as on the web.
  /// - Parameters:
  ///   - key: The key.
  ///   - defaults: The store.
  /// - Returns: The value.
  public static func read(_ key: String, defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: key)
  }
}

/// Whether a chat opens with the right panel shown (`open`) or hidden (`collapsed`, the web's
/// default).
nonisolated public enum WorkspacePanelDefault: String, Hashable, Sendable, CaseIterable,
  Identifiable
{
  /// Shown.
  case open
  /// Hidden.
  case collapsed

  /// The value itself.
  public var id: Self { self }

  /// The label.
  public var title: String {
    switch self {
    case .open: "Open"
    case .collapsed: "Collapsed"
    }
  }

  /// The stored value, or the default for a missing or unknown one.
  /// - Parameter defaults: The store.
  /// - Returns: The value.
  public static func stored(in defaults: UserDefaults = .standard) -> Self {
    defaults.string(forKey: InterfacePreferences.workspacePanelKey).flatMap(Self.init) ?? .collapsed
  }
}

/// The right panel's first tab, under the web's values (`files`, `changes`, `github`,
/// `subagents`).
nonisolated public enum DefaultWorkspaceTab: String, Hashable, Sendable, CaseIterable,
  Identifiable
{
  /// Files.
  case files
  /// Changes.
  case changes
  /// Pull requests.
  case github
  /// Agents.
  case subagents

  /// The value itself.
  public var id: Self { self }

  /// The inspector tab it opens.
  public var inspectorTab: InspectorTab {
    switch self {
    case .files: .files
    case .changes: .changes
    case .github: .pullRequests
    case .subagents: .agents
    }
  }

  /// The label.
  public var title: String { inspectorTab.title }

  /// The stored value, or Files for a missing or unknown one.
  /// - Parameter defaults: The store.
  /// - Returns: The value.
  public static func stored(in defaults: UserDefaults = .standard) -> Self {
    defaults.string(forKey: InterfacePreferences.defaultWorkspaceTabKey).flatMap(Self.init)
      ?? .files
  }
}
