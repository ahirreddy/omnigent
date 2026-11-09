#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor @Observable
  private final class ApproveModel {
    var showsApprove = true
  }

  private struct ReportingCard: View {
    let model: ApproveModel
    let surfaces: DecisionSurfaces

    var body: some View {
      ScrollView {
        Color.clear.frame(height: 200)
          .reportsInlineDecision("one", showsApprove: model.showsApprove)
      }
      .environment(surfaces)
      .frame(width: 400, height: 300)
    }
  }

  @Suite("Decisions: small gaps", .serialized)
  @MainActor
  struct DecisionsGapsTests {
    @Test("An inline card that stops offering Approve tells the dock so")
    func approveChanges() {
      let model = ApproveModel()
      let surfaces = DecisionSurfaces()
      let screen = OffscreenWindow(ReportingCard(model: model, surfaces: surfaces))
      defer { screen.close() }
      screen.settle()
      #expect(surfaces.visibility.approvable == ["one"])
      model.showsApprove = false
      screen.settle()
      #expect(surfaces.visibility.approvable.isEmpty)
      #expect(surfaces.visibility.onScreen == ["one"])
    }

    @Test("Inline Markdown applies, and text it can't parse shows as written")
    func inlineMarkdown() {
      let styled = InlineMarkdownText.attributed("use **Bash** now")
      #expect(String(styled.characters) == "use Bash now")
      struct Unparseable: Error {}
      let plain = InlineMarkdownText.attributed("use **Bash** now") { _ in throw Unparseable() }
      #expect(String(plain.characters) == "use **Bash** now")
    }
  }
#endif
