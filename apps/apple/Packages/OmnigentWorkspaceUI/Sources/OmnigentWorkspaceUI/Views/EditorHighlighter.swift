import SwiftUI

#if os(macOS)
  import AppKit
  typealias PlatformColor = NSColor
  typealias PlatformFont = NSFont
  typealias TextEditActions = NSTextStorageEditActions
#else
  import UIKit
  typealias PlatformColor = UIColor
  typealias PlatformFont = UIFont
  typealias TextEditActions = NSTextStorage.EditActions
#endif

/// Colors the editor's text as the source view does (``SyntaxHighlighter/spans(in:)`` per
/// line). After a typed edit only the edited lines are colored again, so a keystroke costs one
/// line however long the file is; a whole file (loading, a paste, a theme change) is scanned off
/// the main actor and colored when the scan is done.
final class EditorHighlighter: NSObject, NSTextStorageDelegate {
  /// One colored range of the text.
  nonisolated struct Colored: Sendable {
    var range: NSRange
    var token: SyntaxToken
  }

  /// Edits longer than this (UTF-16 units) are colored in the background.
  static let backgroundThreshold = 4_000

  private var highlighter: SyntaxHighlighter?
  private var font: PlatformFont
  private var colors: [SyntaxToken: PlatformColor] = [:]
  private(set) var scheme: ColorScheme
  /// Counts character edits, so a background scan of an older text is not applied.
  private var generation = 0
  private var background: Task<Void, Never>?

  /// A highlighter for `language` (plain text when `nil`).
  init(language: SyntaxLanguage?, scheme: ColorScheme) {
    highlighter = language.map { SyntaxHighlighter(language: $0) }
    font = Self.codeFont
    self.scheme = scheme
    super.init()
    colors = Self.colors(scheme)
  }

  /// The editor's font: the code typography at the source view's size.
  static var codeFont: PlatformFont {
    let typography = CodeTypography.shared
    let size = (12 * typography.scale).rounded()
    let weight: PlatformFont.Weight = typography.isHeavier ? .medium : .regular
    if !typography.family.isEmpty, let custom = PlatformFont(name: typography.family, size: size) {
      return custom
    }
    return .monospacedSystemFont(ofSize: size, weight: weight)
  }

  /// The attributes of uncolored text.
  var baseAttributes: [NSAttributedString.Key: Any] {
    #if os(macOS)
      [.font: font, .foregroundColor: NSColor.textColor]
    #else
      [.font: font, .foregroundColor: UIColor.label]
    #endif
  }

  /// Switches to `scheme`'s colors; the caller colors the whole text again.
  func update(scheme: ColorScheme) -> Bool {
    guard scheme != self.scheme else { return false }
    self.scheme = scheme
    colors = Self.colors(scheme)
    return true
  }

  /// Scans all of `storage` off the main actor and colors it when done; an edit made meanwhile
  /// starts the scan again.
  func highlightInBackground(_ storage: NSTextStorage) {
    background?.cancel()
    guard let highlighter else { return }
    let scanned = generation
    let text = storage.string
    background = Task { [weak self, weak storage] in
      let colored = await Self.scan(text, highlighter)
      guard !Task.isCancelled, let self, let storage else { return }
      guard scanned == self.generation else { return self.highlightInBackground(storage) }
      self.apply(colored, to: storage)
    }
  }

  /// Waits for a background scan, for tests.
  func backgroundScanned() async { await background?.value }

  func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: TextEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    generation += 1
    let lines = textStorage.mutableString.paragraphRange(for: editedRange)
    guard lines.length <= Self.backgroundThreshold else {
      textStorage.setAttributes(baseAttributes, range: lines)
      highlightInBackground(textStorage)
      return
    }
    highlight(textStorage, in: lines)
  }

  private func highlight(_ storage: NSTextStorage, in range: NSRange) {
    storage.setAttributes(baseAttributes, range: range)
    guard let highlighter else { return }
    let text = storage.mutableString
    unsafe text.enumerateSubstrings(in: range, options: [.byLines]) { line, lineRange, _, _ in
      guard let line, !line.isEmpty else { return }
      for span in highlighter.spans(in: line) {
        guard let color = self.colors[span.token] else { continue }
        let spanRange = NSRange(
          location: lineRange.location + span.range.lowerBound, length: span.range.count)
        storage.addAttribute(.foregroundColor, value: color, range: spanRange)
      }
    }
  }

  private func apply(_ colored: [Colored], to storage: NSTextStorage) {
    let whole = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: whole)
    for span in colored where NSMaxRange(span.range) <= whole.length {
      guard let color = colors[span.token] else { continue }
      storage.addAttribute(.foregroundColor, value: color, range: span.range)
    }
    storage.endEditing()
  }

  /// The colored ranges of `text`, line by line, in UTF-16 offsets.
  @concurrent
  nonisolated
    private static func scan(_ text: String, _ highlighter: SyntaxHighlighter) async -> [Colored]
  {
    var colored: [Colored] = []
    var offset = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(line)
      for span in highlighter.spans(in: line) {
        colored.append(
          Colored(
            range: NSRange(location: offset + span.range.lowerBound, length: span.range.count),
            token: span.token))
      }
      offset += line.utf16.count + 1
    }
    return colored
  }

  private static func colors(_ scheme: ColorScheme) -> [SyntaxToken: PlatformColor] {
    let tokens: [SyntaxToken] = [.keyword, .string, .comment, .number, .type]
    return Dictionary(
      uniqueKeysWithValues: tokens.map {
        ($0, PlatformColor(WorkspaceTheme.tokenColor($0, scheme)))
      })
  }
}
