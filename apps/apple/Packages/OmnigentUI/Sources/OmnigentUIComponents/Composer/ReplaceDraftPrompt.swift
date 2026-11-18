import SwiftUI

/// Edit and resend's question when the composer already holds a draft (the web's
/// `ReplaceDraftDialog`): Replace draft loads the sent message, Keep draft drops it.
struct ReplaceDraftPrompt: ViewModifier {
  /// A sent message is waiting on the answer.
  let isAsking: Bool
  let replace: (@MainActor () -> Void)?
  let keep: (@MainActor () -> Void)?

  func body(content: Content) -> some View {
    content.alert(
      "Replace your draft?",
      // Either button answers; Escape is the cancel button's.
      isPresented: Binding(get: { isAsking && replace != nil }, set: { _ in })
    ) {
      Button("Keep draft", role: .cancel) { keep?() }
        .accessibilityIdentifier("replace-draft-keep")
      Button("Replace draft") { replace?() }
        .accessibilityIdentifier("replace-draft-confirm")
    } message: {
      Text(
        "The composer already has an unsent message. Editing this message replaces that text "
          + "and its attachments.")
    }
  }
}
