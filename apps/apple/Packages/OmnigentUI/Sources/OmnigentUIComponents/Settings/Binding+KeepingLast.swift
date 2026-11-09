import SwiftUI

extension Binding {
  /// Unwraps `base`, or `nil` when it holds nothing. Unlike `Binding($optional)`, this survives
  /// `base` clearing while views bound to it are still up: `Binding($optional)` crashes them on
  /// their last read.
  init?(keepingLast base: Binding<Value?>) {
    guard let current = base.wrappedValue else { return nil }
    self.init(get: { base.wrappedValue ?? current }, set: { base.wrappedValue = $0 })
  }
}
