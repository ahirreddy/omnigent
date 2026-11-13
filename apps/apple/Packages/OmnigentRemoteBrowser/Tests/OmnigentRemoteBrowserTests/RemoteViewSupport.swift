#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentRemoteBrowser

  /// A window that is never ordered in, far from the pointer, so a view in it can't change the
  /// cursor on the user's screen.
  @MainActor
  func neverShownWindow(size: CGSize) -> NSWindow {
    SystemSideEffects.install()
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: -60_000, y: -60_000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  /// A SwiftUI view in a never-shown window, drawn and pressed without any pointer.
  @MainActor
  final class OffscreenPage<Content: View> {
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init(width: CGFloat = 900, height: CGFloat = 600, @ViewBuilder content: () -> Content) {
      let size = CGSize(width: width, height: height)
      window = neverShownWindow(size: size)
      host = NSHostingView(rootView: AnyView(content().frame(width: width, height: height)))
      window.contentView = host
      host.frame = CGRect(origin: .zero, size: size)
    }

    /// Applies pending updates: a hidden window has no display cycle, so drawing does it.
    @discardableResult
    func draw() async -> Int {
      var pixels = 0
      for _ in 0..<3 {
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.cacheDisplay(in: host.bounds, to: bitmap)
          pixels = bitmap.pixelsWide * bitmap.pixelsHigh
        }
        await letTasksRun()
      }
      return pixels
    }

    /// The buttons AppKit draws, in order: the borderless style's, and never a popup button,
    /// whose click would open its menu.
    var buttons: [NSButton] {
      descendants(of: host, as: NSButton.self).filter { !($0 is NSPopUpButton) }
    }

    /// The text fields on the page, in order.
    var textFields: [NSTextField] {
      descendants(of: host, as: NSTextField.self).filter { $0.isEditable }
    }

    /// The titles of the page's popup menus; they are never opened.
    var popupTitles: [String] {
      descendants(of: host, as: NSPopUpButton.self).map(\.title)
    }

    private func descendants<Found: NSView>(of view: NSView, as type: Found.Type) -> [Found] {
      view.subviews.flatMap { subview in
        (subview as? Found).map { [$0] }.map { $0 + descendants(of: subview, as: type) }
          ?? descendants(of: subview, as: type)
      }
    }

    func close() {
      window.contentView = nil
    }
  }
#endif
