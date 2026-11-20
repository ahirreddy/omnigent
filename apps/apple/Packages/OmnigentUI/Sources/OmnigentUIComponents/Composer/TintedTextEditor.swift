import SwiftUI

/// The composer's text view over a plain-text draft, with its leading command, a shell
/// command's `!` and tagged mentions tinted (``ComposerTokens``). The editor holds an
/// `AttributedString` of its own: typing changes it and the draft follows, and a draft set from
/// outside (a completion, a recalled prompt, a send) replaces it. Only the tints are kept as
/// attributes; anything else a paste or a format command adds is dropped.
///
/// The text view writes its text while it holds its storage, where an update of the view traps
/// on the storage's exclusive access. So the text lives outside SwiftUI's state, and the draft
/// and tints follow in a run loop block, before the window draws: a key lays out once.
struct TintedTextEditor: View {
  @Binding var text: String
  let source: ComposerTokenSource
  /// The untinted text's color. Every character carries one: text with none draws black, even
  /// in dark mode.
  var textColor: Color = Self.systemText

  @State private var editor = EditorBox()
  @State private var selection = SelectionBox()
  /// Bumped when the editor's text changes other than by typing, so the text view takes it.
  @State private var revision = 0
  @Environment(\.controlAccent) private var accent

  var body: some View {
    let style = TintStyle(
      source: source, base: textColor, tint: accent, fill: accent.opacity(0.12))
    TextEditor(text: typed(style), selection: selected)
      // Read here so a bump draws the text view with the box's new text.
      .onChange(of: revision) {}
      .onChange(of: text, initial: true) { draftChanged(style) }
      .onChange(of: style) { if retint(style) { revision += 1 } }
  }

  /// The tints and what they follow.
  private struct TintStyle: Equatable {
    let source: ComposerTokenSource
    let base: Color
    let tint: Color
    let fill: Color

    /// `plain` with only its tokens' tints.
    func styled(_ plain: String) -> AttributedString {
      var text = AttributedString(plain)
      apply(to: &text, plain: plain)
      return text
    }

    /// Whether `text`'s colors are `plain`'s: the base color with its tokens' tints. Other
    /// attributes the editor adds don't count.
    func isTinted(_ text: AttributedString, plain: String) -> Bool {
      spans(of: text) == spans(of: styled(plain))
    }

    /// The colored runs, with neighbours of the same colors joined.
    private func spans(of text: AttributedString) -> [TintSpan] {
      var spans: [TintSpan] = []
      for run in text.runs {
        let foreground: Color? = run.foregroundColor
        let background: Color? = run.backgroundColor
        let start = text.characters.distance(from: text.startIndex, to: run.range.lowerBound)
        let end = text.characters.distance(from: text.startIndex, to: run.range.upperBound)
        if let last = spans.last, last.foreground == foreground, last.background == background {
          spans[spans.count - 1] = TintSpan(
            start: last.start, end: end, foreground: foreground, background: background)
        } else {
          spans.append(
            TintSpan(start: start, end: end, foreground: foreground, background: background))
        }
      }
      return spans
    }

    /// Clears every attribute of `text`, gives it the base color, then tints its tokens.
    func apply(to text: inout AttributedString, plain: String) {
      var base = AttributeContainer()
      base.foregroundColor = self.base
      text.setAttributes(base)
      for token in ComposerTokens(draft: plain, source: source).tokens {
        let start = text.characters.index(text.startIndex, offsetBy: token.range.lowerBound)
        let end = text.characters.index(start, offsetBy: token.range.count)
        text[start..<end].foregroundColor = tint
        if token.kind == .mention { text[start..<end].backgroundColor = fill }
      }
    }
  }

  /// The system's text color, light or dark with the appearance.
  static let systemText: Color = {
    #if os(macOS)
      Color(nsColor: .textColor)
    #else
      Color(uiColor: .label)
    #endif
  }()

  /// A colored run, by character offsets.
  private struct TintSpan: Equatable {
    let start: Int
    let end: Int
    let foreground: Color?
    let background: Color?
  }

  /// The editor's text, outside SwiftUI's state: typing it needs no update of the view.
  private final class EditorBox {
    var value = AttributedString()
  }

  /// The caret and selection, outside SwiftUI's state: moving them needs no update of the view.
  private final class SelectionBox {
    var value = AttributedTextSelection()
  }

  private var selected: Binding<AttributedTextSelection> {
    Binding(get: { selection.value }, set: { selection.value = $0 })
  }

  /// The editor's text. The text view sets it while it holds its storage; the draft and tints
  /// follow once it lets go.
  private func typed(_ style: TintStyle) -> Binding<AttributedString> {
    Binding(
      get: { editor.value },
      set: { typed in
        editor.value = typed
        // A run loop block, not the main queue: it runs in a nested run loop too.
        RunLoop.main.perform(inModes: [.common]) {
          MainActor.assumeIsolated { follow(style) }
        }
      })
  }

  /// The draft follows the typed text and the tints its tokens; either change draws the text
  /// view again in one update.
  private func follow(_ style: TintStyle) {
    let retinted = retint(style)
    let plain = String(editor.value.characters)
    if plain != text {
      text = plain
    } else if retinted {
      revision += 1
    }
  }

  /// A draft set from outside replaces the editor's text, with the caret at its end.
  private func draftChanged(_ style: TintStyle) {
    guard String(editor.value.characters) != text else { return }
    editor.value = style.styled(text)
    selection.value = AttributedTextSelection(insertionPoint: editor.value.endIndex)
    revision += 1
  }

  /// Puts the tints where the text's tokens are now, keeping the selection, when they moved
  /// (a character typed after a token takes its tint until here).
  /// - Returns: Whether the tints moved.
  private func retint(_ style: TintStyle) -> Bool {
    let plain = String(editor.value.characters)
    guard !style.isTinted(editor.value, plain: plain) else { return false }
    editor.value.transform(updating: &selection.value) { text in
      style.apply(to: &text, plain: plain)
    }
    return true
  }
}
