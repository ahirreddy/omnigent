public import Foundation
public import Observation

#if os(macOS)
  public import AppKit

  /// The native view type engines render into.
  public typealias BrowserPlatformView = NSView
#else
  public import UIKit

  /// The native view type engines render into.
  public typealias BrowserPlatformView = UIView
#endif

/// Observable navigation state of one tab. Engines write it (setters are `package` so engine
/// targets in this package can); UI reads it.
@Observable
public final class BrowserTabState {
  /// Current main-frame URL.
  public package(set) var url: URL?
  /// Current document title, empty when unknown.
  public package(set) var title = ""
  /// Whether a main-frame load is in flight.
  public package(set) var isLoading = false
  /// Load progress in `0...1`.
  public package(set) var estimatedProgress: Double = 0
  /// Whether history has a previous entry.
  public package(set) var canGoBack = false
  /// Whether history has a next entry.
  public package(set) var canGoForward = false
  /// Most recent failure, cleared when a new navigation starts.
  public package(set) var lastError: BrowserError?
  /// Whether the tab has been closed. A closed tab ignores further commands.
  public package(set) var isClosed = false

  /// Creates empty state.
  public init() {}
}

/// Result of a find-in-page request.
nonisolated public struct BrowserFindResult: Hashable, Sendable {
  /// Whether at least one match exists.
  public let matchFound: Bool
  /// Total matches, when the engine reports it.
  public let matchCount: Int?
  /// One-based index of the highlighted match, when the engine reports it.
  public let activeMatch: Int?

  /// Creates a result.
  public init(matchFound: Bool, matchCount: Int?, activeMatch: Int?) {
    self.matchFound = matchFound
    self.matchCount = matchCount
    self.activeMatch = activeMatch
  }
}

/// One browsing context hosted by a specific engine.
public protocol BrowserTab: AnyObject {
  /// The engine rendering this tab.
  var engineKind: BrowserEngineKind { get }
  /// The storage profile this tab uses.
  var profile: BrowserProfile { get }
  /// Observable navigation state.
  var state: BrowserTabState { get }
  /// The native view to embed. Each tab owns exactly one.
  var platformView: BrowserPlatformView { get }

  /// Starts a main-frame navigation.
  func load(_ url: URL)
  /// Navigates back in history if possible.
  func goBack()
  /// Navigates forward in history if possible.
  func goForward()
  /// Reloads the current page.
  func reload()
  /// Stops the current load.
  func stopLoading()
  /// Evaluates a script in the main frame and returns its completion value. Promises are not
  /// awaited.
  func evaluateJavaScript(_ script: String) async throws(BrowserError) -> BrowserScriptValue
  /// Captures the visible page as PNG data.
  func takeSnapshotPNG() async throws(BrowserError) -> Data
  /// Highlights the next match for `text`.
  func find(_ text: String, forward: Bool, caseSensitive: Bool) async throws(BrowserError)
    -> BrowserFindResult
  /// Opens the engine's web inspector.
  func showDevTools() throws(BrowserError)
  /// Tears down the engine view. Idempotent.
  func close()
}
