import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentTerminalStores
@testable import OmnigentUIComponents

/// The menu commands the window's scene publishes, as the app's menu bar reads them.
@MainActor
final class SessionCommandsProbe {
  var commands: SessionCommandActions?
}

/// The window's root with a reader of its scene's menu commands beside it.
struct ChromeWindowRoot: View {
  let root: AppWindowRoot
  let probe: SessionCommandsProbe

  var body: some View {
    root.background { CommandsReader(probe: probe) }
  }

  private struct CommandsReader: View {
    let probe: SessionCommandsProbe
    @FocusedValue(\.sessionCommands) private var commands

    var body: some View {
      probe.commands = commands
      return Color.clear.frame(width: 1, height: 1)
    }
  }
}

/// A mounted window on `conv_a`, whose agent has a terminal and whose workspace lists
/// `alpha-notes.txt`, on a server that shares sessions. `conv_b`, which a side chat tab shows,
/// lists `beta-notes.txt`.
@MainActor
struct ChromeWindow {
  let screen: OffscreenWindow<ChromeWindowRoot>
  let server: AppServer
  let session: ServerSession
  let probe: SessionCommandsProbe
  let browser: FakeBrowserHost
  let preferences: UserDefaults
  let chatTabID: String

  static let shown = "conv_a"
  static let sideChat = "conv_b"
  static let files = [shown: "alpha-notes.txt", sideChat: "beta-notes.txt"]
  /// Where the session's linked pull requests are read.
  static let pullRequests = "/v1/sessions/\(shown)/pull-requests"

  /// The session's toolbar controls, by the labels the toolbar gives them, in toolbar order:
  /// no viewers, no project tag, and no Chat / Terminal switch, which the chat's tab carries.
  static let controls = ["Session", "Share", "Right panel"]
  /// The controls' accessibility identifiers.
  static let sessionMenu = "header-session-menu"
  static let share = "header-share"
  static let panelToggle = "toggle-inspector"
  /// The labels of the toolbar's buttons that AppKit draws itself, by identifier.
  static let labels = [share: "Share", panelToggle: "Right panel"]

  var tabs: TabStore { session.tabs.group(Self.shown) }
  var chrome: SessionChromeState { session.tabs.chrome(Self.shown) }
  var list: SessionListStore { session.connection.sessionList }

  private static func listing(_ file: String) -> String {
    """
    {"object":"list","base":"","data":[{"id":"\(file)",\
    "object":"session.environment.filesystem.entry","name":"\(file)","path":"\(file)",\
    "type":"file","bytes":3,"modified_at":1}],"first_id":null,"last_id":null,"has_more":false}
    """
  }

  /// A server whose two sessions list a file each, with a project to file a session in.
  private static func server() -> AppServer {
    let server = threeSessionServer()
    for (sessionID, file) in files {
      let filesystem = "/v1/sessions/\(sessionID)/resources/environments/default/filesystem"
      server.route(filesystem, .json(listing(file)))
      server.route(
        "\(filesystem)/\(file)",
        .json(
          #"{"object":"session.environment.filesystem.file_content","path":"\#(file)","content_type":"text/plain","bytes":8,"truncated":false,"encoding":"utf-8","content":"one\ntwo\n"}"#
        ))
    }
    server.route("/v1/sessions/projects", .json(#"[{"id":"p1","name":"Alpha"}]"#))
    server.route(
      "/v1/sessions/\(shown)", method: "PATCH",
      .json(sessionRow(shown, host: "mac", workspace: "/work/\(shown)", updatedAt: 30)))
    return server
  }

  static func open(width: CGFloat = 1_300) async throws -> Self {
    let server = server()
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    server.route(
      pullRequests, .json(#"{"object":"list","data":[],"has_more":false,"synced":true}"#))
    server.route(
      "/v1/info",
      .json(#"{"single_user":false,"sharing_mode":"enabled","session_pull_requests":true}"#))
    // The connect read the single-user pages; Share needs the multi-user ones.
    _ = await connection.pages?.loadOffered()
    let session = ServerSession(
      connection: connection, opener: ExternalURLOpener { _ in true },
      remoteBrowser: FixtureRemoteBrowser(latency: .milliseconds(1)))
    let (probe, browser) = (SessionCommandsProbe(), FakeBrowserHost())
    let preferences = try scratchDefaults()
    let root = AppWindowRoot(
      session: session, selection: WindowSelection(.session(shown)),
      tabContext: TabWindowContext(browser: browser), preferences: preferences)
    let screen = try await titled(
      ChromeWindowRoot(root: root, probe: probe), width: width, height: 700)
    // The toolbar places its items in the first layout pass after the window has them.
    screen.window.setContentSize(CGSize(width: width, height: 701))
    try await settle(screen, until: "the session's terminals") {
      session.terminalStores[shown] != nil
    }
    let terminals = try #require(session.terminalStores[shown]).terminals
    let agent = TerminalResource(
      id: "terminal_agent", sessionId: shown, terminalName: "agent", sessionKey: "1",
      running: true, environment: nil, directAttachUrl: nil, isAgentTerminal: true,
      displayLabel: "Agent")
    terminals.apply(
      terminals: [TerminalRow(terminal: agent, status: .idle)], harness: .ready(terminal: agent))
    let chat = try #require(session.tabs.group(shown).tabs.first)
    let window = Self(
      screen: screen, server: server, session: session, probe: probe, browser: browser,
      preferences: preferences, chatTabID: chat.id)
    try await settle(screen, until: "the session's toolbar controls") {
      window.sessionControls == controls
    }
    try #require(window.sessionControls == controls, "the toolbar: \(window.toolbarDescription)")
    try await settle(screen, until: "the switch on the chat's tab") {
      window.switchSides.count == 2
    }
    return window
  }

  /// The toolbar's items that are on screen, by label.
  var toolbarLabels: [String] {
    let toolbar = screen.window.toolbar
    return (toolbar?.visibleItems ?? []).map(\.label).filter { !$0.isEmpty }
  }

  /// Each toolbar item's label, whether it shows and its width, and the window's, for a
  /// failure to say what the toolbar held.
  var toolbarDescription: String {
    let items = (screen.window.toolbar?.items ?? []).map { item in
      "\(item.label)|\(item.isVisible ? "shown" : "folded")|\(item.view?.frame.width ?? -1)"
    }
    return "window \(screen.window.frame.width): \(items.joined(separator: ", "))"
  }

  /// The session's controls the toolbar shows now, in order.
  var sessionControls: [String] { toolbarLabels.filter(Self.controls.contains) }

  /// The toolbar's item objects: a switch that updates them in place keeps every one.
  var toolbarItems: [ObjectIdentifier] {
    (screen.window.toolbar?.items ?? []).map(ObjectIdentifier.init)
  }

  /// Where the titlebar's control with an accessibility identifier is (a toolbar button, or
  /// a control of the tab strip), from the top left of the window's content; `nil` when the
  /// titlebar has none.
  func controlFrame(_ identifier: String) -> CGRect? {
    // AppKit draws a plain button item itself, under its item's label.
    if let label = Self.labels[identifier],
      let view = screen.window.toolbar?.visibleItems?.first(where: { $0.label == label })?.view
    {
      return view.convert(view.bounds, to: screen.host)
    }
    // SwiftUI builds its accessibility tree once an assistive client says it is there.
    let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    _ = unsafe NSApp.perform(setter, with: true, with: "AXEnhancedUserInterface")
    defer { _ = unsafe NSApp.perform(setter, with: false, with: "AXEnhancedUserInterface") }
    screen.settle(0.2)
    var pending: [Any] = (screen.window.toolbar?.visibleItems ?? []).compactMap(\.view)
    var seen = Set<ObjectIdentifier>()
    while let node = pending.popLast() {
      guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted,
        let element = object as? any NSAccessibilityProtocol & NSObject
      else { continue }
      if element.accessibilityIdentifier() == identifier {
        let inWindow = screen.window.convertFromScreen(element.accessibilityFrame())
        return screen.host.convert(inWindow, from: nil)
      }
      pending.append(contentsOf: element.accessibilityChildren() ?? [])
    }
    return nil
  }

  /// Whether the titlebar has a control with this accessibility identifier.
  func hasControl(_ identifier: String) -> Bool { controlFrame(identifier) != nil }

  /// The frame of a titlebar control that must be there.
  func frame(ofControl identifier: String) throws -> CGRect {
    try #require(controlFrame(identifier), "no \(identifier) in the titlebar: \(toolbarLabels)")
  }

  /// Clicks a titlebar control, found by its identifier, with a real mouse down and up.
  func click(control identifier: String) throws {
    let frame = try frame(ofControl: identifier)
    let point = CGPoint(x: frame.midX, y: frame.midY)
    try screen.click(point)
    screen.settle(0.2)
  }

  /// Opens the session menu and chooses `title` in it, at any depth.
  func chooseInSessionMenu(_ title: String) throws {
    let frame = try frame(ofControl: Self.sessionMenu)
    let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
    try screen.choose(title, in: menu)
    screen.settle(0.2)
  }

  /// The controls in the titlebar's tab strip, left to right: the switch's Chat and Terminal
  /// sides lead the session's chat tab, which is first and has no Close button.
  var stripControls: [CGRect] {
    screen.window.recalculateKeyViewLoop()
    screen.settle(0.05)
    let items = screen.window.toolbar?.visibleItems ?? []
    guard let strip = items.compactMap(\.view).max(by: { $0.frame.width < $1.frame.width })
    else { return [] }
    var found: [CGRect] = []
    var pending: [NSView] = [strip]
    while let view = pending.popLast() {
      let name = String(describing: type(of: view))
      let isControl = name == "KeyViewProxy" || name == "SwiftUIAppKitButton"
      if isControl, !view.isHiddenOrHasHiddenAncestor {
        let frame = view.convert(view.bounds, to: screen.host)
        if !found.contains(where: { $0.origin == frame.origin }) { found.append(frame) }
      }
      pending.append(contentsOf: view.subviews)
    }
    return found.sorted { $0.minX < $1.minX }
  }

  /// The Chat and Terminal sides of the switch on the session's chat tab: the strip's controls
  /// of a side's size, left to right.
  var switchSides: [CGRect] {
    let side = TabViewModeSwitch.side
    return stripControls.filter {
      abs($0.width - side.width) < 1 && abs($0.height - side.height) < 1
    }
  }

  /// Clicks the Chat or the Terminal side of the switch on the session's chat tab.
  func click(mode: SessionViewMode) throws {
    let sides = switchSides
    try #require(sides.count == 2, "the switch's sides among \(stripControls)")
    let frame = sides[mode == .chat ? 0 : 1]
    try screen.click(CGPoint(x: frame.midX, y: frame.midY))
    screen.settle(0.2)
  }

  /// Opens a tab of `content` in the session's strip, focused, and lets the window show it.
  @discardableResult
  func show(_ content: AppTabContent) async throws -> AppTab {
    let tab = try #require(session.tabs.open(content))
    try await pause(screen, .milliseconds(300))
    return tab
  }

  /// The right panel's split view, beside the tabs: not the sidebar's. Built once the panel
  /// first shows.
  var panelSplit: NSSplitView? {
    let splits = screen.allViews.compactMap { $0 as? NSSplitView }
    let outer = splits.first { $0.isVertical && $0.arrangedSubviews.count >= 2 }
    return splits.first { $0 !== outer && $0.arrangedSubviews.count == 2 }
  }

  /// The right panel's column while it shows.
  var panelColumn: NSView? {
    guard let split = panelSplit, !split.isSubviewCollapsed(split.arrangedSubviews[1]) else {
      return nil
    }
    return split.arrangedSubviews[1]
  }

  /// Waits for the right panel's column to finish opening, at least its minimum width.
  func settleUntilPanelOpen(_ why: String = "the right panel to open") async throws {
    try await settle(screen, until: why) { (panelColumn?.frame.width ?? 0) >= 260 }
  }

  /// Waits for the right panel's column to finish closing.
  func settleUntilPanelClosed(_ why: String = "the right panel to close") async throws {
    try await settle(screen, until: why) { panelColumn == nil }
  }

  /// How many right panels the window has built, shown or not.
  var panelSplits: Int {
    let splits = screen.allViews.compactMap { $0 as? NSSplitView }
    let outer = splits.first { $0.isVertical && $0.arrangedSubviews.count >= 2 }
    return splits.count { $0 !== outer && $0.arrangedSubviews.count == 2 }
  }

  /// The right panel's frame, from the top left of the window's content.
  func panelFrame() throws -> CGRect {
    let column = try #require(panelColumn, "the right panel is not shown")
    return column.convert(column.bounds, to: screen.host)
  }

  /// Puts `tab` in the trailing pane beside the session's chat and focuses `focus`.
  func split(with tab: AppTab, focus: TabPane) async throws {
    tabs.show(tab.id, in: .trailing)
    tabs.show(chatTabID, in: .leading)
    tabs.focus(focus)
    try await pause(screen, .milliseconds(400))
    try #require(tabs.splitState != nil, "the window is split")
  }
}
