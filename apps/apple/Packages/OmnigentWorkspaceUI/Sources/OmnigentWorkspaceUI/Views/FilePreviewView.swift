public import SwiftUI

/// The files the viewer can render as well as show as source, as the web's file viewer: Markdown,
/// HTML and SVG (in WebKit), Jupyter notebooks, and CSV and TSV files as a table.
nonisolated public enum FilePreviewKind: Hashable, Sendable {
  case markdown
  case html
  case notebook
  case dataTable

  /// The kind `path` previews as, by its extension; `nil` shows only the source.
  public static func of(path: String) -> Self? {
    let name = WorkspacePaths.name(of: path).lowercased()
    guard let dot = name.lastIndex(of: ".") else { return nil }
    switch name[name.index(after: dot)...] {
    case "md", "markdown", "mdx": return .markdown
    case "html", "htm", "svg": return .html
    case "ipynb": return .notebook
    case "csv", "tsv": return dot > name.startIndex ? .dataTable : nil
    default: return nil
    }
  }
}

/// Whether a file opens rendered, as its source, or in the editor; kept across files, as the
/// web.
public enum FileViewMode: String, CaseIterable, Identifiable, Sendable {
  case preview
  case source
  case edit

  /// The mode itself.
  public var id: Self { self }

  var title: String {
    switch self {
    case .preview: "Preview"
    case .source: "Source"
    case .edit: "Edit"
    }
  }
}

/// Renders Markdown for the file viewer's preview with the host's Markdown view. Renderers with
/// the same `id` are equal, so the environment does not invalidate on every update.
public struct WorkspaceMarkdownRenderer: Equatable {
  private let id: String
  let render: @MainActor (String) -> AnyView

  /// A renderer.
  /// - Parameters:
  ///   - id: Names the renderer; equal ids are the same renderer.
  ///   - render: Renders Markdown text.
  public init(id: String, render: @escaping @MainActor (String) -> AnyView) {
    self.id = id
    self.render = render
  }

  /// Renderers with the same id are equal.
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
  /// The file viewer's Markdown renderer; `nil` falls back to the system's inline Markdown.
  @Entry public var workspaceMarkdownRenderer: WorkspaceMarkdownRenderer?
}

/// A previewable file rendered.
struct FilePreviewView: View {
  let kind: FilePreviewKind
  let text: String
  /// A data file's table, which the core parsed.
  var table: DataTablePreview?
  /// Comments on an HTML file's rendered text.
  var htmlReview: HTMLPreviewReview?
  @Environment(\.workspaceMarkdownRenderer) private var renderMarkdown

  var body: some View {
    switch kind {
    case .dataTable:
      if let table {
        // Sorting and filters belong to these columns; a rewrite with others starts afresh.
        DataTableView(table: table).id(table.columns.map(\.name))
      } else {
        ContentUnavailableView(
          "No Rows", systemImage: "tablecells",
          description: Text("This file has no rows. Switch to Source to see the raw file."))
      }
    case .markdown:
      MarkdownPreviewPane(text: text, markdown: markdown)
    case .html:
      HTMLPreviewPane(html: text, comments: htmlReview)
    case .notebook:
      switch NotebookCells.parse(text) {
      case .success(let cells):
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(cells) { cell in
              NotebookCellView(cell: cell, markdown: markdown)
            }
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .failure(let failure):
        ContentUnavailableView(
          "Cannot Preview Notebook", systemImage: "doc.questionmark",
          description: Text("\(failure.message) Show the source instead."))
      }
    }
  }

  private func markdown(_ text: String) -> AnyView {
    if let renderMarkdown { return renderMarkdown.render(text) }
    return AnyView(Text(Self.inlineMarkdown(text)))
  }

  /// `text` with its inline Markdown applied; text that doesn't parse still reads as plain text.
  static func inlineMarkdown(
    _ text: String,
    parse: (String) throws -> AttributedString = {
      try AttributedString(
        markdown: $0,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
  ) -> AttributedString {
    do {
      return try parse(text)
    } catch {
      return AttributedString(text)
    }
  }
}

/// One notebook cell: Markdown rendered, code monospaced with its text outputs beneath.
private struct NotebookCellView: View {
  let cell: NotebookCell
  let markdown: (String) -> AnyView

  var body: some View {
    switch cell.kind {
    case .markdown:
      markdown(cell.source)
    case .code:
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: cell.source)
          .font(WorkspaceTheme.code)
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        ForEach(Array(cell.outputs.enumerated()), id: \.offset) { _, output in
          Text(verbatim: output)
            .font(WorkspaceTheme.code)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
        }
      }
    case .raw:
      Text(verbatim: cell.source).font(WorkspaceTheme.code).textSelection(.enabled)
    }
  }
}

/// One notebook cell: its kind, joined source and text outputs.
nonisolated struct NotebookCell: Identifiable, Hashable {
  enum Kind: Hashable { case markdown, code, raw }
  let id: Int
  let kind: Kind
  let source: String
  let outputs: [String]
}

/// A notebook's cells, read from its `.ipynb` JSON: sources joined, and the text of stream,
/// result and error outputs.
nonisolated enum NotebookCells {
  /// Why a notebook has no preview.
  struct Failure: Error, Hashable {
    let message: String
  }

  static func parse(_ text: String) -> Result<[NotebookCell], Failure> {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    } catch {
      return .failure(Failure(message: "The notebook is not valid JSON."))
    }
    guard let cells = (object as? [String: Any])?["cells"] as? [[String: Any]] else {
      return .failure(Failure(message: "The notebook has no cells."))
    }
    return .success(
      cells.enumerated().map { index, cell in
        let kind: NotebookCell.Kind =
          switch cell["cell_type"] as? String {
          case "markdown": .markdown
          case "code": .code
          default: .raw
          }
        let outputs = (cell["outputs"] as? [[String: Any]] ?? []).compactMap(outputText)
        return NotebookCell(id: index, kind: kind, source: joined(cell["source"]), outputs: outputs)
      })
  }

  private static func outputText(_ output: [String: Any]) -> String? {
    if output["text"] != nil { return joined(output["text"]) }
    if let data = output["data"] as? [String: Any], data["text/plain"] != nil {
      return joined(data["text/plain"])
    }
    if let name = output["ename"] as? String {
      return "\(name): \(output["evalue"] as? String ?? "")"
    }
    return nil
  }

  /// A notebook string is either one string or a list of lines.
  private static func joined(_ value: Any?) -> String {
    if let lines = value as? [String] { return lines.joined() }
    return value as? String ?? ""
  }
}
