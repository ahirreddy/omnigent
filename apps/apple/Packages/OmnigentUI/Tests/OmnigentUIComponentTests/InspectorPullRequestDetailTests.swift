#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  func pullRequestDetail(
    _ content: PullRequestDetailContent, spy: PullRequestSpy, listCount: Int = 2,
    edit: (inout PullRequestPanelExtras) -> Void = { _ in }
  ) -> OffscreenWindow<AnyView> {
    SystemSideEffects.reset()
    var extras = spy.extras
    extras.detail = content
    edit(&extras)
    let view = PullRequestDetailView(
      content: content, extras: extras, listCount: listCount, open: spy.open)
    return OffscreenWindow(AnyView(view), width: 700, height: 600)
  }

  @Suite("Inspector: an open pull request", .serialized)
  @MainActor
  struct InspectorPullRequestDetailTests {
    /// Back, Refresh, Open and Unlink, then the Summary, Comments and Changes picker.
    private enum Control {
      static let back = 0
      static let refresh = 1
      static let provider = 2
      static let unlink = 3
      static let picker = 4
    }

    private func pick(_ segment: Int, _ screen: OffscreenWindow<AnyView>) throws {
      let frame = screen.controlFrames[Control.picker]
      let width = frame.width / 3
      try screen.click(
        CGPoint(x: frame.minX + width * (CGFloat(segment) + 0.5), y: frame.midY))
    }

    @Test("Opening one from the list shows it in place of the list")
    func replacesList() throws {
      let spy = PullRequestSpy()
      var extras = spy.extras
      extras.detail = .ready(PullRequestFixture.detail)
      let screen = OffscreenWindow(
        AnyView(
          PullRequestsPanel(
            state: .loaded([PullRequestFixture.summary()], synced: true), extras: extras,
            open: spy.open, refresh: nil)),
        width: 700, height: 500)
      defer { screen.close() }
      #expect(try screen.shows("All pull requests (1)"))
      #expect(try !screen.shows("1 pull request"))
    }

    @Test("While loading, or when it can't load, it says so; failure can try again")
    func notReady() throws {
      let spy = PullRequestSpy()
      let loading = pullRequestDetail(.loading, spy: spy)
      defer { loading.close() }
      #expect(loading.allViews.contains { $0 is NSProgressIndicator })

      let failed = pullRequestDetail(.failed("boom"), spy: spy)
      defer { failed.close() }
      #expect(try failed.shows("Couldn't Load the Pull Request"))
      #expect(try failed.shows("boom"))
      // Back, the toolbar's Refresh, then Try Again.
      try failed.clickControl(at: 2)
      #expect(spy.calls == ["refresh"])

      let gone = pullRequestDetail(
        .unavailable(title: "Not found", message: "It's gone", systemImage: "questionmark"),
        spy: spy)
      defer { gone.close() }
      #expect(try gone.shows("Not found"))
      #expect(try gone.shows("It's gone"))
    }

    @Test("A failure with no way to refresh has no Try Again")
    func failedWithoutRefresh() {
      let spy = PullRequestSpy()
      let screen = pullRequestDetail(.failed("boom"), spy: spy) { $0.actions.refresh = nil }
      defer { screen.close() }
      // Only Back.
      #expect(screen.controlFrames.count == 1)
    }

    @Test("The bar goes back, refreshes, opens the page and unlinks")
    func toolbar() throws {
      let spy = PullRequestSpy()
      let screen = pullRequestDetail(.ready(PullRequestFixture.detail), spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("All pull requests (2)"))
      try screen.clickControl(at: Control.back)
      try screen.clickControl(at: Control.refresh)
      try screen.clickControl(at: Control.provider)
      try screen.clickControl(at: Control.unlink)
      #expect(spy.calls == ["show list", "refresh", "unlink \(PullRequestFixture.url)"])
      #expect(spy.opened == [URL(string: PullRequestFixture.url)])
    }

    @Test("The bar drops what the app can't do, and a bad address can't open")
    func toolbarWithout() {
      let spy = PullRequestSpy()
      var state = PullRequestFixture.detail
      state.url = ""
      let screen = pullRequestDetail(.ready(state), spy: spy) {
        $0.actions = PullRequestPanelActions()
      }
      defer { screen.close() }
      // Only the tab picker is left.
      #expect(screen.controlFrames.count == 1)
    }

    @Test("Unlink can't run while a change is in flight")
    func unlinkBusy() throws {
      let spy = PullRequestSpy()
      let busy = pullRequestDetail(.ready(PullRequestFixture.detail), spy: spy) { $0.isBusy = true }
      defer { busy.close() }
      try busy.clickControl(at: Control.unlink)
      #expect(spy.calls.isEmpty)
    }

    @Test("A failed change shows above the content")
    func errorBar() throws {
      let spy = PullRequestSpy()
      let screen = pullRequestDetail(.ready(PullRequestFixture.detail), spy: spy) {
        $0.error = "Couldn't merge"
      }
      defer { screen.close() }
      #expect(try screen.shows("Couldn't merge"))
    }

    @Test("The heading shows where it lives, its title, number and status")
    func heading() throws {
      let spy = PullRequestSpy()
      let screen = pullRequestDetail(.ready(PullRequestFixture.detail), spy: spy)
      defer { screen.close() }
      for line in ["acme/app: sidebar to main", "Add the sidebar", "#7", "Ready to merge"] {
        #expect(try screen.shows(line))
      }
    }

    @Test("The tabs switch between summary, comments and changes")
    func tabs() throws {
      let spy = PullRequestSpy()
      let screen = pullRequestDetail(.ready(PullRequestFixture.detail), spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("No description provided."))
      try pick(1, screen)
      #expect(try screen.shows("No comments yet."))
      #expect(try !screen.shows("No description provided."))
      try pick(2, screen)
      #expect(try screen.shows("The pull request's changes appear here."))
      try pick(0, screen)
      #expect(try screen.shows("No description provided."))
    }

    @Test("The Changes tab shows what the app supplies")
    func changesSlot() throws {
      let spy = PullRequestSpy()
      let screen = pullRequestDetail(.ready(PullRequestFixture.detail), spy: spy) {
        $0.changes = AnyView(Text("the stacked diff"))
      }
      defer { screen.close() }
      try pick(2, screen)
      #expect(try screen.shows("the stacked diff"))
    }

    @Test("Tab titles count comments and files, and say when some are missing")
    func tabTitles() {
      var state = PullRequestFixture.detail
      #expect(PullRequestDetailTab.summary.title(state) == "Summary")
      #expect(PullRequestDetailTab.comments.title(state) == "Comments")
      #expect(PullRequestDetailTab.changes.title(state) == "Changes")
      state.comments = [
        PullRequestCommentRow(id: "c", author: "sam", date: nil, body: "ok", url: nil)
      ]
      state.fileCount = 3
      #expect(PullRequestDetailTab.comments.title(state) == "Comments 1")
      #expect(PullRequestDetailTab.changes.title(state) == "Changes 3")
      state.commentsPartial = true
      #expect(PullRequestDetailTab.comments.title(state) == "Comments 1+")
      #expect(PullRequestDetailTab.comments.id == "comments")
    }
  }

  @Suite("Inspector: a pull request's comments", .serialized)
  @MainActor
  struct InspectorPullRequestCommentsTests {
    private func comments(
      _ edit: (inout PullRequestDetailViewState) -> Void = { _ in }, spy: PullRequestSpy,
      isBusy: Bool = false
    ) -> OffscreenWindow<AnyView> {
      var state = PullRequestFixture.detail
      edit(&state)
      var extras = spy.extras
      extras.isBusy = isBusy
      let view = PullRequestCommentsView(state: state, extras: extras, open: spy.open)
      return OffscreenWindow(AnyView(view), width: 600, height: 400)
    }

    @Test("No comments says so; a partial read says some are missing")
    func emptyAndPartial() throws {
      let spy = PullRequestSpy()
      let none = comments(spy: spy)
      defer { none.close() }
      #expect(try none.shows("No comments yet."))
      #expect(try !none.shows("Some comments are unavailable."))
      let partial = comments({ $0.commentsPartial = true }, spy: spy)
      defer { partial.close() }
      #expect(try partial.shows("Some comments are unavailable."))
      #expect(try !partial.shows("No comments yet."))
    }

    @Test("A comment shows who and what, with a link to it on the provider")
    func card() throws {
      let spy = PullRequestSpy()
      let link = URL(string: "https://example.test/c")
      let screen = comments(
        {
          $0.comments = [
            PullRequestCommentRow(
              id: "c", author: "sam", date: Date(timeIntervalSince1970: 0), body: "Looks good",
              url: link),
            PullRequestCommentRow(id: "d", author: "kim", date: nil, body: "Nit", url: nil),
          ]
        }, spy: spy)
      defer { screen.close() }
      for line in ["sam", "Looks good", "kim", "Nit"] {
        #expect(try screen.shows(line))
      }
      #expect(try !screen.shows("No comments yet."))
      // Only the first comment has a link.
      try screen.clickControl(at: 0)
      #expect(spy.opened == [link])
    }

    @Test("Without permission, or a way to post, there's no field")
    func noComposer() {
      let spy = PullRequestSpy()
      let screen = comments(spy: spy)
      defer { screen.close() }
      #expect(screen.firstTextField == nil)
    }

    @Test("Comment posts what's typed and clears it when the post went through")
    func posting() throws {
      let spy = PullRequestSpy()
      let screen = comments({ $0.canComment = true }, spy: spy)
      defer { screen.close() }
      // The Comment button can't run until there's text: only the field is listed.
      #expect(screen.controlFrames.count == 1)
      try screen.typeIntoField("Ship it")
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["comment Ship it"])
      spy.commentFinished?(false)
      screen.settle()
      #expect(screen.firstTextField?.stringValue == "Ship it")
      spy.commentFinished?(true)
      screen.settle()
      #expect(screen.firstTextField?.stringValue.isEmpty == true)
    }

    @Test("Text typed while a comment posts stays in the field")
    func typedWhilePosting() throws {
      let spy = PullRequestSpy()
      let screen = comments({ $0.canComment = true }, spy: spy)
      defer { screen.close() }
      try screen.typeIntoField("Ship")
      try screen.clickControl(at: 1)
      try screen.typeIntoField(" it")
      spy.commentFinished?(true)
      screen.settle()
      #expect(screen.firstTextField?.stringValue.isEmpty == false)
    }

    @Test("Comment can't run while a change is in flight")
    func busy() throws {
      let spy = PullRequestSpy()
      let screen = comments({ $0.canComment = true }, spy: spy, isBusy: true)
      defer { screen.close() }
      try screen.typeIntoField("Ship it")
      #expect(screen.controlFrames.count == 1)
    }
  }
#endif
