#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Says how its window looks to it, and what it is told of the window's real state.
  private struct LookProbe: View {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.windowIsActive) private var windowIsActive

    var body: some View {
      Text(Self.text(looksActive: appearsActive, windowIsActive: windowIsActive))
      Text(controlActiveState == .key ? "controls key" : "controls not key")
    }

    static func text(looksActive: Bool, windowIsActive: Bool) -> String {
      "looks \(looksActive ? "active" : "inactive"), window \(windowIsActive ? "active" : "behind")"
    }
  }

  @Suite("A window that keeps its active look")
  @MainActor
  struct ActiveLookTests {
    /// The probe in a window that is in front, or behind another.
    private func screen(_ view: some View, windowAppearsActive: Bool) -> OffscreenWindow<AnyView> {
      OffscreenWindow(
        AnyView(view.environment(\.appearsActive, windowAppearsActive)), width: 320, height: 120)
    }

    @Test("Behind another window nothing under it greys out, and its real state is still known")
    func behindAnotherWindow() throws {
      let kept = screen(LookProbe().keepsActiveLook(), windowAppearsActive: false)
      defer { kept.close() }
      #expect(try kept.shows(LookProbe.text(looksActive: true, windowIsActive: false)))
      #expect(try kept.shows("controls key"))

      // Without it a view follows its window, and is told nothing else.
      let plain = screen(LookProbe(), windowAppearsActive: false)
      defer { plain.close() }
      #expect(try plain.shows(LookProbe.text(looksActive: false, windowIsActive: true)))
    }

    @Test("In front it looks active and says so")
    func inFront() throws {
      let kept = screen(LookProbe().keepsActiveLook(), windowAppearsActive: true)
      defer { kept.close() }
      #expect(try kept.shows(LookProbe.text(looksActive: true, windowIsActive: true)))
      #expect(try kept.shows("controls key"))
    }
  }
#endif
