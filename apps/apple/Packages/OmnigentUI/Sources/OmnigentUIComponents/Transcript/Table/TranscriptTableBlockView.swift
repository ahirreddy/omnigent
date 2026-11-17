#if os(macOS)
  import AppKit
  import SwiftUI

  /// A block a text cell can't draw as text (display math, a diagram, an image, a table too
  /// wide), hosted on its own between the cell's text runs, in the transcript's environment and
  /// reading style.
  struct TranscriptTableBlockRoot: View {
    var block: MarkdownBlock?
    var width: CGFloat
    let environment: TranscriptTableEnvironment

    var body: some View {
      let values = environment.values
      Group {
        if let block { MarkdownBlockView(block: block) }
      }
      .readingProseStyle()
      .agentOutputRendering()
      // A wide table's cited files open in the app, as in the message's SwiftUI markdown.
      .modifier(WorkspacePathLinking(paths: []))
      .frame(width: max(0, width), alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .transformEnvironment(\.self) { own in
        if let values { own = values }
      }
    }
  }

  /// A piece of an AppKit cell that only SwiftUI draws, hosted on its own and sized by its ideal
  /// height at the cell's width. It reports a change of that height (a diagram drawn, an image
  /// loaded, a tool group opened) once it has first shown.
  class TranscriptTablePieceView<Root: View>: NSHostingView<Root> {
    /// Told when the piece's height may have changed.
    var sizeChanged: (() -> Void)?
    /// Until its content first shows, nothing it reports is a change.
    private var isSettling = true

    /// A piece for a cell: no window bridging, no safe area, sized by its content.
    func configure() {
      sizingOptions = [.intrinsicContentSize]
      safeAreaRegions = []
      sceneBridgingOptions = []
    }

    /// Shows `root`; the report its first layout makes is not a change.
    func present(_ root: Root) {
      rootView = root
      isSettling = true
      MainRunLoop.performAfterDisplay { [weak self] in
        MainActor.assumeIsolated { self?.isSettling = false }
      }
    }

    /// The piece's height at its width, laid out now if it has to be.
    var idealHeight: CGFloat { intrinsicContentSize.height.rounded(.up) }

    /// Reports the change; the cell, not Auto Layout, sizes the piece.
    override func invalidateIntrinsicContentSize() {
      guard !isSettling else { return }
      sizeChanged?()
    }
  }

  /// The hosting view for one such block.
  final class TranscriptTableBlockView: TranscriptTablePieceView<TranscriptTableBlockRoot> {
    /// The piece of the message it shows.
    private(set) var piece = -1

    static func make(environment: TranscriptTableEnvironment) -> TranscriptTableBlockView {
      let view = TranscriptTableBlockView(
        rootView: TranscriptTableBlockRoot(block: nil, width: 0, environment: environment))
      view.configure()
      return view
    }

    /// Shows piece `piece`'s `block` at `width`, unless it shows it already.
    func show(_ block: MarkdownBlock, piece: Int, width: CGFloat) {
      guard block != rootView.block || width != rootView.width || piece != self.piece else {
        return
      }
      self.piece = piece
      present(
        TranscriptTableBlockRoot(block: block, width: width, environment: rootView.environment))
    }
  }
#endif
