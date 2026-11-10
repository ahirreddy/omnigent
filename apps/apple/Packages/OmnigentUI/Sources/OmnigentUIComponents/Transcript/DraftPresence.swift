import SwiftUI

/// Whether the draft has text. Only what answers Command-Return reads it, so a draft's first
/// key does not run the conversation's body and rebuild the transcript beneath it.
@MainActor
@Observable
final class DraftPresence {
  private(set) var hasText = false

  /// Records the composer's report; an unchanged one notifies nobody.
  func report(_ hasText: Bool) {
    if hasText != self.hasText { self.hasText = hasText }
  }
}

/// What decides who answers Command-Return, read in the bodies that use the answer.
@MainActor
struct CommandReturnArbitration {
  let presence: DraftPresence
  /// The composer would send now, were there something to send.
  let sendIsOpen: Bool
  /// Attachments or mentions wait to go, with or without text.
  let hasAttachedContent: Bool
  /// The request whose Approve would take the shortcut, if any.
  let approvableCardID: String?

  /// The draft (or what is attached to it) can be sent now.
  var canSend: Bool {
    let hasText = presence.hasText
    return sendIsOpen && (hasText || hasAttachedContent)
  }

  /// Whether the menus offer Send Message. With no request waiting it is offered whenever the
  /// composer would send, without reading the draft: a first or last character changes nothing.
  var offersSend: Bool {
    approvableCardID == nil ? sendIsOpen : canSend
  }

  /// Send while the draft can go, else the active request's Approve. With no request waiting
  /// Send owns the key whatever the draft holds, so the draft is not read.
  var owner: CommandReturnOwner {
    guard let approvableCardID else { return .send }
    return .resolve(canSend: canSend, approvableCardID: approvableCardID)
  }
}

/// Tells the conversation's Send and Approve which of them owns Command-Return.
struct CommandReturnOwnership: ViewModifier {
  let arbitration: CommandReturnArbitration

  func body(content: Content) -> some View {
    content.environment(\.commandReturnOwner, arbitration.owner)
  }
}

/// The inline card's Approve takes Command-Return while the draft does not own it.
struct InlineApproveShortcut: ViewModifier {
  let target: DecisionShortcutTarget?
  @Environment(\.commandReturnOwner) private var owner

  func body(content: Content) -> some View {
    content.decisionApproveShortcut(target, on: .inline, owner: owner)
  }
}
