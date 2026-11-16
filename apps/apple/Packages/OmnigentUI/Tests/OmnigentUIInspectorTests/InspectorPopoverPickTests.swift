#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  extension OffscreenWindow {
    /// The check boxes in the open popover, top to bottom.
    fileprivate func popoverCheckBoxes() throws -> [NSView] {
      let views = popoverViews
      let boxes = views.filter { $0 is NSButton && $0.enclosingScrollView != nil }
      guard !boxes.isEmpty else {
        let names = Set(views.map { String(describing: Swift.type(of: $0)) }).sorted()
        throw OffscreenWindowError.notFound("a check box among \(names)")
      }
      return boxes.sorted {
        $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
      }
    }

    /// The middle of a row of the list in the open popover, in its window.
    fileprivate func popoverRowCenter(_ row: Int) throws -> CGPoint {
      let list = try #require(popoverViews.lazy.compactMap { $0 as? NSTableView }.first)
      let frame = list.convert(list.rect(ofRow: row), to: nil)
      return CGPoint(x: frame.midX, y: frame.midY)
    }
  }

  /// Choices made inside a popover: a pull request's reviewers and labels, a fork's profile.
  @Suite("Inspector: picking in a popover", .serialized)
  @MainActor
  struct InspectorPopoverPickTests {
    private let sam = PullRequestChip(id: "sam", title: "sam", detail: "Approved")
    private let kim = PullRequestChip(id: "kim", title: "kim")

    @Test("Ticking a candidate requests their review, and unticking a reviewer withdraws it")
    func reviewers() throws {
      let spy = PullRequestSpy()
      var extras = spy.extras
      extras.reviewerChoices = .loaded([kim, sam])
      let section = PullRequestReviewersSection(reviewers: [sam], editable: true, extras: extras)
      let screen = OffscreenWindow(AnyView(section), width: 400, height: 300)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(MainLoop.settle(until: { (try? screen.popoverCheckBoxes())?.count == 2 }))
      #expect(spy.calls == ["load reviewers"])
      let boxes = try screen.popoverCheckBoxes()
      try #require(boxes.count == 2)
      try screen.clickInPopover(boxes[0])
      #expect(spy.calls == ["load reviewers", "reviewer kim true"])
      try screen.clickInPopover(boxes[1])
      #expect(spy.calls == ["load reviewers", "reviewer kim true", "reviewer sam false"])
    }

    @Test("Ticking a label adds it, and unticking one the pull request has removes it")
    func labels() throws {
      let spy = PullRequestSpy()
      let bug = PullRequestChip(id: "bug", title: "bug")
      var extras = spy.extras
      extras.labelChoices = .loaded([bug, PullRequestChip(id: "docs", title: "docs")])
      let section = PullRequestLabelsSection(labels: [bug], editable: true, extras: extras)
      let screen = OffscreenWindow(AnyView(section), width: 400, height: 300)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(MainLoop.settle(until: { (try? screen.popoverCheckBoxes())?.count == 2 }))
      let boxes = try screen.popoverCheckBoxes()
      try #require(boxes.count == 2)
      try screen.clickInPopover(boxes[1])
      #expect(spy.calls == ["load labels", "label docs true"])
      try screen.clickInPopover(boxes[0])
      #expect(spy.calls == ["load labels", "label docs true", "label bug false"])
    }

    @Test("Choosing a profile for a fork's new sandbox selects it and closes the list")
    func forkProfile() throws {
      let log = SheetLog()
      var options = ForkOptions(
        hosts: [ForkHostOption(id: "h", name: "Box")], offersSandbox: true)
      options.profiles = SandboxProfilesState(
        profiles: [
          SandboxProfileOption(id: "small", name: "Small", description: "", revision: "1"),
          SandboxProfileOption(id: "large", name: "Large", description: "", revision: "1"),
        ])
      var actions = forkActions(log)
      actions.profiles = SandboxProfilesActions(select: { log.calls.append("profile \($0.id)") })
      // The form as the window's root, so the popover it opens belongs to the window.
      let screen = OffscreenWindow(
        AnyView(ForkSheet(state: forkState(options: options), actions: actions)), width: 700,
        height: 800)
      defer { screen.close() }
      try screen.pick("New sandbox", in: screen.pickers[1])
      #expect(try screen.shows("Choose profile"))
      // The profile chip is the form's only borderless button.
      try #require(screen.plainButtons.count == 1)
      try screen.click(screen.plainButtons[0])
      try #require(MainLoop.settle(until: { screen.popoverWindow != nil }))
      try screen.clickInPopover(at: try screen.popoverRowCenter(1))
      #expect(log.calls.last == "profile large")
      #expect(MainLoop.settle(until: { screen.popoverWindow == nil }))
    }
  }
#endif
