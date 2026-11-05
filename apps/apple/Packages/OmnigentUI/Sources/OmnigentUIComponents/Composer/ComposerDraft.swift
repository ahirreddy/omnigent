public import SwiftUI

/// The composer's text, handed through a screen without being read on the way. A `Binding`
/// reads its value when it is made, so a screen given one re-renders on every keystroke; the
/// composer makes its binding from this in its own body, and only it re-renders while typing.
public struct ComposerDraft {
  /// Reads the text.
  public let get: @MainActor () -> String
  /// Replaces the text.
  public let set: @MainActor (String) -> Void

  /// Creates a draft from its accessors.
  /// - Parameters:
  ///   - get: Reads the text.
  ///   - set: Replaces the text.
  public init(get: @escaping @MainActor () -> String, set: @escaping @MainActor (String) -> Void) {
    self.get = get
    self.set = set
  }

  /// Creates a draft over a binding (previews and the gallery, whose text is view state).
  /// - Parameter binding: The text.
  public init(_ binding: Binding<String>) {
    self.init(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0 })
  }

  /// A binding to the text, for the view that shows it.
  var binding: Binding<String> {
    Binding(get: get, set: set)
  }
}
