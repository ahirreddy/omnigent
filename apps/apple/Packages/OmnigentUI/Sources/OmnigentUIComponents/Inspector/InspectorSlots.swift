public import SwiftUI

/// The right panel's fixed tabs: the web's Files, Changes, Pull Requests and Agents, the
/// native Info tab with the session facts, and content Search when the server offers it.
/// Terminals, browsers and side chats open as window tabs, not panel tabs.
nonisolated public enum InspectorTab: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// Files.
  case files
  /// Changes.
  case changes
  /// Pull requests.
  case pullRequests
  /// Agents (sub-agents).
  case agents
  /// Session facts (native).
  case info
  /// Content search over the session workspace.
  case search

  /// The tab itself.
  public var id: Self { self }

  /// The tabs the panel shows, in order; Search only when the server offers it.
  /// - Parameter hasSearch: The panel has content search.
  /// - Returns: The tabs.
  static func shown(hasSearch: Bool) -> [Self] {
    allCases.filter { $0 != .search || hasSearch }
  }

  /// The label.
  public var title: String {
    switch self {
    case .files: "Files"
    case .changes: "Changes"
    case .pullRequests: "Pull Requests"
    case .agents: "Agents"
    case .info: "Info"
    case .search: "Search"
    }
  }

  /// A one-word label for the tab picker when the panel is wide enough to show labels.
  public var shortTitle: String {
    switch self {
    case .pullRequests: "PRs"
    default: title
    }
  }

  /// The SF Symbol.
  public var systemImage: String {
    switch self {
    case .files: "folder"
    case .changes: "plus.forwardslash.minus"
    case .pullRequests: "arrow.triangle.pull"
    case .agents: "cpu"
    case .info: "info.circle"
    case .search: "magnifyingglass"
    }
  }
}

/// A file or diff open as a tab in the right panel.
nonisolated public struct InspectorDocumentTab: Hashable, Sendable, Identifiable {
  /// Stable id.
  public var id: String
  /// The file name.
  public var title: String
  /// The full path, for the tooltip.
  public var detail: String
  /// The SF Symbol.
  public var systemImage: String

  /// Creates a tab.
  /// - Parameters:
  ///   - id: Id.
  ///   - title: File name.
  ///   - detail: Full path.
  ///   - systemImage: Symbol.
  public init(id: String, title: String, detail: String, systemImage: String) {
    self.id = id
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
  }
}

/// The files and diffs open as tabs in the right panel, as the web's rail opens them, and the
/// shown one's viewer.
public struct InspectorDocuments {
  /// The open tabs, in order.
  public var tabs: [InspectorDocumentTab]
  /// The shown tab; `nil` shows the selected fixed tab.
  public var selected: String?
  /// Shows a tab.
  public var select: @MainActor (String) -> Void
  /// Closes a tab.
  public var close: @MainActor (String) -> Void
  /// Shows the fixed tab again, keeping the open tabs.
  public var showPanel: @MainActor () -> Void
  /// The shown tab's viewer.
  public var content: AnyView

  /// Creates the open tabs.
  /// - Parameters:
  ///   - tabs: Tabs.
  ///   - selected: The shown tab.
  ///   - select: Show a tab.
  ///   - close: Close a tab.
  ///   - showPanel: Show the fixed tab.
  ///   - content: The shown tab's viewer.
  public init(
    tabs: [InspectorDocumentTab], selected: String?, select: @escaping @MainActor (String) -> Void,
    close: @escaping @MainActor (String) -> Void, showPanel: @escaping @MainActor () -> Void,
    content: AnyView
  ) {
    self.tabs = tabs
    self.selected = selected
    self.select = select
    self.close = close
    self.showPanel = showPanel
    self.content = content
  }
}

/// One entry of the right panel's "Open new" menu.
public struct InspectorMenuItem: Identifiable {
  /// Stable id.
  public var id: String
  /// The label.
  public var title: String
  /// The SF Symbol.
  public var systemImage: String
  /// Whether it can be chosen now.
  public var isEnabled: Bool
  /// What choosing it does.
  public var action: @MainActor () -> Void

  /// Creates an item.
  /// - Parameters:
  ///   - id: Id.
  ///   - title: Label.
  ///   - systemImage: Symbol.
  ///   - isEnabled: Whether it can be chosen.
  ///   - action: What it does.
  public init(
    id: String, title: String, systemImage: String, isEnabled: Bool = true,
    action: @escaping @MainActor () -> Void
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.isEnabled = isEnabled
    self.action = action
  }
}

/// A group of "Open new" items under an optional heading.
public struct InspectorMenuSection: Identifiable {
  /// Stable id.
  public var id: String
  /// The heading.
  public var title: String?
  /// The items.
  public var items: [InspectorMenuItem]

  /// Creates a section.
  /// - Parameters:
  ///   - id: Id.
  ///   - title: Heading.
  ///   - items: Items.
  public init(id: String, title: String? = nil, items: [InspectorMenuItem]) {
    self.id = id
    self.title = title
    self.items = items
  }
}

/// What the Pull Requests tab shows.
nonisolated public enum PullRequestsPanelState: Hashable, Sendable {
  /// The first read is in flight.
  case loading
  /// The session's pull requests; `synced` is false while the server has not imported them
  /// from the host, so an empty list is "not known yet".
  case loaded([PullRequestSummary], synced: Bool)
  /// The read failed.
  case failed(String)
  /// The server does not track pull requests.
  case unsupported
}

/// Content the app supplies for the right panel: the Files, Changes and Search tabs (for
/// example `OmnigentWorkspaceUI`'s file tree, changed-files list and content search), the open
/// file and diff tabs, the Pull Requests list and the "Open new" menu. `nil` shows the
/// built-in fallback.
public struct WorkspaceSlots {
  /// The Files tab.
  public var files: AnyView?
  /// The Changes tab.
  public var changes: AnyView?
  /// The Search tab; `nil` hides it.
  public var search: AnyView?
  /// The open file and diff tabs.
  public var documents: InspectorDocuments?
  /// The Pull Requests tab; `nil` lists the conversation's `pullRequests`.
  public var pullRequests: PullRequestsPanelState?
  /// Re-reads the pull requests; called when the tab shows.
  public var refreshPullRequests: (@MainActor () -> Void)?
  /// The "Open new" menu, read when the panel draws so its sources are observed there; `nil`
  /// or empty hides it.
  public var openNew: (@MainActor () -> [InspectorMenuSection])?

  /// Creates slots.
  /// - Parameters:
  ///   - files: Files content.
  ///   - changes: Changes content.
  ///   - search: Search content.
  ///   - documents: Open file and diff tabs.
  ///   - pullRequests: Pull requests.
  ///   - refreshPullRequests: Re-reads the pull requests.
  ///   - openNew: The "Open new" menu.
  public init(
    files: AnyView? = nil, changes: AnyView? = nil, search: AnyView? = nil,
    documents: InspectorDocuments? = nil, pullRequests: PullRequestsPanelState? = nil,
    refreshPullRequests: (@MainActor () -> Void)? = nil,
    openNew: (@MainActor () -> [InspectorMenuSection])? = nil
  ) {
    self.files = files
    self.changes = changes
    self.search = search
    self.documents = documents
    self.pullRequests = pullRequests
    self.refreshPullRequests = refreshPullRequests
    self.openNew = openNew
  }
}
