#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("The transcript column's gutters", .serialized)
  @MainActor
  struct TranscriptColumnTests {
    /// Where a row's content starts, from the leading edge of a 700 pt pane.
    private func contentStart(_ style: TranscriptStyle, _ layout: LayoutWidth) -> CGFloat {
      final class Recorder { var minX: CGFloat = -1 }
      let recorder = Recorder()
      let screen = transcriptScreen(
        Color.clear.frame(height: 10)
          .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .global).minX
          } action: {
            recorder.minX = $0
          }
          .transcriptColumn()
          .transcriptAppearance(TranscriptAppearance(style: style, contentWidth: .edgeToEdge)),
        layout: layout)
      defer { screen.close() }
      screen.settle()
      return recorder.minX
    }

    @Test("CLI markers hang clear of the turn rail's ticks; where no rail shows, nothing moves")
    func railRoom() {
      let markers = TranscriptAppearance.defaultFontSize * 0.602 * Double(CLIMetrics.markerColumns)
      let regular = contentStart(.cli, .regular)
      #expect(regular - markers >= TurnRail.restingEdge + Theme.Spacing.extraSmall - 0.5)
      let compact = contentStart(.cli, .compact)
      #expect(abs(compact - (markers + Theme.Spacing.extraSmall)) <= 0.5, "\(compact)")
      #expect(abs(contentStart(.chat, .regular) - Theme.Spacing.gutter) <= 0.5)
    }
  }
#endif
