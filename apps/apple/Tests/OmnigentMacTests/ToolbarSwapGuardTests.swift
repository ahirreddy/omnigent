import AppKit
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// A constraint pass nested in a toolbar swap reruns SwiftUI's swap, which unobserves the old
/// toolbar twice and quits the app; the guard holds such passes until the swap returns.
@MainActor
struct ToolbarSwapGuardTests {
  private final class CountingView: NSView {
    var updates = 0

    override func updateConstraints() {
      updates += 1
      super.updateConstraints()
    }
  }

  private func makeWindow() -> (NSWindow, CountingView) {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = CountingView()
    window.contentView = view
    view.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    window.updateConstraintsIfNeeded()
    view.updates = 0
    return (window, view)
  }

  /// Lets the main run loop turn until `done` or a second passes.
  private func runMainLoop(until done: () -> Bool) async throws {
    for _ in 0..<100 where !done() {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test func aConstraintPassDuringASwapRunsAfterIt() async throws {
    #expect(ToolbarSwapGuard.install())
    let (window, view) = makeWindow()
    view.needsUpdateConstraints = true
    window.updateConstraintsIfNeeded()
    #expect(view.updates == 1, "outside a swap the pass runs at once")

    view.needsUpdateConstraints = true
    ToolbarSwapGuard.swap(window) {
      window.updateConstraintsIfNeeded()
      #expect(view.updates == 1, "the pass ran inside the swap")
    }
    try await runMainLoop { view.updates == 2 }

    #expect(view.updates == 2, "the held pass never ran")
  }

  @Test func settingTheToolbarStillSetsIt() {
    #expect(ToolbarSwapGuard.install())
    let (window, _) = makeWindow()
    let toolbar = NSToolbar(identifier: "swap-guard-test")

    window.toolbar = toolbar
    #expect(window.toolbar === toolbar)
    #expect(!ToolbarSwapGuard.isSwapping(window))

    window.toolbar = nil
    #expect(window.toolbar == nil)
  }
}

/// What the app sets on every window before the first opens.
@MainActor
struct WindowLaunchSettingsTests {
  /// Native window tabs would join a full-screen window's new windows to it and then hand them
  /// between spaces, which AppKit throws on; the app's windows have their own tab strip.
  @Test func nativeWindowTabbingIsOff() {
    #expect(!NSWindow.allowsAutomaticWindowTabbing)
  }

  /// The test host launches through the same delegate, so the guard is already in place.
  @Test func theToolbarSwapGuardIsInstalledAtLaunch() {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
      backing: .buffered, defer: true)
    var swapped = false
    ToolbarSwapGuard.swap(window) { swapped = ToolbarSwapGuard.isSwapping(window) }
    #expect(swapped)
    #expect(ToolbarSwapGuard.install(), "a second install reports the first")
  }
}

/// A narrow toolbar's overflow menu can title an item from a SwiftUI item with no label; a nil
/// title throws, and the throw quits the app.
@MainActor
struct MenuTitleGuardTests {
  @Test func aNilTitleBecomesEmpty() {
    #expect(MenuTitleGuard.install())
    let item = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")

    _ = unsafe item.perform(#selector(setter: NSMenuItem.title), with: nil)

    #expect(item.title.isEmpty)
  }

  @Test func otherTitlesAreUnchanged() {
    #expect(MenuTitleGuard.install())
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    item.title = "Right panel"

    #expect(item.title == "Right panel")
  }
}

/// Pasting many lines into a single-line field joins them, so clicks on the text stay fast.
@MainActor
struct SingleLinePasteGuardTests {
  /// A pasteboard of its own, so the test leaves the user's clipboard alone.
  private static func pasteboard(_ text: String) -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("SingleLinePasteGuardTests"))
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return pasteboard
  }

  /// `field`'s field editor in a window that is never ordered front.
  private static func editor(for field: NSTextField) throws -> NSTextView {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 300, height: 100), styleMask: .borderless,
      backing: .buffered, defer: true)
    field.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
    window.contentView?.addSubview(field)
    #expect(window.makeFirstResponder(field))
    return try #require(field.currentEditor() as? NSTextView)
  }

  @Test func pastedLinesAreJoined() throws {
    #expect(SingleLinePasteGuard.install())
    for field in [NSSearchField(), NSTextField(string: "")] {
      let editor = try Self.editor(for: field)
      editor.insertText("find ", replacementRange: editor.selectedRange())

      let pasteboard = Self.pasteboard("\nfirst\r\nsecond\n\nthird\n")
      #expect(editor.readSelection(from: pasteboard, type: .string))

      #expect(editor.string == "find first second third", "\(type(of: field))")
    }
  }

  /// One long line of mixed-direction text past about 9,000 characters crashes CoreText.
  @Test func aLongPasteIsCutToFit() throws {
    #expect(SingleLinePasteGuard.install())
    let editor = try Self.editor(for: NSTextField(string: ""))
    editor.insertText("find ", replacementRange: editor.selectedRange())
    let line = String(repeating: "مرحبا hello 🙂 ", count: 1200)

    #expect(editor.readSelection(from: Self.pasteboard(line), type: .string))

    let length = editor.string.utf16.count
    #expect(length <= SingleLinePasteGuard.maximumLength)
    #expect(length > SingleLinePasteGuard.maximumLength - 20)
    #expect(editor.string.hasPrefix("find مرحبا hello"))
  }

  @Test func aCutKeepsWholeCharacters() {
    #expect(SingleLinePasteGuard.pasted("ab👍🏽c", room: 5) == "ab")
    #expect(SingleLinePasteGuard.pasted("ab👍🏽c", room: 6) == "ab👍🏽")
    #expect(SingleLinePasteGuard.pasted("a\nb", room: 0).isEmpty)
  }

  @Test func aWrappingFieldKeepsItsLines() throws {
    #expect(SingleLinePasteGuard.install())
    let field = NSTextField(wrappingLabelWithString: "")
    field.isEditable = true
    let editor = try Self.editor(for: field)

    #expect(editor.readSelection(from: Self.pasteboard("first\nsecond"), type: .string))

    #expect(editor.string == "first\nsecond")
  }

  @Test func aTextViewKeepsItsLines() {
    #expect(SingleLinePasteGuard.install())
    let view = NSTextView()

    #expect(view.readSelection(from: Self.pasteboard("first\nsecond"), type: .string))

    #expect(view.string == "first\nsecond")
  }
}
