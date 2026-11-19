#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The sidebar's nesting as drawn, from the nesting fixture with a row selected and one
  /// hovered: rows with and without children line up, a family's members sit one step in with a
  /// connector from under their head's chevron, and a project's rows sit where the rows outside
  /// it do, inside a box drawn around them.
  @Suite("Sidebar nesting: siblings line up, members one step in, projects boxed", .serialized)
  @MainActor
  struct SidebarNestingLayoutTests {
    private typealias Fixture = SidebarNestingFixture
    private let step = SessionFamilyMetrics.step
    private let lead = SessionFamilyMetrics.lead

    /// The fixture sidebar with Gateway open, Key Rotation selected and Loose Notes hovered.
    private func sidebar() throws -> OffscreenWindow<SidebarHarness> {
      let spy = SidebarSpy(Fixture.state)
      UserDefaults.standard.set(
        Fixture.project.id, forKey: SidebarNavigationOrder.expandedProjectsKey)
      spy.selection = .session("keys")
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 320, height: 1040)
      try screen.hoverRow(try #require(try screen.listRow(of: "loose")))
      return screen
    }

    /// Session rows by id and folder rows by project id, as drawn.
    private func drawn(
      _ screen: OffscreenWindow<SidebarHarness>, sessions: [String], folders: [String] = []
    ) throws -> [String: DrawnRow] {
      let ids = Dictionary(
        sessions.map { ("session-row-\($0)", $0) } + folders.map { ("sidebar-project-\($0)", $0) },
        uniquingKeysWith: { first, _ in first })
      let rows = try screen.drawnRows(Array(ids.keys), in: try Snapshot(screen))
      var drawn: [String: DrawnRow] = [:]
      for (identifier, row) in rows {
        if let id = ids[identifier] { drawn[id] = row }
      }
      return drawn
    }

    private func icon(_ row: DrawnRow?, _ id: String) throws -> ClosedRange<CGFloat> {
      let drawn = try #require(row, "\(id) is drawn")
      return try #require(drawn.icon, "\(id)'s icon draws: \(drawn.marks)")
    }

    private func middle(_ span: ClosedRange<CGFloat>) -> CGFloat {
      (span.lowerBound + span.upperBound) / 2
    }

    @Test("A row with children and one without line up: one icon and title x per level")
    func siblingsLineUp() throws {
      let screen = try sidebar()
      defer { screen.close() }
      // A project's sessions sit with the top level; members, in a folder or out, a step in.
      let levels = [
        Fixture.topLevel + Fixture.inProject, Fixture.nested + Fixture.nestedInProject,
      ]
      let rows = try drawn(screen, sessions: levels.flatMap { $0 })
      for level in levels {
        let first = try icon(rows[level[0]], level[0])
        let title = try #require(rows[level[0]]?.title, "\(level[0])'s title draws")
        // The title follows the icon by the mark's width and the row's spacing.
        let markAndSpacing = SessionFamilyMetrics.markWidth + Theme.Spacing.small
        #expect(
          abs(title - first.lowerBound - markAndSpacing) <= 2, "\(level[0])'s title at \(title)")
        for id in level {
          let mark = try icon(rows[id], id)
          #expect(abs(mark.lowerBound - first.lowerBound) <= 1, "\(id)'s icon at \(mark)")
          let start = rows[id]?.title
          #expect(start.map { abs($0 - title) <= 1.5 } == true, "\(id)'s title at \(start ?? 0)")
        }
      }
    }

    @Test("The top rows line up: New session, Inbox, Canvas and the filters share icon and title x")
    func navigationRowsLineUp() throws {
      // Each new window's first drawing, before any hover or accessibility read. The first rows
      // of a new window could keep the outline's old indent, 9 points in, now and then; so
      // several windows. Rows 0 to 4 are New session, Inbox, Canvas, Running and Needs you.
      for window in 0..<8 {
        let screen = OffscreenWindow(
          SidebarHarness(spy: SidebarSpy(Fixture.state)), width: 320, height: 1040)
        defer { screen.close() }
        let picture = try Snapshot(screen)
        let rows = try (0..<5).map { try screen.drawnRow($0, in: picture) }
        // A symbol can draw in parts (Canvas's squares); the title starts past its 16 points.
        let starts = rows.map { row -> (icon: CGFloat, title: CGFloat?)? in
          guard let icon = row.marks.first?.lowerBound else { return nil }
          return (icon, row.marks.first { $0.lowerBound >= icon + 18 }?.lowerBound)
        }
        let drawn = try starts.map { try #require($0, "window \(window): a top row draws") }
        let icon = drawn.map(\.icon).sorted()[2]
        let title = try #require(drawn.compactMap(\.title).sorted().dropFirst(2).first)
        for (index, row) in drawn.enumerated() {
          // A symbol's own margin moves its first ink a little (Needs you's hand).
          #expect(abs(row.icon - icon) <= 3, "window \(window), row \(index): \(drawn)")
          #expect(
            row.title.map { abs($0 - title) <= 1.5 } == true,
            "window \(window), row \(index): \(drawn)")
        }
      }
    }

    @Test("A head's chevron fills its gutter, before its icon; the rest leave the gutter empty")
    func chevronsFillTheGutter() throws {
      let screen = try sidebar()
      defer { screen.close() }
      let heads = ["rollout", "spokes", "monitor", "research"]
      let childless = ["workers", "keys", "internals", "loose"]
      let rows = try drawn(screen, sessions: heads + childless)
      let chevrons = try screen.withAccessibilityTree {
        try heads.map { try screen.listElementFrame("session-family-toggle-\($0)") }
      }
      for (id, chevron) in zip(heads, chevrons) {
        let mark = try icon(rows[id], id)
        #expect(abs(chevron.minX - (mark.lowerBound - lead)) <= 1, "\(id)'s chevron at \(chevron)")
        #expect(abs(chevron.width - SessionFamilyMetrics.gutter) < 0.5)
        let lead = rows[id]?.lead ?? []
        #expect(lead.count == 1, "\(id)'s gutter draws its chevron alone: \(lead)")
      }
      for id in childless {
        #expect(rows[id]?.lead.isEmpty == true, "\(id)'s gutter draws \(rows[id]?.lead ?? [])")
      }
    }

    @Test("A folder's icon and name, its sessions and Show more line up with the rows outside it")
    func folderRowsLineUp() throws {
      let screen = try sidebar()
      defer { screen.close() }
      let rows = try drawn(screen, sessions: ["workers"] + Fixture.inProject, folders: ["gateway"])
      let top = try icon(rows["workers"], "workers")
      let folder = try icon(rows["gateway"], "gateway")
      #expect(abs(folder.lowerBound - top.lowerBound) <= 1.5, "folder at \(folder), top \(top)")
      let name = try #require(rows["gateway"]?.title)
      let title = try #require(rows["workers"]?.title)
      #expect(abs(name - title) <= 1.5, "name at \(name), title at \(title)")
      for id in Fixture.inProject {
        let mark = try icon(rows[id], id)
        #expect(abs(mark.lowerBound - top.lowerBound) <= 1, "\(id) at \(mark)")
      }
      let showMore = try screen.withAccessibilityTree {
        try screen.listElementFrame("project-show-more-gateway")
      }
      let sessions = try icon(rows["spokes"], "spokes")
      #expect(abs(showMore.minX - sessions.lowerBound) <= 1.5, "Show more at \(showMore.minX)")
    }

    @Test("A head's chevron sits on the grid of the folders' disclosure triangles")
    func chevronsMeetTheFolderTriangles() throws {
      let screen = try sidebar()
      defer { screen.close() }
      let rows = try drawn(
        screen, sessions: ["rollout", "monitor"], folders: ["gateway", "tools"])
      let lead = { (id: String) throws -> ClosedRange<CGFloat> in
        try #require(rows[id]?.lead.first, "\(id) draws a chevron")
      }
      // Expanded: Release Rollout in Pinned and the Gateway folder, both at the top level.
      let open = middle(try lead("rollout"))
      let folder = middle(try lead("gateway"))
      #expect(abs(open - folder) <= 1.5, "chevron at \(open), triangle at \(folder)")
      // Collapsed: Monitor Job, in Gateway, and the Tooling folder.
      let closed = middle(try lead("monitor"))
      let tooling = middle(try lead("tools"))
      #expect(abs(closed - tooling) <= 1.5, "chevron at \(closed), triangle at \(tooling)")
    }

    @Test("Each level is one step in: a member under its head, inside a folder and out")
    func membersSitOneStepIn() throws {
      let screen = try sidebar()
      defer { screen.close() }
      let pairs = [
        ("rollout", "notes"), ("research", "helper"), ("research", "summary"), ("spokes", "plan"),
      ]
      let rows = try drawn(screen, sessions: pairs.flatMap { [$0.0, $0.1] })
      for (head, member) in pairs {
        let parent = try icon(rows[head], head)
        let child = try icon(rows[member], member)
        #expect(
          abs(child.lowerBound - parent.lowerBound - step) <= 1,
          "\(member) at \(child) under \(head) at \(parent)")
      }
    }

    @Test("A member's connector runs down under its head's chevron and on to the next member")
    func connectorRunsUnderTheHeadsChevron() throws {
      let screen = try sidebar()
      defer { screen.close() }
      let rows = try drawn(screen, sessions: ["research", "helper", "summary", "spokes", "plan"])
      let picture = try Snapshot(screen)
      let inks = { (point: CGPoint) in
        picture.inks(point, against: CGPoint(x: point.x + 5, y: point.y))
      }
      let chevron = { (head: String) throws -> CGFloat in
        self.middle(try #require(rows[head]?.lead.first, "\(head) draws a chevron"))
      }
      for (head, member) in [("research", "helper"), ("research", "summary"), ("spokes", "plan")] {
        let line = try chevron(head)
        let child = try #require(rows[member])
        let mark = try icon(child, member)
        // It turns from under the head's chevron, across the member's empty gutter, to its icon.
        let turn = try #require(child.lead.last, "\(member) draws a connector")
        #expect(abs(turn.lowerBound - line) <= 1.5, "\(member)'s line at \(turn)")
        #expect(abs(turn.upperBound - mark.lowerBound + 4) <= 1.5, "\(member)'s turn to \(turn)")
        #expect(inks(CGPoint(x: line, y: child.frame.minY + 2)), "\(member)'s line from its top")
      }
      let line = try chevron("research")
      let helper = try #require(rows["helper"]).frame
      let summary = try #require(rows["summary"]).frame
      #expect(inks(CGPoint(x: line, y: helper.maxY - 2)), "it runs on to the next member")
      #expect(!inks(CGPoint(x: line, y: summary.maxY - 2)), "it ends at the last member")
    }

    @Test("A box's edges run around each project's rows, and nowhere else")
    func projectsAreBoxed() throws {
      let screen = try sidebar()
      defer { screen.close() }
      let inProject = Fixture.inProject + Fixture.nestedInProject
      let outside = ["workers", "keys", "shared", "research", "loose"]
      var rows = try drawn(
        screen, sessions: inProject + outside, folders: ["gateway", "tools"])
      rows["more"] = try screen.drawnRows(["project-show-more-gateway"], in: try Snapshot(screen))
        .values.first
      let picture = try Snapshot(screen)
      // The box's side, a hairline just inside its inset, against the list beside it.
      let side = SidebarBoxMetrics.inset + 0.5
      let hasSide = { (id: String) throws -> Bool in
        let row = try #require(rows[id], "\(id) is drawn")
        return picture.inks(
          CGPoint(x: side, y: row.frame.midY), against: CGPoint(x: 2, y: row.frame.midY))
      }
      for id in inProject + ["gateway", "tools", "more"] {
        #expect(try hasSide(id), "\(id) is in its project's box")
      }
      for id in outside {
        #expect(try !hasSide(id), "\(id) is in no box")
      }
      // Its top edge on the folder's row, its bottom one on the last; a gap outside each.
      let edge = { (id: String, height: (CGRect) -> CGFloat) throws -> Bool in
        let row = try #require(rows[id]).frame
        let point = CGPoint(x: row.midX, y: height(row))
        return picture.inks(point, against: CGPoint(x: point.x, y: row.midY))
      }
      let gap = SidebarBoxMetrics.gap
      for id in ["gateway", "tools"] {
        #expect(try edge(id) { $0.minY + gap + 0.5 }, "\(id) opens a box")
      }
      for id in ["tools", "more"] {
        #expect(try edge(id) { $0.maxY - gap - 0.5 }, "\(id) closes a box")
      }
      for id in ["spokes", "plan", "internals"] {
        #expect(try !edge(id) { $0.minY + gap + 0.5 }, "\(id) is inside the box, not at its top")
        #expect(try !edge(id) { $0.maxY - gap - 0.5 }, "\(id) is inside the box, not at its end")
      }
    }
  }
#endif
