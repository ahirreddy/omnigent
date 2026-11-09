#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Adaptive: layout helpers", .serialized)
  @MainActor
  struct AdaptiveLayoutTests {
    private struct WidthReader: View {
      @Environment(\.layoutWidth) private var width
      var body: some View { Text(width == .compact ? "is compact" : "is regular") }
    }

    @Test("A wide window is regular and a narrow one compact")
    func measuredWidth() throws {
      let wide = OffscreenWindow(
        AnyView(WidthReader().frame(maxWidth: .infinity).adaptiveLayoutWidth()), width: 800,
        height: 200)
      defer { wide.close() }
      #expect(try wide.shows("is regular"))
      let narrow = OffscreenWindow(
        AnyView(WidthReader().frame(maxWidth: .infinity).adaptiveLayoutWidth()), width: 400,
        height: 200)
      defer { narrow.close() }
      #expect(try narrow.shows("is compact"))
    }

    @Test("A host can force the width class")
    func forcedWidth() throws {
      let screen = OffscreenWindow(
        AnyView(WidthReader().layoutWidth(.compact)), width: 800, height: 200)
      defer { screen.close() }
      #expect(try screen.shows("is compact"))
    }

    @Test("Compact must grow past the threshold to become regular, so it can't flip on each pass")
    func hysteresis() {
      #expect(LayoutWidth.measuring(559, compactBelow: 560, previous: .regular) == .compact)
      #expect(LayoutWidth.measuring(560, compactBelow: 560, previous: .regular) == .regular)
      #expect(LayoutWidth.measuring(570, compactBelow: 560, previous: .compact) == .compact)
      #expect(
        LayoutWidth.measuring(
          560 + LayoutWidth.regularSlack, compactBelow: 560, previous: .compact) == .regular)
    }

    @Test("Only the primary pane shows without a hinge, and no posture is reported")
    func duoLayout() throws {
      let screen = OffscreenWindow(
        AnyView(
          DuoLayout {
            Text("primary pane")
          } secondary: {
            Text("secondary pane")
          }), width: 500, height: 200)
      defer { screen.close() }
      #expect(try screen.shows("primary pane"))
      #expect(try !screen.shows("secondary pane"))
      #expect(EnvironmentValues().hingePosture == .unavailable)
    }

    @Test("The column's minimum holds its content without measuring it")
    func unmeasuredMinimum() throws {
      let screen = OffscreenWindow(
        AnyView(
          Text("inside")
            .unmeasuredMinimum(CGSize(width: 240, height: 200))), width: 500, height: 400)
      defer { screen.close() }
      #expect(try screen.shows("inside"))
    }
  }
#endif
