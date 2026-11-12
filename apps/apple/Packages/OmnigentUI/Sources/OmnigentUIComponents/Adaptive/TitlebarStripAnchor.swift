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
    /// The strip's width at the last sizing, in or out of the toolbar.
    private var lastWidth: CGFloat?
    private var itemWidth: NSLayoutConstraint?

    /// Above the 999.9 of SwiftUI's own width limits on the item, which hold the old width until
    /// its next update. Below required, so the toolbar can still squeeze the item in a window
    /// too narrow for it.
    static let itemWidthPriority = NSLayoutConstraint.Priority(999.95)

    /// How long a strip the toolbar left out waits, after its width last changed, to be offered
    /// again.
    static var offerDelay: TimeInterval = 0.3

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let center = NotificationCenter.default
      center.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
      guard let content = unsafe window?.contentView else { return }
      cancelOffer()
      space?.offeredWidth = nil
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

    /// The toolbar folds away an item too wide for it and does not look at it again when it
    /// narrows: a strip sized while the window's columns were still settling at launch stayed
    /// out. One that narrowed while left out is offered again, as a new item, once it settles.
    private func scheduleOffer() {
      cancelOffer()
      perform(#selector(offerAgain), with: nil, afterDelay: Self.offerDelay, inModes: [.common])
    }

    func cancelOffer() {
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(offerAgain), object: nil)
    }

    /// One offer per width: a strip the window is too narrow for is not offered over and over.
    @objc private func offerAgain() {
      guard unsafe window == nil, let space, space.offeredWidth != stripWidth,
        isFoldedOnScreen(self)
      else { return }
      space.offeredWidth = stripWidth
      space.stripOffer += 1
    }

    /// Whether a toolbar on screen holds this strip's item and has folded it away. Replaced in
    /// tests, whose windows are never on screen.
    var isFoldedOnScreen: @MainActor (TitlebarStripAnchorView) -> Bool = { anchor in
      // coverage:off a toolbar folds its strip only in a window on screen; the relaunch flow
      for window in NSApp.windows where window.occlusionState.contains(.visible) {
        guard let toolbar = window.toolbar, toolbar.isVisible else { continue }
        let item = toolbar.items.first { item in
          item.view.map { anchor.isDescendant(of: $0) } ?? false
        }
        if let item { return !(toolbar.visibleItems ?? []).contains(item) }
      }
      // coverage:on
      return false
    }

    private var stripWidth: CGFloat? {
      space.map {
        TitlebarMetrics.stripWidth(
          detailWidth: $0.detailWidth, isSidebarHidden: isSidebarHidden,
          trailingItems: $0.trailingItems)
      }
    }

    /// Gives the strip's toolbar item the strip's width now, ahead of SwiftUI's next update.
    func sizeItem() {
      guard let width = stripWidth else { return }
      let narrowed = lastWidth.map { width < $0 } ?? false
      lastWidth = width
      guard unsafe window != nil else {
        if narrowed { scheduleOffer() }
        return
      }
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

    static func dismantleNSView(_ view: TitlebarStripAnchorView, coordinator: ()) {
      view.cancelOffer()
    }
  }
#endif
