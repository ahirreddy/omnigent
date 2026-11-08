#if DEBUG
  import AppKit

  /// An element that answers accessibility messages without declaring the protocol (SwiftUI's
  /// nodes, the proxy for a list cell), seen through the protocol ``ChaosTargets`` walks. It sends
  /// the protocol's messages by name when the element has them, else the older attribute
  /// messages, which are deprecated and so also sent by name.
  nonisolated final class ChaosLegacyElement: NSAccessibilityElement {
    private static let valueSelector = NSSelectorFromString("accessibilityAttributeValue:")
    private static let actionNamesSelector = NSSelectorFromString("accessibilityActionNames")
    private static let performSelector = NSSelectorFromString("accessibilityPerformAction:")

    private let object: NSObject

    /// `item` as an element: itself when it adopts the protocol, wrapped when it answers the
    /// messages without adopting it, and `nil` otherwise.
    static func element(_ item: Any) -> (any NSAccessibilityProtocol)? {
      if let element = item as? any NSAccessibilityProtocol { return element }
      guard let object = item as? NSObject,
        object.responds(to: valueSelector)
          || object.responds(to: NSSelectorFromString("accessibilityRole"))
      else { return nil }
      return ChaosLegacyElement(object)
    }

    private init(_ object: NSObject) {
      self.object = object
      super.init()
    }

    /// The object `method` returns, or the older `attribute`'s value when it has no `method`.
    private func value(_ method: String?, or attribute: String) -> Any? {
      if let method {
        let selector = NSSelectorFromString(method)
        if object.responds(to: selector) {
          return unsafe object.perform(selector)?.takeUnretainedValue()
        }
      }
      guard object.responds(to: Self.valueSelector) else { return nil }
      return unsafe object.perform(Self.valueSelector, with: attribute)?.takeUnretainedValue()
    }

    private var actionNames: [String] {
      guard object.responds(to: Self.actionNamesSelector) else { return [] }
      return unsafe object.perform(Self.actionNamesSelector)?.takeUnretainedValue() as? [String]
        ?? []
    }

    /// Calls the protocol's `method` that returns `Bool`, else performs the older `action`.
    private func perform(_ method: String, or action: String) -> Bool {
      let selector = NSSelectorFromString(method)
      if object.responds(to: selector) {
        typealias Call = @convention(c) (NSObject, Selector) -> Bool
        let call = unsafe unsafeBitCast(object.method(for: selector), to: Call.self)
        return call(object, selector)
      }
      guard actionNames.contains(action) else { return false }
      _ = unsafe object.perform(Self.performSelector, with: action)
      return true
    }

    /// Whether the element has a press, through either set of messages.
    var offersPress: Bool {
      object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        || actionNames.contains("AXPress")
    }

    /// In screen coordinates, as the protocol's frame is.
    override func accessibilityFrame() -> NSRect {
      let selector = NSSelectorFromString("accessibilityFrame")
      if object.responds(to: selector) {
        typealias Call = @convention(c) (NSObject, Selector) -> NSRect
        let call = unsafe unsafeBitCast(object.method(for: selector), to: Call.self)
        return call(object, selector)
      }
      guard let position = (value(nil, or: "AXPosition") as? NSValue)?.pointValue,
        let size = (value(nil, or: "AXSize") as? NSValue)?.sizeValue
      else { return .zero }
      return NSRect(origin: position, size: size)
    }

    override func accessibilityParent() -> Any? { value("accessibilityParent", or: "AXParent") }

    override func isAccessibilityFocused() -> Bool {
      value(nil, or: "AXFocused") as? Bool ?? false
    }

    override func accessibilityIdentifier() -> String {
      value("accessibilityIdentifier", or: "AXIdentifier") as? String ?? ""
    }

    // swiftlint:disable:next discouraged_optional_collection
    override func accessibilityChildren() -> [Any]? {
      value("accessibilityChildren", or: "AXChildren") as? [Any]
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
      (value("accessibilityRole", or: "AXRole") as? String).map {
        NSAccessibility.Role(rawValue: $0)
      }
    }

    override func accessibilityLabel() -> String? {
      value("accessibilityLabel", or: "AXDescription") as? String
        ?? value("accessibilityTitle", or: "AXTitle") as? String
    }

    override func accessibilityPerformPress() -> Bool {
      perform("accessibilityPerformPress", or: "AXPress")
    }

    override func accessibilityPerformIncrement() -> Bool {
      perform("accessibilityPerformIncrement", or: "AXIncrement")
    }

    override func accessibilityPerformDecrement() -> Bool {
      perform("accessibilityPerformDecrement", or: "AXDecrement")
    }
  }
#endif
