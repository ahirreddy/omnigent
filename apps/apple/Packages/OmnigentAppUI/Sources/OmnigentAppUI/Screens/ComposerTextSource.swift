import Observation
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The conversation's draft text, for a key-path binding (`$source.text`) the composer makes in
/// its own body. A binding made from closures, or from `Bindable`, counts as changed on every
/// update, which kept iPad's composer re-rendering after a reply streamed in.
@Observable
final class ComposerTextSource {
  @ObservationIgnored private var composer: ComposerStore?

  /// The draft.
  var text: String {
    get { composer?.text ?? "" }
    set {
      if composer?.text != newValue { composer?.text = newValue }
    }
  }

  /// The draft for the screen, without reading the text here.
  /// - Parameters:
  ///   - composer: The conversation's composer.
  ///   - source: This object's `@State` binding, whose `text` projection compares equal.
  /// - Returns: The draft.
  func draft(_ composer: ComposerStore, _ source: Binding<ComposerTextSource>) -> ComposerDraft {
    self.composer = composer
    return ComposerDraft { source.text }
  }
}
