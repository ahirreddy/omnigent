import SwiftUI

#if os(macOS)
  import AppKit
#endif

extension View {
  /// On Mac, lays the split view column holding this view beside the sidebar instead of under
  /// it. By default the detail column spans the window under the floating sidebar and only its
  /// safe area is inset, so content that fills its own frame (a split pane, a page, a terminal)
  /// drew under the sidebar. Elsewhere the view is unchanged.
  /// - Returns: The view.
  @ViewBuilder func detailBesideSidebar() -> some View {
    #if os(macOS)
      background { DetailBesideSidebar() }
    #else
      self
    #endif
  }
}

#if os(macOS)
  /// Finds the split view item that holds it and stops the item extending under the sidebar.
  private struct DetailBesideSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> ItemView { ItemView() }

    func updateNSView(_ view: ItemView, context: Context) { view.layOutBeside() }

    final class ItemView: NSView {
      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layOutBeside()
      }

      override func layout() {
        super.layout()
        layOutBeside()
      }

      func layOutBeside() {
        guard let item = DetailBesideSidebarItem.item(holding: self),
          item.automaticallyAdjustsSafeAreaInsets
        else { return }
        item.automaticallyAdjustsSafeAreaInsets = false
      }
    }
  }

  /// The split view item a view is in.
  enum DetailBesideSidebarItem {
    /// The item of the nearest enclosing split view controller whose view holds `view`.
    static func item(holding view: NSView) -> NSSplitViewItem? {
      // AppKit declares `superview` unowned(unsafe); the chain is only walked here, not kept.
      var ancestor = unsafe view.superview
      while let current = ancestor {
        if let split = current as? NSSplitView,
          let controller = split.delegate as? NSSplitViewController
        {
          return controller.splitViewItems.first { view.isDescendant(of: $0.viewController.view) }
        }
        ancestor = unsafe current.superview
      }
      return nil
    }
  }
#endif
