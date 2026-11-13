#if os(iOS)
  public import UIKit
  // The submodule that lets a subclass set a recognizer's state.
  import UIKit.UIGestureRecognizerSubclass  // swiftlint:disable:this duplicate_imports

  // Recognizers and keys that report what a test says a finger or a keyboard did. A gesture
  // handler reads its recognizer's location, state and movement, so calling the handler with
  // one of these runs it without a touch.

  /// A tap at `point`.
  public final class ScriptedTap: UITapGestureRecognizer {
    /// Where the finger is, in any view's coordinates.
    public var point = CGPoint.zero

    /// A tap at a point.
    /// - Parameter point: Where the finger is.
    public init(at point: CGPoint = .zero) {
      self.point = point
      super.init(target: nil, action: nil)
    }

    override public func location(in view: UIView?) -> CGPoint { point }
  }

  /// A pinch centred on `point`, in the phase the test sets; `scale` is UIKit's own.
  public final class ScriptedPinch: UIPinchGestureRecognizer {
    /// The pinch's centre.
    public var point = CGPoint.zero
    /// The recognizer's state.
    public var phase = UIGestureRecognizer.State.possible

    /// A pinch that has not begun.
    public init() {
      super.init(target: nil, action: nil)
    }

    override public var state: UIGestureRecognizer.State {
      get { phase }
      set { phase = newValue }
    }

    override public func location(in view: UIView?) -> CGPoint { point }
  }

  /// A pan at `point` that has moved `moved` since the handler last reset the translation.
  public final class ScriptedPan: UIPanGestureRecognizer {
    /// Where the finger is.
    public var point = CGPoint.zero
    /// The recognizer's state.
    public var phase = UIGestureRecognizer.State.possible
    /// The translation; a handler's `setTranslation` replaces it.
    public var moved = CGPoint.zero
    /// The velocity, points per second.
    public var speed = CGPoint.zero
    /// How many fingers are down.
    public var fingers = 1

    /// A pan that has not begun.
    public init() {
      super.init(target: nil, action: nil)
    }

    override public var state: UIGestureRecognizer.State {
      get { phase }
      set { phase = newValue }
    }

    override public var numberOfTouches: Int { fingers }
    override public func location(in view: UIView?) -> CGPoint { point }
    override public func translation(in view: UIView?) -> CGPoint { moved }

    override public func setTranslation(_ translation: CGPoint, in view: UIView?) {
      moved = translation
    }

    override public func velocity(in view: UIView?) -> CGPoint { speed }
  }

  /// A long press at `point`, in the phase the test sets.
  public final class ScriptedLongPress: UILongPressGestureRecognizer {
    /// Where the finger is.
    public var point = CGPoint.zero
    /// The recognizer's state.
    public var phase = UIGestureRecognizer.State.possible

    /// A long press that has not begun.
    public init() {
      super.init(target: nil, action: nil)
    }

    override public var state: UIGestureRecognizer.State {
      get { phase }
      set { phase = newValue }
    }

    override public func location(in view: UIView?) -> CGPoint { point }
  }

  /// A pointer hovering at `point`, in the phase the test sets.
  public final class ScriptedHover: UIHoverGestureRecognizer {
    /// Where the pointer is.
    public var point = CGPoint.zero
    /// The recognizer's state.
    public var phase = UIGestureRecognizer.State.possible

    /// A hover that has not begun.
    public init() {
      super.init(target: nil, action: nil)
    }

    override public var state: UIGestureRecognizer.State {
      get { phase }
      set { phase = newValue }
    }

    override public func location(in view: UIView?) -> CGPoint { point }
  }

  /// An edit menu that records where it was asked to appear instead of showing.
  public final class RecordingEditMenu: UIEditMenuInteraction {
    /// The source points of each presentation asked for, in order.
    public private(set) var presentedAt: [CGPoint] = []
    /// How many times the menu was dismissed.
    public private(set) var dismissals = 0

    override public func presentEditMenu(with configuration: UIEditMenuConfiguration) {
      presentedAt.append(configuration.sourcePoint)
    }

    override public func dismissMenu() { dismissals += 1 }
  }

  /// A hardware key as UIKit reports one: its HID usage, the characters it types and the
  /// modifiers held.
  public final class ScriptedKey: UIKey {
    private let usage: UIKeyboardHIDUsage
    private let typed: String
    private let flags: UIKeyModifierFlags

    /// A key.
    /// - Parameters:
    ///   - typed: The characters the key types, empty for keys that type nothing.
    ///   - usage: The key's HID usage.
    ///   - flags: The modifiers held.
    public init(_ typed: String, _ usage: UIKeyboardHIDUsage, _ flags: UIKeyModifierFlags = []) {
      self.typed = typed
      self.usage = usage
      self.flags = flags
      super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      nil
    }

    override public var keyCode: UIKeyboardHIDUsage { usage }
    override public var characters: String { typed }
    override public var charactersIgnoringModifiers: String { typed }
    override public var modifierFlags: UIKeyModifierFlags { flags }

    /// One press of this key, as `pressesBegan` and `pressesEnded` take it.
    public var pressed: Set<UIPress> { [ScriptedPress(key: self)] }
  }

  /// A press carrying a scripted key, or none (a remote's button).
  nonisolated public final class ScriptedPress: UIPress {
    private let pressedKey: UIKey?

    /// A press.
    /// - Parameter key: The key pressed, if the press is a keyboard's.
    public init(key: UIKey?) {
      pressedKey = key
      super.init()
    }

    override public var key: UIKey? { pressedKey }
  }
#endif
