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

  nonisolated extension MessageTextDocument {
    /// What a raster draws of it.
    var run: MessageTextRun { MessageTextRun(text: text, topInset: topInset, links: links) }
  }

  /// Builds and lays out settled answers off the main actor, newest first, once a TextKit answer
  /// has shown the style and width answers draw at: a row then only takes its laid-out text.
  /// With a raster style it also draws the answers asked for ahead (``MessageTextRaster``).
  /// ``MarkdownWarmup`` offers each answer it parses; the table transcript puts those about to
  /// scroll into view first (``prioritize(_:)``).
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

    /// What it builds, shared with the queue's runs.
    private final class Store: Sendable {
      let documents: Mutex<BoundedCache<MessageTextDocumentKey, MessageTextDocument>>
      let rasters: MessageTextRasters
      /// Answers asked for ahead of the rest, which are drawn as well as laid out: drawing
      /// every answer offered would spend the rasters' budget far from the reader.
      let drawn = Mutex<Set<String>>([])

      init(limit: Int, rasters: MessageTextRasters) {
        documents = Mutex(BoundedCache(limit: limit))
        self.rasters = rasters
      }
    }

    /// How many answers asked for ahead it remembers to draw.
    private static let drawnLimit = 64

    private let store: Store
    private let queue: MessageTextPrewarmQueue<Context>
    /// Drawing requests for runs built on the main actor, one at a time.
    private let drawing = DispatchQueue(label: "omnigent.message-text.raster", qos: .utility)
    private let drawingKeys = Mutex<Set<MessageTextRasterKey>>([])

    init(limit: Int, rasters: MessageTextRasters = .shared) {
      let store = Store(limit: limit, rasters: rasters)
      self.store = store
      queue = MessageTextPrewarmQueue(limit: limit) { text, context in
        Self.prepare(text, context: context, store: store)
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

    /// Puts answers about to show at the front of the queue, in order.
    func prioritize(_ texts: [String]) {
      guard !texts.isEmpty else { return }
      store.drawn.withLock { drawn in
        if drawn.count + texts.count > Self.drawnLimit { drawn.removeAll() }
        drawn.formUnion(texts)
      }
      queue.prioritize(texts)
    }

    /// The texts waiting to lay out, first to last, for tests.
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
        _ = drawingKeys.withLock { $0.remove(key) }
      }
    }

    private static func prepare(_ text: String, context: Context, store: Store) {
      let style = context.palette.style
      let split = MessageTextSplit(MarkdownCache.shared.blocks(for: text), ramp: style.ramp)
      // Linked paths depend on the main actor's folder listings; those answers build there.
      guard split.cited.isEmpty else { return }
      let draws = store.drawn.withLock { $0.remove(text) != nil }
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
    }
  }
#endif
