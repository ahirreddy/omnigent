#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  private func summary(
    _ edit: (inout PullRequestDetailViewState) -> Void = { _ in }, spy: PullRequestSpy,
    extras editExtras: (inout PullRequestPanelExtras) -> Void = { _ in }
  ) -> OffscreenWindow<AnyView> {
    SystemSideEffects.reset()
    var state = PullRequestFixture.detail
    edit(&state)
    var extras = spy.extras
    editExtras(&extras)
    let view = PullRequestSummaryView(state: state, extras: extras, open: spy.open)
    return OffscreenWindow(AnyView(view), width: 600, height: 500)
  }

  @Suite("Inspector: a pull request's summary", .serialized)
  @MainActor
  struct InspectorPullRequestSummaryTests {
    private let methods = PullRequestChoices.loaded([
      PullRequestChip(id: "squash", title: "Squash"),
      PullRequestChip(id: "merge", title: "Merge commit"),
    ])

    @Test("Sections with nothing to show hide, and a missing description says so")
    func emptySummary() throws {
      let screen = summary(spy: PullRequestSpy())
      defer { screen.close() }
      #expect(try screen.shows("No description provided."))
      for heading in ["REVIEWERS", "LABELS", "CHECKS"] {
        #expect(try !screen.shows(heading))
      }
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("The description renders as Markdown")
    func description() throws {
      let screen = summary({ $0.body = "Adds the **sidebar**" }, spy: PullRequestSpy())
      defer { screen.close() }
      #expect(try screen.shows("Adds the sidebar"))
      #expect(try !screen.shows("No description provided."))
    }

    @Test("A checks note shows even with no checks to list")
    func checksNote() throws {
      let screen = summary({ $0.checksNote = "Couldn't read the checks" }, spy: PullRequestSpy())
      defer { screen.close() }
      #expect(try screen.shows("CHECKS"))
      #expect(try screen.shows("Couldn't read the checks"))
    }

    @Test("A bucket opens to its checks; a check with a link opens its run")
    func checks() throws {
      let spy = PullRequestSpy()
      let run = URL(string: "https://example.test/run")
      let screen = summary(
        {
          $0.checks = [
            PullRequestCheckGroup(
              bucket: .passed, count: 2,
              runs: [
                PullRequestCheckGroup.Run(name: "lint", url: run),
                PullRequestCheckGroup.Run(name: "test", url: nil),
              ])
          ]
        }, spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("2 passed"))
      #expect(try !screen.shows("lint"))
      try screen.clickControl(at: 0)
      screen.settle(0.3)
      #expect(try screen.shows("lint"))
      #expect(try screen.shows("test"))
      // The chevron and lint: test has no link, so it can't be chosen.
      #expect(screen.controlFrames.count == 2)
      // The name is what takes the click: the row's blank width has no content to hit.
      let lint = screen.controlFrames[1]
      try screen.click(CGPoint(x: lint.minX + 4, y: lint.midY))
      #expect(spy.opened == [run])
    }

    @Test("Each bucket has its own symbol, and problems don't look like passes")
    func buckets() {
      let symbols = PullRequestCheckGroup.Bucket.allCases.map(PullRequestChecksSection.symbol)
      #expect(Set(symbols).count == symbols.count)
      #expect(PullRequestChecksSection.color(.passed) != PullRequestChecksSection.color(.failed))
      #expect(PullRequestChecksSection.color(.pending) != PullRequestChecksSection.color(.passed))
      #expect(
        PullRequestChecksSection.color(.cancelled) == PullRequestChecksSection.color(.skipped))
    }

    @Test("Auto-merge explains itself and can be turned off")
    func autoMerge() throws {
      let spy = PullRequestSpy()
      let screen = summary({ $0.merge = .autoMerge }, spy: spy)
      defer { screen.close() }
      #expect(
        try screen.shows(
          "This pull request will merge automatically when all requirements are met."))
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["disable auto-merge"])
    }

    @Test("Disable Auto-Merge is gone without the action, and off while busy")
    func autoMergeLimits() {
      let spy = PullRequestSpy()
      let without = summary(
        { $0.merge = .autoMerge }, spy: spy, extras: { $0.actions.disableAutoMerge = nil })
      defer { without.close() }
      #expect(without.controlFrames.isEmpty)
      let busy = summary({ $0.merge = .autoMerge }, spy: spy, extras: { $0.isBusy = true })
      defer { busy.close() }
      #expect(busy.controlFrames.isEmpty)
    }

    @Test("While checking it shows a spinner and why; nothing can be clicked")
    func checking() throws {
      let screen = summary({ $0.merge = .checking("Checking mergeability") }, spy: PullRequestSpy())
      defer { screen.close() }
      #expect(try screen.shows("Checking mergeability"))
      #expect(screen.allViews.contains { $0 is NSProgressIndicator })
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("Blocked explains why, and Merge can't be clicked")
    func blocked() throws {
      let screen = summary({ $0.merge = .blocked("Needs a review") }, spy: PullRequestSpy())
      defer { screen.close() }
      #expect(try screen.shows("Needs a review"))
      #expect(try screen.shows("Merge\u{2026}"))
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("Ready has a hint when there is one; busy or no action turns Merge off")
    func readyLimits() throws {
      let spy = PullRequestSpy()
      let hinted = summary({ $0.merge = .ready("Squash only") }, spy: spy)
      defer { hinted.close() }
      #expect(try hinted.shows("Squash only"))
      #expect(hinted.controlFrames.count == 1)

      let busy = summary({ $0.merge = .ready(nil) }, spy: spy, extras: { $0.isBusy = true })
      defer { busy.close() }
      #expect(busy.controlFrames.isEmpty)

      let without = summary(
        { $0.merge = .ready(nil) }, spy: spy, extras: { $0.actions.merge = nil })
      defer { without.close() }
      #expect(without.controlFrames.isEmpty)
    }

    @Test("Merge reads the methods, asks which, and merges with the one chosen")
    func merging() throws {
      let spy = PullRequestSpy()
      let screen = summary(
        { $0.merge = .ready(nil) }, spy: spy, extras: { $0.mergeMethods = methods })
      defer { screen.close() }
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.clickControl(at: 0)
      screen.settle(0.1)
      #expect(SystemSideEffects.record.alertMessages == ["Merge pull request #7?"])
      #expect(spy.calls == ["load methods", "merge merge"])
    }

    @Test("Cancelling the question merges nothing")
    func cancelMerge() throws {
      let spy = PullRequestSpy()
      let screen = summary(
        { $0.merge = .ready(nil) }, spy: spy, extras: { $0.mergeMethods = methods })
      defer { screen.close() }
      SystemSideEffects.answer(alert: .alertThirdButtonReturn)
      try screen.clickControl(at: 0)
      screen.settle(0.1)
      #expect(spy.calls == ["load methods"])
    }

    @Test("While the methods load it spins and asks nothing; a failed read says why")
    func methodStates() throws {
      let spy = PullRequestSpy()
      let loading = summary(
        { $0.merge = .ready(nil) }, spy: spy, extras: { $0.mergeMethods = .loading })
      defer { loading.close() }
      try loading.clickControl(at: 0)
      #expect(loading.allViews.contains { $0 is NSProgressIndicator })
      #expect(SystemSideEffects.record.alertMessages.isEmpty)

      let failed = summary(
        { $0.merge = .ready(nil) }, spy: spy, extras: { $0.mergeMethods = .failed("no") })
      defer { failed.close() }
      #expect(try !failed.shows("no"))
      try failed.clickControl(at: 0)
      #expect(try failed.shows("no"))
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
    }
  }

  @Suite("Inspector: a pull request's people and labels", .serialized)
  @MainActor
  struct InspectorPullRequestPeopleTests {
    private let sam = PullRequestChip(
      id: "sam", title: "sam", detail: "Approved", systemImage: "checkmark.circle")
    private let bug = PullRequestChip(id: "bug", title: "bug", color: 0xD7_3A_4A)

    @Test("Both sections show side by side when they fit, and say when they're empty")
    func emptySections() throws {
      let screen = summary(
        {
          $0.showsReviewers = true
          $0.showsLabels = true
        }, spy: PullRequestSpy())
      defer { screen.close() }
      for line in ["REVIEWERS", "No reviewers", "LABELS", "None yet"] {
        #expect(try screen.shows(line))
      }
      // Nothing is editable here.
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("A reviewer shows their state, and a label its name")
    func filled() throws {
      let screen = summary(
        {
          $0.showsReviewers = true
          $0.reviewers = [sam, PullRequestChip(id: "kim", title: "kim")]
          $0.showsLabels = true
          $0.labels = [bug, PullRequestChip(id: "plain", title: "plain", detail: "No color")]
        }, spy: PullRequestSpy())
      defer { screen.close() }
      for line in ["sam", "Approved", "kim", "bug", "plain"] {
        #expect(try screen.shows(line))
      }
      #expect(try !screen.shows("No reviewers"))
      #expect(try !screen.shows("None yet"))
    }

    @Test("Plus reads the choices for each section")
    func plusButtons() throws {
      let spy = PullRequestSpy()
      let screen = summary(
        {
          $0.showsReviewers = true
          $0.canEditReviewers = true
          $0.showsLabels = true
          $0.canEditLabels = true
        }, spy: spy)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 2)
      try screen.clickControl(at: 0)
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["load reviewers", "load labels"])
    }

    @Test("A review request can be withdrawn from its row, when editable")
    func withdraw() throws {
      let spy = PullRequestSpy()
      let section = PullRequestReviewersSection(
        reviewers: [sam], editable: true, extras: spy.extras)
      let screen = OffscreenWindow(AnyView(section), width: 400, height: 200)
      defer { screen.close() }
      let rowMiddle = try chipCenter(in: screen, x: 30)
      let menu = try #require(try screen.contextMenu(at: rowMiddle))
      #expect(menu.titles == ["Withdraw Request"])
      try screen.choose("Withdraw Request", in: menu)
      #expect(spy.calls == ["reviewer sam false"])
    }

    @Test("A label can be removed from its chip, when editable")
    func removeLabel() throws {
      let spy = PullRequestSpy()
      let section = PullRequestLabelsSection(labels: [bug], editable: true, extras: spy.extras)
      let screen = OffscreenWindow(AnyView(section), width: 400, height: 200)
      defer { screen.close() }
      let chip = try chipCenter(in: screen)
      let menu = try #require(try screen.contextMenu(at: chip))
      #expect(menu.titles == ["Remove Label"])
      try screen.choose("Remove Label", in: menu)
      #expect(spy.calls == ["label bug false"])
    }

    @Test("Without edit rights, no plus and an empty menu")
    func notEditable() throws {
      let spy = PullRequestSpy()
      let labels = OffscreenWindow(
        AnyView(PullRequestLabelsSection(labels: [bug], editable: false, extras: spy.extras)),
        width: 400, height: 200)
      defer { labels.close() }
      #expect(labels.controlFrames.isEmpty)
      let chip = try chipCenter(in: labels)
      #expect(try labels.contextMenu(at: chip)?.titles.isEmpty != false)

      let noAction = OffscreenWindow(
        AnyView(
          PullRequestReviewersSection(
            reviewers: [sam], editable: true, extras: PullRequestPanelExtras())),
        width: 400, height: 200)
      defer { noAction.close() }
      #expect(noAction.controlFrames.isEmpty)
    }

    /// A chip sits at the section's leading edge, below its heading, in the window's middle.
    private func chipCenter(in screen: OffscreenWindow<AnyView>, x left: CGFloat = 20) throws
      -> CGPoint
    {
      CGPoint(x: left, y: screen.host.frame.midY + 10)
    }

    @Test("The choice list spins until it's read, and says when the read failed")
    func choicesStates() throws {
      func list(_ choices: PullRequestChoices) -> OffscreenWindow<AnyView> {
        OffscreenWindow(
          AnyView(
            PullRequestChoiceList(title: "Labels", choices: choices, selected: []) { _, _ in }),
          width: 300, height: 340)
      }
      let idle = list(.idle)
      defer { idle.close() }
      #expect(idle.allViews.contains { $0 is NSProgressIndicator })
      #expect(try idle.shows("Labels"))
      let loading = list(.loading)
      defer { loading.close() }
      #expect(loading.allViews.contains { $0 is NSProgressIndicator })
      let failed = list(.failed("boom"))
      defer { failed.close() }
      #expect(try failed.shows("boom"))
    }

    @Test("Choices filter by name or detail, and toggling one reports it")
    func choices() throws {
      var toggled: [String] = []
      let list = PullRequestChoiceList(
        title: "Reviewers",
        choices: .loaded([
          PullRequestChip(id: "sam", title: "Sam", detail: "Maintainer"),
          PullRequestChip(id: "kim", title: "Kim"),
        ]),
        selected: ["sam"], toggle: { toggled.append("\($0) \($1)") })
      let screen = OffscreenWindow(AnyView(list), width: 300, height: 340)
      defer { screen.close() }
      #expect(try screen.shows("Sam"))
      #expect(try screen.shows("Maintainer"))
      #expect(try screen.shows("Kim"))
      let checkboxes = screen.allViews.compactMap { $0 as? NSButton }
        .filter { $0.frame.width > 0 }
      #expect(checkboxes.count == 2)
      #expect(checkboxes.map(\.state).sorted { $0.rawValue < $1.rawValue } == [.off, .on])
      for checkbox in checkboxes { try screen.click(checkbox) }
      #expect(Set(toggled) == ["sam false", "kim true"])

      try screen.typeIntoField("MAINT")
      #expect(try screen.shows("Sam"))
      #expect(try !screen.shows("Kim"))
      try screen.typeIntoField("nobody")
      #expect(try !screen.shows("Sam"))
    }
  }
#endif
