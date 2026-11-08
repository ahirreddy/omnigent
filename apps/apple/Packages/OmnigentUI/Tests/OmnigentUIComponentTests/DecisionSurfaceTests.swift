import CoreGraphics
import Testing

@testable import OmnigentUIComponents

@Suite("One decision surface at a time")
struct DecisionSurfaceTests {
  private static let viewport = CGRect(x: 0, y: 100, width: 400, height: 600)

  private static func placement(minY: CGFloat, height: CGFloat) -> InlineDecisionPlacement {
    InlineDecisionPlacement(
      card: CGRect(x: 0, y: minY, width: 400, height: height), viewport: viewport,
      showsApprove: true)
  }

  @Test("A card is on screen once half of it shows above the bottom bar")
  func visibilityRule() {
    let bar: CGFloat = 500
    // Fully above the bar.
    #expect(
      InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 200, height: 200), bottomBarTop: bar, wasOnScreen: false))
    // Behind the bar: inside the scroll view's bounds, but covered by the dock and composer.
    #expect(
      !InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 520, height: 160), bottomBarTop: bar, wasOnScreen: false))
    // Scrolled above the viewport.
    #expect(
      !InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: -300, height: 200), bottomBarTop: bar, wasOnScreen: false))
    // A third visible: not yet on screen, but one already on screen stays (no flicker).
    let third = Self.placement(minY: 400, height: 300)
    #expect(!InlineDecisionVisibility.isOnScreen(third, bottomBarTop: bar, wasOnScreen: false))
    #expect(InlineDecisionVisibility.isOnScreen(third, bottomBarTop: bar, wasOnScreen: true))
    // A tenth visible leaves.
    #expect(
      !InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 470, height: 300), bottomBarTop: bar, wasOnScreen: true))
    // A card taller than the viewport counts once it fills half of the viewport.
    #expect(
      InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 280, height: 1_200), bottomBarTop: bar, wasOnScreen: false))
    // Without a bar the whole viewport counts.
    #expect(
      InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 520, height: 160), bottomBarTop: nil, wasOnScreen: false))
  }

  @Test("A sliver of a card over a short viewport is not on screen")
  func shortViewport() {
    // A tall dock leaves the transcript 60 points; the card fills them.
    let short = InlineDecisionPlacement(
      card: CGRect(x: 0, y: 90, width: 400, height: 205),
      viewport: CGRect(x: 0, y: 100, width: 400, height: 60), showsApprove: true)
    #expect(!InlineDecisionVisibility.isOnScreen(short, bottomBarTop: 160, wasOnScreen: false))
    // Ten points of it: one already on screen leaves.
    #expect(!InlineDecisionVisibility.isOnScreen(short, bottomBarTop: 110, wasOnScreen: true))
    // A card shorter than the minimum counts once enough of it shows.
    #expect(
      InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 200, height: 40), bottomBarTop: 500, wasOnScreen: false))
  }

  @Test("The tracker publishes only entries and exits")
  func tracker() {
    let surfaces = DecisionSurfaces()
    surfaces.setBottomBarTop(500)
    surfaces.report("a", placement: Self.placement(minY: 200, height: 200))
    var compact = Self.placement(minY: 250, height: 100)
    compact.showsApprove = false
    surfaces.report("b", placement: compact)
    #expect(surfaces.visibility.onScreen == ["a", "b"])
    #expect(surfaces.visibility.approvable == ["a"])
    // The bar rises over "b" (the keyboard, or a taller dock).
    surfaces.setBottomBarTop(240)
    #expect(surfaces.visibility.onScreen == ["a"])
    surfaces.report("a", placement: nil)
    #expect(surfaces.visibility.onScreen.isEmpty)
  }

  @Test("The dock leaves on-screen cards to the transcript and names them in one line")
  func dockSplitsSurfaces() {
    var state = PreviewData.conversation
    state.decisions = PreviewData.dockDecisions
    let inline = InlineDecisionVisibility(
      onScreen: [PreviewData.codexCommand.id], approvable: [PreviewData.codexCommand.id])
    let model = DecisionDockModel(
      state: state, selectedID: nil, isExpanded: false, layoutWidth: .regular, inline: inline)
    #expect(model.cards.count == 6, "the iPhone sheet still lists every request")
    #expect(!model.dockCards.contains { $0.id == PreviewData.codexCommand.id })
    #expect(model.aboveCount == 1)
    #expect(model.dockHeadline == "6 requests need you \u{00B7} 1 above")
    #expect(model.compactCards.first?.id == PreviewData.approval.id)

    var single = PreviewData.conversation
    single.decisions = [PreviewData.codexCommand]
    let summary = DecisionDockModel(
      state: single, selectedID: nil, isExpanded: true, layoutWidth: .compact, inline: inline)
    #expect(summary.dockCards.isEmpty, "the dock shows only its summary line")
    #expect(summary.selected == nil)
  }

  @Test("Command-Return follows the surface that shows the request")
  func shortcutFollowsSurface() {
    var state = PreviewData.conversation
    state.decisions = PreviewData.dockDecisions
    let command = PreviewData.codexCommand.id
    // Nothing on screen: the dock's first answerable approval.
    let docked = DecisionDockModel(
      state: state, selectedID: nil, isExpanded: false, layoutWidth: .regular)
    #expect(docked.shortcutTarget == DecisionShortcutTarget(cardID: command, surface: .dock))
    // The same card on screen inline: the inline card takes it.
    let inline = DecisionDockModel(
      state: state, selectedID: nil, isExpanded: false, layoutWidth: .regular,
      inline: InlineDecisionVisibility(onScreen: [command], approvable: [command]))
    #expect(inline.shortcutTarget == DecisionShortcutTarget(cardID: command, surface: .inline))
    // On screen as a compact row that only offers Review: no inline Approve to take it.
    let reviewOnly = DecisionDockModel(
      state: state, selectedID: nil, isExpanded: false, layoutWidth: .regular,
      inline: InlineDecisionVisibility(onScreen: [command]))
    #expect(reviewOnly.shortcutTarget == nil, "no other compact row answers in place")
    // An expanded dock keeps its selected approval.
    let expanded = DecisionDockModel(
      state: state, selectedID: PreviewData.claudeBash.id, isExpanded: true,
      layoutWidth: .regular,
      inline: InlineDecisionVisibility(onScreen: [command], approvable: [command]))
    #expect(
      expanded.shortcutTarget
        == DecisionShortcutTarget(cardID: PreviewData.claudeBash.id, surface: .dock))
    // A sendable draft keeps Command-Return on Send whichever surface is active.
    #expect(CommandReturnOwner.resolve(canSend: true, approvableCardID: command) == .send)
    #expect(CommandReturnOwner.resolve(canSend: false, approvableCardID: command) == .approve)
  }

  @Test("A phone dock shows one actionable request and the count")
  func phoneLimit() {
    var state = PreviewData.conversation
    state.decisions = PreviewData.dockDecisions
    let phone = DecisionDockModel(
      state: state, selectedID: nil, isExpanded: false, layoutWidth: .compact)
    #expect(phone.compactCards.count == 1)
    #expect(phone.hiddenCount == 5)
  }

  @Test("Paths read basename first")
  func paths() {
    let path = DecisionPath("client-core/crates/omnigent-core/src/auth/refresh.rs")
    #expect(path.name == "refresh.rs")
    #expect(path.directory == "client-core/crates/omnigent-core/src/auth")
    #expect(DecisionPath("README.md").directory == nil)
    #expect(DecisionPath("/etc/hosts").directory == "/etc")
    #expect(DecisionPath("/hosts").directory == "/")
    #expect(DecisionPath("web/src/").name == "src")
  }

  @Test("Large payloads offer the full-screen review")
  func payloadSize() {
    #expect(DecisionPayloadSize.isLarge(PreviewData.longEdit))
    #expect(DecisionPayloadSize.isLarge(PreviewData.planReview))
    #expect(!DecisionPayloadSize.isLarge(PreviewData.codexCommand))
    #expect(!DecisionPayloadSize.isLarge(PreviewData.singleEdit))
    #expect(!DecisionPayloadSize.isLarge(PreviewData.choice))
  }
}
