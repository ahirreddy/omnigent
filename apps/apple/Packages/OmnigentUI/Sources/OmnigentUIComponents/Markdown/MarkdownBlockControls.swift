import OmnigentPlatform
import SwiftUI
import UniformTypeIdentifiers

/// A Markdown table sitting in the text, with its controls in a row under it: Copy (as
/// Markdown, CSV or TSV), Download (CSV or Markdown) and Expand, which shows the table on its
/// own, scrolling both ways.
struct MarkdownTableBlock: View {
  let table: MarkdownTable
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      MarkdownTableView(table: table)
        .frame(maxWidth: .infinity, alignment: .leading)
      MarkdownTableControls(table: table, isExpanded: $isExpanded)
    }
    .expandedPresentation(isPresented: $isExpanded) {
      ExpandedTable(table: table)
    }
  }
}

private struct MarkdownTableControls: View {
  let table: MarkdownTable
  @Binding var isExpanded: Bool
  @State private var export: TextExport?

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Menu {
        Button("Copy as Markdown") { Pasteboard.copy(MarkdownTableText.markdown(table)) }
        Button("Copy as CSV") { Pasteboard.copy(MarkdownTableText.csv(table)) }
        Button("Copy as TSV") { Pasteboard.copy(MarkdownTableText.tsv(table)) }
      } label: {
        Image(systemName: "doc.on.doc")
          .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
      }
      .help("Copy table")
      .accessibilityLabel("Copy table")
      .accessibilityIdentifier("markdown.table.copy")
      Menu {
        Button("Download CSV") {
          export = TextExport(
            text: MarkdownTableText.csv(table), name: "table.csv", type: .commaSeparatedText)
        }
        Button("Download Markdown") {
          export = TextExport(
            text: MarkdownTableText.markdown(table), name: "table.md", type: .plainText)
        }
      } label: {
        Image(systemName: "arrow.down.circle")
          .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
      }
      .help("Download table")
      .accessibilityLabel("Download table")
      .accessibilityIdentifier("markdown.table.download")
      if !isExpanded {
        Button {
          isExpanded = true
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
        }
        .help("Expand table")
        .accessibilityLabel("Expand table")
        .accessibilityIdentifier("markdown.table.expand")
      }
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .tint(.secondary)
    .fixedSize()
    .textExporter($export)
  }
}

private struct ExpandedTable: View {
  let table: MarkdownTable
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Table")
          .font(.headline)
        Spacer()
        MarkdownTableControls(table: table, isExpanded: .constant(true))
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("markdown.table.done")
      }
      .padding(Theme.Spacing.medium)
      Divider()
      ScrollView([.vertical, .horizontal]) {
        MarkdownTableView(table: table)
          .padding(Theme.Spacing.medium)
      }
    }
    #if os(macOS)
      .frame(minWidth: 640, idealWidth: 960, minHeight: 420, idealHeight: 640)
    #endif
  }
}

/// Download for a code block, as the web's: saves the code under a name with its language's
/// extension.
struct CodeBlockDownloadButton: View {
  let code: String
  let language: String?
  @State private var export: TextExport?

  var body: some View {
    Button {
      export = TextExport(
        text: code, name: "snippet.\(CodeFileExtension.for(language))", type: .plainText)
    } label: {
      Image(systemName: "arrow.down.circle")
        .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help("Download code")
    .accessibilityLabel("Download code")
    .accessibilityIdentifier("markdown.code.download")
    .textExporter($export)
  }
}

/// Text to save through the system's save panel (macOS) or file exporter (iOS).
struct TextExport: Identifiable {
  let text: String
  let name: String
  let type: UTType
  var id: String { name + String(text.hashValue) }
}

struct TextExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.plainText] }
  static var writableContentTypes: [UTType] { [.plainText, .commaSeparatedText] }
  let text: String

  init(text: String) {
    self.text = text
  }

  init(configuration: ReadConfiguration) throws {
    guard configuration.file.isRegularFile, let data = configuration.file.regularFileContents,
      let text = String(bytes: data, encoding: .utf8)
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.text = text
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

/// Saves an export when it is set, then clears it; a failure is shown in an alert.
struct TextExporter: ViewModifier {
  @Binding var export: TextExport?
  @State private var failure: String?

  init(export: Binding<TextExport?>, failure: String? = nil) {
    _export = export
    _failure = State(initialValue: failure)
  }

  /// What the alert says about a finished save; `nil` when it went through.
  static func failureMessage(for result: Result<URL, any Error>) -> String? {
    guard case .failure(let error) = result else { return nil }
    return error.localizedDescription
  }

  func body(content: Content) -> some View {
    content
      .fileExporter(
        isPresented: Binding(
          get: { export != nil }, set: { if !$0, export != nil { export = nil } }),
        document: export.map { TextExportDocument(text: $0.text) },
        contentType: export?.type ?? .plainText,
        defaultFilename: export?.name
      ) { failure = Self.failureMessage(for: $0) }
      .alert(
        "Could Not Save",
        isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
      ) {
        Button("OK", role: .cancel) { failure = nil }
      } message: {
        Text(failure ?? "")
      }
  }
}

extension View {
  /// Saves `export` when it is set, then clears it.
  fileprivate func textExporter(_ export: Binding<TextExport?>) -> some View {
    modifier(TextExporter(export: export))
  }

  /// A sheet on macOS and a full-screen cover on iPhone and iPad.
  fileprivate func expandedPresentation<Content: View>(
    isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    #if os(iOS)
      fullScreenCover(isPresented: isPresented, content: content)
    #else
      sheet(isPresented: isPresented, content: content)
    #endif
  }
}
