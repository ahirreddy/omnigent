#if os(macOS)
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inbox and palette rendering", .serialized)
  struct InboxPaletteRenderTests {
    @Test("triage and palette fit Mac and phone widths in both appearances")
    func render() throws {
      for width in [390.0, 760.0] {
        for scheme in [ColorScheme.light, .dark] {
          let layout: LayoutWidth = width < 600 ? .compact : .regular
          let appearance = scheme == .dark ? "dark" : "light"
          let inbox = try RenderSupport.render(
            InboxTriagePlayground().omnigentTheme(.omni),
            width: width, height: 844, scheme: scheme, layout: layout)
          #expect(RenderSupport.inkCoverage(inbox) > 0.01)
          try RenderSupport.write(inbox, name: "rm-inbox-triage-\(Int(width))-\(appearance)")
          let model = PlaygroundModel(scenario: .palette)
          let palette = try RenderSupport.render(
            CommandPalette(
              state: model.paletteState,
              commands: PaletteCatalog.entries(
                state: model.paletteState,
                commands: SessionCommandActions(
                  focusComposer: {}, toggleViewMode: {}, openChanges: {})),
              perform: { _ in }
            ).omnigentTheme(.omni),
            width: width, height: 540, scheme: scheme, layout: layout)
          #expect(RenderSupport.inkCoverage(palette) > 0.01)
          try RenderSupport.write(palette, name: "rm-inbox-palette-\(Int(width))-\(appearance)")
        }
      }
    }
  }
#endif
