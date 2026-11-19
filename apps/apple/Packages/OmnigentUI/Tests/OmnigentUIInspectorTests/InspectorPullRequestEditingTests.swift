#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The open PR's stored fallback, its commit activity, and editing its title and description.
  @Suite("Inspector: a pull request offline, its activity, and its text", .serialized)
  @MainActor
  struct InspectorPullRequestEditingTests {
    private static let stored = PullRequestStoredViewState(
      url: PullRequestFixture.url, title: "Add the sidebar", numberLabel: "#7",
      repository: "acme/app", status: .open, providerName: "GitHub",
      hint:
        "Last sync time: today. To load the PR details, please reconnect the session\u{2019}s host."
    )

    private func editable(_ edit: (inout PullRequestDetailViewState) -> Void = { _ in })
      -> PullRequestDetailViewState
    {
      var state = PullRequestFixture.detail
      state.canEditDetails = true
      edit(&state)
      return state
    }

    @Test("With the host offline it shows the stored PR, and it can still open and unlink")
    func storedFallback() throws {
      let spy = PullRequestSpy()
      let screen = pullRequestDetail(.stored(Self.stored), spy: spy)
      defer { screen.close() }
      for line in ["acme/app", "Add the sidebar", "#7", "Open", "please reconnect"] {
        #expect(try screen.shows(line))
      }
      // Back, Refresh, Link a PR, Open and Unlink, then the title's link.
      try screen.clickControl(at: 4)
      #expect(spy.calls == ["unlink \(PullRequestFixture.url)"])
      try screen.clickControl(at: 5)
      #expect(spy.opened == [URL(string: PullRequestFixture.url)])
    }

    @Test("Commits and force pushes read as the web words them")
    func timeline() throws {
      let spy = PullRequestSpy()
      var state = PullRequestFixture.detail
      state.timeline = [
        PullRequestTimelineRow(
          id: "c", kind: .commit, author: "ann", date: Date(timeIntervalSince1970: 0),
          sha: "1234567890", message: "Add the sidebar rows",
          url: URL(string: "https://example.test/c")),
        PullRequestTimelineRow(
          id: "f", kind: .forcePush(previousSHA: "abcdef0123"), author: "bob", date: nil,
          sha: nil, message: nil, url: nil),
      ]
      state.timelinePartial = true
      let screen = OffscreenWindow(
        AnyView(PullRequestCommentsView(state: state, extras: spy.extras, open: spy.open)),
        width: 600, height: 400)
      defer { screen.close() }
      for line in [
        "committed", "1234567", "Add the sidebar rows", "force-pushed", "abcdef0", "the branch",
        "Some commit and push history is unavailable.",
      ] {
        #expect(try screen.shows(line))
      }
      #expect(try !screen.shows("No comments yet."))
    }

    @Test("A kept comment draft shows again, and one over the limit says why it can't post")
    func keptCommentDraft() throws {
      var state = PullRequestFixture.detail
      state.canComment = true
      var extras = PullRequestPanelExtras()
      extras.actions.comment = { _, done in done(true) }
      extras.actions.commentProblem = {
        $0.count > 5 ? "A comment can be at most 5 characters." : nil
      }
      let screen = OffscreenWindow(
        AnyView(
          PullRequestCommentsView(
            state: state, extras: extras, open: nil, keptDraft: .constant("Looks too long"))),
        width: 600, height: 300)
      defer { screen.close() }
      #expect(screen.firstTextField?.stringValue == "Looks too long")
      #expect(try screen.shows("A comment can be at most 5 characters."))
    }

    /// Holds the description draft the detail view would.
    private struct DescriptionHost: View {
      let state: PullRequestDetailViewState
      let extras: PullRequestPanelExtras
      @State private var draft: PullRequestDescriptionDraft?

      var body: some View {
        PullRequestDescriptionSection(state: state, extras: extras, draft: $draft)
          .padding()
      }
    }

    @Test("An editor changes the title in place; an unchanged title just closes")
    func editsTitle() throws {
      var saved: [String?] = []
      var extras = PullRequestPanelExtras()
      extras.actions.editDetails = { title, _, done in
        saved.append(title)
        done(true)
      }
      let screen = OffscreenWindow(
        AnyView(PullRequestDetailHeader(state: editable(), extras: extras).padding()),
        width: 600, height: 120)
      defer { screen.close() }
      // The pencil.
      #expect(screen.controlFrames.count == 1)
      try screen.clickControl(at: 0)
      #expect(screen.firstTextField?.stringValue == "Add the sidebar")
      // The field, Save and Cancel.
      try screen.clickControl(at: 1)
      #expect(saved.isEmpty, "an unchanged title saves nothing")
      #expect(screen.firstTextField == nil)
      try screen.clickControl(at: 0)
      try screen.typeIntoField(" rows")
      try screen.clickControl(at: 1)
      #expect(saved == ["Add the sidebar rows"])
      #expect(screen.firstTextField == nil)
    }

    @Test("Without details editing there's no pencil")
    func readOnlyText() {
      var extras = PullRequestPanelExtras()
      extras.actions.editDetails = { _, _, _ in }
      let header = OffscreenWindow(
        AnyView(PullRequestDetailHeader(state: PullRequestFixture.detail, extras: extras)),
        width: 600, height: 120)
      defer { header.close() }
      #expect(header.controlFrames.isEmpty)
      let description = OffscreenWindow(
        AnyView(DescriptionHost(state: PullRequestFixture.detail, extras: extras)),
        width: 600, height: 200)
      defer { description.close() }
      #expect(description.controlFrames.isEmpty)
    }

    @Test("The description opens in an editor that saves its Markdown, with Attach")
    func editsDescription() throws {
      var saved: [String?] = []
      var extras = PullRequestPanelExtras()
      extras.actions.editDetails = { _, body, done in
        saved.append(body)
        done(true)
      }
      extras.actions.attach = { _, _ in }
      let screen = OffscreenWindow(
        AnyView(DescriptionHost(state: editable { $0.canAttach = true }, extras: extras)),
        width: 600, height: 480)
      defer { screen.close() }
      #expect(try screen.shows("No description provided."))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("Write"))
      #expect(try screen.shows("Preview"))
      // Save is the last control; unchanged, it just closes.
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(saved.isEmpty)
      #expect(try screen.shows("No description provided."))

      try screen.clickControl(at: 0)
      let editor = try #require(screen.allViews.first { $0 is NSTextView && $0.frame.height > 40 })
      try screen.click(editor)
      try screen.type("Ships the rows")
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(saved == ["Ships the rows"])
    }

    @Test("An attachment's placeholder becomes its Markdown, or goes with the reason")
    func attachmentDraft() {
      var draft = PullRequestDescriptionDraft(original: "", body: "Intro")
      let placeholder = PullRequestDescriptionDraft.placeholder("shot.png", 1)
      draft.append(placeholder)
      #expect(draft.body == "Intro\n![Uploading shot.png\u{2026}](#upload-1)")
      #expect(PullRequestDescriptionDraft.placeholder("", 2).contains("Uploading file"))
    }

    @Test("The composer preview opens the pull request it lists")
    func previewOpensOne() throws {
      var opened: [String] = []
      let screen = OffscreenWindow(
        AnyView(
          ComposerPullRequestPreview(pullRequests: [PullRequestFixture.summary()]) {
            opened.append($0)
          }),
        width: 400, height: 200)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(opened == [PullRequestFixture.url])
    }
  }
#endif
