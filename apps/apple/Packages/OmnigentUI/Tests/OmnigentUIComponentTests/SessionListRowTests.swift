#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// One row outside the list, where hover and its buttons can be driven directly.
  private struct RowHost: View {
    let spy: SidebarSpy
    let session: SessionSummary
    var info = SessionRowInfo()
    var isUnread = false
    var attention = 0
    var details: Set<SessionRowDetail> = [.updated]
    var pinLimitReached = false
    var isSelecting = false
    var isChecked = false
    var rename: InlineRename?

    var body: some View {
      SessionRow(
        session: session, info: info, isUnread: isUnread, attention: attention, details: details,
        now: Date(timeIntervalSince1970: 3_600),
        menu: SessionRowMenu(
          session: session, isUnread: isUnread, isShared: info.isShared,
          pinLimitReached: pinLimitReached, projects: [], actions: spy.sessionActions,
          rename: { spy.calls.append("rename prompt") },
          confirmDelete: { spy.calls.append("delete prompt") },
          confirmLeave: { spy.calls.append("leave prompt") },
          confirmStop: { spy.calls.append("stop prompt") }),
        isSelecting: isSelecting, isChecked: isChecked, inlineRename: rename
      )
      .frame(width: 280, height: 32)
    }
  }

  @Suite("Sidebar: one session row", .serialized)
  @MainActor
  struct SessionListRowTests {
    private let session = SessionSummary(id: "s", title: "Fix the build", updatedAt: 0)
    private var spy: SidebarSpy { SidebarSpy(SidebarFixture.state) }
    private let middle = CGPoint(x: 140, y: 16)

    @Test("hovering reveals Pin, Archive and More, which do what they say")
    func hoverButtons() throws {
      let spy = spy
      let screen = OffscreenWindow(RowHost(spy: spy, session: session), width: 280, height: 32)
      defer { screen.close() }
      #expect(screen.plainButtons.isEmpty)
      try screen.hover(middle)
      let buttons = screen.plainButtons
      #expect(buttons.count == 2)
      #expect(screen.popUps.count == 1)
      // Archive sits before Pin in the view tree.
      try screen.click(buttons[1])
      try screen.click(screen.plainButtons[0])
      #expect(spy.calls == ["pin s true", "archive s true"])
      try screen.endHover()
      #expect(screen.plainButtons.isEmpty)
    }

    @Test("the hover Unpin and Unarchive ask for the opposite")
    func hoverOpposites() throws {
      let spy = spy
      var pinned = session
      pinned.isPinned = true
      let screen = OffscreenWindow(RowHost(spy: spy, session: pinned), width: 280, height: 32)
      defer { screen.close() }
      try screen.hover(middle)
      try screen.click(screen.plainButtons[1])
      try screen.click(screen.plainButtons[0])
      #expect(spy.calls == ["pin s false", "archive s true"])

      var archived = session
      archived.isArchived = true
      let other = OffscreenWindow(RowHost(spy: spy, session: archived), width: 280, height: 32)
      defer { other.close() }
      try other.hover(middle)
      // An archived row can't be pinned, so Unarchive is the only button.
      #expect(other.plainButtons.count == 1)
      spy.calls = []
      try other.click(other.plainButtons[0])
      #expect(spy.calls == ["archive s false"])
    }

    @Test("a hover Pin at the limit does nothing rather than exceed it")
    func hoverPinAtLimit() throws {
      let spy = spy
      let screen = OffscreenWindow(
        RowHost(spy: spy, session: session, pinLimitReached: true), width: 280, height: 32)
      defer { screen.close() }
      try screen.hover(middle)
      try screen.click(screen.plainButtons[1])
      #expect(spy.calls.isEmpty)
    }

    @Test("a row with nothing to hover for, or being selected, shows no buttons")
    func noHoverButtons() throws {
      let spy = spy
      let locked = SessionSummary(id: "s", title: "T", canPin: false, canArchive: false)
      let screen = OffscreenWindow(RowHost(spy: spy, session: locked), width: 280, height: 32)
      defer { screen.close() }
      try screen.hover(middle)
      #expect(screen.plainButtons.isEmpty && screen.popUps.isEmpty)

      let selecting = OffscreenWindow(
        RowHost(spy: spy, session: session, isSelecting: true, isChecked: true), width: 280,
        height: 32)
      defer { selecting.close() }
      try selecting.hover(middle)
      #expect(selecting.plainButtons.isEmpty && selecting.popUps.isEmpty)
    }

    @Test("the context menu of a row outside a list runs the prompts it was given")
    func prompts() throws {
      let spy = spy
      var stoppable = session
      stoppable.canStop = true
      let screen = OffscreenWindow(RowHost(spy: spy, session: stoppable), width: 280, height: 32)
      defer { screen.close() }
      let menu = try #require(try screen.contextMenu(at: middle))
      try screen.choose("Rename\u{2026}", in: menu)
      try screen.choose("Delete\u{2026}", in: menu)
      try screen.choose("Stop session", in: menu)
      #expect(spy.calls == ["rename prompt", "delete prompt", "stop prompt"])
    }

    @Test("every attention and quiet state draws differently")
    func statusMarks() throws {
      let spy = spy
      func image(_ row: RowHost) throws -> Data {
        let rendered = try RenderSupport.render(
          row, width: 280, height: 32, scheme: .light, layout: .regular)
        return try #require(rendered.image.representation(using: .png, properties: [:]))
      }
      func summary(_ attention: SessionAttentionState) -> SessionSummary {
        SessionSummary(id: "s", title: "T", updatedAt: 0, attention: attention)
      }
      let states: [(String, RowHost)] = [
        ("idle", RowHost(spy: spy, session: summary(.idle))),
        ("needs you", RowHost(spy: spy, session: summary(.needsYou), attention: 1)),
        ("needs you, 3", RowHost(spy: spy, session: summary(.needsYou), attention: 3)),
        ("failed", RowHost(spy: spy, session: summary(.failed))),
        ("unread", RowHost(spy: spy, session: summary(.unread))),
        (
          "disconnected",
          RowHost(
            spy: spy, session: summary(.idle), info: SessionRowInfo(isDisconnected: true))
        ),
        ("draft", RowHost(spy: spy, session: summary(.idle), info: SessionRowInfo(hasDraft: true))),
        ("no time", RowHost(spy: spy, session: summary(.idle), details: [])),
        (
          "shared",
          RowHost(spy: spy, session: summary(.idle), info: SessionRowInfo(isShared: true))
        ),
        (
          "details",
          RowHost(
            spy: spy, session: summary(.idle),
            info: SessionRowInfo(environment: "laptop", repo: "omnigent", branch: "main"),
            details: [.environment, .repo, .branch])
        ),
        (
          "selecting",
          RowHost(spy: spy, session: summary(.idle), isSelecting: true)
        ),
        (
          "checked",
          RowHost(spy: spy, session: summary(.idle), isSelecting: true, isChecked: true)
        ),
      ]
      var seen: [Data: String] = [:]
      for (name, row) in states {
        let picture = try image(row)
        #expect(seen[picture] == nil, "\(name) draws the same as \(seen[picture] ?? "")")
        seen[picture] = name
      }
      // A running spinner animates, so it only has to draw.
      _ = try image(RowHost(spy: spy, session: summary(.working)))
    }

    @Test("Return saves an in-place rename, trimmed; empty, unchanged or long titles don't")
    func inlineEditFinish() {
      let session = SessionSummary(id: "s", title: "Old")
      func finish(_ text: String) -> String? {
        var edit = SidebarInlineEdit()
        edit.begin(session)
        #expect(edit.text == "Old")
        edit.text = text
        let result = edit.finish()
        #expect(edit.session == nil)
        return result?.title
      }
      #expect(finish("  New \n") == "New")
      #expect(finish("") == nil)
      #expect(finish("   ") == nil)
      #expect(finish("Old") == nil)
      #expect(finish(String(repeating: "x", count: SessionDialogs.maxTitleLength + 1)) == nil)
      #expect(finish(String(repeating: "x", count: SessionDialogs.maxTitleLength)) != nil)
      var idle = SidebarInlineEdit()
      #expect(idle.finish() == nil)
    }

    @Test("typing in the in-place field and pressing Return renames; Escape cancels")
    func inlineField() throws {
      let spy = spy
      let session = session
      struct Host: View {
        let spy: SidebarSpy
        let session: SessionSummary
        @State private var edit = SidebarInlineEdit()
        var body: some View {
          RowHost(
            spy: spy, session: session,
            rename: edit.session == nil
              ? nil
              : SidebarInlineEdit.field($edit, rename: { spy.calls.append("rename \($1)") })
          )
          .task { edit.begin(session) }
        }
      }
      let screen = OffscreenWindow(Host(spy: spy, session: session), width: 280, height: 32)
      defer { screen.close() }
      let field = try #require(screen.allViews.first { $0 is NSTextField })
      try screen.click(field)
      screen.settle(0.2)
      try screen.type("!")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls.count == 1)
      #expect(spy.calls.first?.hasPrefix("rename ") == true)
    }

    @Test("relative times read as the web's")
    func relativeTime() {
      let now = Date(timeIntervalSince1970: 1_000_000_000)
      func text(_ seconds: TimeInterval) -> String {
        RelativeTime.short(now.addingTimeInterval(-seconds), now: now)
      }
      let day: TimeInterval = 86_400
      #expect(text(-500) == "now")
      #expect(text(59) == "now")
      #expect(text(60) == "1m")
      #expect(text(3_600) == "1h")
      #expect(text(day) == "1d")
      #expect(text(day * 7) == "1w")
      #expect(text(day * 30) == "1mo")
      #expect(text(day * 365) == "1y")
      #expect(RelativeTime.short(.distantPast, now: .distantFuture).hasSuffix("y"))
    }
  }
#endif
