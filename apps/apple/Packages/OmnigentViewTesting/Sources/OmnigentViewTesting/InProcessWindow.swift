#if os(iOS)
  public import SwiftUI
  public import UIKit

  /// A failure to drive an in-process window.
  public enum InProcessWindowError: Error, Equatable, CustomStringConvertible {
    /// UIKit or the simulator's accessibility library declined what the window needs.
    case unavailable(String)
    /// No element has this identifier or label.
    case notFound(String)
    /// The element is disabled, or declined to be activated.
    case notActivated(String)

    /// A sentence saying what failed.
    public var description: String {
      switch self {
      case .unavailable(let what): "Not available in this process: \(what)."
      case .notFound(let name): "Nothing is named \(name)."
      case .notActivated(let name): "\(name) is disabled or took no activation."
      }
    }
  }

  /// Hosts a view in a window of the test process and presses its controls the way assistive
  /// technology does, so a test runs a control's own action without a UI test or a touch.
  ///
  /// Activation reaches `Button`s, `Toggle`s and links by accessibility identifier or label. It
  /// opens no `Menu`, types into no `TextField` and finds no row inside a `ScrollView`, whose
  /// elements SwiftUI makes only for assistive technology itself: host a menu's items or a
  /// row's view outside its container, and call a UIKit view's own input methods.
  @MainActor
  public final class InProcessWindow {
    /// The window holding the view.
    public let window: UIWindow
    /// The controller whose view fills the window.
    public let controller: UIViewController

    /// Puts a controller's view on a key window and lays it out.
    /// - Parameters:
    ///   - controller: The controller under test.
    ///   - width: The window's width; an iPhone's by default.
    ///   - height: The window's height.
    ///   - horizontalSizeClass: Compact for iPhone layouts, regular for iPad's.
    ///   - style: Light or dark, set here so a result never follows the simulator's setting.
    /// - Throws: `InProcessWindowError` when the process can't make the window.
    public init(
      controller: UIViewController, width: CGFloat = 393, height: CGFloat = 852,
      horizontalSizeClass: UIUserInterfaceSizeClass = .compact,
      style: UIUserInterfaceStyle = .dark
    ) throws {
      try AccessibilityAutomation.enable()
      // A test process has no scene to pass `init(windowScene:)`; the plain initializer, which
      // Swift marks deprecated, attaches the window to the screen's own scene.
      guard let window = (UIWindow.self as NSObject.Type).init() as? UIWindow else {
        throw InProcessWindowError.unavailable("a window")
      }
      self.window = window
      self.controller = controller
      window.frame = CGRect(x: 0, y: 0, width: width, height: height)
      window.traitOverrides.horizontalSizeClass = horizontalSizeClass
      window.traitOverrides.userInterfaceStyle = style
      window.rootViewController = controller
      window.makeKeyAndVisible()
      window.layoutIfNeeded()
    }

    /// Hosts a SwiftUI view.
    /// - Parameters:
    ///   - view: The view under test.
    ///   - width: The window's width.
    ///   - height: The window's height.
    ///   - horizontalSizeClass: Compact for iPhone layouts, regular for iPad's.
    /// - Throws: `InProcessWindowError` when the process can't make the window.
    public convenience init<Content: View>(
      _ view: Content, width: CGFloat = 393, height: CGFloat = 852,
      horizontalSizeClass: UIUserInterfaceSizeClass = .compact
    ) throws {
      try self.init(
        controller: UIHostingController(rootView: view), width: width, height: height,
        horizontalSizeClass: horizontalSizeClass)
    }

    /// Hosts a UIKit view, filling the window.
    /// - Parameters:
    ///   - view: The view under test.
    ///   - width: The window's width.
    ///   - height: The window's height.
    /// - Throws: `InProcessWindowError` when the process can't make the window.
    public convenience init(view: UIView, width: CGFloat = 393, height: CGFloat = 852) throws {
      let controller = UIViewController()
      try self.init(controller: controller, width: width, height: height)
      view.frame = controller.view.bounds
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      controller.view.addSubview(view)
      window.layoutIfNeeded()
    }

    /// Takes the view off the screen. Later activations find nothing.
    public func close() {
      window.isHidden = true
      window.rootViewController = nil
    }

    /// Lets the main run loop turn, so state changes, tasks and layout proceed.
    /// - Parameter duration: How long to wait.
    public func settle(_ duration: Duration = .milliseconds(60)) async {
      window.layoutIfNeeded()
      let nanoseconds =
        duration.components.seconds * 1_000_000_000
        + duration.components.attoseconds / 1_000_000_000
      await withCheckedContinuation { continuation in
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
          continuation.resume()
        }
      }
      window.layoutIfNeeded()
    }

    // MARK: Elements

    /// Every accessibility element and view under the window, in depth-first order.
    public var elements: [NSObject] { Self.elements(under: window, depth: 0) }

    private static func elements(under root: NSObject, depth: Int) -> [NSObject] {
      // A tree deeper than any real screen is a cycle between an element and its container.
      guard depth < 60 else { return [] }
      let children: [NSObject] =
        if let listed = root.accessibilityElements as? [NSObject] {
          listed
        } else if let view = root as? UIView {
          view.subviews
        } else {
          []
        }
      return [root] + children.flatMap { elements(under: $0, depth: depth + 1) }
    }

    private static func identifier(of element: NSObject) -> String? {
      // SwiftUI's elements answer the selector without adopting UIAccessibilityIdentification.
      let key = "accessibilityIdentifier"
      guard element.responds(to: NSSelectorFromString(key)) else { return nil }
      return element.value(forKey: key) as? String
    }

    /// The accessibility identifiers on screen, in depth-first order.
    public var identifiers: [String] { elements.compactMap(Self.identifier(of:)) }

    /// The accessibility labels on screen: the text VoiceOver reads, static text included.
    public var labels: [String] {
      elements.compactMap(\.accessibilityLabel).filter { !$0.isEmpty }
    }

    /// The element with this accessibility identifier, or else this label.
    /// - Parameter name: An identifier or a label.
    /// - Returns: The first match in depth-first order.
    /// - Throws: `InProcessWindowError.notFound` when nothing matches.
    public func element(_ name: String) throws -> NSObject {
      guard let found = firstElement(named: name) else {
        throw InProcessWindowError.notFound(name)
      }
      return found
    }

    private func firstElement(named name: String) -> NSObject? {
      let all = elements
      return all.first { Self.identifier(of: $0) == name }
        ?? all.first { $0.accessibilityLabel == name }
    }

    /// Whether an element with this identifier or label is on screen.
    /// - Parameter name: An identifier or a label.
    /// - Returns: Whether it was found.
    public func shows(_ name: String) -> Bool {
      firstElement(named: name) != nil
    }

    /// Whether the element takes activation: a disabled control doesn't.
    /// - Parameter name: An identifier or a label.
    /// - Returns: Whether it is enabled.
    /// - Throws: `InProcessWindowError.notFound` when nothing matches.
    public func isEnabled(_ name: String) throws -> Bool {
      !(try element(name)).accessibilityTraits.contains(.notEnabled)
    }

    /// The element's accessibility value, such as a toggle's "1" or a progress bar's percentage.
    /// - Parameter name: An identifier or a label.
    /// - Returns: The value, if it has one.
    /// - Throws: `InProcessWindowError.notFound` when nothing matches.
    public func value(of name: String) throws -> String? {
      try element(name).accessibilityValue
    }

    /// Presses a control as VoiceOver's double tap does, then lets the result settle.
    /// - Parameter name: An identifier or a label.
    /// - Throws: `InProcessWindowError` when nothing matches or the control is disabled.
    public func activate(_ name: String) async throws {
      let element = try element(name)
      guard !element.accessibilityTraits.contains(.notEnabled), element.accessibilityActivate()
      else { throw InProcessWindowError.notActivated(name) }
      await settle()
    }

    /// The views of one type under the window, in depth-first order.
    /// - Parameter type: The view class.
    /// - Returns: The views found.
    public func views<Found: UIView>(_ type: Found.Type) -> [Found] {
      var found: [Found] = []
      var pending: [UIView] = [window]
      while let view = pending.popLast() {
        if let match = view as? Found { found.append(match) }
        pending.append(contentsOf: view.subviews.reversed())
      }
      return found
    }
  }

  /// SwiftUI builds its accessibility elements only once something asks for them. This sets the
  /// simulator's automation switch, the one a UI test runner sets, from inside the process.
  enum AccessibilityAutomation {
    private typealias Setter = @convention(c) (Int32) -> Void

    static func enable(library path: String = "/usr/lib/libAccessibility.dylib") throws {
      guard let library = unsafe dlopen(path, RTLD_NOW) else {
        throw InProcessWindowError.unavailable("the accessibility library at \(path)")
      }
      guard let symbol = unsafe dlsym(library, "_AXSSetAutomationEnabled") else {
        throw InProcessWindowError.unavailable("the accessibility automation switch")
      }
      let setEnabled = unsafe unsafeBitCast(symbol, to: Setter.self)
      setEnabled(1)
    }
  }
#endif
