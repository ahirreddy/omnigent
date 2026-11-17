#if os(macOS)
  import AppKit

  /// Text views not on screen, by document, so a row scrolled back into view gets its laid-out
  /// text back. The oldest goes past ``limit``.
  final class MessageTextViews {
    static let shared = MessageTextViews(limit: 96)

    private let limit: Int
    private var idle: [UInt64: MessageTextContentView] = [:]
    private var order: [UInt64] = []
    /// Views made because none was idle, for tests.
    private(set) var made = 0

    init(limit: Int) {
      self.limit = limit
    }

    /// The idle view for `document`, or a new one.
    func checkOut(_ document: MessageTextDocument) -> MessageTextContentView {
      if let view = idle.removeValue(forKey: document.serial) {
        order.removeAll { $0 == document.serial }
        return view
      }
      made += 1
      return MessageTextContentView(document: document)
    }

    /// Keeps `view` for its document's next showing.
    func checkIn(_ view: MessageTextContentView) {
      let serial = view.document.serial
      guard idle[serial] == nil else { return }
      idle[serial] = view
      order.append(serial)
      while order.count > limit {
        idle[order.removeFirst()] = nil
      }
    }
  }

  /// What a SwiftUI row (or a table cell) holds: it shows one document's view, borrowed from
  /// ``MessageTextViews`` and handed back when the row goes.
  final class MessageTextHostView: NSView {
    private(set) var content: MessageTextContentView?
    private var fillsWidth = true

    override var isFlipped: Bool { true }

    func show(
      _ document: MessageTextDocument, fillsWidth: Bool,
      openURL: @escaping @MainActor (URL) -> Void
    ) {
      self.fillsWidth = fillsWidth
      if content?.document !== document {
        releaseContent()
        let adopted = MessageTextViews.shared.checkOut(document)
        adopted.frame = bounds
        addSubview(adopted)
        content = adopted
      }
      content?.openURL = openURL
    }

    /// The size at a proposed width, laid out once per width.
    func fittingSize(for width: CGFloat?) -> CGSize? {
      guard let content else { return nil }
      // Answers fill the column: the next ones lay out ahead at this width.
      if fillsWidth, let width, width.isFinite, width >= MessageTextContentView.minimumWidth {
        MessageTextPrewarm.shared.note(palette: content.document.palette, width: width)
      }
      return content.fittingSize(for: width, fillsWidth: fillsWidth)
    }

    /// Hands the view back for the next row that shows its document.
    func releaseContent() {
      guard let content else { return }
      content.removeFromSuperview()
      MessageTextViews.shared.checkIn(content)
      self.content = nil
    }

    override func layout() {
      super.layout()
      if let content, content.frame != bounds { content.frame = bounds }
    }
  }
#endif
