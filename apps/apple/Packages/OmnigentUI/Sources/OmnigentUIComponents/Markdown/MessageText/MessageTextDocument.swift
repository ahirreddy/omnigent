#if os(macOS)
  import AppKit
  import Synchronization

  /// A control drawn over a block: a code block's header or a table's Copy menu.
  nonisolated enum MessageTextChrome: Sendable {
    case code(code: String, language: String?)
    case table(MarkdownTable)
  }

  /// A run of a message's markdown as one attributed string, built once per text and style and
  /// shared by every view that shows it (``MessageTextDocuments``). Built on or off the main
  /// actor; nothing in it changes after, except a prepared layout handed over once.
  nonisolated final class MessageTextDocument: @unchecked Sendable {
    /// Tells documents apart without hashing their text: views and heights are kept by it.
    let serial: UInt64
    let text: NSAttributedString
    let palette: MessageTextPalette
    /// Each block's control, by block.
    let chrome: [Int: MessageTextChrome]
    /// Each link and where it is.
    let links: [(range: NSRange, url: URL)]
    /// Code blocks span the column, so a user's bubble holding one is as wide as it can be.
    let hasWideBlocks: Bool
    /// Space above the first line: TextKit drops a first paragraph's spacing, so the view adds it.
    let topInset: CGFloat

    private static let serials = Atomic<UInt64>(0)
    /// Its text laid out off the main actor, for the first view that shows it.
    private let prepared = Mutex<MessageTextPreparedLayout?>(nil)

    init(
      text: NSAttributedString, palette: MessageTextPalette, chrome: [Int: MessageTextChrome],
      hasWideBlocks: Bool, topInset: CGFloat = 0
    ) {
      serial = Self.serials.add(1, ordering: .relaxed).newValue
      self.text = text
      self.palette = palette
      self.chrome = chrome
      self.hasWideBlocks = hasWideBlocks
      self.topInset = topInset
      var links: [(range: NSRange, url: URL)] = []
      // The block's third argument is AppKit's stop pointer, unused here.
      let whole = NSRange(location: 0, length: text.length)
      unsafe text.enumerateAttribute(.link, in: whole) { value, range, _ in
        if let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) {
          links.append((range, url))
        }
      }
      self.links = links
    }

    /// Keeps `layout` for the next view that shows this document.
    func offer(_ layout: MessageTextPreparedLayout) {
      prepared.withLock { $0 = layout }
    }

    /// The layout prepared off the main actor, once; a text container shows in one view.
    func takePreparedLayout() -> MessageTextPreparedLayout? {
      prepared.withLock { kept in
        defer { kept = nil }
        return kept
      }
    }
  }

  /// What a document is built from: one text piece of a message, its style and which of the
  /// workspace paths it cites link.
  nonisolated struct MessageTextDocumentKey: Hashable, Sendable {
    var text: String
    var piece: Int
    var style: MessageTextStyle
    var linked: [URL?]
  }

  /// Built documents, so a row scrolled back into view finds its text already built.
  final class MessageTextDocuments {
    static let shared = MessageTextDocuments(limit: 512)

    private var entries: BoundedCache<MessageTextDocumentKey, MessageTextDocument>

    init(limit: Int) {
      entries = BoundedCache(limit: limit)
    }

    func document(
      for key: MessageTextDocumentKey, make: () -> MessageTextDocument
    ) -> MessageTextDocument {
      entries.value(for: key, make: make)
    }
  }
#endif
