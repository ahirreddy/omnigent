#if os(iOS)
  internal import SwiftUI
  internal import UIKit

  /// The tools' layer over the page on iPhone and iPad. A tap picks or places; one finger or
  /// Apple Pencil aims (Annotate) or draws (Draw); two fingers, or a trackpad, scroll the page;
  /// the pointer and Pencil's hover outline; Escape on a keyboard leaves. Where the system
  /// prefers Apple Pencil for drawing, fingers scroll and Pencil draws, as in Notes.
  struct BrowserDesignTouchInput: UIViewRepresentable {
    let handlers: BrowserDesignInputHandlers
    let scrolls: Bool
    let draws: Bool
    /// The page's view, whose scroll view the layer moves.
    let page: UIView?

    func makeUIView(context: Context) -> BrowserDesignTouchView {
      let view = BrowserDesignTouchView()
      update(view)
      return view
    }

    func updateUIView(_ view: BrowserDesignTouchView, context: Context) {
      update(view)
    }

    static func dismantleUIView(_ view: BrowserDesignTouchView, coordinator: ()) {
      if view.isFirstResponder { view.resignFirstResponder() }
    }

    private func update(_ view: BrowserDesignTouchView) {
      view.handlers = handlers
      view.scrolls = scrolls
      view.draws = draws
      view.page = page
      view.applyTouchTypes()
    }
  }

  /// The touch layer's view: its gestures, Apple Pencil's double tap and the keyboard's Escape.
  final class BrowserDesignTouchView: UIView, UIPencilInteractionDelegate {
    var handlers = BrowserDesignInputHandlers()
    var scrolls = false
    var draws = false
    weak var page: UIView?
    private let tapRecognizer = UITapGestureRecognizer()
    private let aimRecognizer = UIPanGestureRecognizer()
    private let scrollRecognizer = UIPanGestureRecognizer()
    private let hoverRecognizer = UIHoverGestureRecognizer()
    private var lastAim: CGPoint?

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      isMultipleTouchEnabled = true
      tapRecognizer.addTarget(self, action: #selector(tapped(_:)))
      aimRecognizer.addTarget(self, action: #selector(aimed(_:)))
      aimRecognizer.maximumNumberOfTouches = 1
      scrollRecognizer.addTarget(self, action: #selector(scrolled(_:)))
      scrollRecognizer.allowedScrollTypesMask = .all
      hoverRecognizer.addTarget(self, action: #selector(hovered(_:)))
      for recognizer in [tapRecognizer, aimRecognizer, scrollRecognizer, hoverRecognizer] {
        addGestureRecognizer(recognizer)
      }
      addInteraction(UIPencilInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      // The tool takes a keyboard's keys from the page as it opens.
      if window != nil { becomeFirstResponder() }
    }

    /// Fingers scroll and only Apple Pencil draws, where the system prefers it for drawing.
    var pencilOnly: Bool { draws && UIPencilInteraction.prefersPencilOnlyDrawing }

    func applyTouchTypes() {
      aimRecognizer.allowedTouchTypes = Self.types(
        pencilOnly ? [.pencil] : [.direct, .pencil, .indirectPointer])
      scrollRecognizer.allowedTouchTypes = Self.types(
        pencilOnly ? [.direct] : [.direct, .indirectPointer])
      scrollRecognizer.minimumNumberOfTouches = pencilOnly ? 1 : 2
      scrollRecognizer.isEnabled = scrolls || pencilOnly
    }

    // swiftlint:disable legacy_objc_type
    /// Touch types as a recognizer takes them: UIKit's API is numbers.
    private static func types(_ kinds: [UITouch.TouchType]) -> [NSNumber] {
      kinds.map { NSNumber(value: $0.rawValue) }
    }
    // swiftlint:enable legacy_objc_type

    // MARK: Gestures

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      tap(at: recognizer.location(in: self))
    }

    @objc private func aimed(_ recognizer: UIPanGestureRecognizer) {
      let point = recognizer.location(in: self)
      let start = CGPoint(
        x: point.x - recognizer.translation(in: self).x,
        y: point.y - recognizer.translation(in: self).y)
      aim(recognizer.state, at: recognizer.state == .began ? start : point)
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
      let delta = recognizer.translation(in: self)
      recognizer.setTranslation(.zero, in: self)
      scroll(by: delta, at: recognizer.location(in: self))
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
      guard recognizer.state == .began || recognizer.state == .changed else { return }
      handlers.move(recognizer.location(in: self))
    }

    /// A tap at `point`: Annotate picks there, Draw places a text mark there.
    func tap(at point: CGPoint) {
      handlers.press(point)
      handlers.release(point)
    }

    /// One finger or Pencil at `point` in `phase`: Draw draws, from where it started; Annotate
    /// outlines what is under it and picks where it lifts.
    func aim(_ phase: UIGestureRecognizer.State, at point: CGPoint) {
      switch (phase, draws) {
      case (.began, true): handlers.press(point)
      case (.changed, true): handlers.drag(point)
      case (.ended, true): handlers.release(point)
      case (.cancelled, true), (.failed, true): handlers.release(lastAim ?? point)
      case (.began, false), (.changed, false): handlers.move(point)
      case (.ended, false): handlers.press(point)
      default: break
      }
      lastAim = phase == .began || phase == .changed ? point : nil
    }

    /// Moves the page by `delta`, as its own scrolling would, within its content.
    func scroll(by delta: CGPoint, at point: CGPoint) {
      guard let scrollView = pageScrollView else { return }
      let inset = scrollView.adjustedContentInset
      let maxX = scrollView.contentSize.width - scrollView.bounds.width + inset.right
      let maxY = scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
      let offset = CGPoint(
        x: min(max(scrollView.contentOffset.x - delta.x, -inset.left), max(maxX, -inset.left)),
        y: min(max(scrollView.contentOffset.y - delta.y, -inset.top), max(maxY, -inset.top)))
      scrollView.setContentOffset(offset, animated: false)
      handlers.scrolled()
      if !draws { handlers.move(point) }
    }

    /// The page view's scroll view: the page's own, or its first.
    var pageScrollView: UIScrollView? {
      guard let page else { return nil }
      if let scrollView = page as? UIScrollView { return scrollView }
      return page.subviews.lazy.compactMap { $0 as? UIScrollView }.first
    }

    // MARK: Apple Pencil and the keyboard

    func pencilInteraction(
      _ interaction: UIPencilInteraction, didReceiveTap _: UIPencilInteraction.Tap
    ) {
      pencilDoubleTap(UIPencilInteraction.preferredTapAction)
    }

    /// Pencil's double tap, as the system's setting asks: the eraser's undoes the last mark, and
    /// the previous tool's switches shapes back.
    func pencilDoubleTap(_ action: UIPencilPreferredAction) {
      switch action {
      case .switchEraser: handlers.undo()
      case .switchPrevious: handlers.previousTool()
      default: break
      }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      guard presses.contains(where: { $0.key?.keyCode == .keyboardEscape }) else {
        super.pressesBegan(presses, with: event)
        return
      }
      handlers.escape()
    }
  }
#endif
