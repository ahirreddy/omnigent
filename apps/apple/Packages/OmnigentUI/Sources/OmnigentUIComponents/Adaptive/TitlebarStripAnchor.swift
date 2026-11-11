#if os(macOS)
  import AppKit
  import SwiftUI

  /// Sits in the strip and resizes its toolbar item with the window. The toolbar fits its items
  /// before the detail column is measured, so a strip still at its old width would fold a
  /// trailing item or show a folded one for that pass.
  final class TitlebarStripAnchorView: NSView {
    var space: TitlebarStripSpace?
    var isSidebarHidden = false
    private var contentWidth: CGFloat?
    private var itemWidth: NSLayoutConstraint?

    /// Above the 999.9 of SwiftUI's own width limits on the item, which hold the old width until
    /// its next update. Below required, so the toolbar can still squeeze the item in a window
    /// too narrow for it.
    static let itemWidthPriority = NSLayoutConstraint.Priority(999.95)

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let center = NotificationCenter.default
      center.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
      guard let content = unsafe window?.contentView else { return }
      contentWidth = content.frame.width
      center.addObserver(
        self, selector: #selector(contentResized(_:)), name: NSView.frameDidChangeNotification,
        object: content)
      sizeItem()
    }

    @objc private func contentResized(_ notification: Notification) {
      guard let content = notification.object as? NSView else { return }
      let width = content.frame.width
      defer { contentWidth = width }
      guard let space, let before = contentWidth, before != width else { return }
      // The window's columns other than the detail keep their widths through a resize.
      space.detailWidth += width - before
      sizeItem()
    }

    /// Gives the strip's toolbar item the strip's width now, ahead of SwiftUI's next update.
    func sizeItem() {
      guard let space else { return }
      let width = TitlebarMetrics.stripWidth(
        detailWidth: space.detailWidth, isSidebarHidden: isSidebarHidden,
        trailingItems: space.trailingItems)
      if let itemWidth, itemWidth.isActive {
        if itemWidth.constant != width { itemWidth.constant = width }
        return
      }
      let item = unsafe window?.toolbar?.items.compactMap(\.view).first { isDescendant(of: $0) }
      guard let item else { return }
      let constraint = item.widthAnchor.constraint(equalToConstant: width)
      constraint.priority = Self.itemWidthPriority
      constraint.isActive = true
      itemWidth = constraint
    }
  }

  struct TitlebarStripAnchor: NSViewRepresentable {
    let space: TitlebarStripSpace
    let isSidebarHidden: Bool
    /// The strip's width, so a change to it updates the item.
    let width: CGFloat

    func makeNSView(context: Context) -> TitlebarStripAnchorView {
      let view = TitlebarStripAnchorView()
      updateNSView(view, context: context)
      return view
    }

    func updateNSView(_ view: TitlebarStripAnchorView, context: Context) {
      view.space = space
      view.isSidebarHidden = isSidebarHidden
      view.sizeItem()
    }
  }
#endif
