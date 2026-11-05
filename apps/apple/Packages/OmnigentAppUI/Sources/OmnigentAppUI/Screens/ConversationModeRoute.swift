import Observation
import OmnigentUIComponents

/// A conversation's Chat/Terminal choice, for a key-path binding (`$route.mode`). With tabs,
/// choosing Terminal opens the agent's TUI in its own tab and the chat stays on Chat.
///
/// A closure binding compares unequal on every update, so each navigation-bar update re-rendered
/// the conversation, which re-vended its bar items: a loop that held iPhone's main thread for
/// half a minute when a long session opened.
@Observable
final class ConversationModeRoute {
  private var stored: SessionViewMode = .chat
  /// Opens the harness tab; `nil` without tabs. The container sets it on each render.
  @ObservationIgnored var openHarness: (@MainActor () -> Void)?

  /// The mode the screen shows.
  var mode: SessionViewMode {
    get { openHarness == nil ? stored : .chat }
    set {
      if newValue == .terminal, let openHarness {
        openHarness()
      } else if stored != newValue {
        stored = newValue
      }
    }
  }
}
