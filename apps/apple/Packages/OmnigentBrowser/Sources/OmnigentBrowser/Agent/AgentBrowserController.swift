public import CoreGraphics
internal import Foundation
internal import os

#if os(macOS)
  internal import AppKit
#endif

/// Runs agent browser actions. Stores call this when the core delivers a
/// `browser.action_request` event this client claimed, then post the result with the claim
/// token. See OmnigentWebLayer/DESIGN.md, "Agent browser actions".
public protocol AgentBrowserActing: AnyObject {
  /// Runs one action and returns the result to post. Never throws: failures are
  /// `{ok: false, error}` results.
  func perform(_ request: AgentBrowserActionRequest) async -> AgentBrowserActionResult
  /// Closes the conversation's agent pages and discards their profile's tabs.
  func close(conversationID: String)
}

/// The agent browser: one agent tab per conversation, in an ephemeral or isolated profile,
/// driven with the engine's agent input path (renderer-direct on Chromium).
///
/// - Agent pages are never in an app window. On macOS each sits in a private off-screen panel
///   that ignores the mouse and never becomes key, so WebKit keeps rendering and no input from
///   the agent can reach app chrome. Chromium additionally tags agent input in the web host.
/// - The controller is each agent tab's delegate and answers every prompt itself without UI:
///   alerts are accepted, other dialogs dismissed, permissions, file choosers, downloads,
///   authentication, certificate errors and colors denied. Each is reported in the next
///   result's `data.dialogs`.
/// - The URL policy is set on the tab before its first load (engines enforce its rules for
///   redirects and page-initiated navigations) and checked before every `navigate`.
/// - Popups the agent page opens become extra pages in the same profile; the newest open page
///   receives the following actions.
public final class AgentBrowserController: AgentBrowserActing {
  /// Where agent tabs come from.
  public let provider: any BrowserEngineProvider
  /// The engine for agent tabs.
  public let engineKind: BrowserEngineKind
  /// Where agents may navigate.
  public let urlPolicy: any BrowserURLPolicy
  /// The longest a navigation or `wait_for_load` waits.
  public let actionTimeout: Duration
  /// The size of agent pages, in points.
  public let viewport: CGSize

  let profileForConversation: (String) -> BrowserProfile
  var sessions: [String: AgentSession] = [:]
  private var tails: [String: Task<AgentBrowserActionResult, Never>] = [:]
  let logger = Logger(subsystem: "ai.omnigent.browser", category: "agent")

  /// Creates a controller. Nothing starts until the first action.
  /// - Parameters:
  ///   - provider: Resolves `engine`.
  ///   - engine: The engine for agent tabs.
  ///   - urlPolicy: Where agents may navigate. The default allows http and https to public
  ///     hosts only.
  ///   - profile: The profile for a conversation's pages. The default is a fresh in-memory
  ///     profile per conversation.
  ///   - actionTimeout: The longest a load may take.
  ///   - viewport: The page size.
  public init(
    provider: any BrowserEngineProvider, engine: BrowserEngineKind,
    urlPolicy: any BrowserURLPolicy = BrowserURLRules(),
    profile: @escaping (String) -> BrowserProfile = { .ephemeral("agent:\($0)") },
    actionTimeout: Duration = .seconds(20), viewport: CGSize = CGSize(width: 1280, height: 800)
  ) {
    self.provider = provider
    engineKind = engine
    self.urlPolicy = urlPolicy
    profileForConversation = profile
    self.actionTimeout = actionTimeout
    self.viewport = viewport
  }

  /// The tab that receives the conversation's next action, if one exists.
  public func activeTab(conversationID: String) -> (any BrowserTab)? {
    sessions[conversationID]?.activePage?.tab
  }

  /// See `AgentBrowserActing.perform(_:)`. Actions for one conversation run one at a time, in
  /// arrival order.
  public func perform(_ request: AgentBrowserActionRequest) async -> AgentBrowserActionResult {
    let id = request.conversationID
    let previous = tails[id]
    let task = Task { [weak self] () -> AgentBrowserActionResult in
      if let previous {
        // Only ordering matters; the previous result was returned to its own caller.
        _ = await previous.value
      }
      guard let self else { return .failure("The agent browser was closed.") }
      return await self.execute(request)
    }
    tails[id] = task
    let result = await task.value
    if tails[id] == task {
      tails[id] = nil
    }
    return result
  }

  private func execute(_ request: AgentBrowserActionRequest) async -> AgentBrowserActionResult {
    var session: AgentSession?
    do throws(BrowserError) {
      let action = try AgentAction(action: request.action, args: request.args)
      let current = try self.session(for: request.conversationID)
      session = current
      guard let page = current.activePage else { throw .tabClosed }
      let result = try await run(action, on: page.tab)
      return result.merging(current.takeEvents())
    } catch {
      logger.error(
        "Agent action \(request.action, privacy: .public) (\(request.actionID, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
      )
      return AgentBrowserActionResult(
        ok: false, error: error.localizedDescription, data: session?.takeEvents() ?? [:])
    }
  }

  /// See `AgentBrowserActing.close(conversationID:)`.
  public func close(conversationID: String) {
    sessions.removeValue(forKey: conversationID)?.close()
  }

  /// Closes every agent page.
  public func closeAll() {
    for session in sessions.values {
      session.close()
    }
    sessions.removeAll()
  }

  // MARK: Pages

  private func session(for conversationID: String) throws(BrowserError) -> AgentSession {
    let session =
      sessions[conversationID]
      ?? AgentSession(profile: profileForConversation(conversationID))
    sessions[conversationID] = session
    session.pruneClosedPages()
    if session.activePage == nil {
      let engine = try provider.engine(for: engineKind)
      let tab = try engine.makeTab(profile: session.profile, initialURL: nil)
      session.pages.append(adopt(tab))
    }
    return session
  }

  /// Configures an agent tab before anything loads in it and hosts it off screen.
  func adopt(_ tab: any BrowserTab) -> AgentPage {
    tab.delegate = self
    tab.popupPolicy = .requireUserGesture
    tab.urlPolicy = urlPolicy
    return AgentPage(tab: tab, viewport: viewport)
  }

  func session(containing tab: any BrowserTab) -> AgentSession? {
    sessions.values.first { session in session.pages.contains { $0.tab === tab } }
  }
}

/// The pages of one conversation.
final class AgentSession {
  let profile: BrowserProfile
  var pages: [AgentPage] = []
  /// Prompts, popups and downloads the controller handled since the last result.
  var events: [AgentJSONValue] = []

  init(profile: BrowserProfile) {
    self.profile = profile
  }

  /// The newest page that is still open.
  var activePage: AgentPage? {
    pages.last { !$0.tab.state.isClosed }
  }

  func pruneClosedPages() {
    for page in pages where page.tab.state.isClosed {
      page.close()
    }
    pages.removeAll { $0.tab.state.isClosed }
  }

  func takeEvents() -> [String: AgentJSONValue] {
    defer { events.removeAll() }
    return events.isEmpty ? [:] : ["dialogs": .array(events)]
  }

  func close() {
    for page in pages {
      page.close()
    }
    pages.removeAll()
  }
}

/// One agent tab and, when its engine needs a window to render (WebKit on macOS), the
/// off-screen panel that hosts its view. Chromium agent pages render in the web host with no
/// window at all.
final class AgentPage {
  let tab: any BrowserTab
  #if os(macOS)
    private let panel: NSPanel?
  #endif

  init(tab: any BrowserTab, viewport: CGSize) {
    self.tab = tab
    tab.agentInput.prepareForAgent(viewport: viewport)
    #if os(macOS)
      guard tab.agentInput.needsHostWindow else {
        panel = nil
        return
      }
      // An NSPanel, borderless and non-activating: it never becomes key or main, ignores the
      // mouse, and sits far off every screen. Window lists that skip panels skip it too.
      let panel = NSPanel(
        contentRect: NSRect(origin: CGPoint(x: -40_000, y: -40_000), size: viewport),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.ignoresMouseEvents = true
      panel.hidesOnDeactivate = false
      panel.isExcludedFromWindowsMenu = true
      panel.collectionBehavior = [.transient, .ignoresCycle]
      let view = tab.platformView
      view.frame = NSRect(origin: .zero, size: viewport)
      view.autoresizingMask = [.width, .height]
      panel.contentView = view
      panel.orderBack(nil)
      self.panel = panel
    #endif
  }

  func close() {
    tab.close()
    #if os(macOS)
      panel?.contentView = nil
      panel?.close()
    #endif
  }
}
