#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The phone's presentation of the dock: a sheet listing each request, each opening in full.
  @Suite("Decision dock: the phone's sheet", .serialized)
  @MainActor
  struct DecisionSheetTests {
    private let log = DecisionDockLog()

    private func request(_ id: String, answered: Bool = false) -> DecisionCard {
      .sample(id: id, detail: "Do \(id)", answered: answered)
    }

    private func phone(
      _ state: ConversationViewState
    ) -> (OffscreenWindow<DecisionDockScreen>, DecisionDockModelHost) {
      let host = DecisionDockModelHost(state)
      let screen = OffscreenWindow(
        DecisionDockScreen(host: host, actions: log.actions, layoutWidth: .compact))
      screen.settle()
      return (screen, host)
    }

    @Test("A phone shows one row and the count; Show all opens the list in a sheet")
    func showAll() throws {
      let (screen, _) = phone(.requests([request("one"), request("two")]))
      defer { screen.close() }
      #expect(try screen.shows("2 requests need you"))
      #expect(try screen.shows("Do one"))
      #expect(try !screen.shows("Do two"))
      #expect(try !screen.shows("Show 1 more"))
      try screen.tapButton(0)
      screen.settle(0.5)
      #expect(screen.window.attachedSheet != nil)
      #expect(screen.activeWindow.frame.height >= 560)
      #expect(try screen.shows("Do two"))
      // Done is the sheet's toolbar button.
      try screen.tapButton(fromEnd: 0)
      screen.settle(0.5)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("A row opens its request straight in the sheet, whose answer goes to the host")
    func openRow() throws {
      let (screen, _) = phone(.requests([.command("a\nb", id: "long")]))
      defer { screen.close() }
      // The row's own button.
      try screen.tapButton(0)
      screen.settle(0.5)
      #expect(screen.window.attachedSheet != nil)
      #expect(screen.activeWindow.frame.height >= 560)
      #expect(try screen.shows("Command approval"))
    }

    @Test("When nothing is left waiting the sheet closes")
    func closesWhenEmpty() throws {
      let (screen, host) = phone(.requests([request("one"), request("two")]))
      defer { screen.close() }
      try screen.tapButton(0)
      screen.settle(0.5)
      host.state = .requests([request("one", answered: true), request("two", answered: true)])
      screen.settle(0.5)
      #expect(screen.window.attachedSheet == nil)
    }

    private struct SheetHost: View {
      @Bindable var host: DecisionDockModelHost
      let actions: ConversationActions
      let start: [String]
      @State private var path: [String] = []
      @State private var closes = 0

      var body: some View {
        Color.clear.sheet(isPresented: .constant(true)) {
          VStack {
            Text(verbatim: "path \(path) closes \(closes)")
            DecisionSheet(
              state: host.state, actions: actions, path: $path, close: { closes += 1 })
          }
          .frame(width: 480, height: 500)
          .onAppear { path = start }
        }
      }
    }

    private func sheet(
      _ state: ConversationViewState, start: [String] = []
    ) -> (OffscreenWindow<SheetHost>, DecisionDockModelHost) {
      let host = DecisionDockModelHost(state)
      let screen = OffscreenWindow(SheetHost(host: host, actions: log.actions, start: start))
      screen.settle(0.5)
      return (screen, host)
    }

    @Test("The sheet lists each request with who asks")
    func list() throws {
      var state = ConversationViewState.requests([
        .command("swift test", id: "one"), request("two"),
      ])
      state.header.settings = SessionSettings(harness: "codex")
      let (screen, _) = sheet(state)
      defer { screen.close() }
      #expect(try screen.shows("Requests"))
      #expect(try screen.shows("Run swift test"))
      #expect(try screen.shows("Do two"))
      #expect(try screen.shows("Codex"))
    }

    @Test("An open request shows in full and answers to the host")
    func detail() throws {
      let (screen, _) = sheet(.requests([request("one")]), start: ["one"])
      defer { screen.close() }
      #expect(try screen.shows("Approval required"))
      #expect(try screen.shows("Do one"))
      // Back, then the card's own Approve.
      try screen.tapButton(1)
      #expect(log.responses == ["one:Approved"])
    }

    @Test("A request that's gone says it was answered")
    func gone() throws {
      let (screen, _) = sheet(.requests([request("one")]), start: ["missing"])
      defer { screen.close() }
      #expect(try screen.shows("Request answered"))
      #expect(try screen.shows("This request is no longer waiting for you."))
    }

    @Test("Answering the open request goes back to the list; answering them all closes")
    func returnsToList() throws {
      let (screen, host) = sheet(.requests([request("one"), request("two")]), start: ["one"])
      defer { screen.close() }
      #expect(try screen.shows("path [\"one\"] closes 0"))
      host.state = .requests([request("one", answered: true), request("two")])
      screen.settle(0.5)
      #expect(try screen.shows("path [] closes 0"))
      host.state = .requests([request("one", answered: true), request("two", answered: true)])
      screen.settle(0.5)
      #expect(try screen.shows("path [] closes 1"))
    }

    @Test("Another request being answered leaves the open one where it is")
    func staysOpen() throws {
      let (screen, host) = sheet(.requests([request("one"), request("two")]), start: ["one"])
      defer { screen.close() }
      host.state = .requests([request("one"), request("two", answered: true)])
      screen.settle(0.5)
      #expect(try screen.shows("path [\"one\"] closes 0"))
    }

    @Test("Done closes the sheet")
    func done() throws {
      let (screen, _) = sheet(.requests([request("one")]))
      defer { screen.close() }
      try screen.tapButton(fromEnd: 0)
      #expect(try screen.shows("closes 1"))
    }
  }
#endif
