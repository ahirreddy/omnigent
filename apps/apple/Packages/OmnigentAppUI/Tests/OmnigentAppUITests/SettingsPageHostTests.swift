#if os(macOS)
  import AppKit
  import OmnigentUIComponents
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAppUI

  /// A window's content, shaped as the app's: a sidebar's list beside a detail, with state only
  /// its views hold (the page it shows and a draft).
  private struct WindowContent: View {
    @State private var page = "first"
    @State private var draft = ""

    var body: some View {
      NavigationSplitView {
        // Where the Settings page's own sidebar goes, so a click there has two lists to reach.
        List(0..<12, id: \.self) { Text(verbatim: "Session \($0)") }
      } detail: {
        VStack {
          Text(verbatim: "Showing \(page)")
          Button("Next page") { page = "second" }
          TextField("Draft", text: $draft)
          EntryPoints()
        }
        .padding()
      }
    }
  }

  /// The ways a window's content opens Settings, as buttons.
  private struct EntryPoints: View {
    @Environment(\.openSettingsAt) private var openSettingsAt
    @Environment(\.openSettingsPage) private var openSettingsPage
    @Environment(\.openAppearanceSettings) private var openAppearance

    var body: some View {
      Button("Gear") { openSettingsPage?() }
      Button("Appearance") { openAppearance?() }
      Button("Terminal link") { openSettingsAt?(.tab(SettingsNavigator.terminalTab)) }
      Button("Server settings") {
        openSettingsAt?(.server(url: "https://a.test", pane: .importSessions))
      }
    }
  }

  /// What a window shows, for ``SwiftUICore/View/leavesSettings(_:onChangeOf:)``.
  @MainActor
  @Observable
  private final class Place {
    var value = "inbox"
    var binding: Binding<String> { Binding(get: { self.value }, set: { self.value = $0 }) }
  }

  @Suite("A window's Settings page", .serialized, .timeLimit(.minutes(1)))
  @MainActor
  struct SettingsPageHostTests {
    private let navigator = SettingsNavigator()

    private var categories: [SettingsPageCategory] {
      [
        SettingsPageCategory(
          SettingsNavigator.generalTab, systemImage: "gearshape",
          content: AnyView(Text(verbatim: "General pane"))),
        SettingsPageCategory(
          SettingsNavigator.appearanceTab, systemImage: "paintpalette",
          content: AnyView(Text(verbatim: "Appearance pane"))),
        SettingsPageCategory(
          SettingsNavigator.terminalTab, systemImage: "apple.terminal",
          content: AnyView(Text(verbatim: "Terminal pane"))),
        SettingsPageCategory(
          SettingsNavigator.serversTab, systemImage: "network", isWide: true,
          content: AnyView(Text(verbatim: "Servers pane"))),
      ]
    }

    /// The content's controls, top to bottom.
    enum Control: Int, Sendable {
      case nextPage, draft, gear, appearance, terminal, server
    }

    /// A window with the content under a real Settings page, and where the content's controls are.
    @MainActor
    private struct Window {
      let screen: OffscreenWindow<AnyView>
      let controls: [CGRect]

      /// Clicks one of the content's controls where it was laid out.
      func click(_ control: Control) throws {
        let frame = controls[control.rawValue]
        try screen.click(CGPoint(x: frame.midX, y: frame.midY))
      }

      /// Clicks a category's row in the page's sidebar: the list over the content's own.
      func clickCategory(_ row: Int) throws {
        let list = try #require(screen.allViews.compactMap { $0 as? NSTableView }.last)
        let frame = list.convert(list.rect(ofRow: row), to: screen.host)
        try screen.click(CGPoint(x: frame.midX, y: frame.midY))
      }

      /// Clicks Back: the first of the controls the page adds, above its rows.
      func clickBack() throws {
        let back = try #require(screen.controlFrames.first { !controls.contains($0) })
        try screen.click(CGPoint(x: back.midX, y: back.midY))
      }

      var field: NSTextField? { screen.allViews.lazy.compactMap { $0 as? NSTextField }.first }
    }

    /// The content under a real Settings page over the test's categories.
    private func window() throws -> Window {
      SystemSideEffects.reset()
      let navigator = navigator
      let categories = categories
      let screen = OffscreenWindow(
        AnyView(
          WindowContent().settingsPage(navigator) {
            SettingsPage(
              categories: categories, selection: Bindable(navigator).tab,
              back: { navigator.close() })
          }),
        width: 900, height: 600)
      let controls = screen.controlFrames
      try #require(controls.count == 6, "\(controls)")
      return Window(screen: screen, controls: controls)
    }

    @Test("Settings takes the whole window: the content is neither drawn nor clicked")
    func coversTheContent() throws {
      let window = try window()
      let screen = window.screen
      defer { screen.close() }
      let field = try #require(window.field)
      #expect(screen.drawnViews.contains(field))
      #expect(try !screen.shows("General pane"))

      navigator.open()
      screen.settle()
      #expect(try screen.shows("General pane"))
      #expect(!screen.drawnViews.contains(field), "the content is hidden under the page")
      try window.click(.nextPage)

      navigator.close()
      screen.settle()
      #expect(try screen.shows("Showing first"), "the click under the page reached nothing")
      #expect(screen.drawnViews.contains(field))
      #expect(try !screen.shows("General pane"))
      try window.click(.nextPage)
      #expect(try screen.shows("Showing second"), "the content takes clicks again")
    }

    @Test(
      "Back and Escape return to the content as it was: its page and its draft",
      arguments: ["Back", "Escape"])
    func returnsToTheContent(leaving: String) throws {
      let window = try window()
      let screen = window.screen
      defer { screen.close() }
      try window.click(.nextPage)
      let field = try #require(window.field)
      try screen.click(field)
      try screen.type("half a thought")
      #expect(try screen.shows("Showing second"))

      try window.click(.gear)
      #expect(navigator.isPresented)
      try window.clickCategory(2)
      #expect(navigator.tab == SettingsNavigator.terminalTab)
      #expect(try screen.shows("Terminal pane"))
      if leaving == "Back" {
        try window.clickBack()
      } else {
        #expect(try pressShortcut(screen, keyCode: 53, characters: "\u{1B}", modifiers: []))
      }
      #expect(!navigator.isPresented)
      #expect(try screen.shows("Showing second"))
      #expect(field.stringValue == "half a thought")
      #expect(screen.drawnViews.contains(field))
      #expect(navigator.tab == SettingsNavigator.terminalTab, "Settings reopens where it was")
    }

    @Test(
      "each way in lands on its category",
      arguments: [
        (Control.gear, "General pane"), (.appearance, "Appearance pane"),
        (.terminal, "Terminal pane"), (.server, "Servers pane"),
      ])
    func entryPoints(entry: Control, pane: String) throws {
      let window = try window()
      let screen = window.screen
      defer { screen.close() }
      try window.click(entry)
      #expect(navigator.isPresented)
      #expect(try screen.shows(pane))
      for other in ["General pane", "Appearance pane", "Terminal pane", "Servers pane"]
      where other != pane {
        #expect(try !screen.shows(other), "\(other) with \(pane)")
      }
    }

    @Test("a link to a server's pane leaves the request for the Servers category")
    func serverPane() throws {
      let window = try window()
      defer { window.screen.close() }
      try window.click(.server)
      #expect(navigator.tab == SettingsNavigator.serversTab)
      let request = try #require(navigator.takeServerRequest())
      #expect(request.url == "https://a.test" && request.pane == .importSessions)
    }

    @Test("the gear opens Settings where it was left, not back on General")
    func reopensWhereItWas() throws {
      let window = try window()
      defer { window.screen.close() }
      try window.click(.terminal)
      try window.clickBack()
      #expect(!navigator.isPresented)
      try window.click(.gear)
      #expect(try window.screen.shows("Terminal pane"))
    }

    @Test("going somewhere else in the window leaves Settings")
    func leavesOnNavigation() throws {
      SystemSideEffects.reset()
      let navigator = navigator
      let place = Place()
      let screen = OffscreenWindow(
        Text(verbatim: "Content")
          .settingsPage(navigator) { Text(verbatim: "Settings page") }
          .leavesSettings(navigator, onChangeOf: place.binding),
        width: 400, height: 300)
      defer { screen.close() }
      navigator.open(.tab(SettingsNavigator.appearanceTab))
      screen.settle()
      #expect(try screen.shows("Settings page"))
      place.value = "session"
      screen.settle()
      #expect(!navigator.isPresented)
      #expect(try !screen.shows("Settings page"))
    }
  }

  @Suite("Settings navigation: the Mac's page")
  @MainActor
  struct SettingsPagePresentationTests {
    @Test("opening shows the page at a destination, or where it was; closing goes back")
    func openAndClose() {
      let navigator = SettingsNavigator()
      #expect(!navigator.isPresented)
      navigator.open()
      #expect(navigator.isPresented && navigator.tab == SettingsNavigator.generalTab)
      navigator.open(.tab(SettingsNavigator.appearanceTab))
      #expect(navigator.isPresented && navigator.tab == SettingsNavigator.appearanceTab)
      navigator.close()
      #expect(!navigator.isPresented && navigator.tab == SettingsNavigator.appearanceTab)
      navigator.close()
      #expect(!navigator.isPresented)
    }

    @Test("the window's action shows the page at a tab or a server's pane")
    func action() {
      let navigator = SettingsNavigator()
      let open = OpenSettingsDestinationAction.settingsPage(navigator)
      open(.tab(SettingsNavigator.appearanceTab))
      #expect(navigator.isPresented && navigator.tab == SettingsNavigator.appearanceTab)
      navigator.close()
      open(.server(url: "https://a.test", pane: nil))
      #expect(navigator.isPresented && navigator.tab == SettingsNavigator.serversTab)
      #expect(navigator.takeServerRequest()?.url == "https://a.test")
      #expect(navigator.takeServerRequest() == nil)
    }
  }
#endif
