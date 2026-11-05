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

  /// Creates a draft whose binding the composer makes when it renders: a key-path projection of
  /// an `@State` object (`$source.text`), which compares equal across updates. One made from
  /// closures counts as changed on every update, which kept re-rendering iPad's composer.
  /// - Parameter makeBinding: Makes the binding to the text.
  public init(binding makeBinding: @escaping @MainActor () -> Binding<String>) {
    self.init(get: { makeBinding().wrappedValue }, set: { makeBinding().wrappedValue = $0 })
    self.makeBinding = makeBinding
  }

  private var makeBinding: (@MainActor () -> Binding<String>)?

  /// A binding to the text, for the view that shows it.
  var binding: Binding<String> {
    makeBinding?() ?? Binding(get: get, set: set)
  }
}
