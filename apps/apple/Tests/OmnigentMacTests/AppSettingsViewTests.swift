import AppKit
import OmnigentAppUI
import OmnigentViewTesting
import SwiftUI
import Testing

#if OMNIGENT_CHROMIUM
  import OmnigentDesktopUpdate
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

#if DEBUG
  /// The Settings window's content, with this edition's tabs, offscreen and never clicked.
  @MainActor
  @Suite(.enabled(if: HostedOffscreen.isAllowed), .serialized)
  struct AppSettingsViewTests {
    private func settings(_ scratch: TestScratch) -> some View {
      #if OMNIGENT_CHROMIUM
        AppSettingsView(services: scratch.services, updater: SparkleUpdater { _ in })
      #else
        AppSettingsView(services: scratch.services)
      #endif
    }

    /// The accessibility names on a tab, once SwiftUI has built it.
    private func names(onTab tab: String, _ scratch: TestScratch) async throws -> [String] {
      let navigator = SettingsNavigator.shared
      let existing = navigator.tab
      defer { navigator.tab = existing }
      navigator.tab = tab
      let screen = OffscreenWindow(settings(scratch), width: 800, height: 700)
      defer { screen.close() }
      try await Task.sleep(for: .milliseconds(300))
      ChaosTargets.buildAccessibilityTree()
      return ChaosTargets.controls(in: screen.window).map(\.name)
    }

    /// A link opens Settings at a tab, and the tab shows its own controls.
    @Test(arguments: [
      ("General", "#settings.submit-with-command-return"),
      ("Appearance", "#settings.terminal-theme"),
      ("Terminal", "#settings.terminal-font-family"),
      ("Notifications", "#settings.notifications.play-sound"),
      ("Servers", "#server-settings-picker"), ("Phone", "#pairing.no-servers"),
    ])
    func aTabShowsItsOwnControls(tab: String, control: String) async throws {
      let scratch = try TestScratch()
      defer { scratch.remove() }
      let found = try await names(onTab: tab, scratch)
      #expect(found.contains { $0.contains(control) }, "\(found)")
      for other in ["General", "Appearance", "Terminal", "Notifications", "Phone", "Servers"] {
        #expect(found.contains { $0.hasPrefix("AXRadioButton") && $0.hasSuffix(other) }, "\(found)")
      }
    }

    /// The desktop's own tabs stay beside the app's: only this Mac's server has a tab of its own.
    @Test func theLocalServerAndAdvancedTabsStay() async throws {
      let scratch = try TestScratch()
      defer { scratch.remove() }
      let found = try await names(onTab: "General", scratch)
      #expect(found.contains { $0.hasSuffix("Local Server") })
      #expect(found.contains { $0.hasSuffix("Advanced") })
    }
  }
#endif

/// Settings opened at a tab keeps its toolbar's highlight on that tab.
@MainActor
@Suite(.enabled(if: HostedOffscreen.isAllowed), .serialized)
struct SettingsToolbarHighlightTests {
  private final class TabsDelegate: NSObject, NSToolbarDelegate {
    let labels: [String]
    init(labels: [String]) { self.labels = labels }

    private var identifiers: [NSToolbarItem.Identifier] {
      labels.map { NSToolbarItem.Identifier($0) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
      identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
      identifiers
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
      identifiers
    }

    func toolbar(
      _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
      willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = identifier.rawValue
      return item
    }
  }

  /// A toolbar with its items added directly: only a window with a title bar loads them.
  private func toolbar(labels: [String]) -> (NSToolbar, TabsDelegate) {
    let delegate = TabsDelegate(labels: labels)
    let toolbar = NSToolbar(identifier: "settings.highlight.\(UUID().uuidString)")
    toolbar.delegate = delegate
    for (index, label) in labels.enumerated() {
      toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(label), at: index)
    }
    return (toolbar, delegate)
  }

  @Test func theShownTabIsHighlighted() {
    let (toolbar, delegate) = toolbar(labels: ["General", "Servers"])
    #expect(delegate.labels.count == toolbar.items.count)

    SettingsToolbarHighlight.select("Servers", in: toolbar)
    #expect(toolbar.selectedItemIdentifier?.rawValue == "Servers")
    SettingsToolbarHighlight.select("No such tab", in: toolbar)
    #expect(toolbar.selectedItemIdentifier?.rawValue == "Servers")
  }

  /// Another window's toolbar isn't Settings': it has no General item.
  @Test func otherToolbarsAreLeftAlone() {
    let (toolbar, _) = toolbar(labels: ["Servers", "Other"])
    SettingsToolbarHighlight.select("Servers", in: toolbar)
    #expect(toolbar.selectedItemIdentifier == nil)
  }

  /// The window walk reaches a visible window's toolbar and skips windows with none.
  @Test func selectingWalksTheVisibleWindows() {
    let screen = OffscreenWindow(Text("No toolbar"), width: 300, height: 200)
    defer { screen.close() }
    SettingsToolbarHighlight.select("Servers")
    #expect(screen.window.toolbar == nil)
  }
}
