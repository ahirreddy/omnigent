import AppKit
import Foundation
import OSLog
import OmnigentAppUI
import OmnigentBrowser
import OmnigentUIComponents
import SwiftUI

/// View > Show Browser (Option-Command-B): a browser tab in the key server window. The browser
/// used to be its own window; it is now a tab like any other.
struct BrowserCommands: Commands {
  @FocusedValue(\.tabCommands) private var tabs

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button("Show Browser") { tabs?.openBrowser?() }
        .keyboardShortcut("b", modifiers: [.command, .option])
        .disabled(tabs?.openBrowser == nil)
    }
  }
}

/// The app's browser tabs over `OmnigentBrowser`: one `BrowserTabModel` per tab, app-wide, so a
/// tab torn off into another window keeps its page. Pages build when their tab is first shown,
/// restoring from the tab's saved `BrowserTabRestoreState`.
///
/// Pages a page opens (popups, "Open Link in New Tab") become tabs in the opener's window.
@MainActor
final class BrowserTabHost: BrowserTabHosting {
  let environment: BrowserEnvironment
  private let agent: AgentBrowserController?
  private let logger: Logger
  private var models: [UUID: BrowserTabModel] = [:]
  private var windows: [UUID: TabStore] = [:]

  /// Creates the host.
  /// - Parameters:
  ///   - environment: The browser's profiles, history and prompts.
  ///   - agent: The agent browser, for read-only agent tabs; `nil` in the App Store edition.
  ///   - logger: The app log.
  init(environment: BrowserEnvironment, agent: AgentBrowserController?, logger: Logger) {
    self.environment = environment
    self.agent = agent
    self.logger = logger
    environment.onOpenTab = { [weak self] model, context in self?.adopt(model, context) }
    environment.onSwitchToTab = { [weak self] id in self?.switchTo(modelID: id) }
    environment.onCloseTab = { [weak self] model in self?.pageClosed(model) }
  }

  func makePage(url: URL?) -> (id: UUID, state: Data?) {
    let model = environment.makeTab(url: url)
    models[model.id] = model
    return (model.id, encode(model))
  }

  func content(
    for id: UUID, restoring state: Data?, onChange: @escaping @MainActor () -> Void
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
    return AnyView(
      // The menu bar's Browser menu (`BrowserTabCommands`) owns the shortcuts.
      BrowserTabContentView(model: model, environment: environment, keyboardShortcuts: false)
        .onChange(of: model.restoreRevision) { onChange() })
  }

  func status(of id: UUID) -> BrowserTabStatus? {
    guard let model = models[id] else { return nil }
    let error = model.pageError.map { !$0.isCancellation } ?? false
    // The profile dot only tells profiles apart, so it shows once there is more than one.
    let profileColor =
      environment.profiles.profiles.count > 1 ? model.profile?.color.color : nil
    return BrowserTabStatus(
      title: model.displayTitle, url: model.url, isLoading: model.isLoading,
      isAudible: model.isAudible || model.isMuted, hasError: error,
      favicon: model.favicon?.pngData, profileColor: profileColor)
  }

  func snapshot(of id: UUID) throws -> Data? {
    guard let model = models[id] else { return nil }
    return try JSONEncoder().encode(model.snapshotForRestore())
  }

  func close(_ id: UUID) throws -> Data? {
    guard let model = models.removeValue(forKey: id) else { return nil }
    return try JSONEncoder().encode(closeOwned(model))
  }

  /// The live page of a browser tab, for menu commands routed to it.
  /// - Parameter id: The page.
  /// - Returns: The page, or `nil` before it is built.
  func page(_ id: UUID) -> BrowserTabModel? {
    models[id]
  }

  func agentContent(for sessionID: String) -> AnyView? {
    guard let agent, let tab = agent.activeTab(conversationID: sessionID) else { return nil }
    return AnyView(AgentBrowserMirror(tab: tab))
  }

  func attach(window: UUID, tabs: TabStore) {
    windows[window] = tabs
  }

  func detach(window: UUID) {
    windows[window] = nil
  }

  /// A window closed for good: its browser pages close with it.
  /// - Parameter window: The window.
  func windowClosed(_ window: UUID) {
    guard let tabs = windows.removeValue(forKey: window) else { return }
    for tab in tabs.tabs {
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

  private func restore(_ id: UUID, from state: Data?) throws -> BrowserTabModel {
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

  private func encode(_ model: BrowserTabModel) -> Data? {
    do {
      return try JSONEncoder().encode(model.snapshotForRestore())
    } catch {
      // The tab still opens; it saves once the page reports a state that encodes.
      logger.error(
        "A new browser tab's state did not encode: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  private func pageID(of model: BrowserTabModel) -> UUID? {
    models.first { $0.value === model }?.key
  }

  /// The window showing `pageID`, and its tab.
  private func location(of pageID: UUID) -> (tabs: TabStore, tab: AppTab)? {
    for tabs in windows.values {
      if let tab = tabs.tabs.first(where: { $0.content == .browser(browserID: pageID) }) {
        return (tabs, tab)
      }
    }
    return nil
  }

  private func adopt(_ model: BrowserTabModel, _ context: BrowserTabOpenContext) {
    let opener = context.opener.flatMap(pageID(of:)).flatMap(location(of:))
    guard let tabs = opener?.tabs ?? windows.values.first else {
      logger.error("A page opened a tab, but no window can show it; it was closed.")
      model.close()
      return
    }
    models[model.id] = model
    if let opener { tabs.select(opener.tab.id) }
    tabs.open(
      .browser(browserID: model.id), select: context.disposition != .backgroundTab,
      browserState: encode(model))
  }

  private func switchTo(modelID: UUID) {
    guard let pageID = models.first(where: { $0.value.id == modelID })?.key,
      let location = location(of: pageID)
    else { return }
    location.tabs.select(location.tab.id)
  }

  private func pageClosed(_ model: BrowserTabModel) {
    guard let pageID = pageID(of: model), let location = location(of: pageID) else {
      model.close()
      return
    }
    location.tabs.close(location.tab.id)
  }
}

/// The page an agent drives, mirrored read-only: a screenshot refreshed every second, so the
/// agent's page never leaves its off-screen panel and no input can reach it.
private struct AgentBrowserMirror: View {
  let tab: any BrowserTab

  @State private var image: NSImage?
  @State private var failure: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label("The agent is browsing. This view is read-only.", systemImage: "eye")
        Spacer()
        Text(tab.state.url?.absoluteString ?? "")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.callout)
      .padding(8)
      Divider()
      Group {
        if let image {
          Image(nsImage: image).resizable().scaledToFit()
            .accessibilityLabel("The page the agent is on")
        } else if let failure {
          ContentUnavailableView(
            "No Picture of the Page", systemImage: "exclamationmark.triangle",
            description: Text(failure))
        } else {
          ProgressView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationTitle(tab.state.title.isEmpty ? "Agent Browser" : tab.state.title)
    .accessibilityIdentifier("agent-browser-tab")
    .task { await refresh() }
  }

  private func refresh() async {
    while !Task.isCancelled {
      do {
        let data = try await tab.takeSnapshotPNG()
        image = NSImage(data: data)
        failure = nil
      } catch {
        failure = error.localizedDescription
      }
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
    }
  }
}
