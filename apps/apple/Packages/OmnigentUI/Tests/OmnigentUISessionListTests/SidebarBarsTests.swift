#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What the search box writes.
  @MainActor @Observable
  private final class SearchText {
    var value = ""
  }

  private struct SearchBoxHost: View {
    @Bindable var text: SearchText

    var body: some View {
      SidebarSearchBox(text: $text.value).frame(width: 240)
    }
  }

  /// The sidebar's header sits above its search field, and both hide the rows scrolling under
  /// them: the field is the sidebar's own, on the sidebar's own backdrop.
  @Suite("Sidebar: the bars over the list", .serialized)
  @MainActor
  struct SidebarBarsTests {
    private func field(_ screen: OffscreenWindow<some View>) throws -> NSSearchField {
      try #require(screen.allViews.compactMap { $0 as? NSSearchField }.first)
    }

    @Test("The search box shows the host's text, and its clear button empties it")
    func searchBox() throws {
      let text = SearchText()
      let screen = OffscreenWindow(SearchBoxHost(text: text), width: 260, height: 60)
      defer { screen.close() }
      let box = try field(screen)
      #expect(box.placeholderString == "Search sessions")

      text.value = "zeta"
      screen.settle()
      #expect(box.stringValue == "zeta")

      let delegate = try #require(box.delegate)
      delegate.searchFieldDidEndSearching?(box)
      #expect(text.value.isEmpty)
    }

    @Test("Typing searches as the text changes, and a click on the field's clear button empties it")
    func clearButton() throws {
      let text = SearchText()
      let screen = OffscreenWindow(SearchBoxHost(text: text), width: 260, height: 60)
      defer { screen.close() }
      let box = try field(screen)
      try screen.click(box)
      try screen.type("zeta")
      #expect(text.value == "zeta")
      let cell = try #require(box.cell as? NSSearchFieldCell)
      let clear = box.convert(cell.cancelButtonRect(forBounds: box.bounds), to: screen.host)
      try screen.click(CGPoint(x: clear.midX, y: clear.midY))
      #expect(text.value.isEmpty)
      #expect(box.stringValue.isEmpty)
    }

    @Test("The header comes first, then the search field, then the rows")
    func headerAboveSearch() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      let box = try field(screen)
      let search = box.convert(box.bounds, to: screen.host)
      // The header's Search button is the window's first control.
      let header = try #require(screen.controlFrames.first)
      #expect(header.maxY <= search.minY, "header \(header), search \(search)")
      let list = try #require(screen.list)
      let firstRow = list.convert(list.rect(ofRow: 0), to: screen.host)
      #expect(search.maxY <= firstRow.minY, "search \(search), first row \(firstRow)")
    }

    private func materials(_ view: some View) -> (
      screen: OffscreenWindow<AnyView>, found: [NSVisualEffectView]
    ) {
      let screen = OffscreenWindow(
        AnyView(view.frame(width: 200, height: 40)), width: 200, height: 40)
      let found = screen.allViews.compactMap { $0 as? NSVisualEffectView }.filter {
        $0.material == .sidebar && $0.blendingMode == .behindWindow && $0.state == .active
      }
      return (screen, found)
    }

    @Test("A bar draws the sidebar's own material, tinted where the theme tints its sidebar")
    func backdrop() {
      for theme in [OmnigentTheme.nord, .omni] {
        for scheme in [ColorScheme.dark, .light] {
          let drawn = materials(
            SidebarBarBackdrop().environment(\.omnigentTheme, theme).environment(
              \.colorScheme, scheme))
          defer { drawn.screen.close() }
          #expect(drawn.found.count == 1, "\(theme.id) \(scheme)")
        }
      }
    }

    @Test("A peeking sidebar's bars stay on its glass panel")
    func peekHasNoBackdrop() {
      let drawn = materials(SidebarBarBackdrop().environment(\.isSidebarPeek, true))
      defer { drawn.screen.close() }
      #expect(drawn.found.isEmpty)
    }
  }
#endif
