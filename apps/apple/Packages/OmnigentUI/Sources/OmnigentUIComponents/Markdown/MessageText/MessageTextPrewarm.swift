#if os(macOS)
  import AppKit
  import Synchronization

  /// A document's text laid out at one width on a TextKit 2 stack of its own, made off the main
  /// actor. A text view takes its container on the main actor, layout and all.
  nonisolated final class MessageTextPreparedLayout: @unchecked Sendable {
    let storage: NSTextContentStorage
    let manager: NSTextLayoutManager
    let container: NSTextContainer
    let width: CGFloat

    /// The container's height: unlimited, as a text view's own.
    static let unlimitedHeight: CGFloat = 10_000_000

    init(text: NSAttributedString, width: CGFloat) {
      storage = NSTextContentStorage()
      manager = NSTextLayoutManager()
      storage.addTextLayoutManager(manager)
      container = NSTextContainer(size: CGSize(width: width, height: Self.unlimitedHeight))
      container.lineFragmentPadding = 0
      container.widthTracksTextView = false
      container.heightTracksTextView = false
      manager.textContainer = container
      storage.textStorage?.setAttributedString(text)
      manager.ensureLayout(for: manager.documentRange)
      self.width = width
    }
  }

  /// Builds and lays out settled answers off the main actor, newest first, once a TextKit answer
  /// has shown the style and width answers draw at: a row then only takes its laid-out text.
  /// ``MarkdownWarmup`` offers each answer it parses.
  nonisolated final class MessageTextPrewarm: Sendable {
    static let shared = MessageTextPrewarm(limit: 256)

    /// `omnigent:message-text-prewarm`: `NO` leaves every answer to lay out on the main actor
    /// as its row shows, to measure what laying out ahead saves.
    static let isEnabled = enabled(in: .standard)

    /// Whether `defaults` leave the prewarm on: unless the key says `NO`.
    static func enabled(in defaults: UserDefaults) -> Bool {
      let key = "omnigent:message-text-prewarm"
      return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    /// The style and width answers draw at.
    struct Context: Sendable {
      var palette: MessageTextPalette
      var width: CGFloat
    }

    private struct State {
      var context: Context?
      /// Answers offered, newest first, to lay out again when the context changes.
      var offered: [String] = []
      var pending: [String] = []
      var isRunning = false
      var documents: BoundedCache<MessageTextDocumentKey, MessageTextDocument>
    }

    private let limit: Int
    private let state: Mutex<State>

    init(limit: Int) {
      self.limit = limit
      state = Mutex(State(documents: BoundedCache(limit: limit)))
    }

    /// Notes the style and width an answer showed at; a change lays out the answers offered so
    /// far again.
    func note(palette: MessageTextPalette, width: CGFloat) {
      let start = state.withLock { state -> Bool in
        if let context = state.context, context.width == width,
          context.palette.style == palette.style
        {
          return false
        }
        state.context = Context(palette: palette, width: width)
        state.pending = state.offered
        return Self.claimRun(&state)
      }
      if start { run() }
    }

    /// Queues an answer's text to lay out.
    func offer(_ text: String) {
      let start = state.withLock { state -> Bool in
        if state.offered.count < limit { state.offered.append(text) }
        guard state.context != nil, state.pending.count < limit else { return false }
        state.pending.append(text)
        return Self.claimRun(&state)
      }
      if start { run() }
    }

    /// The document prepared for `key`, if one was.
    func takeDocument(for key: MessageTextDocumentKey) -> MessageTextDocument? {
      state.withLock { $0.documents.cached(key) }
    }

    /// Whether this caller starts the run: nothing runs yet and there is work.
    private static func claimRun(_ state: inout State) -> Bool {
      guard !state.isRunning, !state.pending.isEmpty else { return false }
      state.isRunning = true
      return true
    }

    private func run() {
      Task.detached(priority: .utility) { [self] in
        while let work = next() {
          prepare(work.text, context: work.context)
        }
      }
    }

    /// The next answer to lay out and the context to lay it out in; `nil` ends the run.
    private func next() -> (text: String, context: Context)? {
      state.withLock { state in
        guard let context = state.context, !state.pending.isEmpty else {
          state.isRunning = false
          return nil
        }
        return (state.pending.removeFirst(), context)
      }
    }

    private func prepare(_ text: String, context: Context) {
      let style = context.palette.style
      let split = MessageTextSplit(MarkdownCache.shared.blocks(for: text), ramp: style.ramp)
      // Linked paths depend on the main actor's folder listings; those answers build there.
      guard split.cited.isEmpty else { return }
      for piece in split.pieces {
        guard case .text(let blocks) = piece.content else { continue }
        let key = MessageTextDocumentKey(text: text, piece: piece.id, style: style, linked: [])
        guard state.withLock({ $0.documents.cached(key) }) == nil else { continue }
        var builder = MessageTextBuilder(palette: context.palette)
        let document = builder.document(blocks)
        document.offer(MessageTextPreparedLayout(text: document.text, width: context.width))
        state.withLock { $0.documents.store(document, for: key) }
      }
    }
  }
#endif
