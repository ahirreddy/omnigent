import SwiftUI

#if os(macOS)
  import AppKit
  typealias PlatformTextView = NSTextView
#else
  import UIKit
  typealias PlatformTextView = UITextView
#endif

/// Drives the editor's text view from outside it: the Markdown toolbar's formats, as undoable
/// edits.
@MainActor
final class CodeEditorController {
  weak var textView: PlatformTextView?

  /// Applies `format` to the selection.
  func apply(_ format: MarkdownFormat) {
    guard let textView else { return }
    #if os(macOS)
      let replacement = MarkdownFormatting.apply(
        format, to: textView.string, selection: textView.selectedRange())
      guard textView.shouldChangeText(in: replacement.range, replacementString: replacement.text)
      else { return }
      unsafe textView.textStorage?.replaceCharacters(in: replacement.range, with: replacement.text)
      textView.didChangeText()
      textView.setSelectedRange(replacement.selection)
      unsafe textView.window?.makeFirstResponder(textView)
    #else
      let replacement = MarkdownFormatting.apply(
        format, to: textView.text, selection: textView.selectedRange)
      guard
        let start = textView.position(
          from: textView.beginningOfDocument, offset: replacement.range.location),
        let end = textView.position(from: start, offset: replacement.range.length),
        let range = textView.textRange(from: start, to: end)
      else { return }
      textView.replace(range, withText: replacement.text)
      // The editor ignores a repeated report when UIKit already sent one.
      textView.delegate?.textViewDidChange?(textView)
      textView.selectedRange = replacement.selection
      textView.becomeFirstResponder()
    #endif
  }
}

/// The editor's text view (AppKit or UIKit, for undo, find and fast typing in long files) over
/// a ``FileEditor``: typing writes ``FileEditor/text``, and the text view reloads only when the
/// editor's text is replaced (``FileEditor/textRevision``).
struct CodeEditorTextView {
  let editor: FileEditor
  let language: SyntaxLanguage?
  let controller: CodeEditorController
  /// Reports a selection of at least one character, or `nil`.
  let onSelection: (NSRange?) -> Void
  @Environment(\.colorScheme) private var scheme

  /// Keeps the text view and the editor in step.
  final class Coordinator: NSObject {
    let highlighter: EditorHighlighter
    var editor: FileEditor
    var revision: Int
    var onSelection: (NSRange?) -> Void
    private var lastSelection: NSRange?

    init(
      editor: FileEditor, language: SyntaxLanguage?, scheme: ColorScheme,
      onSelection: @escaping (NSRange?) -> Void
    ) {
      highlighter = EditorHighlighter(language: language, scheme: scheme)
      self.editor = editor
      revision = editor.textRevision
      self.onSelection = onSelection
    }

    /// Colors `storage` as it changes and fills it with the editor's text.
    func load(_ storage: NSTextStorage?) {
      guard let storage else { return }
      storage.delegate = highlighter
      storage.replaceCharacters(
        in: NSRange(location: 0, length: storage.length), with: editor.text)
    }

    /// Typing: the editor reads `storage` (kept alive here) only when it needs the text.
    func textChanged(_ storage: NSTextStorage?) {
      guard let storage else { return }
      // A native copy: a bridged string would be slow to compare and hash.
      // swiftlint:disable:next optional_data_string_conversion
      editor.textEdited { String(decoding: Array(storage.string.utf8), as: UTF8.self) }
    }

    func selectionChanged(_ range: NSRange) {
      let selection = range.length > 0 ? range : nil
      guard selection != lastSelection else { return }
      lastSelection = selection
      onSelection(selection)
    }

    /// Loads the editor's text into `storage` when it was replaced, or recolors after a theme
    /// change.
    func sync(_ storage: NSTextStorage?, editor: FileEditor, scheme: ColorScheme) {
      guard let storage else { return }
      if editor !== self.editor || editor.textRevision != revision {
        self.editor = editor
        revision = editor.textRevision
        // The storage's delegate colors the replaced text.
        storage.replaceCharacters(
          in: NSRange(location: 0, length: storage.length), with: editor.text)
      } else if highlighter.update(scheme: scheme) {
        highlighter.highlightInBackground(storage)
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(editor: editor, language: language, scheme: scheme, onSelection: onSelection)
  }
}

#if os(macOS)
  extension CodeEditorTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
      let scrollView = NSTextView.scrollableTextView()
      guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
      textView.isRichText = false
      textView.importsGraphics = false
      textView.allowsUndo = true
      textView.usesFindBar = true
      textView.isIncrementalSearchingEnabled = true
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      textView.isAutomaticTextReplacementEnabled = false
      textView.isAutomaticSpellingCorrectionEnabled = false
      textView.isContinuousSpellCheckingEnabled = false
      textView.smartInsertDeleteEnabled = false
      textView.textContainerInset = NSSize(width: 6, height: 8)
      textView.typingAttributes = context.coordinator.highlighter.baseAttributes
      textView.delegate = context.coordinator
      textView.setAccessibilityIdentifier("workspace.editor")
      unsafe context.coordinator.load(textView.textStorage)
      controller.textView = textView
      return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
      context.coordinator.onSelection = onSelection
      guard let textView = scrollView.documentView as? NSTextView else { return }
      controller.textView = textView
      unsafe context.coordinator.sync(textView.textStorage, editor: editor, scheme: scheme)
    }
  }

  extension CodeEditorTextView.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      unsafe textChanged(textView.textStorage)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      selectionChanged(textView.selectedRange())
    }
  }
#else
  extension CodeEditorTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
      let textView = UITextView()
      textView.autocorrectionType = .no
      textView.autocapitalizationType = .none
      textView.spellCheckingType = .no
      textView.smartQuotesType = .no
      textView.smartDashesType = .no
      textView.smartInsertDeleteType = .no
      textView.keyboardDismissMode = .interactive
      textView.alwaysBounceVertical = true
      textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
      textView.typingAttributes = context.coordinator.highlighter.baseAttributes
      textView.delegate = context.coordinator
      textView.accessibilityIdentifier = "workspace.editor"
      context.coordinator.load(textView.textStorage)
      controller.textView = textView
      return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
      context.coordinator.onSelection = onSelection
      controller.textView = textView
      context.coordinator.sync(textView.textStorage, editor: editor, scheme: scheme)
    }
  }

  extension CodeEditorTextView.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
      textChanged(textView.textStorage)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      selectionChanged(textView.selectedRange)
    }
  }
#endif
