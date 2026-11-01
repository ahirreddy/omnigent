public import CoreGraphics
public import Foundation

/// Receives the browser UI a tab's page asks for, from any engine. `BrowserPromptPresenter` is
/// the app's implementation; `AgentBrowserController` installs its own for agent tabs.
public protocol BrowserTabDelegate: AnyObject {
  /// The page needs an answer. The prompt also sits in `tab.state.pendingPrompts` until it is
  /// answered or withdrawn.
  func tab(_ tab: any BrowserTab, didRequest prompt: BrowserPrompt)
  /// The engine withdrew a prompt (the page navigated, the tab closed). Dismiss its UI.
  func tab(_ tab: any BrowserTab, didCancel prompt: BrowserPrompt)
  /// The page opened a new tab or window that keeps an opener relationship. Show it or close it.
  func tab(_ tab: any BrowserTab, didOpen popup: BrowserPopup)
  /// The popup policy stopped a window the page tried to open.
  func tab(_ tab: any BrowserTab, didBlock popup: BrowserBlockedPopup)
  /// A download started after its prompt was answered.
  func tab(_ tab: any BrowserTab, didStart download: BrowserDownload)
  /// Items the app adds to a page's context menu. Engines with fully native menus (WebKit) do
  /// not ask.
  func tab(_ tab: any BrowserTab, contextMenuItemsFor context: BrowserContextMenuContext)
    -> [BrowserContextMenuItem]
}

extension BrowserTabDelegate {
  /// No extra items by default.
  public func tab(_ tab: any BrowserTab, contextMenuItemsFor context: BrowserContextMenuContext)
    -> [BrowserContextMenuItem]
  {
    []
  }
}

/// What was under the pointer when a context menu opened.
nonisolated public struct BrowserContextMenuContext: Sendable, Hashable {
  /// The link, if any.
  public let linkURL: URL?
  /// The selected text.
  public let selectionText: String
  /// Whether the target is editable.
  public let isEditable: Bool

  /// Creates a context.
  public init(linkURL: URL?, selectionText: String, isEditable: Bool) {
    self.linkURL = linkURL
    self.selectionText = selectionText
    self.isEditable = isEditable
  }
}

/// A context menu item the app adds.
public struct BrowserContextMenuItem {
  /// The label.
  public let title: String
  /// Runs when chosen.
  public let action: () -> Void

  /// Creates an item.
  public init(title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }
}

/// Where a page asked a new tab or window to open.
nonisolated public enum BrowserPopupDisposition: String, Sendable, Hashable {
  /// A foreground tab.
  case foregroundTab
  /// A background tab.
  case backgroundTab
  /// A popup window with its own size.
  case popup
  /// A new window.
  case window

  /// Whether the app should give it a window rather than a tab.
  public var wantsWindow: Bool { self == .popup || self == .window }
}

/// Which page-opened windows a tab allows. Engines enforce it synchronously.
nonisolated public enum BrowserPopupPolicy: String, Sendable, Hashable, CaseIterable {
  /// Every window.open opens.
  case allow
  /// Only opens after a user gesture (click, key press). The default.
  case requireUserGesture
  /// Nothing opens; each attempt is reported.
  case block
}

/// A tab a page opened. It shares the opener's profile; `window.opener` works when the engine
/// created it for window.open or target=_blank.
public struct BrowserPopup {
  /// The new tab.
  public let tab: any BrowserTab
  /// The tab that opened it.
  public let opener: any BrowserTab
  /// The URL it loads.
  public let targetURL: URL?
  /// Where the page wanted it.
  public let disposition: BrowserPopupDisposition
  /// The size the page asked for, in points.
  public let requestedSize: CGSize?

  /// Creates a popup.
  public init(
    tab: any BrowserTab, opener: any BrowserTab, targetURL: URL?,
    disposition: BrowserPopupDisposition, requestedSize: CGSize?
  ) {
    self.tab = tab
    self.opener = opener
    self.targetURL = targetURL
    self.disposition = disposition
    self.requestedSize = requestedSize
  }
}

/// A window the popup policy stopped.
nonisolated public struct BrowserBlockedPopup: Sendable, Hashable, Identifiable {
  /// Identity.
  public let id: UUID
  /// The URL the page tried to open.
  public let url: URL?
  /// Why it was blocked.
  public let reason: String

  /// Creates a record.
  public init(url: URL?, reason: String) {
    id = UUID()
    self.url = url
    self.reason = reason
  }
}
