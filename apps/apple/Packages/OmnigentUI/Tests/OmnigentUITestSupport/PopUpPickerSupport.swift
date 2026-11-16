#if os(macOS)
  import AppKit
  import OmnigentViewTesting

  extension OffscreenWindow {
    /// The menu-style pickers and menus, in view order.
    var pickers: [NSPopUpButton] { allViews.compactMap { $0 as? NSPopUpButton } }

    /// Picks an item in the picker.
    func pick(_ title: String, in picker: NSView) throws {
      try choose(title, in: try openMenu(picker))
    }
  }
#endif
