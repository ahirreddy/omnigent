import CoreGraphics
import Testing

@testable import OmnigentUIComponents

@Suite("One decision surface at a time")
struct DecisionSurfaceTests {
  /// What the dock and composer leave of the scroll view.
  private static let viewport = CGRect(x: 0, y: 100, width: 400, height: 400)

  private static func placement(minY: CGFloat, height: CGFloat) -> InlineDecisionPlacement {
    InlineDecisionPlacement(
      card: CGRect(x: 0, y: minY, width: 400, height: height), viewport: viewport)
  }

  @Test("A card is on screen once half of it shows above the bottom bar")
  func visibilityRule() {
    // Fully above the bar.
    #expect(
      InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 200, height: 200), wasOnScreen: false))
    // Behind the bar, which ends the viewport.
    #expect(
      !InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 520, height: 160), wasOnScreen: false))
    // Scrolled above the viewport.
    #expect(
      !InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: -300, height: 200), wasOnScreen: false))
    // A third visible: not yet on screen, but one already on screen stays (no flicker).
    let third = Self.placement(minY: 400, height: 300)
    #expect(!InlineDecisionVisibility.isOnScreen(third, wasOnScreen: false))
    #expect(InlineDecisionVisibility.isOnScreen(third, wasOnScreen: true))
    // A tenth visible leaves.
    #expect(
      !InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 470, height: 300), wasOnScreen: true))
    // A card taller than the viewport counts once it fills half of the viewport.
    #expect(
      InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 280, height: 1_200), wasOnScreen: false))
  }

  @Test("A sliver of a card over a short viewport is not on screen")
  func shortViewport() {
    // A tall dock leaves the transcript 60 points; the card fills them.
    let short = InlineDecisionPlacement(
      card: CGRect(x: 0, y: 90, width: 400, height: 205),
      viewport: CGRect(x: 0, y: 100, width: 400, height: 60))
    #expect(!InlineDecisionVisibility.isOnScreen(short, wasOnScreen: false))
    // Ten points of it: one already on screen leaves.
    let tenPoints = InlineDecisionPlacement(
      card: short.card, viewport: CGRect(x: 0, y: 100, width: 400, height: 10))
    #expect(!InlineDecisionVisibility.isOnScreen(tenPoints, wasOnScreen: true))
    // A card shorter than the minimum counts once enough of it shows.
    #expect(
      InlineDecisionVisibility.isOnScreen(
        Self.placement(minY: 200, height: 40), wasOnScreen: false))
  }

  @Test("The tracker publishes only entries and exits")
  func tracker() {
    let surfaces = DecisionSurfaces()
    surfaces.report("a", isOnScreen: true, showsApprove: true)
    surfaces.report("b", isOnScreen: true, showsApprove: false)
    #expect(surfaces.visibility.onScreen == ["a", "b"])
    #expect(surfaces.visibility.approvable == ["a"])
    // A row that starts answering in place shows Approve from then on.
    surfaces.report("b", isOnScreen: true, showsApprove: true)
    #expect(surfaces.visibility.approvable == ["a", "b"])
    surfaces.report("b", isOnScreen: false, showsApprove: true)
    #expect(surfaces.visibility.onScreen == ["a"])
    #expect(surfaces.visibility.approvable == ["a"])
    surfaces.report("a", isOnScreen: false, showsApprove: true)
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
