#if os(macOS)
  import AppKit
  import SwiftUI

  /// A titlebar tab's context menu. The toolbar answers a secondary click on its items with its
  /// own "Icon and Text" menu before SwiftUI's `contextMenu` sees the click, so the click is
  /// taken here first and the tab's menu is shown in its place.
  struct TitlebarTabMenu<Items: View>: NSViewRepresentable {
    @ViewBuilder let items: () -> Items
    @Environment(\.copyWithConfirmation) private var copy

    func makeNSView(context: Context) -> TitlebarMenuClickView {
      let view = TitlebarMenuClickView()
      view.makeMenu = makeMenu
      return view
    }

    func updateNSView(_ view: TitlebarMenuClickView, context: Context) {
      view.makeMenu = makeMenu
    }

    static func dismantleNSView(_ view: TitlebarMenuClickView, coordinator: ()) {
      view.stop()
    }

    /// The menu is built when it opens, so it shows the tab as it is then.
    private var makeMenu: @MainActor () -> NSMenu {
      let items = items
      let copy = copy
      return { NSHostingMenu(rootView: items().environment(\.copyWithConfirmation, copy)) }
    }
  }

  /// Shows a menu for a secondary click inside its visible frame. It takes no clicks itself.
  final class TitlebarMenuClickView: NSView {
    var makeMenu: (@MainActor () -> NSMenu)?
    /// Shows the menu at a point of this view. Replaced in tests, which have no menu tracking.
    var present: @MainActor (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
      menu.popUp(positioning: nil, at: point, in: view)
    }
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      // AppKit declares `window` unowned(unsafe); it is only compared here, never retained.
      guard unsafe window != nil else { return }
      let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
      monitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
        self?.takes(event) == true ? nil : event
      }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    /// Shows the menu when `event` is a secondary click on this view.
    /// - Returns: Whether the click was taken, so nothing else answers it.
    func takes(_ event: NSEvent) -> Bool {
      guard let window = unsafe window, event.window === window, let makeMenu,
        !isHiddenOrHasHiddenAncestor
      else { return false }
      let point = convert(event.locationInWindow, from: nil)
      guard
        Self.isMenuClick(
          isRightButton: event.type == .rightMouseDown, modifiers: event.modifierFlags,
          isInside: visibleRect.contains(point))
      else { return false }
      // After the monitor returns: the menu tracks the mouse in a loop of its own.
      Task { @MainActor [weak self] in
        guard let self else { return }
        present(makeMenu(), point, self)
      }
      return true
    }

    /// A right click, or a Control-click, inside the view.
    static func isMenuClick(
      isRightButton: Bool, modifiers: NSEvent.ModifierFlags, isInside: Bool
    ) -> Bool {
      isInside && (isRightButton || modifiers.contains(.control))
    }
  }
#endif
