import Foundation
import Markdown

/// Recording links inside a sentence, which the web's chat draws as its compact player in place
/// of the link.
nonisolated extension MarkdownParser {
  /// `markup`'s blocks: its block, or for a paragraph whose text holds a link to a recording,
  /// the text before the link, the player, then the text after, as the web's chat puts the
  /// player where the link was.
  static func expanded(_ markup: any Markup) -> [MarkdownBlock] {
    guard let paragraph = markup as? Paragraph, paragraph.childCount > 1,
      paragraph.children.contains(where: { videoLink($0) != nil })
    else { return block(markup).map { [$0] } ?? [] }
    var result: [MarkdownBlock] = []
    var text = AttributedString()
    func flush() {
      if !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.append(.paragraph(text))
      }
      text = AttributedString()
    }
    for child in paragraph.children {
      if let video = videoLink(child) {
        flush()
        result.append(video)
      } else {
        text.append(inline(child))
      }
    }
    flush()
    return result
  }

  /// The player for a link to a recording; `nil` for anything else.
  private static func videoLink(_ markup: any Markup) -> MarkdownBlock? {
    guard let link = markup as? Markdown.Link, let destination = link.destination,
      MarkdownVideoSource(destination) != nil
    else { return nil }
    return .video(source: destination, title: String(inline(link.children).characters))
  }
}
