import Foundation
import OmnigentWorkspaceUI
import SwiftUI

extension ComposerPreferences {
  /// Whether Command-Return sends, for a view's first render.
  @MainActor static var commandReturnSends: Bool {
    UserDefaults.standard.bool(forKey: submitWithCommandReturnKey)
  }
}

extension View {
  /// Keeps `sends` and the stored "Send with Command-Return" setting equal, without the view
  /// rendering for the store's other writes.
  func commandReturnPreference(_ sends: Binding<Bool>) -> some View {
    modifier(
      StoredPreference(
        sends,
        stored: AppStorage(wrappedValue: false, ComposerPreferences.submitWithCommandReturnKey)))
  }
}
