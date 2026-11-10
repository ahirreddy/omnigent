import Foundation
import OmnigentUIComponents
import SwiftUI

/// The composer's stored preferences, as the screen that builds a composer holds them.
nonisolated struct StoredComposerPreferences: Equatable {
  /// Return inserts a newline and Command-Return sends.
  var submitWithCommandReturn: Bool
  /// A message sent mid-turn goes into the running turn.
  var alwaysSteer: Bool

  /// The stored values, for a screen's first render.
  @MainActor
  static func stored(in defaults: UserDefaults = .standard) -> Self {
    Self(
      submitWithCommandReturn: defaults.bool(
        forKey: ComposerPreferences.submitWithCommandReturnKey),
      alwaysSteer: defaults.object(forKey: ComposerPreferences.alwaysSteerKey) as? Bool ?? true)
  }
}

/// Keeps a screen's copy of the composer's preferences current. `@AppStorage` renders its view
/// for every write to the store when its key has a dot in it, so it is read here, where a
/// render costs nothing, and the screen renders only when one of these changes.
struct ComposerPreferencesReader: ViewModifier {
  @Binding var preferences: StoredComposerPreferences
  @AppStorage(ComposerPreferences.submitWithCommandReturnKey) private var commandReturnSends = false
  @AppStorage(ComposerPreferences.alwaysSteerKey) private var alwaysSteer = true

  func body(content: Content) -> some View {
    let stored = StoredComposerPreferences(
      submitWithCommandReturn: commandReturnSends, alwaysSteer: alwaysSteer)
    content.onChange(of: stored, initial: true) {
      if preferences != stored { preferences = stored }
    }
  }
}
