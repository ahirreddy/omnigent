#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentViewTesting

  /// Records the color scheme a view is given.
  @MainActor
  private final class SchemeLog {
    var scheme: ColorScheme?
  }

  private struct SchemeProbe: View {
    let log: SchemeLog
    @Environment(\.colorScheme) private var scheme

    var body: some View {
      Color.clear.onAppear { log.scheme = scheme }
    }
  }

  @Suite("Offscreen window appearance", .serialized)
  @MainActor
  struct OffscreenAppearanceTests {
    @Test("a view is dark by default, whatever the system is set to")
    func defaultIsDark() {
      let log = SchemeLog()
      let screen = OffscreenWindow(SchemeProbe(log: log))
      defer { screen.close() }
      #expect(log.scheme == .dark)
      #expect(screen.window.effectiveAppearance.name == .darkAqua)
    }

    @Test("a test can ask for light")
    func lightOnRequest() {
      let log = SchemeLog()
      let screen = OffscreenWindow(SchemeProbe(log: log), appearance: .aqua)
      defer { screen.close() }
      #expect(log.scheme == .light)
      #expect(screen.window.effectiveAppearance.name == .aqua)
    }
  }
#endif
