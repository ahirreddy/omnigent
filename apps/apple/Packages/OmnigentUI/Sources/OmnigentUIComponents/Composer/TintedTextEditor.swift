import SwiftUI

/// The composer's text view over a plain-text draft, with its leading command, a shell
/// command's `!` and tagged mentions tinted (``ComposerTokens``). The editor holds an
/// `AttributedString` of its own: typing changes it and the draft follows, and a draft set from
/// outside (a completion, a recalled prompt, a send) replaces it. Only the tints are kept as
/// attributes; anything else a paste or a format command adds is dropped.
struct TintedTextEditor: View {
  @Binding var text: String
  let source: ComposerTokenSource

  @State private var editor = AttributedString()
  @State private var selection = SelectionBox()
  @Environment(\.controlAccent) private var accent

  var body: some View {
    let style = TintStyle(source: source, tint: accent, fill: accent.opacity(0.12))
    TextEditor(text: typed, selection: selected)
      .onChange(of: editor) { retint(style) }
      .onChange(of: text, initial: true) { draftChanged(style) }
      .onChange(of: style) { retint(style) }
  }

  /// The tints and what they follow.
  private struct TintStyle: Equatable {
    let source: ComposerTokenSource
    let tint: Color
    let fill: Color

    /// `plain` with only its tokens' tints.
    func styled(_ plain: String) -> AttributedString {
      var text = AttributedString(plain)
      apply(to: &text, plain: plain)
      return text
    }

    /// Whether `text`'s tints sit on `plain`'s tokens; attributes the editor adds don't count.
    func isTinted(_ text: AttributedString, plain: String) -> Bool {
      spans(of: text) == spans(of: styled(plain))
    }

    private func spans(of text: AttributedString) -> [TintSpan] {
      text.runs.compactMap { run in
        let foreground: Color? = run.foregroundColor
        let background: Color? = run.backgroundColor
        guard foreground != nil || background != nil else { return nil }
        return TintSpan(
          start: text.characters.distance(from: text.startIndex, to: run.range.lowerBound),
          end: text.characters.distance(from: text.startIndex, to: run.range.upperBound),
          foreground: foreground, background: background)
      }
    }

    /// Clears every attribute of `text`, then tints its tokens.
    func apply(to text: inout AttributedString, plain: String) {
      text.setAttributes(AttributeContainer())
      for token in ComposerTokens(draft: plain, source: source).tokens {
        let start = text.characters.index(text.startIndex, offsetBy: token.range.lowerBound)
        let end = text.characters.index(start, offsetBy: token.range.count)
        text[start..<end].foregroundColor = tint
        if token.kind == .mention { text[start..<end].backgroundColor = fill }
      }
    }
  }

  /// A tinted run, by character offsets.
  private struct TintSpan: Equatable {
    let start: Int
    let end: Int
    let foreground: Color?
    let background: Color?
  }

  /// The caret and selection, outside SwiftUI's state: moving them needs no update of the view.
  private final class SelectionBox {
    var value = AttributedTextSelection()
  }

  private var selected: Binding<AttributedTextSelection> {
    Binding(get: { selection.value }, set: { selection.value = $0 })
  }

  /// The editor's text: typing changes it and the draft in the same update, so a key lays the
  /// window out once; the tints follow it.
  private var typed: Binding<AttributedString> {
    Binding(
      get: { editor },
      set: { typed in
        editor = typed
        let plain = String(typed.characters)
        if plain != text { text = plain }
      })
  }

  /// A draft set from outside replaces the editor's text, with the caret at its end.
  private func draftChanged(_ style: TintStyle) {
    guard String(editor.characters) != text else { return }
    editor = style.styled(text)
    selection.value = AttributedTextSelection(insertionPoint: editor.endIndex)
  }

  /// Puts the tints where the text's tokens are now, keeping the selection, when they moved
  /// (a character typed after a token takes its tint until here).
  private func retint(_ style: TintStyle) {
    let plain = String(editor.characters)
    guard !style.isTinted(editor, plain: plain) else { return }
    editor.transform(updating: &selection.value) { text in style.apply(to: &text, plain: plain) }
  }
}
