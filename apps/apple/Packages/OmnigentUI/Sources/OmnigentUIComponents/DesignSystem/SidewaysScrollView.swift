import SwiftUI

/// Content that scrolls sideways inside a list that scrolls up and down, such as a wide table or
/// a code block's long lines in a transcript row. On the Mac it is an ``InnerScrollView``, so a
/// vertical scroll over it moves the list; elsewhere it is SwiftUI's scroll view.
struct SidewaysScrollView<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    #if os(macOS)
      // Content that fits needs no scroll view of its own, nor its own hosting view. It still
      // reads as the scroll area it would be if it were wider.
      ViewThatFits(in: .horizontal) {
        content.fixedSize(horizontal: true, vertical: false)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityRepresentation { ScrollView(.horizontal) { content } }
        InnerScrollHost(axis: .horizontal, content: content)
      }
    #else
      ScrollView(.horizontal) { content }
    #endif
  }
}

#if os(macOS)
  import AppKit

  /// SwiftUI content in an ``InnerScrollView``, sized as SwiftUI's scroll view sizes it: as wide
  /// as offered and as tall as the content when it scrolls sideways; as wide as offered and as
  /// tall as the content, up to `maxHeight`, when it scrolls vertically.
  struct InnerScrollHost<Content: View>: NSViewRepresentable {
    let axis: Axis
    var maxHeight: CGFloat = .infinity
    let content: Content

    func makeNSView(context: Context) -> InnerHostingScrollView<Content> {
      InnerHostingScrollView(axis: axis, root: root(in: context.environment))
    }

    func updateNSView(_ view: InnerHostingScrollView<Content>, context: Context) {
      view.show(root(in: context.environment))
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize, nsView view: InnerHostingScrollView<Content>,
      context: Context
    ) -> CGSize? {
      view.size(fitting: proposal, maxHeight: maxHeight)
    }

    private func root(in environment: EnvironmentValues) -> InnerScrollRoot<Content> {
      InnerScrollRoot(content: content, axis: axis, environment: environment)
    }
  }

  /// The content at its ideal length along the axis it scrolls, at the top leading corner, in
  /// the environment of the view around it: a hosting view of its own starts from a fresh one.
  struct InnerScrollRoot<Content: View>: View {
    let content: Content
    let axis: Axis
    let environment: EnvironmentValues

    var body: some View {
      let environment = environment
      Group {
        if axis == .horizontal {
          content.fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          content.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .transformEnvironment(\.self) { own in own = environment }
    }
  }

  /// The AppKit side of ``InnerScrollHost``: its content in a hosting controller as the
  /// document, measured as SwiftUI's scroll view measures it.
  final class InnerHostingScrollView<Content: View>: InnerScrollView {
    private let controller: NSHostingController<InnerScrollRoot<Content>>
    private let axis: Axis
    /// The content's ideal size, until it changes.
    private var idealSize: CGSize?
    /// The content's height by the width it was laid out at, until it changes.
    private var heights: [CGFloat: CGFloat] = [:]

    init(axis: Axis, root: InnerScrollRoot<Content>) {
      self.axis = axis
      controller = NSHostingController(rootView: root)
      controller.sizingOptions = [.intrinsicContentSize]
      controller.safeAreaRegions = []
      controller.sceneBridgingOptions = []
      super.init(frame: .zero)
      drawsBackground = false
      contentView.drawsBackground = false
      hasHorizontalScroller = axis == .horizontal
      hasVerticalScroller = axis == .vertical
      autohidesScrollers = true
      horizontalScrollElasticity = axis == .horizontal ? .automatic : .none
      verticalScrollElasticity = axis == .vertical ? .automatic : .none
      documentView = controller.view
      fitDocument()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    func show(_ root: InnerScrollRoot<Content>) {
      controller.rootView = root
      idealSize = nil
      heights = [:]
      fitDocument()
    }

    /// The content's size with nothing offered: its intrinsic size.
    private var ideal: CGSize {
      if let idealSize { return idealSize }
      let size = Self.rounded(controller.view.intrinsicContentSize)
      idealSize = size
      return size
    }

    /// The content's height laid out `width` wide.
    private func height(at width: CGFloat) -> CGFloat {
      if let height = heights[width] { return height }
      let size = controller.sizeThatFits(
        in: CGSize(width: width, height: .greatestFiniteMagnitude))
      let height = Self.rounded(size).height
      heights[width] = height
      return height
    }

    private static func rounded(_ size: CGSize) -> CGSize {
      CGSize(width: max(0, size.width).rounded(.up), height: max(0, size.height).rounded(.up))
    }

    func size(fitting proposal: ProposedViewSize, maxHeight: CGFloat) -> CGSize {
      let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil }
      switch axis {
      case .horizontal:
        let width = offered ?? ideal.width
        return CGSize(width: width, height: ideal.height + scrollerHeight(over: width))
      case .vertical:
        let width = offered ?? ideal.width
        return CGSize(width: width, height: min(height(at: width), maxHeight))
      }
    }

    /// A legacy scroller sits under content wider than `width`; an overlay one draws over it.
    private func scrollerHeight(over width: CGFloat) -> CGFloat {
      guard scrollerStyle == .legacy, ideal.width > width + 0.5 else { return 0 }
      return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    override func layout() {
      super.layout()
      fitDocument()
    }

    /// Sizes the document to the content, at least the viewport. Before the view has a size, the
    /// content's ideal one: laid out at no size, the content would center on its leading edge.
    private func fitDocument() {
      let visible = contentView.bounds.size
      let size =
        switch axis {
        case .horizontal:
          CGSize(width: max(visible.width, ideal.width), height: max(visible.height, ideal.height))
        case .vertical:
          visible.width > 0
            ? CGSize(width: visible.width, height: max(visible.height, height(at: visible.width)))
            : ideal
        }
      if controller.view.frame.size != size {
        controller.view.frame = CGRect(origin: .zero, size: size)
      }
    }
  }
#endif
