#if os(macOS)
  import AppKit

  /// A text cell's actions to VoiceOver, as a SwiftUI message row's `accessibilityActions`: each
  /// action that applies, by its title.
  extension TranscriptTableTextCell {
    // AppKit's signature makes them optional.
    // swiftlint:disable:next discouraged_optional_collection
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
      guard let message, let values = style.environment.values else { return nil }
      let items = MessageActionItem.items(
        for: message.row, actions: values.conversationActions,
        copy: values.copyWithConfirmation)
      return items.filter { $0.unavailableReason == nil }.map { item in
        let perform = item.perform
        return NSAccessibilityCustomAction(name: item.title) {
          // VoiceOver performs an action on the main thread.
          MainActor.assumeIsolated { perform() }
          return true
        }
      }
    }
  }

  extension TranscriptTableController {
    /// Shows or hides the text cells' actions as VoiceOver turns on or off.
    func watchVoiceOver() {
      guard voiceOverWatch == nil else { return }
      voiceOverWatch = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
        MainRunLoop.perform {
          MainActor.assumeIsolated { self?.refreshTextCellActions() }
        }
      }
    }

    /// The text cells on screen show their actions or hide them again.
    func refreshTextCellActions() {
      tableView.enumerateAvailableRowViews { rowView, _ in
        guard rowView.numberOfColumns > 0 else { return }
        (rowView.view(atColumn: 0) as? TranscriptTableTextCell)?.refreshActions()
      }
    }
  }
#endif
