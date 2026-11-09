#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inspector: the pull requests list", .serialized)
  @MainActor
  struct InspectorPullRequestListTests {
    private func panel(
      _ state: PullRequestsPanelState, spy: PullRequestSpy, extras: PullRequestPanelExtras? = nil,
      hasRefresh: Bool = true
    ) -> OffscreenWindow<AnyView> {
      SystemSideEffects.reset()
      var refresh: (@MainActor () -> Void)?
      if hasRefresh { refresh = { spy.calls.append("refresh") } }
      return OffscreenWindow(
        AnyView(
          PullRequestsPanel(
            state: state, extras: extras ?? spy.extras, open: spy.open, refresh: refresh)),
        width: 500, height: 500)
    }

    @Test("Each read state says where things stand")
    func readStates() throws {
      let spy = PullRequestSpy()
      let loading = panel(.loading, spy: spy)
      defer { loading.close() }
      #expect(loading.allViews.contains { $0 is NSProgressIndicator })

      let unsupported = panel(.unsupported, spy: spy)
      defer { unsupported.close() }
      #expect(try unsupported.shows("This server doesn't track pull requests."))

      let notRead = panel(.loaded([], synced: false), spy: spy)
      defer { notRead.close() }
      #expect(try notRead.shows("Looking for pull requests"))
      #expect(
        try notRead.shows("The server hasn't read this session's pull requests from its host yet."))

      let none = panel(.loaded([], synced: true), spy: spy)
      defer { none.close() }
      #expect(try none.shows("No pull requests"))
    }

    @Test("A failed read says why and tries again")
    func failedRead() throws {
      let spy = PullRequestSpy()
      let screen = panel(.failed("boom"), spy: spy, extras: PullRequestPanelExtras())
      defer { screen.close() }
      #expect(try screen.shows("Couldn't Load Pull Requests"))
      #expect(try screen.shows("boom"))
      spy.calls = []
      // The toolbar's Refresh, then Try Again.
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["refresh"])
    }

    @Test("Without a way to refresh, a failed read has no Try Again and no toolbar")
    func failedWithoutRefresh() throws {
      let spy = PullRequestSpy()
      let screen = OffscreenWindow(
        AnyView(PullRequestsPanel(state: .failed("boom"), open: spy.open, refresh: nil)),
        width: 500,
        height: 500)
      defer { screen.close() }
      #expect(screen.controlFrames.isEmpty)
      #expect(try !screen.shows("0 pull requests"))
    }

    @Test("Showing the tab refreshes it, and the toolbar's Refresh does it again")
    func refreshes() async throws {
      let spy = PullRequestSpy()
      let screen = panel(.loaded([], synced: true), spy: spy, extras: PullRequestPanelExtras())
      defer { screen.close() }
      try await Task.sleep(for: .milliseconds(30))
      screen.settle(0.05)
      #expect(spy.calls == ["refresh"])
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["refresh", "refresh"])
    }

    @Test("The toolbar counts in words")
    func counts() throws {
      let spy = PullRequestSpy()
      let one = panel(.loaded([PullRequestFixture.summary()], synced: true), spy: spy)
      defer { one.close() }
      #expect(try one.shows("1 pull request"))
      let two = panel(
        .loaded([PullRequestFixture.summary(), PullRequestFixture.summary(id: "8")], synced: true),
        spy: spy)
      defer { two.close() }
      #expect(try two.shows("2 pull requests"))
    }

    @Test("Choosing a row opens it in the panel when the app can read it")
    func selectsRow() throws {
      let spy = PullRequestSpy()
      let screen = panel(.loaded([PullRequestFixture.summary()], synced: true), spy: spy)
      defer { screen.close() }
      spy.calls = []
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(spy.calls == ["select \(PullRequestFixture.url)"])
      #expect(spy.opened.isEmpty)
    }

    @Test("Otherwise choosing a row opens its page; a broken address does nothing")
    func opensRow() throws {
      let spy = PullRequestSpy()
      let good = OffscreenWindow(
        AnyView(PullRequestList(pullRequests: [PullRequestFixture.summary()], open: spy.open)),
        width: 500, height: 300)
      defer { good.close() }
      try good.clickControl(at: good.controlFrames.count - 1)
      #expect(spy.opened == [URL(string: PullRequestFixture.url)])

      let broken = OffscreenWindow(
        AnyView(
          PullRequestList(pullRequests: [PullRequestFixture.summary(url: "")], open: spy.open)),
        width: 500, height: 300)
      defer { broken.close() }
      try broken.clickControl(at: broken.controlFrames.count - 1)
      #expect(spy.opened.count == 1)
    }

    @Test("A row reads as title, status, repository and number, and its detail")
    func rowContent() throws {
      let spy = PullRequestSpy()
      let screen = panel(
        .loaded(
          [PullRequestFixture.summary(status: .merged, detail: "2 checks failing")], synced: true),
        spy: spy)
      defer { screen.close() }
      for line in ["Add the sidebar", "Merged", "acme/app #7", "2 checks failing"] {
        #expect(try screen.shows(line))
      }
    }

    @Test("A row's menu opens, copies and unlinks")
    func rowMenu() throws {
      let spy = PullRequestSpy()
      let list = PullRequestList(
        pullRequests: [PullRequestFixture.summary()], open: spy.open, actions: spy.actions)
      SystemSideEffects.reset()
      let screen = OffscreenWindow(AnyView(list), width: 500, height: 300)
      defer { screen.close() }
      func menu() throws -> NSMenu {
        try #require(try screen.menu(ofRow: 0))
      }
      #expect(try menu().titles == ["Open in Browser", "Copy Link", "Unlink"])
      try screen.choose("Open in Browser", in: menu())
      #expect(spy.opened == [URL(string: PullRequestFixture.url)])
      try screen.choose("Copy Link", in: menu())
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == PullRequestFixture.url)
      try screen.choose("Unlink", in: menu())
      #expect(spy.calls == ["unlink \(PullRequestFixture.url)"])
    }

    @Test("A row with a broken address offers only what doesn't need it")
    func brokenAddressMenu() throws {
      let spy = PullRequestSpy()
      let list = PullRequestList(
        pullRequests: [PullRequestFixture.summary(url: "")], open: spy.open, actions: spy.actions)
      let screen = OffscreenWindow(AnyView(list), width: 500, height: 300)
      defer { screen.close() }
      #expect(try #require(try screen.menu(ofRow: 0)).titles == ["Unlink"])
    }

    @Test("Each status has its symbol, and finished states share no color with live ones")
    func statuses() {
      let all: [PullRequestSummary.Status] = [
        .conflicts, .failing, .ready, .running, .open, .draft, .merged, .closed, .unknown,
      ]
      // Open and unknown share the plain pull request symbol.
      #expect(Set(all.map(PullRequestStatusIcon.symbol)).count == all.count - 1)
      #expect(PullRequestStatusIcon.color(.merged) != PullRequestStatusIcon.color(.ready))
      #expect(PullRequestStatusIcon.color(.closed) == PullRequestStatusIcon.color(.failing))
      #expect(PullRequestStatusIcon.color(.running) != PullRequestStatusIcon.color(.draft))
      #expect(PullRequestStatusIcon.color(.open) == PullRequestStatusIcon.color(.ready))
      #expect(PullRequestStatusIcon.color(.unknown) == PullRequestStatusIcon.color(.draft))
    }
  }

  @Suite("Inspector: linking a pull request", .serialized)
  @MainActor
  struct InspectorPullRequestLinkTests {
    private func panel(_ spy: PullRequestSpy, extras: PullRequestPanelExtras? = nil)
      -> OffscreenWindow<AnyView>
    {
      OffscreenWindow(
        AnyView(
          PullRequestsPanel(
            state: .loaded([PullRequestFixture.summary()], synced: true),
            extras: extras ?? spy.extras, open: spy.open, refresh: nil)),
        width: 500, height: 400)
    }

    /// Opens the field with the toolbar's Link a PR.
    private func openField(_ screen: OffscreenWindow<AnyView>) throws {
      try screen.clickControl(at: 0)
    }

    @Test("Link a PR opens a field; Link can't run until there's an address")
    func linkDisabledUntilTyped() throws {
      let spy = PullRequestSpy()
      let screen = panel(spy)
      defer { screen.close() }
      let closed = screen.controlFrames.count
      try openField(screen)
      #expect(screen.firstTextField != nil)
      // The field and Cancel are new; Link is disabled.
      #expect(screen.controlFrames.count == closed + 2)
      try screen.typeIntoField("  ")
      #expect(screen.controlFrames.count == closed + 2)
      try screen.typeIntoField("https://example.test/1")
      #expect(screen.controlFrames.count == closed + 3)
    }

    @Test("Link sends the address; the field closes only if it worked")
    func linking() throws {
      let spy = PullRequestSpy()
      let screen = panel(spy)
      defer { screen.close() }
      try openField(screen)
      try screen.typeIntoField("https://example.test/1")
      // Link a PR, the field, Link, Cancel.
      try screen.clickControl(at: 2)
      #expect(spy.calls == ["link https://example.test/1"])
      spy.linkFinished?(false)
      screen.settle()
      #expect(screen.firstTextField != nil)
      spy.linkFinished?(true)
      screen.settle()
      #expect(screen.firstTextField == nil)
    }

    @Test("Return links too; Escape and Cancel close the field")
    func keys() throws {
      let spy = PullRequestSpy()
      let screen = panel(spy)
      defer { screen.close() }
      try openField(screen)
      try screen.typeIntoField("https://example.test/1")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls == ["link https://example.test/1"])
      try screen.press(keyCode: 53, characters: "\u{1B}")
      #expect(screen.firstTextField == nil)

      try openField(screen)
      #expect(screen.firstTextField != nil)
      // Link a PR, the field and Cancel: Link is disabled while the field is empty.
      try screen.clickControl(at: 2)
      #expect(screen.firstTextField == nil)
    }

    @Test("Link a PR closes the field it opened")
    func toggleField() throws {
      let spy = PullRequestSpy()
      let screen = panel(spy)
      defer { screen.close() }
      try openField(screen)
      try openField(screen)
      #expect(screen.firstTextField == nil)
    }

    @Test("While a change is in flight, neither Link nor Return links")
    func busy() throws {
      let spy = PullRequestSpy()
      var extras = spy.extras
      extras.isBusy = true
      let screen = panel(spy, extras: extras)
      defer { screen.close() }
      try openField(screen)
      try screen.typeIntoField("https://example.test/1")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls.isEmpty)
    }

    @Test("The empty list offers Link a PR, and stops offering it once the field is open")
    func linkFromEmpty() throws {
      let spy = PullRequestSpy()
      let screen = OffscreenWindow(
        AnyView(
          PullRequestsPanel(
            state: .loaded([], synced: true), extras: spy.extras, open: spy.open, refresh: nil)),
        width: 500, height: 400)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 2)
      try screen.clickControl(at: 1)
      #expect(screen.firstTextField != nil)
      // Link a PR in the toolbar, the field and Cancel.
      #expect(screen.controlFrames.count == 3)
    }

    @Test("A failed change shows above the list and can be dismissed")
    func errorBar() throws {
      let spy = PullRequestSpy()
      var extras = spy.extras
      extras.error = "Couldn't link"
      let screen = panel(spy, extras: extras)
      defer { screen.close() }
      #expect(try screen.shows("Couldn't link"))
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["dismiss error"])
    }

    @Test("An error with no way to dismiss it has no X")
    func errorBarWithoutDismiss() {
      let screen = OffscreenWindow(
        AnyView(PullRequestErrorBar(message: "Couldn't link", dismiss: nil)), width: 400,
        height: 100)
      defer { screen.close() }
      #expect(screen.controlFrames.isEmpty)
    }
  }
#endif
