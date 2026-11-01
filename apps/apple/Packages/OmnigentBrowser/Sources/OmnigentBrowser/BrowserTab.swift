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
  /// Prompts the page is waiting on, oldest first.
  public package(set) var pendingPrompts: [BrowserPrompt] = []
  /// The most recent window the popup policy stopped, for a "popup blocked" notice.
  public package(set) var lastBlockedPopup: BrowserBlockedPopup?

  /// Creates empty state.
  public init() {}

  /// Adds a prompt to the queue.
  package func enqueue(_ prompt: BrowserPrompt) {
    pendingPrompts.append(prompt)
  }

  /// Removes a finished or withdrawn prompt.
  package func remove(_ prompt: BrowserPromptBase) {
    pendingPrompts.removeAll { $0.base === prompt }
  }

  /// Clears the blocked-popup notice.
  public func dismissBlockedPopup() {
    lastBlockedPopup = nil
  }

  /// Records an error for the UI's banner.
  package func report(_ error: BrowserError) {
    lastError = error
  }
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

  /// Receives prompts, popups and downloads. Without one, prompts are denied and reported in
  /// `state.lastError`. Engines hold it weakly.
  var delegate: (any BrowserTabDelegate)? { get set }
  /// Which page-opened windows are allowed.
  var popupPolicy: BrowserPopupPolicy { get set }
  /// Where the tab may navigate. Nil allows everything. Set before the first load to cover it.
  var urlPolicy: (any BrowserURLPolicy)? { get set }
  /// Input for agents, kept apart from user input.
  var agentInput: any BrowserAgentInput { get }
}
