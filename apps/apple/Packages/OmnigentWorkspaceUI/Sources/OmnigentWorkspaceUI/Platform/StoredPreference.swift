public import Foundation
public import SwiftUI

/// Keeps a view's copy of a stored preference current, and stores what the view sets it to.
/// `@AppStorage` renders its view for every write to the store when its key has a dot in it,
/// so it is read here, where a render costs nothing, and the view renders when the value changes.
public struct StoredPreference<Value: Equatable>: ViewModifier {
  @Binding private var value: Value
  @AppStorage private var stored: Value

  /// Creates the modifier.
  /// - Parameters:
  ///   - value: The view's copy, held in its own state.
  ///   - stored: The preference in the store.
  public init(_ value: Binding<Value>, stored: AppStorage<Value>) {
    _value = value
    _stored = stored
  }

  /// The content, with the copy and the store following each other.
  public func body(content: Content) -> some View {
    content
      .onChange(of: stored, initial: true) { if value != stored { value = stored } }
      .onChange(of: value) { if stored != value { stored = value } }
  }
}

extension UserDefaults {
  /// A stored choice for a view's first render, before ``StoredPreference`` has read its store.
  public func choice<Value: RawRepresentable>(_ key: String, default fallback: Value) -> Value
  where Value.RawValue == String {
    string(forKey: key).flatMap(Value.init(rawValue:)) ?? fallback
  }
}
