#if os(macOS)
  import AppKit
  import os

  /// Ways for a test to answer an alert or a menu as a person does, instead of with the default.
  extension SystemSideEffects {
    /// Makes an alert sheet open for real on its window, until the next `reset()`, instead of
    /// answering at once. No window is ever seen or takes a real click, so a test presses the
    /// sheet's buttons with `OffscreenWindow`, whose calls act on a sheet while one is up.
    public static func showAlertSheets() {
      state.withLock { $0.showsAlertSheets = true }
    }

    /// Makes a menu that product code pops up choose its item of this title, until the next
    /// `reset()`. The menu still never opens; a menu with no such item closes with no choice.
    /// - Parameter title: The item's title, at any depth of the menu.
    public static func chooseFromMenus(_ title: String) {
      state.withLock { $0.menuChoice = title }
    }

    /// Runs the item of this title, as choosing it from the open menu does.
    /// - Returns: Whether the menu has such an item.
    static func choose(_ title: String, in menu: NSMenu) -> Bool {
      // AppKit pops a menu up on the main thread, which is where this is called from.
      nonisolated(unsafe) let opened = menu
      return MainActor.assumeIsolated {
        var pending = [unsafe opened]
        while let next = pending.popLast() {
          if let index = next.items.firstIndex(where: { $0.title == title }) {
            next.performActionForItem(at: index)
            return true
          }
          pending.append(contentsOf: next.items.compactMap(\.submenu))
        }
        return false
      }
    }
  }
#endif
