import AppKit
import SwiftUI
import Testing

@testable import OmnigentTerminalUI

private let hostileText = [
  "", "\u{202E}مرحبا שלום 👩‍👩‍👧‍👦 e\u{0301}", "first\nsecond\t\r\n\u{0}end",
  String(repeating: "W", count: 10_000),
]

private struct ListState {
  let rows: [TerminalListItem]
  let canEdit: Bool
  let shells: [String]
  let error: String?
}

@Suite("Terminal views, offscreen", .serialized)
struct TerminalViewRenderTests {
  @Test("the status overlay draws every state with hostile reasons")
  func statusOverlay() {
    var states: [TerminalConnectionState] = [.idle, .connecting, .attached(readOnly: true)]
    for text in hostileText {
      states += [
        .reconnecting(failures: .min, retryInMilliseconds: 1, reason: text),
        .reconnecting(failures: .max, retryInMilliseconds: 0, reason: text),
        .reconnecting(failures: 0, retryInMilliseconds: .min, reason: text),
        .reconnecting(failures: 1, retryInMilliseconds: Int.max - 999, reason: text),
        .closed(.terminalEnded(reason: text)), .closed(.detached(reason: text)),
        .closed(.serverClosed(code: .min, reason: text)), .closed(.stopped),
        .failed(TerminalFailure(message: text)),
        .failed(TerminalFailure(message: text, requiresSignIn: true, readOnlyMayWork: true)),
      ]
    }
    for state in states {
      #expect(OffscreenRender.draw(TerminalStatusOverlay(state: state) {}, settle: 0) > 0)
    }
  }

  @Test(
    "a retry delay near the largest Int reads as a long wait")
  func hugeRetryDelay() {
    let state = TerminalConnectionState.reconnecting(
      failures: 1, retryInMilliseconds: .max, reason: "lost")
    #expect(OffscreenRender.draw(TerminalStatusOverlay(state: state) {}, settle: 0) > 0)
  }

  @Test("banners, badges and the unavailable view draw hostile text")
  func banners() throws {
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    for text in hostileText {
      #expect(OffscreenRender.draw(TerminalErrorBanner(message: text) {}, settle: 0) > 0)
      #expect(OffscreenRender.draw(TerminalUnavailableView(message: text), settle: 0) > 0)
      let pending = PendingClipboardWrite(id: UUID(), text: text)
      #expect(
        OffscreenRender.draw(
          ClipboardConsentBanner(controller: controller, pending: pending), settle: 0) > 0)
    }
    for status in [TerminalListStatus.active, .idle, .exited, .unknown] {
      #expect(OffscreenRender.draw(TerminalStatusBadge(status: status), settle: 0) > 0)
    }
  }

  @Test("the list draws empty, hostile and long, with and without edit access")
  func listView() {
    var items: [TerminalListItem] = []
    for (index, text) in hostileText.enumerated() {
      items.append(
        TerminalListItem(
          id: "hostile-\(index)", title: text, status: .unknown, isAgentTerminal: index == 1))
    }
    for index in 0..<300 {
      items.append(
        TerminalListItem(
          id: "row-\(index)", title: "zsh \(index)", status: .idle, isAgentTerminal: false))
    }
    // A repeated id, which List has to survive.
    items.append(
      TerminalListItem(id: "row-1", title: "again", status: .exited, isAgentTerminal: false))
    let states = [
      ListState(rows: [], canEdit: false, shells: [], error: nil),
      ListState(rows: [], canEdit: true, shells: ["zsh", "zsh", ""], error: hostileText[1]),
      ListState(rows: items, canEdit: true, shells: ["zsh"], error: hostileText[3]),
      ListState(rows: items, canEdit: false, shells: [], error: ""),
    ]
    for state in states {
      let view = TerminalListView(
        items: state.rows, shellChoices: state.shells, canEdit: state.canEdit,
        errorMessage: state.error, selection: .constant("missing"), onCreate: { _ in },
        onClose: { _ in })
      #expect(OffscreenRender.draw(NavigationStack { view }) > 0)
    }
  }

  @Test("the find bar draws match counts of every kind")
  func findBar() throws {
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    let searches = [
      TerminalSearch(needle: ""), TerminalSearch(needle: "", total: 0),
      TerminalSearch(needle: "", total: 3), TerminalSearch(needle: "", total: 3, selected: 1),
      TerminalSearch(needle: "", total: .max, selected: .max - 1),
      TerminalSearch(needle: "", total: -1, selected: -1),
      TerminalSearch(needle: "", total: 3, selected: -5),
    ]
    for search in searches {
      controller.search = search
      #expect(OffscreenRender.draw(TerminalFindBar(controller: controller), settle: 0) > 0)
    }
    controller.search = TerminalSearch(needle: hostileText[3])
    #expect(OffscreenRender.draw(TerminalFindBar(controller: controller)) > 0)
    #expect(controller.search?.needle == hostileText[3])
  }

  @Test(
    "a selected match at the largest Int reads as a count")
  func hugeSelectedMatch() throws {
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    controller.search = TerminalSearch(needle: "", total: .max, selected: .max)
    #expect(OffscreenRender.draw(TerminalFindBar(controller: controller), settle: 0) > 0)
  }

  @Test("a session terminal draws with each overlay at once, in both color schemes")
  func sessionTerminal() async throws {
    let surface = try NeverShownSurface(
      connection: EchoTerminalConnection(prompt: "$ ", banner: "ready", readOnly: true))
    let controller = surface.controller
    #expect(await surface.ready())
    #expect(await eventually { controller.state == .attached(readOnly: true) })
    controller.search = TerminalSearch(needle: "", total: 2, selected: 0)
    controller.remoteCopied(hostileText[3], policy: .ask)
    controller.report(hostileText[3])
    surface.window.contentView = nil
    for scheme in [ColorScheme.dark, .light] {
      let view = SessionTerminalView(controller: controller).environment(\.colorScheme, scheme)
      #expect(OffscreenRender.draw(view) > 0)
      #expect(controller.runtime.appearance.colorScheme == (scheme == .dark ? .dark : .light))
    }
  }

  @Test("a session terminal with its own controller starts the connection once it appears")
  func ownController() async throws {
    let connection = EchoTerminalConnection()
    #expect(OffscreenRender.draw(SessionTerminalView(connection: connection), settle: 0.2) > 0)
    #expect(await eventually { connection.state == .attached(readOnly: false) })
  }

  @Test("the holder creates one controller, whatever it is asked")
  func holder() throws {
    let holder = TerminalControllerHolder()
    let connection = EchoTerminalConnection()
    holder.load(connection)
    let first = try #require(try holder.result?.get())
    holder.load(EchoTerminalConnection())
    #expect(try holder.result?.get() === first)
    #expect(first.connection === connection)
  }

  @Test("settings draw for the live runtime")
  func settings() throws {
    _ = try GhosttyRuntime.shared()
    #expect(OffscreenRender.draw(TerminalSettingsView(), settle: 0.2) > 0)
    #expect(!TerminalFonts.monospacedFamilies().isEmpty)
    #expect(!TerminalFonts.isInstalled(""))
    #expect(!TerminalFonts.isInstalled(".hidden"))
    #expect(!TerminalFonts.isInstalled("\u{0}"))
    #expect(!TerminalFonts.isInstalled(String(repeating: "W", count: 100_000)))
    #expect(TerminalAppearance.system().fontSize == 13)
  }

  @Test("every gallery page draws", arguments: TerminalGalleryView.Page.allCases)
  func galleryPages(page: TerminalGalleryView.Page) {
    #expect(!page.title.isEmpty)
    #expect(page.id == page.rawValue)
    let view = TerminalGalleryView(initialPage: page)
    #expect(OffscreenRender.draw(view, width: 900, height: 600, settle: 0.3) > 0)
  }

  @Test("the gallery model's list creates, selects and closes")
  func galleryModel() {
    let model = TerminalGalleryModel()
    #expect(model.states.count == 4)
    #expect(model.listItems.count == 3)
    model.create("")
    model.create("\u{202E}x y")
    #expect(model.listItems.count == 5)
    #expect(model.listSelection == model.listItems.last?.id)
    for item in model.listItems {
      model.close(item.id)
      model.close(item.id)
    }
    #expect(model.listItems.isEmpty)
    #expect(model.listSelection == nil)
    if case .success = model.listController(for: "missing") {
      Issue.record("a missing terminal has no controller")
    }
  }

  @Test("a shell gone with its host reads as that, and other failures keep their message")
  func shellGoneText() {
    #expect(
      TerminalStatusOverlay.shellIsGone(
        "the server could not attach the terminal: runner attach factory failed"))
    #expect(!TerminalStatusOverlay.shellIsGone("the server could not attach the terminal: busy"))
  }
}
