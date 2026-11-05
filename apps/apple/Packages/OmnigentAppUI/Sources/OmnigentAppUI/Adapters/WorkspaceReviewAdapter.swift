import OmnigentCoreFFI
import OmnigentStores
import OmnigentWorkspaceUI

/// The file viewer's agent actions on the composer.
enum WorkspaceReviewAdapter {
  /// "Ask About This": attaches the span's lines and quotes its text in the draft, as the
  /// transcript's Reply quotes a selection.
  /// - Parameters:
  ///   - span: The selected lines.
  ///   - composer: The conversation's composer.
  static func ask(_ span: FileTextSpan, _ composer: ComposerStore) {
    composer.addMention(span.reference)
    composer.text = replyQuote(draft: composer.text, selection: span.text)
  }
}
