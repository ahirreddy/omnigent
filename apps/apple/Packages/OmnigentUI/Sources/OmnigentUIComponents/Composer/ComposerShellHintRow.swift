import SwiftUI

/// Under the card while the draft runs as a shell command: "Shell command" in the accent, or
/// why such a send is refused (web `composer-shell-mode-indicator`). VoiceOver hears the change.
struct ComposerShellHintRow: View {
  let hint: ComposerShellHint

  var body: some View {
    Label(hint.text, systemImage: "terminal")
      .font(.caption)
      .foregroundStyle(Theme.accent)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.Spacing.medium)
      .accessibilityIdentifier("composer-shell-mode-indicator")
      .onAppear { announce() }
      .onChange(of: hint) { announce() }
  }

  private func announce() {
    AccessibilityNotification.Announcement(hint.text).post()
  }
}
