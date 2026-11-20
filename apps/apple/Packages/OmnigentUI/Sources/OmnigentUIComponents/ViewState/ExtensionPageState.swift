import Foundation

/// A sidebar entry an extension contributes, between Canvas and Usage.
nonisolated public struct SidebarExtensionEntry: Hashable, Sendable, Identifiable {
  /// The entry's id.
  public var id: String
  /// The row's label.
  public var label: String
  /// The SF Symbol.
  public var systemImage: String
  /// The page it opens.
  public var destination: SidebarDestination

  /// Creates an entry.
  /// - Parameters:
  ///   - id: The entry's id.
  ///   - label: The row's label.
  ///   - icon: The web's icon name (`dashboard`, `panels-top-left`, `puzzle`, `search`).
  ///   - extensionID: The extension.
  ///   - route: The page's route.
  public init(id: String, label: String, icon: String?, extensionID: String, route: String) {
    self.id = id
    self.label = label
    systemImage = Self.systemImage(forIcon: icon)
    destination = .extensionPage(extensionID: extensionID, route: route)
  }

  /// The SF Symbol for one of the web's extension icon names; any other is the puzzle piece.
  /// - Parameter icon: The icon name.
  /// - Returns: The symbol.
  public static func systemImage(forIcon icon: String?) -> String {
    switch icon {
    case "dashboard": "rectangle.3.group"
    case "panels-top-left": "sidebar.left"
    case "search": "magnifyingglass"
    default: "puzzlepiece.extension"
    }
  }
}

/// An extension page as it starts: its bundle loading, the page activating, running, or why it
/// could not start.
nonisolated public struct ExtensionPageState: Hashable, Sendable {
  /// Where the page stands.
  public enum Phase: Hashable, Sendable {
    /// Reading the extensions or the page's bundle.
    case loading
    /// The page is loading in its frame and has not said it is ready.
    case activating
    /// The page is running.
    case ready
    /// It could not start, with why.
    case failed(String)
    /// The server has no such extension page.
    case notFound
  }

  /// The page's title.
  public var title: String
  /// Where it stands.
  public var phase: Phase
  /// The native page that frames the bundle, once its bundle is read.
  public var hostPage: String?
  /// Changes with every mount, so a retry loads a new frame.
  public var mountID: String

  /// Creates a state.
  /// - Parameters:
  ///   - title: The page's title.
  ///   - phase: Where it stands.
  ///   - hostPage: The native page that frames the bundle.
  ///   - mountID: The mount.
  public init(title: String, phase: Phase, hostPage: String? = nil, mountID: String = "") {
    self.title = title
    self.phase = phase
    self.hostPage = hostPage
    self.mountID = mountID
  }

  /// The error card's heading, as the web's.
  public var failureTitle: String { "\(title) could not start" }
}

/// What an extension page asks of its host.
public struct ExtensionPageActions {
  /// Loads the page again after a failure.
  public var retry: @MainActor () -> Void
  /// The appearance changed: `true` for dark.
  public var themeChanged: @MainActor (Bool) -> Void

  /// Creates actions.
  /// - Parameters:
  ///   - retry: Loads the page again.
  ///   - themeChanged: Reports the appearance.
  public init(
    retry: @escaping @MainActor () -> Void, themeChanged: @escaping @MainActor (Bool) -> Void
  ) {
    self.retry = retry
    self.themeChanged = themeChanged
  }

  /// Actions that do nothing, for previews and renders.
  public static let inert = Self(retry: {}, themeChanged: { _ in })
}
