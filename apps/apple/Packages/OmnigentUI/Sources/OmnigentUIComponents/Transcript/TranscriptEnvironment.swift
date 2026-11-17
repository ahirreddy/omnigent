import Foundation
import SwiftUI

/// Keeps the transcript's environment values stable across updates, as ``FocusedActionsRelay``
/// does for focused values: a new `ConversationActions` or `OpenURLAction` in the environment
/// would re-render every row that reads it on every streamed delta.
@MainActor
final class TranscriptEnvironmentRelay {
  private let relay = FocusedActionsRelay<ConversationActions>()
  private var openLink: (@MainActor (URL) -> Void)?

  /// Opens links through the latest actions' `openURL`, or the system when there is none.
  private(set) lazy var openURL = OpenURLAction { [weak self] url in
    guard let open = self?.openLink else { return .systemAction }
    open(url)
    return .handled
  }

  /// How many times new actions were published.
  var publications: Int { relay.publications }

  /// The actions ``publish(_:)`` last returned.
  private(set) var actions = ConversationActions()

  /// The actions to put in the environment: the last value while the same actions exist, with
  /// closures that call `actions`'.
  /// - Parameter actions: The current actions.
  /// - Returns: The stable actions.
  func publish(_ actions: ConversationActions) -> ConversationActions {
    openLink = actions.openURL
    self.actions = relay.publish(actions) ?? actions
    return self.actions
  }
}

/// Puts the transcript's actions, link opener and scroll state in its rows' environment. Its
/// inputs are references and the relay's publication count, so a transcript render that
/// publishes nothing new writes nothing: written in the transcript's body, these made every
/// selectable text in the rows resolve again and update its AppKit view on each render.
struct TranscriptEnvironment: ViewModifier {
  let relay: TranscriptEnvironmentRelay
  /// Changes when the relay publishes new actions.
  let publications: Int
  /// The stack's scroll state; the table transcript has none.
  let scroll: TranscriptScrollState?

  func body(content: Content) -> some View {
    content
      .environment(\.conversationActions, relay.actions)
      .environment(\.openURL, relay.openURL)
      .environment(\.transcriptScrollState, scroll)
  }
}
