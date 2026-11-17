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

  /// Builds and lays out settled answers off the main actor, on a few workers, once a TextKit
  /// answer has shown the style and width answers draw at: a row then only takes its laid-out
  /// text, and a row far from view is measured from its size (``MessageTextSizes``). With a
  /// raster style it also draws the answers asked for ahead (``MessageTextRaster``).
  /// ``MarkdownWarmup`` offers each answer it parses, newest first; the table transcript asks for
  /// those about to scroll into view, which go first, nearest the reader first
  /// (``prioritize(_:at:)``).
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

    /// The style and width answers draw at, and, to draw them ahead, the scale and the layers'
    /// colors.
    struct Context: Sendable {
      var palette: MessageTextPalette
      var width: CGFloat
      var scale: CGFloat = 0
      var raster: MessageTextRasterStyle?
    }

    /// What it builds, shared with the queue's workers.
    private final class Store: Sendable {
      let documents: Mutex<BoundedCache<MessageTextDocumentKey, MessageTextDocument>>
      let rasters: MessageTextRasters
      let sizes: MessageTextSizes

      init(limit: Int, rasters: MessageTextRasters, sizes: MessageTextSizes) {
        documents = Mutex(BoundedCache(limit: limit))
        self.rasters = rasters
        self.sizes = sizes
      }
    }

    /// `omnigent:message-text-prewarm-workers`: how many answers lay out at once; by default
    /// as many as the cores spare beyond the main thread and the window server's, up to four.
    static let workers: Int = {
      let asked = UserDefaults.standard.integer(forKey: "omnigent:message-text-prewarm-workers")
      if asked > 0 { return asked }
      return min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 3))
    }()

    private let store: Store
    private let queue: MessageTextPrewarmQueue<Context>
    /// Drawing requests for runs built on the main actor, one at a time.
    private let drawing = DispatchQueue(label: "omnigent.message-text.raster", qos: .utility)
    private let drawingKeys = Mutex<Set<MessageTextRasterKey>>([])

    init(
      limit: Int, rasters: MessageTextRasters = .shared, sizes: MessageTextSizes = .shared,
      workers: Int = MessageTextPrewarm.workers
    ) {
      let store = Store(limit: limit, rasters: rasters, sizes: sizes)
      self.store = store
      // Answers asked for ahead are drawn as well as laid out: drawing every answer offered
      // would spend the rasters' budget far from the reader.
      queue = MessageTextPrewarmQueue(limit: limit, workers: workers) { text, draws, context in
        Self.prepare(text, draws: draws, context: context, store: store)
      }
    }

    /// Notes the style and width an answer showed at, and the scale and colors to draw it
    /// ahead at; a change lays out the answers offered so far again.
    func note(
      palette: MessageTextPalette, width: CGFloat, scale: CGFloat = 0,
      raster: MessageTextRasterStyle? = nil
    ) {
      queue.setContext(
        Context(palette: palette, width: width, scale: scale, raster: raster)
      ) { current in
        guard current.width == width, current.palette.style == palette.style else {
          return false
        }
        // A note without drawing (a SwiftUI row's) keeps the drawing a text cell asked for.
        return raster == nil || (current.raster != nil && current.scale == scale)
      }
    }

    /// Queues an answer's text to lay out.
    func offer(_ text: String) {
      queue.offer(text)
    }

    /// Asks for answers about to show, at their places in the transcript: they lay out and draw
    /// before the rest, the one nearest the reader first.
    func prioritize(_ texts: [String], at positions: [Double]) {
      queue.prioritize(texts, at: positions)
    }

    /// Asks for answers about to show, the first nearest the reader.
    func prioritize(_ texts: [String]) {
      queue.prioritize(texts)
    }

    /// Where the reader is in the transcript and which way they scroll (+1 down, -1 up, 0 still).
    func focus(at position: Double, direction: Int) {
      queue.focus(at: position, direction: direction)
    }

    /// The texts waiting to lay out, in the order they would go now, for tests.
    var pendingTexts: [String] { queue.pendingTexts }

    /// Whether it draws answers ahead as it lays them out.
    var drawsAhead: Bool { queue.context?.raster != nil }

    /// Whether it lays answers out: a row has shown the width they lay out at.
    var hasContext: Bool { queue.context != nil }

    /// The document prepared for `key`, if one was.
    func takeDocument(for key: MessageTextDocumentKey) -> MessageTextDocument? {
      store.documents.withLock { $0.cached(key) }
    }

    /// Draws `document` at `width` and `scale` off the main actor, unless it is drawn or being
    /// drawn: for a run built on the main actor, which shows as a live text view until then.
    func draw(
      _ document: MessageTextDocument, width: CGFloat, scale: CGFloat,
      style: MessageTextRasterStyle
    ) {
      let key = MessageTextRasterKey(document: document.serial, width: width, scale: scale)
      guard !store.rasters.contains(key),
        drawingKeys.withLock({ $0.insert(key).inserted })
      else { return }
      drawing.async { [self] in
        let raster = MessageTextRaster.make(
          document.run, width: width, scale: scale, style: style)
        store.rasters.store(raster, for: key)
        store.sizes.store(raster.size, document: document.serial, width: width)
        _ = drawingKeys.withLock { $0.remove(key) }
      }
    }

    private static func prepare(_ text: String, draws: Bool, context: Context, store: Store) {
      let style = context.palette.style
      let split = MessageTextSplit(MarkdownCache.shared.blocks(for: text), ramp: style.ramp)
      // Linked paths depend on the main actor's folder listings; those answers build there.
      guard split.cited.isEmpty else { return }
      for piece in split.pieces {
        guard case .text(let blocks) = piece.content else { continue }
        let key = MessageTextDocumentKey(text: text, piece: piece.id, style: style, linked: [])
        let built = store.documents.withLock { $0.cached(key) }
        if let built {
          if draws { drawAhead(built, context: context, store: store) }
          continue
        }
        var builder = MessageTextBuilder(palette: context.palette)
        let document = builder.document(blocks)
        let layout = MessageTextPreparedLayout(text: document.text, width: context.width)
        store.sizes.store(
          MessageTextSize.measure(
            layout.manager, width: context.width, topInset: document.topInset),
          document: document.serial, width: context.width)
        if draws { drawAhead(document, context: context, store: store) }
        document.offer(layout)
        store.documents.withLock { $0.store(document, for: key) }
      }
    }

    /// Draws `document` into a raster when the context asks for one and none is kept.
    private static func drawAhead(
      _ document: MessageTextDocument, context: Context, store: Store
    ) {
      guard let style = context.raster, context.scale > 0 else { return }
      let key = MessageTextRasterKey(
        document: document.serial, width: context.width, scale: context.scale)
      guard !store.rasters.contains(key) else { return }
      // On a stack of its own: the prepared layout's links stay links for the live view.
      let raster = MessageTextRaster.make(
        document.run, width: context.width, scale: context.scale, style: style)
      store.rasters.store(raster, for: key)
      store.sizes.store(raster.size, document: document.serial, width: context.width)
    }
  }
#endif
