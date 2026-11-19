import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

extension ComposerAdapter {
  /// The stream's state under the composer while it is not live. A closed or superseded
  /// session has its own banner, so it shows nothing here.
  static func connection(_ store: ConversationStore) -> ComposerConnectionNotice? {
    guard !store.isClosed, store.supersededBy == nil,
      let message = ConversationAdapter.connectionStatus(store)
    else { return nil }
    if store.isOffline { return ComposerConnectionNotice(message: message, isOffline: true) }
    switch store.link {
    case .closed, .stopped, .failed:
      return ComposerConnectionNotice(message: message, isFailure: true)
    default: return ComposerConnectionNotice(message: message)
    }
  }
}

/// Why the connection dropped, in one plain line for the connection lines: what the system said,
/// without the layers that carried it ("Could not reach the server: connection failed:
/// offline: ..."), or what the failure means when the system said nothing a person would.
enum ConnectionReason {
  /// The plain line for `error`.
  static func text(_ error: CoreError) -> String {
    switch error {
    case .Transport(_, let message):
      return sentence(innermost(message))
    case .HttpStatus(let status, _):
      return "The server answered HTTP \(status)."
    case .Link(let kind, let message, _):
      switch kind {
      case .endOfStream, .socketClosed: return "The server closed the connection."
      case .stalled: return "The server stopped responding."
      default: return sentence(innermost(message))
      }
    default:
      return sentence(error.message)
    }
  }

  /// The last of the colon-separated layers: the system's own words.
  private static func innermost(_ message: String) -> String {
    let parts = message.components(separatedBy: ": ")
    return parts.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? message
  }

  /// `text` as a sentence: a capital first letter and a closing period.
  private static func sentence(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return trimmed }
    let capitalized = first.uppercased() + trimmed.dropFirst()
    return [".", "!", "?", ")"].contains { capitalized.hasSuffix($0) }
      ? capitalized : capitalized + "."
  }
}
