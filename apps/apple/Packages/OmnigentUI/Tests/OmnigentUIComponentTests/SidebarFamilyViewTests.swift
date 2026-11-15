#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar families: the rows, as clicked", .serialized)
  @MainActor
  struct SidebarFamilyViewTests {
    private let home = SessionProject(id: "home", name: "Home", sessionIds: [])

    private func sidebar(_ state: SidebarViewState = FamilyFixture.state()) -> (
      SidebarSpy, OffscreenWindow<SidebarHarness>
    ) {
      let spy = SidebarSpy(state)
      return (spy, OffscreenWindow(SidebarHarness(spy: spy), width: 320, height: 700))
    }

    private func attribute(_ name: String, of element: NSObject) -> String? {
      element.responds(to: NSSelectorFromString(name))
        ? element.value(forKey: name) as? String : nil
    }

    /// A session row's content frame, from its accessibility element.
    private func rowFrame(_ id: String, _ screen: OffscreenWindow<SidebarHarness>) throws -> CGRect
    {
      try screen.withAccessibilityTree { try screen.listElementFrame("session-row-\(id)") }
    }

    /// A session's whole list row.
    private func listRow(_ id: String, _ screen: OffscreenWindow<SidebarHarness>) throws -> CGRect {
      let list = try #require(screen.list)
      let row = list.row(at: list.convert(center(try rowFrame(id, screen)), from: screen.host))
      return list.convert(list.rect(ofRow: row), to: screen.host)
    }

    private func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    @Test("Clicking a family's chevron hides its members, and clicking again shows them")
    func chevronCollapsesAndExpands() throws {
      let (spy, screen) = sidebar()
      defer { screen.close() }
      #expect(try screen.shows("Implementation") && screen.shows("Review"))
      try screen.clickListElement("session-family-toggle-coord")
      screen.settle(0.2)
      #expect(
        spy.state.collapsedFamilies == [SidebarFamilyScope.section("Sessions").key(family: "coord")]
      )
      #expect(try !screen.shows("Implementation") && !screen.shows("Review"))
      #expect(try screen.shows("Coordinator") && screen.shows("Solo"))
      #expect(spy.selection == nil, "the chevron is not the row")
      try screen.clickListElement("session-family-toggle-coord")
      screen.settle(0.2)
      #expect(spy.state.collapsedFamilies.isEmpty)
      #expect(try screen.shows("Implementation") && screen.shows("Review"))
    }

    @Test(
      "The chevron reads as Collapse or Expand session family with its state; only a head has one")
    func chevronAccessibility() throws {
      let (spy, screen) = sidebar()
      defer { screen.close() }
      try screen.withAccessibilityTree {
        let chevron = try screen.listElement("session-family-toggle-coord")
        #expect(attribute("accessibilityLabel", of: chevron) == "Collapse session family")
        #expect(attribute("accessibilityValue", of: chevron) == "Expanded")
        #expect(throws: OffscreenWindowError.self) {
          try screen.listElement("session-family-toggle-impl")
        }
        #expect(throws: OffscreenWindowError.self) {
          try screen.listElement("session-family-toggle-solo")
        }
      }
      spy.state.collapsedFamilies = [SidebarFamilyScope.section("Sessions").key(family: "coord")]
      screen.settle(0.2)
      try screen.withAccessibilityTree {
        let chevron = try screen.listElement("session-family-toggle-coord")
        #expect(attribute("accessibilityLabel", of: chevron) == "Expand session family")
        #expect(attribute("accessibilityValue", of: chevron) == "Collapsed")
      }
    }

    @Test("Members sit indented with an elbow beside them; their head's chevron leads it")
    func membersAreIndentedWithAnElbow() throws {
      let (_, screen) = sidebar()
      defer { screen.close() }
      let leading = try rowFrame("solo", screen).minX
      let chevron = SessionFamilyMetrics.chevronWidth + SessionFamilyMetrics.chevronSpacing
      #expect(abs(try rowFrame("coord", screen).minX - leading - chevron) < 1)
      let picture = try Snapshot(screen)
      // Above a row's content, where only an elbow draws.
      let line = leading + SessionFamilyMetrics.chevronWidth
      let hasElbow = { (id: String) throws -> Bool in
        let top = try listRow(id, screen).minY + 3
        return picture.inks(CGPoint(x: line, y: top), against: CGPoint(x: line + 4, y: top))
      }
      #expect(try hasElbow("impl") && hasElbow("review"))
      #expect(try !hasElbow("coord") && !hasElbow("solo"))
      // Below the elbow's turn the first ink is the row's own icon.
      let contentStart = { (id: String) throws -> CGFloat? in
        let row = try listRow(id, screen)
        let blank = CGPoint(x: leading - 8, y: row.midY + 4)
        return picture.firstInk(
          from: leading - 4, to: row.maxX, along: row.midY + 4, against: blank)
      }
      let lone = try #require(try contentStart("solo"))
      let member = try #require(try contentStart("impl"))
      #expect(abs(member - lone - SessionFamilyMetrics.nestedIndent) <= 1)
    }

    @Test("A member's row menu has no Pin or Add to project; its representative's has both")
    func memberMenuLacksPinAndMove() throws {
      var state = FamilyFixture.state()
      state.projects = [home]
      let (_, screen) = sidebar(state)
      defer { screen.close() }
      let head = try #require(try screen.contextMenu(at: center(try rowFrame("coord", screen))))
      #expect(head.titles.contains("Pin") && head.titles.contains("Add to project"))
      let member = try #require(try screen.contextMenu(at: center(try rowFrame("impl", screen))))
      #expect(!member.titles.contains("Pin") && !member.titles.contains("Add to project"))
      for kept in ["Share", "Fork", "Rename\u{2026}", "Archive", "Delete\u{2026}"] {
        #expect(member.titles.contains(kept), "\(kept) stays")
      }
    }

    @Test("Hovering a member offers Archive but no Pin; hovering its representative offers Pin")
    func memberHoverLacksPin() throws {
      let spy = SidebarSpy(FamilyFixture.state())
      let row = { (session: SessionSummary) in
        SessionRow(
          session: session, info: SessionRowInfo(), isUnread: false, attention: 0, details: [],
          now: nil,
          menu: SessionRowMenu(
            session: session, isUnread: false, isShared: false, pinLimitReached: false,
            projects: [], actions: spy.sessionActions, rename: {}, confirmDelete: {},
            confirmLeave: {}, confirmStop: {})
        )
        .frame(width: 280, height: 32)
      }
      let middle = CGPoint(x: 140, y: 16)
      let member = OffscreenWindow(row(FamilyFixture.implementation), width: 280, height: 32)
      defer { member.close() }
      try member.hover(middle)
      #expect(member.plainButtons.count == 1)
      try member.click(try #require(member.plainButtons.first))
      let head = OffscreenWindow(row(FamilyFixture.coordinator), width: 280, height: 32)
      defer { head.close() }
      try head.hover(middle)
      #expect(head.plainButtons.count == 2)
      for button in head.plainButtons { try head.click(button) }
      #expect(spy.calls.first == "archive impl true")
      #expect(Set(spy.calls.dropFirst()) == ["archive coord true", "pin coord true"])
    }

    @Test("A member can't be dropped into a project; its representative moves the family")
    func memberIsNotFiled() async throws {
      var state = FamilyFixture.state()
      state.projects = [home]
      let (spy, screen) = sidebar(state)
      defer { screen.close() }
      let folder = try screen.withAccessibilityTree {
        try screen.listElementFrame("sidebar-project-home")
      }
      try await screen.drop(SidebarDragItem.session("impl").payload, at: center(folder))
      #expect(spy.calls.isEmpty)
      try await screen.drop(SidebarDragItem.session("coord").payload, at: center(folder))
      #expect(spy.calls == ["drop coord \(SidebarDropAction.move(to: home, unpin: false))"])
    }

    @Test("Bulk move waits for a member's representative, then sends the representative alone")
    func bulkMove() throws {
      var state = FamilyFixture.state()
      state.projects = [home]
      let spy = SidebarSpy(state)
      let bar = { (selected: [SessionSummary]) in
        BulkActionBar(
          selected: selected, state: spy.state, actions: spy.actions,
          exit: { spy.calls.append("exit") }, clear: {}, confirmDelete: { _ in }
        )
        .frame(width: 320, height: 60)
      }
      let partial = OffscreenWindow(bar([FamilyFixture.implementation]), width: 320, height: 60)
      defer { partial.close() }
      #expect(try #require(partial.popUps.first).isEnabled == false)
      let whole = OffscreenWindow(
        bar([FamilyFixture.coordinator, FamilyFixture.implementation, FamilyFixture.solo]),
        width: 320, height: 60)
      defer { whole.close() }
      try whole.choose("Home", in: try whole.openMenu(try #require(whole.popUps.first)))
      #expect(spy.calls == ["move coord home", "move solo home", "exit"])
    }
  }

  /// The window as drawn, read a point at a time.
  @MainActor
  private struct Snapshot {
    let bitmap: NSBitmapImageRep
    let scale: CGFloat

    init(_ screen: OffscreenWindow<SidebarHarness>) throws {
      let host = screen.host
      bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
    }

    /// Whether `point` draws in another color than `background`.
    func inks(_ point: CGPoint, against background: CGPoint) -> Bool {
      guard let ink = color(point), let blank = color(background) else { return false }
      let difference = max(
        abs(ink.redComponent - blank.redComponent), abs(ink.greenComponent - blank.greenComponent),
        abs(ink.blueComponent - blank.blueComponent))
      return difference > 0.06
    }

    /// The first point along the height `line` from `start` that draws in another color than
    /// `background`.
    func firstInk(
      from start: CGFloat, to end: CGFloat, along line: CGFloat, against background: CGPoint
    ) -> CGFloat? {
      stride(from: start, to: end, by: 0.5).first {
        inks(CGPoint(x: $0, y: line), against: background)
      }
    }

    private func color(_ point: CGPoint) -> NSColor? {
      bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.deviceRGB)
    }
  }

  /// A list's rows each host their content in a hosting view of their own, which the window's
  /// accessibility tree doesn't reach; these search from every hosting view.
  extension OffscreenWindow {
    func listElement(_ identifier: String) throws -> NSObject {
      var pending: [Any] = allViews.filter {
        String(describing: Swift.type(of: $0)).contains("HostingView")
      }
      var seen = Set<ObjectIdentifier>()
      while let next = pending.popLast() {
        guard let element = next as? NSObject, seen.insert(ObjectIdentifier(element)).inserted
        else { continue }
        if Self.listAttribute("accessibilityIdentifier", of: element) as? String == identifier {
          return element
        }
        pending.append(
          contentsOf: Self.listAttribute("accessibilityChildren", of: element) as? [Any] ?? [])
      }
      throw OffscreenWindowError.notFound(identifier)
    }

    /// Where the element is, from the top left of the window's root view.
    func listElementFrame(_ identifier: String) throws -> CGRect {
      let frame = Self.listAttribute("accessibilityFrame", of: try listElement(identifier))
      guard let onScreen = (frame as? NSValue)?.rectValue else {
        throw OffscreenWindowError.notFound("the frame of \(identifier)")
      }
      return host.convert(window.convertFromScreen(onScreen), from: nil)
    }

    /// Clicks the middle of the element.
    func clickListElement(_ identifier: String) throws {
      let frame = try withAccessibilityTree { try listElementFrame(identifier) }
      try click(CGPoint(x: frame.midX, y: frame.midY))
    }

    private static func listAttribute(_ name: String, of element: NSObject) -> Any? {
      element.responds(to: NSSelectorFromString(name)) ? element.value(forKey: name) : nil
    }
  }
#endif
