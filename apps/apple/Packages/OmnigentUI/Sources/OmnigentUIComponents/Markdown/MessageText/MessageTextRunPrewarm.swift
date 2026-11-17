#if os(iOS)
  import Foundation
  import Synchronization
  import UIKit

  /// Builds settled messages' text runs and draws them off the main actor on iPhone and iPad, on
  /// the shared prewarm queue (``MessageTextPrewarmQueue``): the text rows ask for the messages
  /// about to scroll in, which build and draw first, nearest the reader first, and a row then
  /// only takes its drawing (``MessageTextRasters``). ``MarkdownWarmup`` offers each answer it
  /// parses, which only lays out, so a row far from view is measured from its size
  /// (``MessageTextSizes``).
  nonisolated final class MessageTextRunPrewarm: Sendable {
    /// Answers, at the column's width.
    static let answers = MessageTextRunPrewarm(limit: 256, workers: workers)
    /// Users' prompts, at the width inside their bubbles.
    static let prompts = MessageTextRunPrewarm(limit: 64, workers: 1)

    /// How many messages asked for ahead build at once: one per three cores, up to three.
    static let workers = min(3, max(1, ProcessInfo.processInfo.activeProcessorCount / 3))

    /// The style and width messages build at, and the scale and colors they draw at.
    struct Context: Sendable {
      var palette: MessageTextPalette
      var width: CGFloat
      var scale: CGFloat
      var raster: MessageTextRasterStyle
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

    private let store: Store
    private let queue: MessageTextPrewarmQueue<Context>

    init(
      limit: Int, workers: Int, rasters: MessageTextRasters = .shared,
      sizes: MessageTextSizes = .shared
    ) {
      let store = Store(limit: limit, rasters: rasters, sizes: sizes)
      self.store = store
      // Messages asked for ahead are drawn as well as built: drawing every message offered
      // would spend the rasters' budget far from the reader.
      queue = MessageTextPrewarmQueue(limit: limit, workers: workers) { text, draws, context in
        Self.prepare(text, draws: draws, context: context, store: store)
      }
    }

    /// Sets the style, width, scale and colors messages build and draw at; a change builds the
    /// messages offered so far again.
    func note(_ context: Context) {
      queue.setContext(context) { current in
        current.width == context.width && current.scale == context.scale
          && current.palette.style == context.palette.style
      }
    }

    /// Queues an answer's text to lay out, behind those asked for.
    func offer(_ text: String) {
      queue.offer(text)
    }

    /// Asks for messages about to show, at their places in the transcript: they build and draw
    /// before the rest, the one nearest the reader first.
    func prioritize(_ texts: [String], at positions: [Double]) {
      queue.prioritize(texts, at: positions)
    }

    /// Where the reader is in the transcript and which way they scroll (+1 down, -1 up, 0 still).
    func focus(at position: Double, direction: Int) {
      queue.focus(at: position, direction: direction)
    }

    /// The context messages build in, once one is set.
    var context: Context? { queue.context }

    /// The texts waiting, in the order they would go now, for tests.
    var pendingTexts: [String] { queue.pendingTexts }

    /// The document built for `key`, if one was.
    func document(for key: MessageTextDocumentKey) -> MessageTextDocument? {
      store.documents.withLock { $0.cached(key) }
    }

    /// Keeps `document`, built on the main actor, for `key`: a message asked for ahead then
    /// draws that document, or nothing once its drawing is kept, rather than one of its own.
    func keep(_ document: MessageTextDocument, for key: MessageTextDocumentKey) {
      store.documents.withLock { $0.store(document, for: key) }
    }

    /// The document an answer's or a prompt's prewarm built for `key`, if either did.
    static func preparedDocument(for key: MessageTextDocumentKey) -> MessageTextDocument? {
      answers.document(for: key) ?? prompts.document(for: key)
    }

    private static func prepare(_ text: String, draws: Bool, context: Context, store: Store) {
      let style = context.palette.style
      let split = MessageTextSplit(MarkdownCache.shared.blocks(for: text), ramp: style.ramp)
      // Linked paths depend on the main actor's folder listings; those messages build there.
      guard split.cited.isEmpty else { return }
      for piece in split.pieces {
        guard case .text(let blocks) = piece.content else { continue }
        // The inline math typeset so far, as the row shows it.
        var math: [String: RenderedRichBlock] = [:]
        for tex in piece.inlineMath {
          let request = RichBlockRequest(
            kind: .math(display: false, size: style.ramp.body), source: tex)
          math[tex] = MessageTextTypesetMath.shared.image(for: request)
        }
        let key = MessageTextDocumentKey(
          text: text, piece: piece.id, style: style, linked: [], math: math.keys.sorted())
        let document: MessageTextDocument
        if let built = store.documents.withLock({ $0.cached(key) }) {
          document = built
        } else {
          var builder = MessageTextBuilder(palette: context.palette)
          builder.typesetMath = math
          document = builder.document(blocks)
          store.documents.withLock { $0.store(document, for: key) }
        }
        let width = context.width
        if draws {
          let rasterKey = MessageTextRasterKey(
            document: document.serial, width: width, scale: context.scale)
          guard !store.rasters.contains(rasterKey) else { continue }
          let raster = MessageTextRaster.make(
            document.run, width: width, scale: context.scale, style: context.raster)
          store.rasters.store(raster, for: rasterKey)
          store.sizes.store(raster.size, document: document.serial, width: width)
        } else if store.sizes.size(document: document.serial, width: width) == nil {
          store.sizes.store(
            MessageTextSize.measure(document.run, width: width), document: document.serial,
            width: width)
        }
      }
    }
  }

  nonisolated extension MessageTextSize {
    /// The size `run` lays out at `width` on a TextKit stack of its own, as its raster would.
    static func measure(_ run: MessageTextRun, width: CGFloat) -> Self {
      let storage = NSTextContentStorage()
      let manager = NSTextLayoutManager()
      storage.addTextLayoutManager(manager)
      let container = NSTextContainer(size: CGSize(width: width, height: 10_000_000))
      container.lineFragmentPadding = 0
      manager.textContainer = container
      storage.textStorage?.setAttributedString(run.text)
      return measure(manager, width: width, topInset: run.topInset)
    }
  }
#endif
