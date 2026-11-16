#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The Mac's row under the pill keeps one line as the pane narrows, until it can't.
  @MainActor
  @Suite("Composer footer widths", .serialized)
  struct ComposerFooterWidthTests {
    private let log = ComposerActionLog()

    /// Where the context line and the model menu sit in a composer this wide.
    private func frames(width: CGFloat) throws -> (context: CGRect, controls: CGRect) {
      var state = ComposerSamples.idle
      state.context?.host = "workspace-sandbox-440409769963544"
      let screen = OffscreenWindow(
        ComposerView(draft: .constant(""), state: state, actions: log.actions)
          .environment(\.composerLayoutStyle, .card),
        width: width, height: 240)
      defer { screen.close() }
      return try screen.withAccessibilityTree {
        (
          try screen.accessibilityFrame("composer-context"),
          try screen.accessibilityFrame("composer-configuration")
        )
      }
    }

    @Test("A narrow pane shortens where it runs and keeps the controls on its line")
    func narrowKeepsOneRow() throws {
      let wide = try frames(width: 900)
      #expect(abs(wide.context.midY - wide.controls.midY) < 4, "one row")
      let narrow = try frames(width: 520)
      #expect(abs(narrow.context.midY - narrow.controls.midY) < 4, "still one row")
      #expect(narrow.context.width < wide.context.width, "the context line gives way")
    }

    @Test("A very narrow pane puts where it runs on its own line, the controls under it")
    func veryNarrowStacks() throws {
      let stacked = try frames(width: 300)
      #expect(stacked.context.maxY <= stacked.controls.minY + 1)
      #expect(abs(stacked.context.minX - stacked.controls.minX) < 12, "both from the left")
    }
  }
#endif
