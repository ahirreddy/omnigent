#if os(macOS)
  public import AppKit

  /// Where composed text goes: the page's renderer, local or remote.
  public protocol TextInputSink: AnyObject {
    /// A plain key with no IME involvement: RawKeyDown plus Char, as without an input method.
    /// - Parameter event: The key-down.
    func forwardKeyEvent(_ event: NSEvent)
    /// Inserts committed text.
    /// - Parameters:
    ///   - text: The text.
    ///   - replacementRange: What it replaces, or `NSNotFound`.
    func commitText(_ text: String, replacementRange: NSRange)
    /// Shows or updates the composition (marked text).
    /// - Parameters:
    ///   - text: The marked text.
    ///   - selectedRange: The selection inside it.
    ///   - replacementRange: What it replaces, or `NSNotFound`.
    func setComposition(_ text: String, selectedRange: NSRange, replacementRange: NSRange)
    /// Commits the composition as it stands.
    /// - Parameter keepSelection: Keep the selection instead of moving the caret to the end.
    func finishComposing(keepSelection: Bool)
    /// Drops the composition.
    func cancelComposition()
  }

  /// IME composition through `NSTextInputClient`, on the model of Chromium's own Mac view: a
  /// key-down runs the input context, and what it did decides between plain key events, a
  /// composition update, or committed text. A view conforms to `NSTextInputClient` by forwarding
  /// the marked-text callbacks here. A class because `handleEvent` re-enters the callbacks.
  public final class TextInputComposer {
    /// Receives the result.
    public weak var sink: (any TextInputSink)?
    /// The current marked text.
    public private(set) var markedText = ""
    /// Whether there is marked text.
    public private(set) var hasMarkedText = false
    private var markedSelection = NSRange(location: 0, length: 0)
    private var markedReplacement = NSRange(location: NSNotFound, length: 0)
    /// Set while `keyDown` runs the input context; callbacks are collected, then sent once.
    private var handlingKeyDown = false
    private var insertedText = ""
    private var insertedReplacement = NSRange(location: NSNotFound, length: 0)
    private var unmarkCalled = false

    /// Creates a composer.
    /// - Parameter sink: Where results go.
    public init(sink: (any TextInputSink)? = nil) {
      self.sink = sink
    }

    /// Runs a key-down through `context` and sends what the input method did.
    /// - Parameters:
    ///   - event: The key-down.
    ///   - context: The view's input context.
    public func keyDown(_ event: NSEvent, context: NSTextInputContext?) {
      let hadMarkedText = hasMarkedText
      handlingKeyDown = true
      insertedText = ""
      insertedReplacement = NSRange(location: NSNotFound, length: 0)
      unmarkCalled = false
      // The result is always true for a view with an input context; what matters is which
      // NSTextInputClient callbacks ran.
      _ = context?.handleEvent(event)
      handlingKeyDown = false
      guard let sink else { return }
      if !hasMarkedText, !hadMarkedText {
        if insertedText.utf16.count <= 1 {
          sink.forwardKeyEvent(event)
        } else {
          sink.commitText(insertedText, replacementRange: insertedReplacement)
        }
        return
      }
      if !insertedText.isEmpty {
        sink.commitText(insertedText, replacementRange: insertedReplacement)
      } else if hasMarkedText, !markedText.isEmpty {
        sink.setComposition(
          markedText, selectedRange: markedSelection, replacementRange: markedReplacement)
      } else if hadMarkedText, !hasMarkedText {
        if unmarkCalled {
          sink.finishComposing(keepSelection: false)
        } else {
          sink.cancelComposition()
        }
      }
    }

    /// `NSTextInputClient.insertText(_:replacementRange:)`.
    /// - Parameters:
    ///   - string: A `String` or `NSAttributedString`.
    ///   - replacementRange: What it replaces.
    public func insertText(_ string: Any, replacementRange: NSRange) {
      let text = Self.plainText(string)
      hasMarkedText = false
      markedText = ""
      if handlingKeyDown {
        insertedText += text
        insertedReplacement = replacementRange
      } else {
        // Not from a key (emoji palette, dictation, a simulated input method).
        sink?.commitText(text, replacementRange: replacementRange)
      }
    }

    /// `NSTextInputClient.setMarkedText(_:selectedRange:replacementRange:)`.
    /// - Parameters:
    ///   - string: A `String` or `NSAttributedString`.
    ///   - selectedRange: The selection inside it.
    ///   - replacementRange: What it replaces.
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
      let text = Self.plainText(string)
      markedText = text
      markedSelection = selectedRange
      markedReplacement = replacementRange
      hasMarkedText = !text.isEmpty
      guard !handlingKeyDown else { return }
      if text.isEmpty {
        sink?.cancelComposition()
      } else {
        sink?.setComposition(text, selectedRange: selectedRange, replacementRange: replacementRange)
      }
    }

    /// `NSTextInputClient.unmarkText()`.
    public func unmarkText() {
      hasMarkedText = false
      markedText = ""
      unmarkCalled = true
      if !handlingKeyDown {
        sink?.finishComposing(keepSelection: false)
      }
    }

    /// `NSTextInputClient.markedRange()`.
    public var markedRange: NSRange {
      hasMarkedText
        ? NSRange(location: 0, length: markedText.utf16.count)
        : NSRange(location: NSNotFound, length: 0)
    }

    /// `NSTextInputClient.validAttributesForMarkedText()`.
    public static let validAttributesForMarkedText: [NSAttributedString.Key] = [
      .underlineStyle, .underlineColor, .backgroundColor,
    ]

    private static func plainText(_ string: Any) -> String {
      if let attributed = string as? NSAttributedString {
        return attributed.string
      }
      return string as? String ?? ""
    }
  }
#endif
