public import Foundation
public import SwiftUI

/// What a browser tab shows in the strip.
nonisolated public struct BrowserTabStatus: Hashable, Sendable {
  /// The page title, or the host while it loads.
  public var title: String
  /// The committed URL.
  public var url: URL?
  /// Loading.
  public var isLoading: Bool
  /// Playing (or muted) audio.
  public var isAudible: Bool
  /// The page failed to load.
  public var hasError: Bool
  /// The favicon (PNG).
  public var favicon: Data?
  /// The browser profile's color.
  public var profileColor: Color?

  /// Creates a status.
  /// - Parameters:
  ///   - title: Title.
  ///   - url: URL.
  ///   - isLoading: Loading.
  ///   - isAudible: Audio.
  ///   - hasError: Failed.
  ///   - favicon: Favicon.
  ///   - profileColor: Profile color.
  public init(
    title: String, url: URL? = nil, isLoading: Bool = false, isAudible: Bool = false,
    hasError: Bool = false, favicon: Data? = nil, profileColor: Color? = nil
  ) {
    self.title = title
    self.url = url
    self.isLoading = isLoading
    self.isAudible = isAudible
    self.hasError = hasError
    self.favicon = favicon
    self.profileColor = profileColor
  }
}

/// The app's browser, for browser tabs. The Mac app implements it over `OmnigentBrowser`; builds
/// without a browser pass `nil` and the tab system offers no Browser.
///
/// Pages are keyed by the tab's browser id and live app-wide, so a tab torn off into another
/// window keeps its page. A page is built only when its tab is first shown.
@MainActor
public protocol BrowserTabHosting: AnyObject {
  /// A new page at `url` (the server's web app when `nil`), returning its id and initial state.
  /// - Parameter url: The first page.
  /// - Returns: The page id and its restore state.
  func makePage(url: URL?) -> (id: UUID, state: Data?)

  /// The page's content view, restoring it from `state` the first time it is shown.
  /// - Parameters:
  ///   - id: The page.
  ///   - state: Its saved restore state.
  ///   - onChange: Called when the page's title, URL or history changes, to save the tab.
  /// - Returns: The view.
  func content(for id: UUID, restoring state: Data?, onChange: @escaping @MainActor () -> Void)
    -> AnyView

  /// The strip's status of a live page, or `nil` before it is built.
  /// - Parameter id: The page.
  /// - Returns: The status.
  func status(of id: UUID) -> BrowserTabStatus?

  /// The live page's restore state, or `nil` before it is built.
  /// - Parameter id: The page.
  /// - Returns: The state.
  /// - Throws: When the state cannot be encoded.
  func snapshot(of id: UUID) throws -> Data?

  /// Closes a live page and returns its final restore state.
  /// - Parameter id: The page.
  /// - Returns: The state, or `nil` when the page was never built.
  /// - Throws: When the state cannot be encoded.
  func close(_ id: UUID) throws -> Data?

  /// The page an agent drives for a session, read-only; `nil` when the agent has none here.
  /// - Parameter sessionID: The session.
  /// - Returns: The view.
  func agentContent(for sessionID: String) -> AnyView?

  /// Connects a window's tabs, so pages a page opens (popups, "Open Link in New Tab") become tabs
  /// in the opener's window, and the omnibox's "Switch to tab" selects one.
  /// - Parameters:
  ///   - window: The window.
  ///   - tabs: Its tabs.
  func attach(window: UUID, tabs: TabStore)

  /// Disconnects a window.
  /// - Parameter window: The window.
  func detach(window: UUID)
}
