#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Otto and painted surfaces", .serialized)
  @MainActor
  struct DesignSystemPartsTests {
    private func pixels(_ view: some View) throws -> NSBitmapImageRep {
      try RenderSupport.render(view, width: 120, height: 120, scheme: .dark, layout: .regular).image
    }

    private func bytes(_ view: some View) throws -> Data? {
      try pixels(view).tiffRepresentation
    }

    @Test("Otto's pupils follow the gaze, only so far")
    func gaze() throws {
      let ahead = try bytes(OttoView())
      let right = try bytes(OttoView(gaze: CGSize(width: 1, height: 0)))
      let left = try bytes(OttoView(gaze: CGSize(width: -1, height: 0)))
      #expect(ahead != right)
      #expect(left != right)
      #expect(try bytes(OttoView(gaze: CGSize(width: 40, height: 0))) == right)
    }

    @Test("Otto looks ahead under Reduce Motion, whatever the gaze")
    func gazeReduced() throws {
      let ahead = try bytes(OttoView().environment(\._accessibilityReduceMotion, true))
      let looking = try bytes(
        OttoView(gaze: CGSize(width: 1, height: 1)).environment(\._accessibilityReduceMotion, true))
      #expect(ahead == looking)
    }

    @Test("Otto is drawn whatever shape it's given, not stretched")
    func square() throws {
      let image = try pixels(OttoView().frame(width: 60, height: 120))
      #expect(image.pixelsWide > 0)
      let tall = try bytes(OttoView().frame(width: 60, height: 120))
      #expect(try tall != bytes(OttoView().frame(width: 120, height: 120)))
    }

    private func color(_ image: NSBitmapImageRep, atFraction fraction: CGFloat) throws -> NSColor {
      let row = Int(CGFloat(image.pixelsHigh - 1) * fraction)
      return try #require(image.colorAt(x: image.pixelsWide / 2, y: row))
    }

    @Test("a sidebar takes its theme's tint, with the wash growing downward")
    func sidebarTint() throws {
      let theme = try #require(
        OmnigentTheme.builtIn.first { $0.palette(for: .dark).sidebarWash != nil })
      let plain = try pixels(Color.clear)
      let tinted = try pixels(Color.clear.themeSidebar().environment(\.omnigentTheme, theme))
      #expect(try color(tinted, atFraction: 0.05) != color(plain, atFraction: 0.05))
      #expect(try color(tinted, atFraction: 0.05) != color(tinted, atFraction: 0.95))
    }

    @Test("a theme with no sidebar tint leaves the material alone until transparency is reduced")
    func sidebarWithoutTint() throws {
      var custom = CustomTheme.default
      custom.translucentSidebar = true
      let theme = custom.theme()
      #expect(theme.palette(for: .dark).sidebarTint == nil)
      let plain = try bytes(Color.clear)
      let view = Color.clear.themeSidebar().environment(\.omnigentTheme, theme)
      #expect(try bytes(view) == plain)
      #expect(try bytes(view.environment(\._accessibilityReduceTransparency, true)) != plain)
    }

    @Test("selection fills only what's selected")
    func selection() throws {
      let selected = try bytes(Color.clear.selectionFill(true))
      #expect(try selected != bytes(Color.clear.selectionFill(false)))
      #expect(try bytes(Color.clear.selectionFill(false)) == bytes(Color.clear))
    }

    @Test("glass transitions leave the content as it was")
    func glassTransition() throws {
      let plain = try bytes(Color.red)
      #expect(try bytes(Color.red.glassTransition()) == plain)
      #expect(
        try bytes(Color.red.glassTransition().environment(\._accessibilityReduceMotion, true))
          == plain)
    }

    @Test("a pill reads the same with or without its symbol")
    func pill() throws {
      let screen = OffscreenWindow(
        VStack {
          Pill(text: "Beta")
          Pill(text: "Gamma", systemImage: "star", tint: Theme.accent)
          HarnessGlyph(harness: "codex")
        })
      defer { screen.close() }
      #expect(try screen.shows("Beta"))
      #expect(try screen.shows("Gamma"))
    }

    @Test("Copy copies, says so, and the label can be shown or only named")
    func copyButton() throws {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(CopyButton(text: "payload", showsLabel: true).frame(width: 200))
      defer { screen.close() }
      #expect(try screen.shows("Copy"))
      try screen.clickControl(at: 0)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "payload")
      #expect(try screen.shows("Copied"))
    }

    @Test("a hidden label stays off the screen")
    func copyWithoutLabel() throws {
      let screen = OffscreenWindow(CopyButton(text: "payload", label: "Copy it").frame(width: 200))
      defer { screen.close() }
      #expect(try !screen.shows("Copy it"))
    }
  }

  @Suite("Relative dates and turn status")
  struct DesignSystemLogicMoreTests {
    @Test("lines are counted from their breaks")
    func lineCount() {
      #expect(Theme.lineCount("") == 1)
      #expect(Theme.lineCount("one") == 1)
      #expect(Theme.lineCount("one\ntwo\n") == 3)
    }

    private func date(_ days: Int, from now: Date) throws -> Date {
      try #require(Calendar.current.date(byAdding: .day, value: days, to: now))
    }

    private func formatted(_ date: Date, template: String) -> String {
      let formatter = DateFormatter()
      formatter.setLocalizedDateFormatFromTemplate(template)
      return formatter.string(from: date)
    }

    @Test("today is a time, this week a weekday, and older a date")
    func pastDates() throws {
      let now = try #require(
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12)))
      let earlier = now.addingTimeInterval(-3_600)
      #expect(
        Theme.relativeDate(earlier, now: now)
          == earlier.formatted(date: .omitted, time: .shortened))
      let yesterday = try date(-1, from: now)
      #expect(Theme.relativeDate(yesterday, now: now) == formatted(yesterday, template: "EEE"))
      let lastMonth = try date(-30, from: now)
      #expect(Theme.relativeDate(lastMonth, now: now) == formatted(lastMonth, template: "MMMd"))
    }

    @Test("a date ahead of the clock is a date, not a weekday that reads as last week")
    func futureDates() throws {
      let now = try #require(
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12)))
      let later = try date(40, from: now)
      #expect(Theme.relativeDate(later, now: now) == formatted(later, template: "MMMd"))
      let tomorrow = try date(2, from: now)
      #expect(Theme.relativeDate(tomorrow, now: now) == formatted(tomorrow, template: "MMMd"))
    }

    @Test(
      "turn status reads from the header",
      arguments: [
        (TurnStatus.idle, 0, "Idle"), (.running, 0, "Running"),
        (.needsResponse, 0, "Needs you"), (.idle, 2, "Needs you"),
      ])
    func turnStatus(status: TurnStatus, pending: Int, label: String) {
      let header = SessionHeader(
        id: "s", title: "T", status: status, permissionLevel: 0, settings: PreviewData.settings)
      #expect(StatusPresentation.turn(header, pending: pending).label == label)
    }
  }
#endif
