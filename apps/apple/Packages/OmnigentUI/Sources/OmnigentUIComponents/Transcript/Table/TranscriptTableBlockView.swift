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
      .frame(width: max(0, width), alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .transformEnvironment(\.self) { own in
        if let values { own = values }
      }
    }
  }

  /// The hosting view for one such block, sized by its ideal height at the cell's width. It
  /// reports a change of that height (a diagram drawn, an image loaded) once it has first shown.
  final class TranscriptTableBlockView: NSHostingView<TranscriptTableBlockRoot> {
    /// The piece of the message it shows.
    private(set) var piece = -1
    /// Told when the block's height may have changed.
    var sizeChanged: (() -> Void)?
    private var isSettling = false

    static func make(environment: TranscriptTableEnvironment) -> TranscriptTableBlockView {
      let view = TranscriptTableBlockView(
        rootView: TranscriptTableBlockRoot(block: nil, width: 0, environment: environment))
      view.sizingOptions = [.intrinsicContentSize]
      view.safeAreaRegions = []
      view.sceneBridgingOptions = []
      return view
    }

    /// Shows piece `piece`'s `block` at `width`, unless it shows it already.
    func show(_ block: MarkdownBlock, piece: Int, width: CGFloat) {
      guard block != rootView.block || width != rootView.width || piece != self.piece else {
        return
      }
      self.piece = piece
      rootView = TranscriptTableBlockRoot(
        block: block, width: width, environment: rootView.environment)
      isSettling = true
      MainRunLoop.performAfterDisplay { [weak self] in
        MainActor.assumeIsolated { self?.isSettling = false }
      }
    }

    /// The block's height at its width, laid out now if it has to be.
    var idealHeight: CGFloat { intrinsicContentSize.height.rounded(.up) }

    /// Reports the change; the cell, not Auto Layout, sizes the block.
    override func invalidateIntrinsicContentSize() {
      guard !isSettling else { return }
      sizeChanged?()
    }
  }
#endif
