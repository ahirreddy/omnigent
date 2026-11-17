import Foundation

/// Builds and lays out CLI texts off the main actor, once a CLI text cell has shown the style
/// and width they draw at, and draws those asked for ahead (``MessageTextRaster``): a row
/// about to scroll in then only takes its drawing, and a row far from view is measured from
/// its built document. The table transcript asks for the rows near the reader, nearest first.
nonisolated final class CLITextPrewarm: Sendable {
  static let shared = CLITextPrewarm(limit: 256)

  /// The style and width CLI texts lay out at, and, to draw them ahead, the scale and colors.
  struct Context: Sendable {
    var style: CLITextStyle
    var width: CGFloat
    var palette: MessageTextPalette
    var scale: CGFloat = 0
    var raster: MessageTextRasterStyle?
  }

  /// How many texts lay out at once: one per three cores, up to three.
  static let workers = min(3, max(1, ProcessInfo.processInfo.activeProcessorCount / 3))

  private let queue: MessageTextPrewarmQueue<Context>

  init(
    limit: Int, documents: CLITextDocuments = .shared, rasters: MessageTextRasters = .shared,
    workers: Int = CLITextPrewarm.workers
  ) {
    queue = MessageTextPrewarmQueue(limit: limit, workers: workers) { key, draws, context in
      Self.prepare(key, draws: draws, context: context, documents: documents, rasters: rasters)
    }
  }

  /// Notes the style, width and drawing a cell showed its text at; a change lays out the texts
  /// asked for so far again.
  func note(_ context: Context) {
    queue.setContext(context) { current in
      current.style == context.style && current.width == context.width
        && current.scale == context.scale && (current.raster != nil) == (context.raster != nil)
        && current.palette.style == context.palette.style
    }
  }

  /// Asks for texts about to show, at their places in the transcript, the nearest first.
  func prioritize(_ specs: [CLITextSpec], at positions: [Double]) {
    queue.prioritize(specs.map(\.key), at: positions)
  }

  /// Where the reader is and which way they scroll (+1 down, -1 up, 0 still).
  func focus(at position: Double, direction: Int) {
    queue.focus(at: position, direction: direction)
  }

  /// The context texts lay out in, once a cell has shown one.
  var context: Context? { queue.context }

  /// The texts waiting, in the order they would go now, for tests.
  var pendingSpecs: [CLITextSpec] { queue.pendingTexts.compactMap(CLITextSpec.init(key:)) }

  private static func prepare(
    _ key: String, draws: Bool, context: Context, documents: CLITextDocuments,
    rasters: MessageTextRasters
  ) {
    guard let spec = CLITextSpec(key: key) else { return }
    let document = documents.document(
      for: CLITextKey(spec: spec, style: context.style, width: context.width),
      palette: context.palette)
    guard draws, let style = context.raster, context.scale > 0 else { return }
    let rasterKey = MessageTextRasterKey(
      document: document.text.serial, width: context.width, scale: context.scale)
    guard !rasters.contains(rasterKey) else { return }
    rasters.store(
      MessageTextRaster.make(
        document.text.run, width: context.width, scale: context.scale, style: style),
      for: rasterKey)
  }
}
