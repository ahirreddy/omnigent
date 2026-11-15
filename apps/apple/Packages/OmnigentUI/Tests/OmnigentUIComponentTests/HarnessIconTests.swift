#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Harness marks on session rows", .serialized)
  @MainActor
  struct HarnessIconTests {
    private func render(_ view: some View, side: CGFloat = 48) throws -> RenderSupport.Rendered {
      try RenderSupport.render(
        view.frame(width: side, height: side), width: side, height: side, scheme: .dark,
        layout: .regular)
    }

    private func shows(_ hex: UInt32, in rendered: RenderSupport.Rendered) -> Bool {
      RenderSupport.shows(hex, in: rendered)
    }

    @Test("Every harness the app names by brand has a mark whose glyph fits its square")
    func marks() {
      #expect(
        HarnessMark.marks.keys.sorted() == [
          "antigravity", "claude", "codex", "cursor", "devin", "goose", "hermes", "kimi", "kiro",
          "opencode", "pi", "qwen",
        ])
      for (identifier, mark) in HarnessMark.marks {
        // The app must name the harness, or its sessions would show a monogram instead.
        #expect(HarnessAppearance(harness: "\(identifier)-native").identifier == identifier)
        #expect(!mark.mono.isEmpty, "\(identifier)")
        for part in mark.mono {
          let bounds = SVGPath.parse(part.path).boundingRect
          #expect(!bounds.isEmpty || part.stroke != nil, "\(identifier)")
          #expect(
            CGRect(x: -0.5, y: -0.5, width: 25, height: 25).contains(bounds), "\(identifier)")
        }
        #expect(mark.parts(.monochrome).count == mark.mono.count)
        let colored = mark.color.isEmpty ? mark.mono : mark.color
        #expect(mark.parts(.color).count == colored.count)
      }
    }

    @Test(
      "Each mark draws in color and in one color",
      arguments: HarnessMark.marks.keys.sorted(), [HarnessIconStyle.color, .monochrome])
    func draws(identifier: String, style: HarnessIconStyle) throws {
      let rendered = try render(HarnessIcon(harness: identifier, style: style, size: 40))
      #expect(RenderSupport.inkCoverage(rendered) > 0.02, "\(identifier) \(style)")
    }

    @Test("The marks read on a dark and a light sidebar", arguments: [ColorScheme.dark, .light])
    func sheet(scheme: ColorScheme) throws {
      let identifiers = HarnessMark.marks.keys.sorted() + ["claude-sdk", "openai-agents", "zeta"]
      let sheet = VStack(alignment: .leading, spacing: 6) {
        ForEach(identifiers, id: \.self) { identifier in
          HStack(spacing: 10) {
            HarnessIcon(harness: identifier, style: .color)
            HarnessIcon(harness: identifier, style: .monochrome)
            HarnessIcon(harness: identifier, style: .color, size: 32)
            HarnessIcon(harness: identifier, style: .monochrome, size: 32)
            Text(HarnessAppearance(harness: identifier).label).font(.callout)
          }
        }
      }
      .padding(12)
      let rendered = try RenderSupport.render(
        sheet, width: 260, scheme: scheme, layout: .regular)
      #expect(RenderSupport.inkCoverage(rendered) > 0.03)
      try RenderSupport.write(rendered, name: "harness-marks-\(scheme == .dark ? "dark" : "light")")
    }

    @Test("Color shows the brand's colors; Monochrome draws the same glyph in the text color")
    func brandColors() throws {
      let orange: UInt32 = 0xD97757
      let color = try render(HarnessIcon(harness: "claude-native", style: .color, size: 40))
      #expect(shows(orange, in: color))
      let mono = try render(
        HarnessIcon(harness: "claude-native", style: .monochrome, size: 40)
          .foregroundStyle(Color(red: 0, green: 1, blue: 0)))
      #expect(!shows(orange, in: mono))
      #expect(shows(0x00FF00, in: mono))
      // Kiro's colored mark is a purple tile; its one-color glyph has none.
      #expect(shows(0x9046FF, in: try render(HarnessIcon(harness: "kiro", size: 40))))
      let kiro = try render(HarnessIcon(harness: "kiro", style: .monochrome, size: 40))
      #expect(!shows(0x9046FF, in: kiro))
      // A mark with no brand colors follows the text in both.
      let cursor = try render(
        HarnessIcon(harness: "cursor", size: 40).foregroundStyle(Color(red: 0, green: 1, blue: 0)))
      #expect(shows(0x00FF00, in: cursor))
    }

    @Test("A harness with no mark shows its monogram, outlined when color is off")
    func monogram() throws {
      let screen = OffscreenWindow(
        HStack {
          HarnessIcon(harness: "zeta-runner")
          HarnessIcon(harness: "claude-sdk", style: .monochrome)
          HarnessIcon(harness: "openai-agents")
          HarnessIcon(harness: nil)
        }, width: 120, height: 40)
      defer { screen.close() }
      for monogram in ["Z", "C", "OA", "A"] { #expect(try screen.shows(monogram), "\(monogram)") }
      let tinted = try render(HarnessIcon(harness: "claude-sdk", size: 40))
      #expect(shows(0xD97757, in: tinted))
      let plain = try render(HarnessIcon(harness: "claude-sdk", style: .monochrome, size: 40))
      #expect(!shows(0xD97757, in: plain))
    }

    @Test("A session row leads with the mark unless the setting turns it off")
    func row() throws {
      func row(_ style: HarnessIconStyle) throws -> RenderSupport.Rendered {
        try RenderSupport.render(
          HarnessActivityRow(style: style), width: 280, height: 32, scheme: .dark,
          layout: .regular)
      }
      #expect(shows(0xD97757, in: try row(.color)))
      #expect(!shows(0xD97757, in: try row(.monochrome)))
      let withMark = RenderSupport.inkedWidth(try row(.monochrome))
      #expect(withMark > RenderSupport.inkedWidth(try row(.hidden)))
    }

    @Test("In a sidebar list row the one-color mark is drawn in the row's text color")
    func inSidebarList() throws {
      func row(_ style: HarnessIconStyle) throws -> RenderSupport.Rendered {
        try RenderSupport.render(
          List {
            HStack {
              if style != .hidden { HarnessIcon(harness: "codex-native", style: style, size: 32) }
              Spacer()
            }
            .foregroundStyle(Color(red: 0, green: 1, blue: 0))
          }
          .listStyle(.sidebar)
          .frame(height: 80),
          width: 200, height: 80, scheme: .dark, layout: .regular)
      }
      #expect(shows(0x00FF00, in: try row(.monochrome)))
      #expect(!shows(0x00FF00, in: try row(.hidden)))
    }

    @Test("The style is Color while active until chosen, a past choice keeps its stored value")
    func setting() throws {
      #expect(HarnessIconStyle.default == .colorWhileActive)
      #expect(
        HarnessIconStyle.allCases.map(\.title)
          == ["Color while active", "Always color", "Always monochrome", "No icon"])
      #expect(HarnessIconStyle(rawValue: "color") == .color)
      #expect(HarnessIconStyle(rawValue: "monochrome") == .monochrome)
      #expect(HarnessIconStyle(rawValue: "hidden") == .hidden)
      #expect(HarnessIconStyle(rawValue: "color-while-active") == .colorWhileActive)
      // Display options saved with the old style still load.
      let saved = Data(
        (#"{"show":"all","groupBy":"default","sortBy":"updated","#
          + #""details":["repo"],"harnessIcon":"color"}"#).utf8)
      let read = try JSONDecoder().decode(SessionDisplayOptions.self, from: saved)
      #expect(read.details == [.repo])
    }

    @Test("Appearance settings choose the style under its own key")
    func appearanceSetting() throws {
      let store = try #require(UserDefaults(suiteName: "harness-icon-\(UUID())"))
      let screen = settingsForm(store: store) { InterfaceAppearanceSections() }
      defer { screen.close() }
      #expect(try screen.shows("Harness icons"))
      let picker = try #require(
        screen.popUps.first { $0.title == HarnessIconStyle.colorWhileActive.title })
      #expect(try screen.titles(inPopUp: picker) == HarnessIconStyle.allCases.map(\.title))
      try screen.choose(HarnessIconStyle.color.title, inPopUp: picker)
      #expect(store.string(forKey: InterfacePreferences.harnessIconKey) == "color")
      try screen.choose(HarnessIconStyle.monochrome.title, inPopUp: picker)
      #expect(store.string(forKey: InterfacePreferences.harnessIconKey) == "monochrome")
      try screen.choose(HarnessIconStyle.hidden.title, inPopUp: picker)
      #expect(store.string(forKey: InterfacePreferences.harnessIconKey) == "hidden")
      try screen.choose(HarnessIconStyle.colorWhileActive.title, inPopUp: picker)
      #expect(store.string(forKey: InterfacePreferences.harnessIconKey) == "color-while-active")
    }

    @Test("The session list draws the mark by the stored style, and follows a change at once")
    func sidebarFollowsSetting() throws {
      let store = try #require(UserDefaults(suiteName: "harness-icon-\(UUID())"))
      var state = SidebarFixture.state
      // A harness with no mark draws its letter, which the window's text shows.
      state.rowInfo["beta"] = SessionRowInfo(harness: "zeta-runner")
      let screen = OffscreenWindow(
        SidebarHarness(spy: SidebarSpy(state)).defaultAppStorage(store), width: 340, height: 800)
      defer { screen.close() }
      #expect(try screen.shows("Z"))
      store.set(HarnessIconStyle.hidden.rawValue, forKey: InterfacePreferences.harnessIconKey)
      screen.settle()
      #expect(try !screen.shows("Z"))
      store.set(HarnessIconStyle.color.rawValue, forKey: InterfacePreferences.harnessIconKey)
      screen.settle()
      #expect(try screen.shows("Z"))
    }

    @Test("The display menu no longer offers the style")
    func menu() throws {
      let screen = OffscreenWindow(
        DisplayMenu(options: SessionDisplayOptions(), showsShared: false) { _ in },
        width: 80, height: 40)
      defer { screen.close() }
      let menu = try screen.openMenu(try #require(screen.popUps.first))
      let show = try #require(menu.item(named: "Show")?.submenu)
      #expect(show.item(named: "Harness Icon") == nil)
      #expect(show.items.contains { !$0.isSeparatorItem })
    }
  }
#endif
