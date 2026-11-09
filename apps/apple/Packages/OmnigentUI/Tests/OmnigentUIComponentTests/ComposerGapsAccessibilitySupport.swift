#if os(macOS)
  import AppKit
  import OmnigentViewTesting

  /// SwiftUI's accessibility tree, which it builds once an assistive client says it's there. A
  /// process-local flag asks for it; nothing outside this process hears of it.
  extension OffscreenWindow {
    /// Runs `body` with the tree on, and turns it off again.
    func withAccessibilityTree<Result>(_ body: () throws -> Result) throws -> Result {
      let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
      _ = unsafe NSApp.perform(setter, with: true, with: "AXEnhancedUserInterface")
      defer { _ = unsafe NSApp.perform(setter, with: false, with: "AXEnhancedUserInterface") }
      settle(0.2)
      return try body()
    }

    /// The accessibility element with this identifier.
    func accessibilityElement(_ identifier: String) throws -> NSObject {
      var pending: [Any] = [host]
      while let next = pending.popLast() {
        guard let element = next as? NSObject else { continue }
        if Self.attribute("accessibilityIdentifier", of: element) as? String == identifier {
          return element
        }
        pending.append(
          contentsOf: Self.attribute("accessibilityChildren", of: element) as? [Any] ?? [])
      }
      throw OffscreenWindowError.notFound(identifier)
    }

    /// The custom action of this name on an element.
    func customAction(_ name: String, of element: NSObject) throws -> NSAccessibilityCustomAction {
      let actions = Self.attribute("accessibilityCustomActions", of: element)
      guard
        let action = (actions as? [NSAccessibilityCustomAction])?.first(where: { $0.name == name })
      else { throw OffscreenWindowError.notFound(name) }
      return action
    }

    private static func attribute(_ name: String, of element: NSObject) -> Any? {
      element.responds(to: NSSelectorFromString(name)) ? element.value(forKey: name) : nil
    }
  }
#endif
