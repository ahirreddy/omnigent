#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Records what the tab strip and its menus ask the window to do.
  @MainActor
  final class TabSpy {
    var calls: [String] = []

    init() {
      SystemSideEffects.reset()
    }

    /// Every action set, so each menu shows all its items.
    var actions: TabActions {
      var actions = basicActions
      actions.reopenClosed = { [self] in calls.append("reopen") }
      actions.moveToNewWindow = { [self] in calls.append("new window \($0)") }
      actions.showInPane = { [self] in calls.append("show \($0) \($1.rawValue)") }
      actions.focusPane = { [self] in calls.append("focus \($0.rawValue)") }
      actions.setSplitFraction = { [self] in calls.append("fraction \($0)") }
      actions.closeSplit = { [self] in calls.append("close split") }
      actions.renameSession = { [self] in calls.append("rename \($0)") }
      return actions
    }

    /// Every New Tab launcher, as the page and the + menu offer them.
    var newTabActions: NewTabPageActions {
      NewTabPageActions(
        newSideChat: { [self] in calls.append("side chat") },
        newTerminal: { [self] in calls.append("terminal \($0 ?? "-")") },
        openBrowser: { [self] in calls.append("browser") },
        openRemoteBrowser: { [self] in calls.append("remote \($0)") })
    }

    /// Only the actions every window has.
    var basicActions: TabActions {
      TabActions(
        select: { [self] in calls.append("select \($0)") },
        close: { [self] in calls.append("close \($0)") },
        newTab: { [self] in calls.append("new tab") },
        move: { [self] in calls.append("move \($0) \($1)") },
        setPinned: { [self] in calls.append("pin \($0) \($1)") },
        duplicate: { [self] in calls.append("duplicate \($0)") },
        closeOthers: { [self] in calls.append("close others \($0)") },
        closeToRight: { [self] in calls.append("close right \($0)") })
    }
  }

  enum TabFixture {
    /// Preferences of their own, so a remembered terminal stays in one test.
    static func scratchDefaults() throws -> UserDefaults {
      try #require(UserDefaults(suiteName: "tabs-\(UUID().uuidString)"))
    }

    static func tab(
      _ id: String, _ kind: TabKind = .chat, status: TabStatus = .none, isPinned: Bool = false,
      isClosable: Bool = true, pane: TabPane? = nil
    ) -> TabItemState {
      var tab = TabItemState(
        id: id, kind: kind, title: id.capitalized, status: status, isPinned: isPinned)
      tab.isClosable = isClosable
      tab.pane = pane
      return tab
    }

    /// Two tabs side by side: "one" (selected) and "two".
    static var pair: TabsState {
      TabsState(tabs: [tab("one"), tab("two")], selectedID: "one")
    }
  }

  extension RenderSupport {
    /// The view's pixels, for telling two states apart.
    static func picture(_ view: some View, width: CGFloat, height: CGFloat) throws -> Data {
      let rendered = try render(
        view, width: width, height: height, scheme: .light, layout: .regular)
      return try #require(rendered.image.tiffRepresentation)
    }
  }

  extension OffscreenWindow {
    /// The middle of the tab at this distance along an unpinned strip with equal tabs.
    func tabCenter(index: Int, width: CGFloat, leading: CGFloat = 4) -> CGPoint {
      CGPoint(x: leading + width * (CGFloat(index) + 0.5), y: host.bounds.midY)
    }
  }
#endif
