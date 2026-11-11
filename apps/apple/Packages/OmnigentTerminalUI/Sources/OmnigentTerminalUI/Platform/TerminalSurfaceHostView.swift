#if os(macOS)
  import AppKit

  /// Holds a terminal's surface clear of the window's title bar and toolbar, wherever it is
  /// hosted. The window's tabs float over its content, and a terminal has no rows to spare under
  /// them: the surface takes what they leave uncovered, so its grid is what shows.
  final class TerminalSurfaceHostView: NSView {
    /// Called after a layout that changed ``coveredTop``, for what is drawn over the surface.
    var coveredTopChanged: (@MainActor (CGFloat) -> Void)?
    /// How much of this view's top the window's title bar and toolbar cover, in points.
    private(set) var coveredTop: CGFloat = 0

    private let surface: NSView
    /// Follows the window's uncovered area: a toolbar that shows or hides, full screen.
    private var uncoveredAreaObservation: NSKeyValueObservation?

    /// Takes `surface` from the view that held it, at the size it has.
    init(surface: NSView) {
      self.surface = surface
      super.init(frame: CGRect(origin: .zero, size: surface.frame.size))
      // Sized by `placeSurface()` first: a tab that shows again keeps the grid it had.
      surface.autoresizingMask = []
      surface.setFrameOrigin(.zero)
      addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      uncoveredAreaObservation = unsafe window?.observe(\.contentLayoutRect) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.needsLayout = true }
      }
      needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      needsLayout = true
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
      super.setFrameOrigin(newOrigin)
      needsLayout = true
    }

    override func layout() {
      super.layout()
      placeSurface()
    }

    /// Lays the surface out below what covers this view's top. Out of a window nothing is
    /// known to cover it, and the surface keeps its size rather than report one that won't show.
    private func placeSurface() {
      guard unsafe surface.superview === self, let window = unsafe window, !bounds.isEmpty
      else { return }
      let covered = Self.coveredTop(
        of: bounds, uncovered: convert(window.contentLayoutRect, from: nil))
      let frame = CGRect(
        x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - covered)
      if surface.frame != frame { surface.frame = frame }
      // A resize keeps the covered part as it is; the next layout places the surface again.
      surface.autoresizingMask = [.width, .height]
      guard covered != coveredTop else { return }
      coveredTop = covered
      // After the layout pass, which SwiftUI may be running.
      Task { [coveredTopChanged] in coveredTopChanged?(covered) }
    }

    /// How much of the top of `bounds` lies above `uncovered`, in whole points and no more than
    /// its height. The view's origin is its bottom left, as the window's is.
    /// - Parameters:
    ///   - bounds: The view's bounds.
    ///   - uncovered: The window's content area clear of its title bar, in the view's space.
    /// - Returns: The covered height: zero for a view that starts below the title bar.
    static func coveredTop(of bounds: CGRect, uncovered: CGRect) -> CGFloat {
      min(bounds.height, max(0, (bounds.maxY - uncovered.maxY).rounded()))
    }
  }
#endif
