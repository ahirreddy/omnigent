import AppKit
import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// What the host keeps for a window: the page it shows.
@MainActor
@Observable
final class WindowSelection {
  var page: SidebarDestination?

  init(_ page: SidebarDestination? = nil) { self.page = page }

  var binding: Binding<SidebarDestination?> {
    Binding(get: { self.page }, set: { self.page = $0 })
  }
}

/// A window's root over `session`, the way the host mounts it: the page is the root's own
/// state, which its body never reads.
struct AppWindowRoot: View {
  let session: ServerSession
  let selection: WindowSelection
  var tabContext = TabWindowContext()
  var serverSwitching: ServerSwitching?
  var openInNewWindow: (@MainActor (String) -> Void)?
  /// What `@AppStorage` reads in the window. The process's own defaults are one file shared by
  /// every test process on the machine, so a write from any of them renders the views reading it.
  var preferences = UserDefaults.standard
  @State private var page: SidebarDestination?

  init(
    session: ServerSession, selection: WindowSelection,
    tabContext: TabWindowContext = TabWindowContext(), serverSwitching: ServerSwitching? = nil,
    openInNewWindow: (@MainActor (String) -> Void)? = nil,
    preferences: UserDefaults = .standard
  ) {
    self.session = session
    self.selection = selection
    self.tabContext = tabContext
    self.serverSwitching = serverSwitching
    self.openInNewWindow = openInNewWindow
    self.preferences = preferences
    _page = State(initialValue: selection.page)
  }

  var body: some View {
    ServerRootView(
      session: session, selection: $page, openInNewWindow: openInNewWindow,
      tabContext: tabContext, serverSwitching: serverSwitching
    )
    .modifier(HostedSelection(selection: selection, page: $page))
    .defaultAppStorage(preferences)
  }
}

/// Keeps the root's page and the test's ``WindowSelection`` the same, in a body of its own.
private struct HostedSelection: ViewModifier {
  let selection: WindowSelection
  @Binding var page: SidebarDestination?

  func body(content: Content) -> some View {
    content
      .onChange(of: selection.page) { _, chosen in
        if page != chosen { page = chosen }
      }
      .onChange(of: page) { _, shown in
        if selection.page != shown { selection.page = shown }
      }
  }
}

/// The core's offline demo server, connected: sample sessions, with replies on a timer.
@MainActor
func connectedDemo() async throws -> ServerSession {
  SystemSideEffects.install()
  let session = try ServerSession.demo()
  await session.connection.connect(serverURL: ServerSession.demoServerURL)
  #expect(session.isSignedIn, "phase: \(session.connection.phase)")
  try await eventually("the demo's sessions") { session.connection.sessionList.isLoaded }
  return session
}

/// A server with sessions `conv_a`, `conv_b` and `conv_c` on one online host.
nonisolated func threeSessionServer() -> AppServer {
  let server = newSessionServer()
  let ids = ["conv_a", "conv_b", "conv_c"]
  let rows = ids.enumerated().map { index, id in
    sessionRow(id, host: "mac", workspace: "/work/\(id)", updatedAt: Int64(30 - index))
  }
  server.route(
    "/v1/sessions", method: "GET",
    .json(#"{"object":"list","data":[\#(rows.joined(separator: ","))],"has_more":false}"#))
  for (index, id) in ids.enumerated() {
    server.route("/v1/sessions/\(id)", .json(rows[index]))
  }
  return server
}

/// Where `formRequestServer()` takes the answer to its request.
nonisolated let formRequestResolvePath = "/v1/sessions/conv_a/elicitations/req/resolve"

/// `threeSessionServer()` whose `conv_a` waits on the form `req`: a required Title of at most
/// five characters.
nonisolated func formRequestServer() -> AppServer {
  let server = threeSessionServer()
  server.route(
    "/v1/sessions/conv_a", method: "GET",
    .json(
      #"""
      {"id":"conv_a","status":"idle","created_at":1,"permission_level":4,
      "pending_elicitations":[{"elicitation_id":"req","params":{"mode":"form",
      "message":"Name the change","requestedSchema":{"type":"object","required":["title"],
      "properties":{"title":{"type":"string","title":"Title","maxLength":5}}}}}]}
      """#))
  server.route(formRequestResolvePath, method: "POST", .json("{}"))
  server.route("/v1/sessions/conv_a/items", .json(#"{"data":[],"has_more":false}"#))
  return server
}

/// A store signed in to `server` with `conv_a` open and its form request read.
@MainActor
func storeWithFormRequest(_ server: AppServer) async throws -> ConnectionStore {
  SystemSideEffects.install()
  let streams = FakeEventStreamTransport()
  let connection = try await signedInStore(server, streams: streams)
  try await eventually("the list") { connection.sessionList.session("conv_a") != nil }
  let conversation = try #require(connection.conversation("conv_a"))
  // The first frame on the stream makes the core read the session and its request.
  let opened = await streams.waitForOpenedStream()
  opened.sink.response(
    status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/event-stream")])
  let heartbeat = #"event: session.heartbeat\#ndata: {"type":"session.heartbeat"}\#n\#n"#
  opened.sink.chunk(bytes: Data(heartbeat.utf8))
  try await eventually("the request") { conversation.decisions.cards.map(\.id) == ["req"] }
  return connection
}

/// Gives the keyboard to the editable field whose placeholder is `placeholder`, once it shows.
@MainActor
@discardableResult
func focusField<Content: View>(
  _ placeholder: String, in screen: OffscreenWindow<Content>
) async throws -> NSTextField {
  func shown() -> NSTextField? {
    screen.allViews.compactMap { $0 as? NSTextField }
      .first { $0.isEditable && $0.placeholderString == placeholder }
  }
  try await settle(screen, until: "the \(placeholder) field") { shown() != nil }
  let field = try #require(shown())
  screen.activeWindow.makeFirstResponder(field)
  return field
}

/// Answers `formRequestServer()`'s form on `screen`: a title over the limit, then one within
/// it and Submit. The core's problem must show and keep Submit from being pressed, and only
/// the second title be sent. In a list's row Submit is the control that comes to lead the
/// form's actions; in the transcript's table, whose cells' SwiftUI controls at times have no
/// focus proxy to find, it is found by `submitID`, its accessibility identifier.
@MainActor
func answerFormRequest<Content: View>(
  on screen: OffscreenWindow<Content>, server: AppServer, submitID: String? = nil
) async throws {
  let problem = "Title allows at most 5 characters."
  var field = try await focusField("Title", in: screen)
  try screen.type("Too long")
  try await settle(screen, untilShowing: problem)
  // Submit leads the form's actions once it can be pressed; until then Cancel stands alone.
  let withoutSubmit = formActions(under: field, in: screen).count

  field = try await focusField("Title", in: screen)
  field.currentEditor()?.selectAll(nil)
  try screen.type("Fix")
  try await settle(screen, until: "the problem to clear") {
    (try? screen.shows(problem)) == false
  }
  if let submitID {
    try screen.click(try center(of: submitID, in: screen))
  } else {
    try await settle(screen, until: "Submit to be offered") {
      formActions(under: field, in: screen).count > withoutSubmit
    }
    let offered = formActions(under: field, in: screen)
    let submit = try #require(offered.first, "\(screen.controlFrames)")
    #expect(offered.count == withoutSubmit + 1, "only Submit was held back: \(offered)")
    try screen.click(CGPoint(x: submit.midX, y: submit.midY))
  }
  try await settle(screen, until: "the answer to reach the server") {
    !server.requests("POST", formRequestResolvePath).isEmpty
  }
  let answers = try server.posted(formRequestResolvePath)
  #expect(answers.count == 1, "the title over the limit was never sent: \(answers)")
  #expect("\(answers)".contains("Fix"))
}

/// The controls on the first line under a form's `field`: its actions. Controls further down
/// (the composer's) come and go on their own.
@MainActor
private func formActions<Content: View>(
  under field: NSView, in screen: OffscreenWindow<Content>
) -> [CGRect] {
  let below = controls(under: field, in: screen)
  guard let first = below.first else { return [] }
  return below.filter { abs($0.midY - first.midY) < 8 }
}

/// A signed-in session over `server` whose links are only recorded.
@MainActor
func signedInSession(_ server: AppServer) async throws -> ServerSession {
  SystemSideEffects.install()
  let connection = try await signedInStore(server)
  try await eventually("the session list") { connection.sessionList.isLoaded }
  return ServerSession(connection: connection, opener: ExternalURLOpener { _ in true })
}

/// The connected view's actions, as its sidebar calls them, without a window.
@MainActor
func connectedView(
  _ session: ServerSession, _ selection: WindowSelection,
  opener: ExternalURLOpener = ExternalURLOpener { _ in true },
  serverSwitching: ServerSwitching? = nil, openInNewWindow: (@MainActor (String) -> Void)? = nil
) -> ConnectedServerView {
  ConnectedServerView(
    session: session, selection: selection.binding, sidebar: SidebarModel(), opener: opener,
    openInNewWindow: openInNewWindow, serverSwitching: serverSwitching)
}
