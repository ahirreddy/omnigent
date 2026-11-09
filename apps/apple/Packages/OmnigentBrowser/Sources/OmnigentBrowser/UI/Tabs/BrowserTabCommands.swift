#if os(macOS)
  public import SwiftUI

  /// Menu commands for the focused browser tab, for apps that put browser actions in the menu
  /// bar. Add to a scene's `.commands`; `BrowserTabContentView` publishes the focused tab. Every
  /// item is disabled while no browser tab is focused, so the app's own shortcuts win elsewhere.
  public struct BrowserTabCommands: Commands {
    @FocusedValue(\.browserTab) private var tab
    @FocusedValue(\.browserTabSheet) private var sheet
    private let includesFindAndZoom: Bool

    /// Creates the commands.
    /// - Parameter includesFindAndZoom: Include Find and Zoom; pass `false` when the app's Edit
    ///   and View menus already route Command-F, Command-G and Command-0/+/- to the page.
    public init(includesFindAndZoom: Bool = true) {
      self.includesFindAndZoom = includesFindAndZoom
    }

    /// The menus.
    public var body: some Commands {
      CommandMenu("Browser") {
        BrowserTabCommandItems(
          tab: tab, sheet: sheet, includesFindAndZoom: includesFindAndZoom)
      }
    }
  }

  /// The Browser menu's items, disabled while no browser tab is focused.
  struct BrowserTabCommandItems: View {
    let tab: BrowserTabModel?
    let sheet: Binding<BrowserTabSheet?>?
    let includesFindAndZoom: Bool

    var body: some View {
      Group { items }.disabled(tab == nil)
    }

    @ViewBuilder private var items: some View {
      Button("Open Location") { tab?.focusOmnibox() }
        .keyboardShortcut("l")
      Button("Reload Page") { tab?.reload() }
        .keyboardShortcut("r")
      Button("Reload Ignoring Cache") { tab?.reloadIgnoringCache() }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      if includesFindAndZoom {
        Divider()
        Button("Find…") { tab?.showFindBar() }
          .keyboardShortcut("f")
        Button("Find Next") { Task { await tab?.findNext(forward: true) } }
          .keyboardShortcut("g")
        Button("Find Previous") { Task { await tab?.findNext(forward: false) } }
          .keyboardShortcut("g", modifiers: [.command, .shift])
        Divider()
        Button("Zoom In") { tab?.zoomIn() }
          .keyboardShortcut("+")
        Button("Zoom Out") { tab?.zoomOut() }
          .keyboardShortcut("-")
        Button("Actual Size") { tab?.resetZoom() }
          .keyboardShortcut("0")
      }
      Divider()
      Button(tab?.isMuted == true ? "Unmute Tab" : "Mute Tab") { tab?.toggleMute() }
      Button("Bookmark This Page") { tab?.toggleBookmark() }
        .keyboardShortcut("d")
      Button("Show History") { sheet?.wrappedValue = .history }
        .keyboardShortcut("y")
      Button("Show Bookmarks") { sheet?.wrappedValue = .bookmarks }
      Button("Clear Browsing Data…") { sheet?.wrappedValue = .clearData }
      Divider()
      Button("Print…") { tab?.printPage() }
        .keyboardShortcut("p")
      Button("View Source") { tab?.viewSource() }
        .keyboardShortcut("u", modifiers: [.command, .option])
      Button("Developer Tools") { tab?.showDevTools() }
        .keyboardShortcut("i", modifiers: [.command, .option])
    }
  }
#endif
