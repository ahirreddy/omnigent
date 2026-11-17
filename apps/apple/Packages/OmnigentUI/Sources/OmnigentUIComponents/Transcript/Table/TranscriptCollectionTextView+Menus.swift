#if os(iOS)
  import SwiftUI
  import UIKit

  /// A text row's menus and what VoiceOver offers: the message's context menu off its text,
  /// the edit menu's actions for a selection, and the row's actions on each element.
  extension TranscriptCollectionTextView: UIContextMenuInteractionDelegate {
    // MARK: Menus

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      // A long press on the text selects it; the edit menu has the message's actions too.
      guard message != nil, !isOnText(location) else { return nil }
      return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
        guard let self else { return nil }
        return UIMenu(children: self.messageMenu())
      }
    }

    /// Whether `point` is on the run's text.
    func isOnText(_ point: CGPoint) -> Bool {
      guard let runView, let frames else { return false }
      return CGRect(origin: runView.frame.origin, size: frames.run.size).contains(point)
    }

    /// The message's menu, as ``MessageContextMenu`` builds it on touch: Reply and Ask in side
    /// chat with the whole message, its actions (one that doesn't apply disabled, with why),
    /// Share, then Copy Message ID.
    func messageMenu() -> [UIMenuElement] {
      guard let message, let values = style.environment.values else { return [] }
      let row = message.row
      let actions = values.conversationActions
      let copy = values.copyWithConfirmation
      var sections: [UIMenuElement] = []
      let quotes = MessageActionItem.quoteItems(for: row, actions: actions).map(Self.menuAction)
      if !quotes.isEmpty { sections.append(UIMenu(options: .displayInline, children: quotes)) }
      var main: [UIMenuElement] = MessageActionItem.items(
        for: row, actions: actions, copy: copy
      ).map(Self.menuAction)
      let text = row.text
      let shareImage = UIImage(systemName: "square.and.arrow.up")
      let share = UIAction(title: "Share", image: shareImage) { [weak self] _ in
        self?.presentFromFront(
          UIActivityViewController(activityItems: [text], applicationActivities: nil))
      }
      if text.isEmpty { share.attributes = .disabled }
      main.append(share)
      sections.append(UIMenu(options: .displayInline, children: main))
      let id = row.id
      let copyID = UIAction(title: "Copy Message ID", image: UIImage(systemName: "number")) { _ in
        copy(id, confirmation: "Message ID copied")
      }
      sections.append(UIMenu(options: .displayInline, children: [copyID]))
      return sections
    }

    private static func menuAction(_ item: MessageActionItem) -> UIAction {
      let perform = item.perform
      let image = UIImage(systemName: item.systemImage)
      let action = UIAction(title: item.menuTitle, image: image) { _ in perform() }
      if let reason = item.unavailableReason {
        action.attributes = .disabled
        action.subtitle = reason
      }
      return action
    }

    /// What the edit menu offers for `selected` text after Copy: Reply and Ask in side chat
    /// quoting it, where the conversation has them, then the message's own menu.
    func selectionMenu(for selected: String) -> [UIMenuElement] {
      guard let values = style.environment.values else { return [] }
      let actions = values.conversationActions
      var own: [UIMenuElement] = []
      if let reply = actions.replyWithSelection {
        let image = UIImage(systemName: "arrowshape.turn.up.left")
        own.append(
          UIAction(title: "Reply", image: image) { [weak self] _ in
            self?.runView?.endSelecting()
            reply(selected)
          })
      }
      if let ask = actions.askInSideChat {
        let image = UIImage(systemName: "bubble.left.and.bubble.right")
        own.append(
          UIAction(title: "Ask in Side Chat", image: image) { [weak self] _ in
            self?.runView?.endSelecting()
            ask(selected)
          })
      }
      let menu = messageMenu()
      if !menu.isEmpty {
        let image = UIImage(systemName: "text.bubble")
        own.append(UIMenu(title: "Message", image: image, children: menu))
      }
      return own
    }

    // MARK: VoiceOver

    /// The message's actions, as its SwiftUI row offers them to VoiceOver: those that apply,
    /// then Reply and Ask in side chat with the whole message.
    func messageAccessibilityActions() -> [UIAccessibilityCustomAction] {
      guard let message, let values = style.environment.values else { return [] }
      let actions = values.conversationActions
      let items =
        MessageActionItem.items(
          for: message.row, actions: actions, copy: values.copyWithConfirmation
        ).filter { $0.unavailableReason == nil }
        + MessageActionItem.quoteItems(for: message.row, actions: actions)
      return items.map { item in
        let perform = item.perform
        return UIAccessibilityCustomAction(name: item.title) { _ in
          perform()
          return true
        }
      }
    }
  }
#endif
