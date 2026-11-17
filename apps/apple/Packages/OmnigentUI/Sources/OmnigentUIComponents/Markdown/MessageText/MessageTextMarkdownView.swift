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

    var body: some View {
      let split = MessageTextSplits.shared.split(text, ramp: ramp)
      // Reading the links' state here redraws the text once a cited file is found.
      let linked =
        links.map { links in
          split.cited.map { links.target(for: $0.text, explicit: $0.explicit)?.url }
        } ?? []
      let code = MessageCodeFont()
      VStack(alignment: .leading, spacing: 0) {
        ForEach(split.pieces) { piece in
          Group {
            switch piece.content {
            case .text(let blocks):
              MessageTextBlocksView(
                source: MessageTextSource(text: text, piece: piece.id), blocks: blocks,
                linked: linked, code: code, fillsWidth: fillsWidth)
            case .block(let block):
              MarkdownBlockView(block: block)
            }
          }
          .padding(.top, piece.gapAbove)
        }
      }
      .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
      .modifier(WorkspacePathLinking(paths: split.cited))
    }
  }

  /// Which piece of which message a text view shows.
  nonisolated struct MessageTextSource: Hashable, Sendable {
    var text: String
    var piece: Int
  }

  /// One run of text blocks in a ``MessageTextHostView``: the document is built once per text,
  /// style and linked paths, and its view lays out once per width.
  struct MessageTextBlocksView: NSViewRepresentable {
    let source: MessageTextSource
    let blocks: [MarkdownBlock]
    let linked: [URL?]
    let code: MessageCodeFont
    let fillsWidth: Bool

    func makeNSView(context: Context) -> MessageTextHostView {
      MessageTextHostView()
    }

    func updateNSView(_ view: MessageTextHostView, context: Context) {
      let environment = context.environment
      let document = Self.document(
        source: source, blocks: blocks, linked: linked,
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
      style: MessageTextStyle, links: WorkspaceFileLinks?
    ) -> MessageTextDocument {
      let key = MessageTextDocumentKey(
        text: source.text, piece: source.piece, style: style, linked: linked)
      return MessageTextDocuments.shared.document(for: key) {
        // An answer laid out ahead, off the main actor, comes with its layout.
        if let prepared = MessageTextPrewarm.shared.takeDocument(for: key) { return prepared }
        let shown = links.map { links in blocks.map { $0.linking(with: links) } } ?? blocks
        var builder = MessageTextBuilder(palette: MessageTextPalette(style))
        return builder.document(linked.isEmpty ? blocks : shown)
      }
    }
  }

  extension MarkdownBlock {
    /// The block with the workspace paths it cites linked, once they are known to exist.
    func linking(with links: WorkspaceFileLinks) -> MarkdownBlock {
      switch self {
      case .paragraph(let text):
        return .paragraph(links.linking(text))
      case .heading(let level, let text):
        return .heading(level: level, text: links.linking(text))
      case .quote(let blocks):
        return .quote(blocks.map { $0.linking(with: links) })
      case .list(let ordered, let start, let items):
        let linked = items.map {
          MarkdownListItem(blocks: $0.blocks.map { $0.linking(with: links) }, task: $0.task)
        }
        return .list(ordered: ordered, start: start, items: linked)
      case .table(var table):
        table.header = table.header.map { links.linking($0) }
        table.rows = table.rows.map { $0.map { links.linking($0) } }
        return .table(table)
      case .code, .rule, .html, .image, .math:
        return self
      }
    }
  }
#endif
