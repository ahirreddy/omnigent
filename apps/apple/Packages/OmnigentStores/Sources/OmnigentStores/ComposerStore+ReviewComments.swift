import Foundation
public import OmnigentCoreFFI

/// Local review comments attached to the draft, as the web's composer chips: each goes after the
/// message's text as the snapshot the agent reads (`formatLocalReviewComments`).
extension ComposerStore {
  /// Attaches a comment, once.
  /// - Parameter comment: The comment.
  public func attachReviewComment(_ comment: LocalReviewComment) {
    guard !reviewComments.contains(where: { $0.id == comment.id }) else { return }
    reviewComments.append(comment)
  }

  /// Takes a comment off the draft.
  /// - Parameter id: The comment.
  public func detachReviewComment(_ id: String) {
    reviewComments.removeAll { $0.id == id }
  }

  /// `message` with the attached comments after it; the instruction leads only when the draft
  /// has no text of its own.
  func withReviewComments(_ message: String) -> String {
    guard !reviewComments.isEmpty else { return message }
    let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let authored = !blank(text) || quotes.contains { !blank($0.before) }
    let context = formatLocalReviewComments(
      comments: reviewComments, includeInstruction: !authored)
    return blank(message) ? context : "\(message)\n\n\(context)"
  }
}
