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

    /// Whether any pixel is strongly colored in `hex`'s hue. Hues survive the display's color
    /// matching, which shifts exact values.
    private func shows(_ hex: UInt32, in rendered: RenderSupport.Rendered) -> Bool {
      let image = rendered.image
      let wanted = NSColor(Color(hex: hex)).usingColorSpace(.deviceRGB)?.hueComponent ?? 0
      for row in 0..<image.pixelsHigh {
        for column in 0..<image.pixelsWide {
          guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB),
            color.saturationComponent > 0.4, color.brightnessComponent > 0.4
          else { continue }
          let distance = abs(color.hueComponent - wanted)
          if min(distance, 1 - distance) < 0.05 { return true }
        }
      }
      return false
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
        let session = SessionSummary(id: "s", title: "Fix the build", updatedAt: 0)
        let actions = SessionListActions()
        return try RenderSupport.render(
          SessionRow(
            session: session, info: SessionRowInfo(harness: "claude-native"), isUnread: false,
            attention: 0, details: [], harnessIcon: style, now: Date(timeIntervalSince1970: 60),
            menu: SessionRowMenu(
              session: session, isUnread: false, isShared: false, pinLimitReached: false,
              projects: [], actions: actions, rename: {}, confirmDelete: {}, confirmLeave: {},
              confirmStop: {})),
          width: 280, height: 32, scheme: .dark, layout: .regular)
      }
      #expect(shows(0xD97757, in: try row(.color)))
      #expect(!shows(0xD97757, in: try row(.monochrome)))
      let withMark = RenderSupport.inkCoverage(try row(.monochrome))
      #expect(withMark > RenderSupport.inkCoverage(try row(.hidden)))
    }

    @Test("Saved display options without the setting show the mark in color, and it round-trips")
    func setting() throws {
      let old = Data(
        (#"{"show":"all","groupBy":"default","sortBy":"updated","#
          + #""details":["repo"]}"#).utf8)
      let read = try JSONDecoder().decode(SessionDisplayOptions.self, from: old)
      #expect(read.harnessIcon == .color)
      #expect(read.details == [.repo])
      var changed = read
      changed.harnessIcon = .hidden
      let saved = try JSONEncoder().encode(changed)
      #expect(try JSONDecoder().decode(SessionDisplayOptions.self, from: saved) == changed)
      #expect(HarnessIconStyle.allCases.map(\.title) == ["Color", "Monochrome", "Off"])
    }

    @Test("The display menu's Show submenu chooses the mark's style")
    func menu() throws {
      var written: [SessionDisplayOptions] = []
      let screen = OffscreenWindow(
        DisplayMenu(options: SessionDisplayOptions(), showsShared: false) { written.append($0) },
        width: 80, height: 40)
      defer { screen.close() }
      let menu = try screen.openMenu(try #require(screen.popUps.first))
      let show = try #require(menu.item(named: "Show")?.submenu)
      let styles = try #require(show.item(named: "Harness Icon")?.submenu)
      try screen.choose(HarnessIconStyle.monochrome.title, in: styles)
      #expect(written.last?.harnessIcon == .monochrome)
      #expect(written.last?.details == SessionDisplayOptions().details)
    }
  }
#endif
