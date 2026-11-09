import CoreGraphics
import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Tab split view")
struct TabSplitTests {
  @Test("Panes share the width by the fraction but never go below their minimum")
  func paneWidths() {
    let even = TabSplitLayout(width: 1_001, fraction: 0.5)
    #expect(even.leading == 500)
    #expect(even.trailing == 500)
    #expect(even.gap == TabSplitMetrics.divider)
    let narrowLeft = TabSplitLayout(width: 1_001, fraction: 0.2)
    #expect(narrowLeft.leading == TabSplitState.minimumPaneWidth)
    #expect(narrowLeft.trailing == 1_000 - TabSplitState.minimumPaneWidth)
    let narrowRight = TabSplitLayout(width: 1_001, fraction: 0.8)
    #expect(narrowRight.trailing == TabSplitState.minimumPaneWidth)
    #expect(!TabSplitState.fits(width: 600), "two panes need twice the minimum")
    #expect(TabSplitState.fits(width: 641))
  }

  @Test("An unfolded Duo puts the panes either side of the hinge")
  func hinge() {
    let hinge = CGRect(x: 420, y: 0, width: 20, height: 900)
    let layout = TabSplitLayout(width: 860, fraction: 0.3, hinge: hinge)
    #expect(layout.isAtHinge)
    #expect(layout.leading == 420)
    #expect(layout.gap == 20)
    #expect(layout.trailing == 420)
    // A hinge that would leave a pane too narrow (the sidebar is showing) is ignored.
    let offCenter = TabSplitLayout(
      width: 860, fraction: 0.5, hinge: CGRect(x: 120, y: 0, width: 20, height: 900))
    #expect(!offCenter.isAtHinge)
  }

  @Test("Dragging the divider keeps the share in range and both panes wide enough")
  func dividerDrag() {
    #expect(TabSplitLayout.fraction(at: 500, width: 1_000) == 0.5)
    #expect(TabSplitLayout.fraction(at: 10, width: 1_000) == 0.32)
    #expect(TabSplitLayout.fraction(at: 990, width: 1_000) == 0.68)
    #expect(TabSplitState.clamp(.nan) == 0.5)
    #expect(TabSplitState(leadingID: "a", trailingID: "b", fraction: 2).fraction == 0.8)
  }

  @Test("Either edge of the content takes a dragged tab; its own pane does not")
  func dropTargets() {
    let tracker = TabDragTracker()
    tracker.contentFrame = CGRect(x: 100, y: 100, width: 1_000, height: 600)
    tracker.update(id: "a", pane: nil, location: CGPoint(x: 150, y: 300))
    #expect(tracker.target == .leading)
    tracker.update(id: "a", pane: nil, location: CGPoint(x: 600, y: 300))
    #expect(tracker.target == nil, "the middle tears the tab off instead")
    tracker.update(id: "a", pane: nil, location: CGPoint(x: 1_050, y: 300))
    #expect(tracker.target == .trailing)
    tracker.update(id: "a", pane: nil, location: CGPoint(x: 150, y: 50))
    #expect(tracker.target == nil, "above the content")
    tracker.end()
    #expect(tracker.draggedID == nil)
  }

  @Test("In a split the whole of the other pane takes a dragged tab; its own pane does not")
  func splitDropTargets() {
    let tracker = TabDragTracker()
    tracker.contentFrame = CGRect(x: 100, y: 100, width: 1_000, height: 600)
    tracker.isSplit = true
    tracker.update(id: "a", pane: .trailing, location: CGPoint(x: 1_050, y: 300))
    #expect(tracker.target == nil, "a tab already in the right pane stays")
    tracker.update(id: "a", pane: .trailing, location: CGPoint(x: 590, y: 300))
    #expect(tracker.target == .leading, "left of the middle, before the divider is known")
    tracker.update(id: "a", pane: .leading, location: CGPoint(x: 610, y: 300))
    #expect(tracker.target == .trailing)
    // The panes are not halves: the divider decides.
    tracker.dividerX = 400
    tracker.update(id: "a", pane: .leading, location: CGPoint(x: 410, y: 300))
    #expect(tracker.target == .trailing)
    tracker.update(id: "a", pane: .trailing, location: CGPoint(x: 410, y: 300))
    #expect(tracker.target == nil)
    tracker.update(id: "a", pane: .trailing, location: CGPoint(x: 390, y: 300))
    #expect(tracker.target == .leading)
    tracker.update(id: "a", pane: .trailing, location: CGPoint(x: 390, y: 50))
    #expect(tracker.target == nil, "above the content")
    // Over the other pane's strip section, that pane is the target.
    tracker.update(id: "a", pane: .trailing, location: nil, section: .leading)
    #expect(tracker.target == .leading)
    tracker.end()
    #expect(tracker.target == nil)
    #expect(tracker.section == nil)
  }

  @Test("The strip's left section ends over the panes' divider")
  func sectionAlignment() {
    let strip = CGRect(x: 100, y: 0, width: 1_000, height: 30)
    let gap = Theme.Spacing.extraSmall
    #expect(
      TabStrip.leadingSectionWidth(sections: strip, dividerX: 700, fraction: 0.5) == 600 - gap)
    #expect(
      TabStrip.leadingSectionWidth(sections: strip, dividerX: nil, fraction: 0.5) == 500 - gap)
    #expect(
      TabStrip.leadingSectionWidth(sections: strip, dividerX: 120, fraction: 0.5)
        == TabMetrics.sectionMinWidth, "each section keeps room for a tab")
    let narrow = CGRect(x: 0, y: 0, width: 200, height: 30)
    #expect(TabStrip.leadingSectionWidth(sections: narrow, dividerX: 50, fraction: 0.5) == 95)
  }

  @Test("A divider past the strip's end leaves the right section a readable width")
  func portraitStrip() {
    // iPad portrait: the strip stops short of the window's trailing toolbar, the divider does
    // not, so aligning to it would leave the right section a sliver.
    let strip = CGRect(x: 380, y: 0, width: 600, height: 34)
    let leading = TabStrip.leadingSectionWidth(sections: strip, dividerX: 960, fraction: 0.5)
    let trailing = strip.width - leading - (Theme.Spacing.extraSmall * 2 + 1)
    #expect(trailing >= TabMetrics.sectionMinWidth)
    #expect(trailing >= TabMetrics.minWidth, "the pane's one tab fits without scrolling")
  }

  @Test("Only text dragged from a tab drops into a pane")
  func dropPayload() {
    #expect(TabDropPayload.tabID(in: TabDropPayload.text(for: "a1")) == "a1")
    #expect(TabDropPayload.tabID(in: "a1") == nil)
  }

  @Test("A session's tabs never pass the primary chat that leads them")
  func groupLeader() {
    var chat = TabItemState(id: "chat", kind: .chat, title: "Session")
    chat.groupID = "s1"
    chat.leadsGroup = true
    var shell = TabItemState(id: "zsh", kind: .terminal, title: "zsh")
    shell.groupID = "s1"
    var other = TabItemState(id: "other", kind: .terminal, title: "zsh")
    other.groupID = "s2"
    #expect(!TabStrip.canSwap(shell, with: chat, forward: false))
    #expect(TabStrip.canSwap(other, with: chat, forward: false))
    #expect(TabStrip.canSwap(chat, with: shell, forward: true), "the chat carries its tabs")
  }

  @Test("A split strip lists each pane's tabs; the overview names the pane")
  func panes() {
    var left = TabItemState(id: "a", kind: .chat, title: "A")
    left.pane = .leading
    var right = TabItemState(id: "b", kind: .browser, title: "B", subtitle: "Docs")
    right.pane = .trailing
    var state = TabsState(tabs: [left, right], selectedID: "a")
    #expect(state.tabs(in: .trailing).map(\.id) == ["a", "b"], "not split: one pane")
    state.split = TabSplitState(leadingID: "a", trailingID: "b")
    #expect(state.tabs(in: .leading).map(\.id) == ["a"])
    #expect(state.tabs(in: .trailing).map(\.id) == ["b"])
    #expect(TabOverviewSheet.detail(right) == "Right pane \u{00B7} Docs")
    #expect(TabPane.leading.other == .trailing)
  }

  @Test("The overview's second line carries the tab's live state before its context")
  func overviewState() {
    let waiting = TabItemState(
      id: "c", kind: .chat, title: "Fix", subtitle: "Codex \u{00B7} omnigent", status: .needsYou)
    #expect(TabOverviewSheet.detail(waiting) == "Needs you \u{00B7} Codex \u{00B7} omnigent")
    let idle = TabItemState(id: "t", kind: .terminal, title: "zsh")
    #expect(TabOverviewSheet.detail(idle) == "Terminal")
  }

  @Test("Busy tabs are running, loading or printing")
  func busy() {
    let tabs = [
      TabItemState(id: "r", kind: .chat, title: "R", status: .running),
      TabItemState(id: "l", kind: .browser, title: "L", status: .loading),
      TabItemState(id: "t", kind: .terminal, title: "T", status: .terminalActivity),
      TabItemState(id: "n", kind: .chat, title: "N", status: .needsYou),
      TabItemState(id: "u", kind: .chat, title: "U", status: .unread),
    ]
    #expect(TabsState(tabs: tabs).busyIDs == ["r", "l", "t"])
  }
}
