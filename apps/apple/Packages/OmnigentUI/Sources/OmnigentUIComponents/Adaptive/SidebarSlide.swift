#if os(macOS)
  import AppKit
  import QuartzCore
  import SwiftUI

  /// How the Mac sidebar shows and hides (`omnigent:sidebar-slide`, read at launch).
  enum SidebarSlideMode: String {
    /// AppKit's animation: the detail column takes a new width, and lays out, every frame.
    case animated
    /// One layout at the final width, with no motion.
    case instant
    /// One layout at the final width; Core Animation moves the columns, and pictures of what
    /// they showed, through the slide, as the render server draws its frames.
    case prerendered

    static let launchValue = read(.standard)

    static func read(_ defaults: UserDefaults) -> Self {
      defaults.string(forKey: "omnigent:sidebar-slide").flatMap(Self.init(rawValue:))
        ?? .prerendered
    }
  }

  extension View {
    /// On Mac, shows and hides the sidebar of the split view holding this view as
    /// ``SidebarSlideMode`` says, and gives `columns` that split view's sidebar.
    /// - Parameter columns: The shell's sidebar visibility.
    /// - Returns: The view.
    func sidebarSlide(_ columns: ShellColumns) -> some View {
      background { SidebarSlideAnchor(mode: SidebarSlideMode.launchValue, columns: columns) }
    }

    /// Animates nothing under this view while a collapse lays the window out at its new widths
    /// (``SidebarSlide/holdsAnimations``): the slide moves the window, not SwiftUI.
    /// - Returns: The view.
    func sidebarSlideTransactions() -> some View {
      transaction { transaction in
        if SidebarSlide.holdsAnimations { transaction.disablesAnimations = true }
      }
    }
  }

  /// Finds the split view controller holding it, gives `columns` its sidebar, and has the
  /// sidebar slide as `mode` says.
  struct SidebarSlideAnchor: NSViewRepresentable {
    let mode: SidebarSlideMode
    let columns: ShellColumns

    func makeNSView(context: Context) -> AnchorView { AnchorView(mode: mode, columns: columns) }

    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
      let mode: SidebarSlideMode
      let columns: ShellColumns
      private(set) var slide: SidebarSlide?

      init(mode: SidebarSlideMode, columns: ShellColumns) {
        self.mode = mode
        self.columns = columns
        super.init(frame: .zero)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
      }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let controller = unsafe window == nil ? nil : SidebarSlide.controller(holding: self)
        if let sidebar = controller?.splitViewItems.first(where: { $0.behavior == .sidebar }) {
          columns.sidebar = sidebar
        }
        guard mode != .animated, let controller else {
          slide = nil
          return
        }
        if slide?.controller !== controller { slide = SidebarSlide(controller, mode: mode) }
      }
    }
  }

  /// Shows and hides a split view controller's sidebar in one layout pass at the final width:
  /// the item's collapse takes no time in AppKit, so no frame lays the window out again. In
  /// ``SidebarSlideMode/prerendered`` Core Animation then moves the columns from where they
  /// were, over and beside pictures of what they showed, and the render server draws the
  /// frames. Clicks in the window are dropped until the slide ends: the views are where they
  /// will be, not where they show.
  @MainActor
  final class SidebarSlide {
    static let duration: CFTimeInterval = 0.25
    /// A collapse that takes no time, which AppKit reads from the item's animations.
    static let collapse: CAAnimation = {
      let animation = CABasicAnimation()
      animation.duration = 0
      return animation
    }()
    static let animationKey = "sidebar slide"

    weak var controller: NSSplitViewController?
    let mode: SidebarSlideMode
    private var watch: NSKeyValueObservation?
    private var start: Start?
    private var overlays: [CALayer] = []
    private var moved: [CALayer] = []
    private var clipped: [(layer: CALayer, wasMasking: Bool)] = []
    private var clicks: Any?
    private var generation = 0
    /// The animation group a collapse runs in, and its settings before ``holdAnimationGroup()``;
    /// kept by the type, so they come back should the slide go before the collapse is laid out.
    private static var heldGroup: HeldGroup?

    private struct HeldGroup {
      let group: NSAnimationContext
      let duration: TimeInterval
      let allowsImplicitAnimation: Bool
    }
    /// Whether a slide is moving now.
    private(set) var isSliding = false

    /// The window as a slide starts: the column's frame in window coordinates, and pictures
    /// of what it showed, those that slide over the columns and those left under them.
    struct Start {
      var hides: Bool
      var detail: NSRect
      var over: [(layer: CALayer, frame: NSRect)] = []
      var under: [(layer: CALayer, frame: NSRect)] = []
      var titlebar: CALayer?
    }

    init(_ controller: NSSplitViewController, mode: SidebarSlideMode) {
      self.controller = controller
      self.mode = mode
      guard let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar })
      else { return }
      sidebar.animations = ["collapsed": Self.collapse]
      let options: NSKeyValueObservingOptions = [.prior, .old, .new]
      watch = sidebar.observe(\.isCollapsed, options: options) { [weak self] _, change in
        let isPrior = change.isPrior
        let changed = change.oldValue != change.newValue
        // AppKit collapses on the main thread.
        MainActor.assumeIsolated {
          if isPrior {
            self?.willSlide()
          } else if changed {
            self?.didSlide()
          } else {
            Self.settle()
          }
        }
      }
    }

    /// Whether `item` collapses in one step, so what is beside it takes one new width.
    nonisolated static func collapsesAtOnce(_ item: NSSplitViewItem) -> Bool {
      (item.animations["collapsed"] as? CAAnimation)?.duration == 0
    }

    private var sidebarItem: NSSplitViewItem? {
      controller?.splitViewItems.first { $0.behavior == .sidebar }
    }

    private var detailItem: NSSplitViewItem? {
      controller?.splitViewItems.last { $0.behavior == .default }
    }

    /// The most room a shown sidebar takes: how much of the column the pictures keep.
    static var sidebarRoom: CGFloat { AppShellMetrics.sidebarMaxWidth }

    /// The sidebar is about to collapse or expand: what the window shows now, where the slide
    /// starts from.
    private func willSlide() {
      finish()
      start = nil
      // SwiftUI reports the collapse with an animated transaction; animating its views to their
      // new frames would lay the window out at every frame of the slide.
      Self.holdsAnimations = true
      Self.holdAnimationGroup()
      guard mode == .prerendered, let controller, controller.isViewLoaded,
        let window = unsafe controller.view.window, window.isVisible, !window.inLiveResize,
        let sidebar = sidebarItem, let detail = detailItem?.viewController.view
      else { return }
      var start = Start(
        hides: !sidebar.isCollapsed, detail: detail.convert(detail.bounds, to: nil),
        titlebar: Self.titlebarPicture(in: window))
      if start.hides {
        // What the sidebar showed slides out over the column.
        if sidebar.viewController.isViewLoaded {
          let view = sidebar.viewController.view
          if let picture = Self.picture(of: view) {
            start.over.append((picture, view.convert(view.bounds, to: nil)))
          }
        }
      } else {
        // What the column showed stays under the sidebar sliding in, and beside the column's
        // end until the column reaches it: margins, mostly, shown for a moment, so at one
        // pixel a point.
        let bounds = detail.bounds
        let room = min(bounds.width, Self.sidebarRoom)
        let edges = [
          NSRect(x: bounds.minX, y: bounds.minY, width: room, height: bounds.height),
          NSRect(x: bounds.maxX - room / 2, y: bounds.minY, width: room / 2, height: bounds.height),
        ]
        for edge in edges {
          if let picture = Self.picture(of: detail, in: edge, scale: 1) {
            start.under.append((picture, detail.convert(edge, to: nil)))
          }
        }
      }
      self.start = start
    }

    /// The sidebar collapsed or expanded, in no time. Once the window is laid out at its new
    /// widths, before that frame is drawn, the columns and the pictures start moving.
    private func didSlide() {
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated {
          self?.animate()
          Self.settle()
        }
      }
    }

    /// The collapse is laid out: animations run again as they did.
    private static func settle() {
      holdsAnimations = false
      if let held = heldGroup {
        held.group.duration = held.duration
        held.group.allowsImplicitAnimation = held.allowsImplicitAnimation
      }
      heldGroup = nil
    }

    /// AppKit's toggle collapses inside an animation group that animates every frame changed
    /// in it: the toolbar's items and the hosting views would lay out again at every frame. At
    /// no duration the window takes its new layout at once.
    private static func holdAnimationGroup() {
      let group = NSAnimationContext.current
      if heldGroup == nil {
        heldGroup = HeldGroup(
          group: group, duration: group.duration,
          allowsImplicitAnimation: group.allowsImplicitAnimation)
      }
      group.duration = 0
      group.allowsImplicitAnimation = false
    }

    /// While a collapse lays the window out, SwiftUI animates nothing in the shell
    /// (``View/sidebarSlideTransactions()``).
    static var holdsAnimations = false

    private func animate() {
      guard let start else { return }
      self.start = nil
      guard let controller, let window = unsafe controller.view.window,
        let detail = detailItem?.viewController.view, let detailLayer = detail.layer,
        let host = controller.splitView.layer
      else { return }
      let split = controller.splitView
      window.layoutIfNeeded()
      generation += 1
      let generation = generation
      isSliding = true
      holdClicks(in: window)
      let end = detail.convert(detail.bounds, to: nil)
      let timing = CAMediaTimingFunction(name: .easeInEaseOut)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      let ends: @Sendable () -> Void = { [weak self] in
        MainActor.assumeIsolated {
          guard let self, generation == self.generation else { return }
          self.finish()
        }
      }
      CATransaction.setCompletionBlock(ends)
      // Should the animations go without completing, the clicks come back all the same.
      MainRunLoop.perform(after: Self.duration + 0.25, ends)
      // The column keeps its middle where it was and moves it to its new one, as a reading
      // column and the composer move through a resize.
      // AppKit declares `superview` unowned(unsafe); it is only read here.
      clip(unsafe detail.superview?.layer)
      slide(detailLayer, from: start.detail.midX - end.midX, timing: timing)
      for (picture, frame) in start.under {
        picture.frame = split.convert(frame, from: nil)
        host.insertSublayer(picture, at: 0)
        overlays.append(picture)
      }
      for (picture, frame) in start.over {
        picture.frame = split.convert(frame, from: nil)
        host.addSublayer(picture)
        overlays.append(picture)
        slide(picture, from: 0, to: -frame.maxX, timing: timing)
      }
      if !start.hides, let sidebar = sidebarItem?.viewController.view,
        let sidebarLayer = sidebar.layer
      {
        slide(sidebarLayer, from: -sidebar.convert(sidebar.bounds, to: nil).maxX, timing: timing)
      }
      if let picture = start.titlebar { fade(picture, overTitlebarOf: window, timing: timing) }
      CATransaction.commit()
    }

    /// Fades the toolbar as it was, `picture`, out over the toolbar as it is.
    private func fade(
      _ picture: CALayer, overTitlebarOf window: NSWindow, timing: CAMediaTimingFunction
    ) {
      guard let titlebar = Self.titlebar(in: window), let titlebarLayer = titlebar.layer else {
        return
      }
      picture.frame = titlebar.bounds
      titlebarLayer.addSublayer(picture)
      overlays.append(picture)
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.toValue = 0
      fade.duration = Self.duration
      fade.timingFunction = timing
      picture.opacity = 0
      picture.add(fade, forKey: Self.animationKey)
    }

    /// Moves `layer` sideways from `from` points to `to`, on top of where its view lays it.
    private func slide(
      _ layer: CALayer, from: CGFloat, to: CGFloat = 0, timing: CAMediaTimingFunction
    ) {
      let move = CABasicAnimation(keyPath: "transform.translation.x")
      move.fromValue = from
      move.toValue = to
      move.duration = Self.duration
      move.timingFunction = timing
      move.fillMode = .both
      move.isRemovedOnCompletion = false
      layer.add(move, forKey: Self.animationKey)
      moved.append(layer)
    }

    /// Clips `layer` to its bounds while the slide lasts, so a column moved past its edge does
    /// not draw over its neighbour.
    private func clip(_ layer: CALayer?) {
      guard let layer else { return }
      clipped.append((layer, layer.masksToBounds))
      layer.masksToBounds = true
    }

    /// Drops clicks in `window` until the slide ends.
    private func holdClicks(in window: NSWindow) {
      guard clicks == nil else { return }
      let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
      let number = window.windowNumber
      clicks = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
        let clicked = event.windowNumber
        let drops = MainActor.assumeIsolated { self?.isSliding == true && clicked == number }
        return drops ? nil : event
      }
    }

    /// Ends a slide: the pictures go, and the columns stay where they are laid out.
    func finish() {
      generation += 1
      for layer in moved { layer.removeAnimation(forKey: Self.animationKey) }
      moved = []
      for layer in overlays { layer.removeFromSuperlayer() }
      overlays = []
      for (layer, wasMasking) in clipped { layer.masksToBounds = wasMasking }
      clipped = []
      if let clicks { NSEvent.removeMonitor(clicks) }
      clicks = nil
      isSliding = false
    }

  }
#endif
