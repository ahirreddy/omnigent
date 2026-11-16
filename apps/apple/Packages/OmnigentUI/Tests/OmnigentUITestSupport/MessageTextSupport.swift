#if os(macOS)
  import AppKit
  import SwiftUI

  @testable import OmnigentUIComponents

  /// Builds TextKit message documents and reads their attributes.
  @MainActor
  enum MessageTextFixture {
    static let ramp = TypeRamp(body: TypeRamp.defaultBody)

    static var style: MessageTextStyle {
      MessageTextStyle(environment: EnvironmentValues(), code: MessageCodeFont())
    }

    /// The document for all of `markdown`, as one text run.
    static func document(_ markdown: String) -> MessageTextDocument {
      var builder = MessageTextBuilder(palette: MessageTextPalette(style), links: nil)
      return builder.document(MarkdownParser.parse(markdown))
    }

    /// Where `word` starts in `text`, after the first `after` when given.
    static func offset(of word: String, in text: NSAttributedString, after: String? = nil) -> Int {
      let string = text.string
      var start = string.startIndex
      if let after, let found = string.range(of: after) { start = found.upperBound }
      guard let found = string.range(of: word, range: start..<string.endIndex) else { return -1 }
      return string.utf16.distance(from: string.startIndex, to: found.lowerBound)
    }

    static func value<Value>(
      _ key: NSAttributedString.Key, at offset: Int, in text: NSAttributedString,
      as _: Value.Type
    ) -> Value? {
      guard offset >= 0, offset < text.length else { return nil }
      // Nothing reads the effective range back.
      return unsafe text.attribute(key, at: offset, effectiveRange: nil) as? Value
    }

    static func value<Value>(
      _ key: NSAttributedString.Key, at word: String, in text: NSAttributedString,
      as type: Value.Type
    ) -> Value? {
      value(key, at: offset(of: word, in: text), in: text, as: type)
    }

    static func font(at offset: Int, in text: NSAttributedString) -> NSFont? {
      value(.font, at: offset, in: text, as: NSFont.self)
    }

    static func font(at word: String, in text: NSAttributedString) -> NSFont? {
      font(at: offset(of: word, in: text), in: text)
    }

    static func paragraph(at offset: Int, in text: NSAttributedString) -> NSParagraphStyle? {
      value(.paragraphStyle, at: offset, in: text, as: NSParagraphStyle.self)
    }

    /// A font's weight, as its traits say.
    static func weight(of font: NSFont) -> CGFloat {
      let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
      return (traits?[.weight] as? CGFloat) ?? 0
    }
  }
#endif
