import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Short windows stay compact")
struct ShortWindowLayoutTests {
  private func layout(
    _ horizontal: UserInterfaceSizeClass?, _ vertical: UserInterfaceSizeClass?
  ) -> UserInterfaceSizeClass? {
    ShortWindowLayout.horizontalClass(horizontal: horizontal, vertical: vertical)
  }

  @Test("a phone in landscape lays out compact; tall windows keep their class")
  func horizontalClass() {
    // A large iPhone in landscape reports regular width and compact height.
    #expect(layout(.regular, .compact) == .compact)
    #expect(layout(.compact, .compact) == .compact)
    // iPad and an unfolded Duo are tall.
    #expect(layout(.regular, .regular) == .regular)
    #expect(layout(.compact, .regular) == .compact)
    #expect(layout(.regular, nil) == .regular)
  }
}
