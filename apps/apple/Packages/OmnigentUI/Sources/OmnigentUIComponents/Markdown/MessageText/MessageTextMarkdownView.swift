#if os(macOS)
  import AppKit
  import SwiftUI

  /// A message's markdown with each run of text blocks in one TextKit 2 view
  /// (``MessageTextContentView``), so its layout is kept and selection crosses paragraphs. Display
  /// math, diagrams, images and tables too wide to draw as text stay ``MarkdownView``'s blocks,
  /// between the runs.
  struct MessageTextMarkdownView: View {
    let text: String
    var fillsWidth = true
    @Environment(\.typeRamp) private var ramp
    @Environment(\.workspaceFileLinks) private var links
    /// Inline math typeset since the view appeared, by its TeX.
    @State private var typeset: [String: RenderedRichBlock] = [:]

    var body: some View {
      let split = MessageTextSplits.shared.split(text, ramp: ramp)
      // Reading the links' state here redraws the text once a cited file is found.
      let linked =
        links.map { links in
          split.cited.map { links.target(for: $0.text, explicit: $0.explicit)?.url }
        } ?? []
      let code = MessageCodeFont()
      let math = split.pieces.flatMap(\.inlineMath)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(split.pieces) { piece in
          Group {
            switch piece.content {
            case .text(let blocks):
              MessageTextBlocksView(
                source: MessageTextSource(text: text, piece: piece.id), blocks: blocks,
                linked: linked, math: readyMath(piece.inlineMath), code: code,
                fillsWidth: fillsWidth)
            case .block(let block):
              MarkdownBlockView(block: block)
            }
          }
          .padding(.top, piece.gapAbove)
        }
      }
      .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
      .modifier(WorkspacePathLinking(paths: split.cited))
      .task(id: math) { await typesetMath(math) }
    }

    private func request(_ tex: String) -> RichBlockRequest {
      RichBlockRequest(kind: .math(display: false, size: ramp.body), source: tex)
    }

    /// The typeset images of `math` that are ready.
    private func readyMath(_ math: [String]) -> [String: RenderedRichBlock] {
      var ready: [String: RenderedRichBlock] = [:]
      for tex in math {
        if let image = typeset[tex] ?? RichBlockRenderer.shared.cached(request(tex)) {
          ready[tex] = image
        }
      }
      return ready
    }

    /// Typesets each span not yet typeset; a span KaTeX rejects keeps its Unicode form, as in
    /// ``MarkdownParagraphText``.
    private func typesetMath(_ math: [String]) async {
      for tex in math where typeset[tex] == nil {
        let request = request(tex)
        if RichBlockRenderer.shared.cached(request) != nil { continue }
        do {
          typeset[tex] = try await RichBlockRenderer.shared.render(request)
        } catch {
          continue
        }
      }
    }
  }

  /// One run of text blocks in a ``MessageTextHostView``: the document is built once per text,
  /// style and linked paths, and its view lays out once per width.
  struct MessageTextBlocksView: NSViewRepresentable {
    let source: MessageTextSource
    let blocks: [MarkdownBlock]
    let linked: [URL?]
    /// The piece's inline math typeset so far.
    var math: [String: RenderedRichBlock] = [:]
    let code: MessageCodeFont
    let fillsWidth: Bool

    func makeNSView(context: Context) -> MessageTextHostView {
      MessageTextHostView()
    }

    func updateNSView(_ view: MessageTextHostView, context: Context) {
      let environment = context.environment
      let document = Self.document(
        source: source, blocks: blocks, linked: linked, math: math,
        style: MessageTextStyle(environment: environment, code: code),
        links: environment.workspaceFileLinks)
      let openURL = environment.openURL
      view.show(document, fillsWidth: fillsWidth) { openURL($0) }
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize, nsView view: MessageTextHostView, context: Context
    ) -> CGSize? {
      view.fittingSize(for: proposal.width)
    }

    static func dismantleNSView(_ view: MessageTextHostView, coordinator: ()) {
      view.releaseContent()
    }

    /// The document for one piece, built on first ask.
    static func document(
      source: MessageTextSource, blocks: [MarkdownBlock], linked: [URL?],
      math: [String: RenderedRichBlock] = [:], style: MessageTextStyle, links: WorkspaceFileLinks?
    ) -> MessageTextDocument {
      let key = MessageTextDocumentKey(
        text: source.text, piece: source.piece, style: style, linked: linked,
        math: math.keys.sorted())
      return MessageTextDocuments.shared.document(for: key) {
        // An answer laid out ahead, off the main actor, comes with its layout.
        if let prepared = MessageTextPrewarm.shared.takeDocument(for: key) { return prepared }
        let shown = links.map { links in blocks.map { $0.linking(with: links) } } ?? blocks
        var builder = MessageTextBuilder(palette: MessageTextPalette(style))
        builder.typesetMath = math
        return builder.document(linked.isEmpty ? blocks : shown)
      }
    }
  }
#endif
