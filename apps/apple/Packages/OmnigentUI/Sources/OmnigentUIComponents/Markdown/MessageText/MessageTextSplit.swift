import SwiftUI

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

/// A message split into runs of blocks drawn as text and the blocks between them.
nonisolated struct MessageTextSplit {
  var pieces: [MessageTextPiece]
  /// The workspace paths the message cites.
  var cited: [CitedPath]

  /// Splits `blocks` where a block can't be text: display math, a diagram, an image or a
  /// table too wide.
  init(_ blocks: [MarkdownBlock], ramp: TypeRamp) {
    var pieces: [MessageTextPiece] = []
    var run: [MarkdownBlock] = []
    var runGap: CGFloat = 0
    func flush() {
      guard !run.isEmpty else { return }
      pieces.append(MessageTextPiece(id: pieces.count, gapAbove: runGap, content: .text(run)))
      run = []
    }
    for (index, block) in blocks.enumerated() {
      let gap = TypeRamp.spacing(above: block, after: index > 0 ? blocks[index - 1] : nil)
      if Self.drawsAsText(block, ramp: ramp) {
        if run.isEmpty { runGap = gap }
        run.append(block)
      } else {
        flush()
        pieces.append(MessageTextPiece(id: pieces.count, gapAbove: gap, content: .block(block)))
      }
    }
    flush()
    self.pieces = pieces
    cited = MarkdownBlock.citedPaths(in: blocks)
  }

  static func drawsAsText(_ block: MarkdownBlock, ramp: TypeRamp) -> Bool {
    switch block {
    case .paragraph, .heading, .quote, .list, .rule, .html: true
    case .code(let language, _): CodeHighlighting.fenceName(language) != "mermaid"
    case .table(let table): MessageTableColumns.fits(table, ramp: ramp)
    case .image, .math: false
    }
  }
}

/// One piece of a split message.
nonisolated struct MessageTextPiece: Identifiable, Sendable {
  enum Content: Sendable {
    case text([MarkdownBlock])
    case block(MarkdownBlock)
  }

  let id: Int
  /// The gap above it, as ``TypeRamp/spacing(above:after:)`` gives it.
  let gapAbove: CGFloat
  let content: Content
}

/// Split messages by text and ramp, so a row built again splits nothing.
final class MessageTextSplits {
  static let shared = MessageTextSplits(limit: 1024)

  private struct Key: Hashable {
    var text: String
    var ramp: TypeRamp
  }

  private var entries: BoundedCache<Key, MessageTextSplit>

  init(limit: Int) {
    entries = BoundedCache(limit: limit)
  }

  func split(_ text: String, ramp: TypeRamp) -> MessageTextSplit {
    entries.value(for: Key(text: text, ramp: ramp)) {
      MessageTextSplit(MarkdownCache.shared.blocks(for: text), ramp: ramp)
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
