import AppKit
import Testing

@testable import OmnigentDesktop

@MainActor
private final class MenuTarget: NSObject {
  var chosen: [String] = []

  @objc func choose(_ sender: NSMenuItem) {
    chosen.append(sender.title)
  }
}

@Suite("New Window menu item")
@MainActor
struct NewWindowMenuItemTests {
  private func item(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags)
    -> NSMenuItem
  {
    let item = NSMenuItem(
      title: title, action: #selector(MenuTarget.choose(_:)), keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
  }

  @Test("matches Shift-Command-N in either spelling, not Command-N")
  func matching() {
    #expect(NewWindowMenuItem.isNewWindow(item("New Window", "n", [.command, .shift])))
    #expect(NewWindowMenuItem.isNewWindow(item("New Window", "N", .command)))
    #expect(!NewWindowMenuItem.isNewWindow(item("New Session", "n", .command)))
    #expect(!NewWindowMenuItem.isNewWindow(item("Find", "f", [.command, .shift])))
  }

  @Test("chooses the item in a submenu")
  func performsInSubmenu() {
    // Menu actions are sent through the shared application.
    _ = NSApplication.shared
    let target = MenuTarget()
    let file = NSMenu(title: "File")
    for entry in [item("New Session", "n", .command), item("New Window", "n", [.command, .shift])] {
      entry.target = target
      file.addItem(entry)
    }
    let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileItem.submenu = file
    let main = NSMenu(title: "Main")
    main.addItem(fileItem)

    #expect(NewWindowMenuItem.perform(in: main))
    #expect(target.chosen == ["New Window"])
    #expect(!NewWindowMenuItem.perform(in: NSMenu(title: "Empty")))
  }
}
