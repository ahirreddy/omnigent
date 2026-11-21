public import Foundation
public import OSLog
public import OmnigentAppUI
public import OmnigentBrowser
public import OmnigentStores
import OmnigentUIComponents
public import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The app's browser tabs over `OmnigentBrowser`: one `BrowserTabModel` per tab, app-wide. Pages
/// build when their tab is first shown, restoring from the tab's saved `BrowserTabRestoreState`.
///
/// Pages a page opens (popups, "Open Link in New Tab") become tabs beside the opener, in the
/// opener's session; without an opener, in the first window's shown session.
@MainActor
public final class BrowserTabHost: BrowserTabHosting {
  /// The browser's profiles, history and prompts.
  public let environment: BrowserEnvironment
  private let agent: AgentBrowserController?
  let logger: Logger
  private let keyboardShortcuts: Bool
  private(set) var models: [UUID: BrowserTabModel] = [:]
  private(set) var windows: [UUID: SessionTabGroups] = [:]
  /// Each window's design request outbox.
  var designOutboxes: [UUID: DesignRequestOutbox] = [:]
  /// Encodes a new page's state.
  var encodeState: (BrowserTabRestoreState) throws -> Data = { try JSONEncoder().encode($0) }
  /// Each page's Chrome DevTools target id, once an agent's directory asked for it.
  var devToolsTargets: [UUID: String] = [:]

  /// Creates the host.
  /// - Parameters:
  ///   - environment: The browser's profiles, history and prompts.
  ///   - agent: The agent browser, for read-only agent tabs; `nil` where the app runs no agent
  ///     browser (the App Store edition, iOS).
  ///   - logger: The app log.
  ///   - keyboardShortcuts: Pages install their own shortcuts (iPad keyboards); off where a menu
  ///     bar's Browser menu (`BrowserTabCommands`) owns them.
  public init(
    environment: BrowserEnvironment, agent: AgentBrowserController?, logger: Logger,
    keyboardShortcuts: Bool = false
  ) {
    self.environment = environment
    self.agent = agent
    self.logger = logger
    self.keyboardShortcuts = keyboardShortcuts
    environment.onOpenTab = { [weak self] model, context in self?.adopt(model, context) }
    environment.onSwitchToTab = { [weak self] id in self?.switchTo(modelID: id) }
    environment.onCloseTab = { [weak self] model in self?.pageClosed(model) }
    environment.designRequestSender = { [weak self] request, model throws(BrowserError) in
      guard let self else { throw .designToolFailed("The browser is closing.") }
      try self.queueDesignRequest(request, from: model)
    }
  }

  /// See ``BrowserTabHosting``.
  public func makePage(url: URL?) -> (id: UUID, state: Data?) {
    makePage(url: url, engine: nil)
  }

  /// A new page in `engine` whatever the preference, or the preferred engine when `nil`.
  func makePage(url: URL?, engine: BrowserEngineKind?) -> (id: UUID, state: Data?) {
    let model = environment.makeTab(url: url, engine: engine)
    models[model.id] = model
    return (model.id, encode(model))
  }

  /// See ``BrowserTabHosting``.
  public func content(
    for id: UUID, restoring state: Data?, navigation: BrowserTabNavigation?,
    onChange: @escaping @MainActor () -> Void
  ) -> AnyView {
    let model: BrowserTabModel
    if let existing = models[id] {
      model = existing
    } else {
      do {
        model = try restore(id, from: state)
      } catch {
        logger.error(
          "A browser tab could not be restored: \(String(describing: error), privacy: .public)")
        return AnyView(
          ContentUnavailableView(
            "Page Not Restored", systemImage: "exclamationmark.triangle",
            description: Text("The saved page could not be read: \(String(describing: error))")))
      }
    }
    let page = BrowserTabContentView(
      model: model, environment: environment, keyboardShortcuts: keyboardShortcuts,
      showSessions: navigation?.showSessions, tabsButton: navigation?.tabsButton
    )
    .onChange(of: model.restoreRevision) { onChange() }
    #if os(macOS)
      return AnyView(page.modifier(BrowserPageFocus(model: model)))
    #else
      return AnyView(page)
    #endif
  }

  /// See ``BrowserTabHosting``.
  public func canStep(_ id: UUID, by offset: Int) -> Bool {
    guard let model = models[id] else { return false }
    return offset < 0 ? model.canGoBack : model.canGoForward
  }

  /// See ``BrowserTabHosting``.
  public func step(_ id: UUID, by offset: Int) {
    guard let model = models[id] else { return }
    if offset < 0 { model.goBack() } else { model.goForward() }
  }

  /// See ``BrowserTabHosting``.
  public func status(of id: UUID) -> BrowserTabStatus? {
    guard let model = models[id] else { return nil }
    let error = model.pageError.map { !$0.isCancellation } ?? false
    // The profile dot only tells profiles apart, so it shows once there is more than one.
    let profileColor =
      environment.profiles.profiles.count > 1 ? model.profile?.color.color : nil
    return BrowserTabStatus(
      title: model.displayTitle, url: model.url, isLoading: model.isLoading,
      isAudible: model.isAudible || model.isMuted, hasError: error,
      favicon: model.favicon?.pngData, profileColor: profileColor,
      agentControl: model.agentControl.map(Self.badge))
  }

  /// See ``BrowserTabHosting``.
  public func snapshot(of id: UUID) throws -> Data? {
    guard let model = models[id] else { return nil }
    return try JSONEncoder().encode(model.snapshotForRestore())
  }

  /// See ``BrowserTabHosting``.
  public func close(_ id: UUID) throws -> Data? {
    devToolsTargets[id] = nil
    guard let model = models.removeValue(forKey: id) else { return nil }
    return try JSONEncoder().encode(closeOwned(model))
  }

  /// The live page of a browser tab, for menu commands routed to it.
  /// - Parameter id: The page.
  /// - Returns: The page, or `nil` before it is built.
  public func page(_ id: UUID) -> BrowserTabModel? {
    models[id]
  }

  /// See ``BrowserTabHosting``.
  public func agentContent(for sessionID: String) -> AnyView? {
    guard let agent, let tab = agent.activeTab(conversationID: sessionID) else { return nil }
    return AnyView(AgentBrowserMirror(tab: tab))
  }

  /// See ``BrowserTabHosting``.
  public func attach(window: UUID, tabs: SessionTabGroups) {
    windows[window] = tabs
  }

  /// See ``BrowserTabHosting``.
  public func isPageShown(_ id: UUID, outside window: UUID) -> Bool {
    windows.contains { other, tabs in
      other != window
        && tabs.groups.values.contains { group in
          group.tabs.contains { $0.content == .browser(browserID: id) }
        }
    }
  }

  /// See ``BrowserTabHosting``.
  public func detach(window: UUID) {
    windows[window] = nil
    designOutboxes[window] = nil
  }

  /// See ``BrowserTabHosting``.
  public func attachDesignRequests(window: UUID, outbox: DesignRequestOutbox) {
    designOutboxes[window] = outbox
  }

  /// A window closed for good: its browser pages close with it.
  /// - Parameter window: The window.
  public func windowClosed(_ window: UUID) {
    designOutboxes[window] = nil
    guard let tabs = windows.removeValue(forKey: window) else { return }
    for tab in tabs.groups.values.flatMap(\.tabs) {
      guard case .browser(let id) = tab.content, let model = models.removeValue(forKey: id) else {
        continue
      }
      closeOwned(model)
    }
  }

  // MARK: Internals

  /// Closes a page that belongs to a window's tab. The window's ``TabStore`` keeps the closed
  /// tab (with this state) for Reopen Closed Tab, so the browser's own recently-closed list
  /// drops it: one stack, and a reopened page never comes back twice.
  @discardableResult
  private func closeOwned(_ model: BrowserTabModel) -> BrowserTabRestoreState {
    let state = model.close()
    let closed = environment.recentlyClosed
    if closed.states.last?.id == state.id {
      // The page was pushed by `close()` just now; the tab store's entry replaces it.
      _ = closed.popLast()
    }
    return state
  }

  func restore(_ id: UUID, from state: Data?) throws -> BrowserTabModel {
    guard let state else {
      // A tab saved before its page had any state: start it fresh at the new-tab page.
      let model = environment.makeTab()
      models[id] = model
      return model
    }
    let decoded = try JSONDecoder().decode(BrowserTabRestoreState.self, from: state)
    let model = environment.restoreTab(decoded)
    models[id] = model
    return model
  }

  func encode(_ model: BrowserTabModel) -> Data? {
    do {
      return try encodeState(model.snapshotForRestore())
    } catch {
      // The tab still opens; it saves once the page reports a state that encodes.
      logger.error(
        "A new browser tab's state did not encode: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  func pageID(of model: BrowserTabModel) -> UUID? {
    models.first { $0.value === model }?.key
  }

  /// The window and session group holding `pageID`, and its tab.
  private func location(of pageID: UUID) -> (window: SessionTabGroups, tab: AppTab)? {
    for tabs in windows.values {
      for group in tabs.groups.values {
        if let tab = group.tabs.first(where: { $0.content == .browser(browserID: pageID) }) {
          return (tabs, tab)
        }
      }
    }
    return nil
  }

  private func adopt(_ model: BrowserTabModel, _ context: BrowserTabOpenContext) {
    let opener = context.opener.flatMap(pageID(of:)).flatMap(location(of:))
    guard let tabs = opener?.window ?? windows.values.first(where: { $0.current != nil }) else {
      logger.error("A page opened a tab, but no session can show it; it was closed.")
      model.close()
      return
    }
    models[model.id] = model
    // The opener's session is shown, so the new tab joins it.
    if let opener { tabs.select(opener.tab.id) }
    tabs.open(
      .browser(browserID: model.id), select: context.disposition != .backgroundTab,
      browserState: encode(model))
  }

  private func switchTo(modelID: UUID) {
    guard let pageID = models.first(where: { $0.value.id == modelID })?.key,
      let location = location(of: pageID)
    else { return }
    location.window.select(location.tab.id)
  }

  private func pageClosed(_ model: BrowserTabModel) {
    guard let pageID = pageID(of: model), let location = location(of: pageID) else {
      model.close()
      return
    }
    location.window.close(location.tab.id)
  }
}

#if os(macOS)
  /// Puts the keyboard in a browser page when its tab shows in the focused pane, so typing
  /// reaches what the page has focused without a click.
  struct BrowserPageFocus: ViewModifier {
    let model: BrowserTabModel

    func body(content: Content) -> some View {
      content.modifier(TabPageKeyboardFocus(view: Self.keyboardView(of: model)))
    }

    /// The view that takes typing for the page; `nil` before the page is built, and on a new
    /// tab's empty page, where the address field takes the keyboard.
    static func keyboardView(of model: BrowserTabModel) -> NSView? {
      model.showsEmptyPage ? nil : model.tab?.keyboardView
    }
  }
#endif
