#if os(iOS)
  import SwiftUI

  extension TranscriptCollectionController {
    /// Moves to the previous or next user message from the rows on screen, as the Mac's list
    /// does; with none above, older history loads, and with none below, the newest row shows.
    func step(_ direction: TranscriptNavigation.Direction) {
      let users = Set(model.rows.filter(\.isUserMessage).map(\.id))
      let target = TranscriptNavigation.target(
        direction, order: model.ids, userMessages: users, visible: Set(visibleRowIDs))
      guard let target else {
        if direction == .previous { requestOlder() } else { jumpToLatest() }
        return
      }
      show(target, at: .top)
    }
  }

  /// The previous and next message buttons over the iPhone and iPad transcript, as the web's
  /// `UserMessageNav` floats them in the corner opposite the jump pill; a hardware keyboard's
  /// Option-Command arrows run them too.
  struct TranscriptMessageStepper: View {
    let isShown: Bool
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
      if isShown {
        VStack(spacing: Theme.Spacing.small) {
          button("chevron.up", "Previous user message", previous)
            .keyboardShortcut(AppShortcuts.previousMessage)
          button("chevron.down", "Next user message", next)
            .keyboardShortcut(AppShortcuts.nextMessage)
        }
        .padding(Theme.Spacing.medium)
        .accessibilityIdentifier("transcript-message-stepper")
      }
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void)
      -> some View
    {
      Button(action: action) {
        Image(systemName: symbol)
          .font(.body.weight(.semibold))
          .frame(width: Theme.Control.target, height: Theme.Control.target)
          .accessibilityLabel(label)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
    }
  }
#endif
