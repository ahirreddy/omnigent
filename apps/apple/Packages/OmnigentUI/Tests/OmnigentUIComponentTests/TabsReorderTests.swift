import CoreGraphics
import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Tabs: dragging a tab")
struct TabsReorderTests {
  private let width: CGFloat = 100
  private var step: CGFloat { width + TabMetrics.spacing }
  private var group: [TabItemState] {
    [TabFixture.tab("a"), TabFixture.tab("b"), TabFixture.tab("c")]
  }

  private func follow(
    _ drag: inout TabDrag, across: CGFloat, down: CGFloat = 0, tab: String,
    in tabs: [TabItemState] = [], tracker: TabDragTracker? = nil, canShowInPane: Bool = true,
    canTear: Bool = true, closable: Bool = true
  ) -> String? {
    let shown = tabs.isEmpty ? group : tabs
    var dragged = shown.first { $0.id == tab } ?? TabFixture.tab(tab)
    dragged.isClosable = closable
    return drag.follow(
      TabDrag.Pointer(
        translation: CGSize(width: across, height: down),
        location: CGPoint(x: 500 + across, y: 100 + down)),
      tab: dragged, group: shown,
      widthOf: { _ in width },
      drops: TabDrag.Drops(tracker: tracker, canShowInPane: canShowInPane, canTear: canTear))
  }

  @Test("A small drag only follows the pointer")
  func followsPointer() {
    var drag = TabDrag(id: "b")
    #expect(follow(&drag, across: 40, down: 3, tab: "b") == nil)
    #expect(drag.offset == 40)
    #expect(drag.lift == 3)
    #expect(drag.shift == 0)
    #expect(!drag.isTearing)
  }

  @Test("Past half the next tab's width it swaps forward, and keeps its place under the pointer")
  func swapsForward() {
    var drag = TabDrag(id: "b")
    #expect(follow(&drag, across: step / 2 + 1, tab: "b") == "c")
    #expect(drag.shift == step)
    #expect(drag.offset == step / 2 + 1 - step)
  }

  @Test("Past half the previous tab's width it swaps backward")
  func swapsBackward() {
    var drag = TabDrag(id: "b")
    #expect(follow(&drag, across: -(step / 2 + 1), tab: "b") == "a")
    #expect(drag.shift == -step)
  }

  @Test("Exactly half is not past half")
  func exactHalf() {
    var drag = TabDrag(id: "b")
    #expect(follow(&drag, across: step / 2, tab: "b") == nil)
    #expect(follow(&drag, across: -step / 2, tab: "b") == nil)
  }

  @Test("The ends have nothing to swap with")
  func ends() {
    var first = TabDrag(id: "a")
    #expect(follow(&first, across: -500, tab: "a") == nil)
    var last = TabDrag(id: "c")
    #expect(follow(&last, across: 500, tab: "c") == nil)
  }

  @Test("A tab outside the group doesn't swap")
  func outsideGroup() {
    var drag = TabDrag(id: "z")
    #expect(follow(&drag, across: 500, tab: "z") == nil)
  }

  @Test("A session's tab stops at the chat that leads the group")
  func stopsAtLeader() {
    var leader = TabFixture.tab("lead")
    leader.groupID = "s"
    leader.leadsGroup = true
    var member = TabFixture.tab("member")
    member.groupID = "s"
    var drag = TabDrag(id: "member")
    #expect(follow(&drag, across: -500, tab: "member", in: [leader, member]) == nil)
  }

  @Test("Far below the strip it stops swapping and tears off")
  func tears() {
    var drag = TabDrag(id: "b")
    let neighbour = follow(&drag, across: 500, down: TabDrag.tearDistance + 1, tab: "b")
    #expect(neighbour == nil)
    #expect(drag.isTearing)
    #expect(drag.lift == TabDrag.tearDistance + 1)
  }

  @Test("At the tear distance it hasn't torn yet")
  func tearBoundary() {
    var drag = TabDrag(id: "b")
    _ = follow(&drag, across: 0, down: TabDrag.tearDistance, tab: "b")
    #expect(!drag.isTearing)
  }

  @Test("A tab that can't close, or a window that can't tear, keeps the tab")
  func tearNeedsBoth() {
    var fixed = TabDrag(id: "b")
    _ = follow(&fixed, across: 0, down: 200, tab: "b", closable: false)
    #expect(!fixed.isTearing)
    var noWindow = TabDrag(id: "b")
    _ = follow(&noWindow, across: 0, down: 200, tab: "b", canTear: false)
    #expect(!noWindow.isTearing)
  }

  @Test("Over a content edge the tab previews a pane instead of tearing")
  func previewsPane() {
    let tracker = TabDragTracker()
    tracker.contentFrame = CGRect(x: 0, y: 200, width: 1_000, height: 500)
    var drag = TabDrag(id: "b")
    // 500 + 300 is in the right 30 percent of the content, 100 + 200 inside its height.
    _ = follow(&drag, across: 300, down: 200, tab: "b", tracker: tracker)
    #expect(tracker.target == .trailing)
    #expect(tracker.draggedID == "b")
    #expect(!drag.isTearing)
    // The middle of the content is no pane's edge.
    _ = follow(&drag, across: 0, down: 200, tab: "b", tracker: tracker)
    #expect(tracker.target == nil)
    #expect(drag.isTearing)
    // Without panes to show in, an edge tears like anywhere else.
    _ = follow(&drag, across: 300, down: 200, tab: "b", tracker: tracker, canShowInPane: false)
    #expect(drag.isTearing)
    // Back over the strip the tracker forgets the pointer.
    _ = follow(&drag, across: 0, down: 0, tab: "b", tracker: tracker)
    #expect(tracker.location == nil)
    tracker.end()
    #expect(tracker.draggedID == nil)
  }

  fileprivate struct Release: Sendable {
    var target: TabPane?
    var isTearing = false
    var canShow = true
    var isSplit = true
    var pane: TabPane?
    var overOther = false
    var expected: TabDragRelease
  }

  @Test(
    "A release does what its place says",
    arguments: [
      // A content edge wins over everything.
      Release(
        target: .leading, isTearing: true, pane: .trailing, overOther: true,
        expected: .show(.leading)
      ),
      // The other pane's section moves it there.
      Release(isTearing: true, pane: .trailing, overOther: true, expected: .show(.leading)),
      Release(isTearing: true, pane: .leading, overOther: true, expected: .show(.trailing)),
      // Over its own section it stays; a tear still tears.
      Release(pane: .leading, expected: .stay),
      Release(isTearing: true, pane: .leading, expected: .newWindow),
      // A window with no panes ignores both, and a tab in no pane has no other section.
      Release(
        target: .leading, isTearing: true, canShow: false, isSplit: false, overOther: true,
        expected: .newWindow),
      Release(target: .leading, canShow: false, isSplit: false, overOther: true, expected: .stay),
      Release(isSplit: false, pane: .leading, overOther: true, expected: .stay),
      Release(overOther: true, expected: .stay),
    ])
  fileprivate func release(_ release: Release) {
    let outcome = TabDragRelease(
      target: release.target, isTearing: release.isTearing, canShowInPane: release.canShow,
      isSplit: release.isSplit, pane: release.pane, isOverOtherSection: release.overOther)
    #expect(outcome == release.expected)
  }
}
