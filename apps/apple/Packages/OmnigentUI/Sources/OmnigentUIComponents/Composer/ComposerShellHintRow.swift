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

/// The accent ring around the card while the draft is a shell command. A one-line pill is a
/// capsule, so the ring is one too; a taller card keeps the card's corners.
struct ComposerShellRing: View {
  var body: some View {
    GeometryReader { proxy in
      if proxy.size.height <= Theme.Radius.composer * 2 {
        Capsule().strokeBorder(Theme.accent, lineWidth: 1.5)
      } else {
        RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
          .strokeBorder(Theme.accent, lineWidth: 1.5)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
