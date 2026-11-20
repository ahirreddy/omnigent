import PDFKit
import SwiftUI

/// A PDF, as the web's `PdfViewer` shows it: its pages in a column fit to the width, a toolbar
/// with the page count and zoom, and a note when the server cut the file or it does not open.
struct PDFPreviewView: View {
  let data: Data
  let truncated: Bool
  /// The file, for comments on its text.
  var path = ""
  /// Comments on its selected text; `nil` offers none.
  var review: FileReviewContext?
  /// The comment the panel shows; a highlight's click selects its comment.
  var selectedCommentID: Binding<String?> = .constant(nil)
  /// Opens the comment composer on the selected text.
  var comment: ((FileTextSpan) -> Void)?
  @State private var scale = 1.0
  @State private var parsed: Parsed?
  @State private var selection: FileTextSpan?

  /// Zoom bounds and step, as on the web.
  static let minimumScale = 0.5
  static let maximumScale = 3.0
  static let scaleStep = 0.25

  /// The document parsed from `data`; `nil` when PDFKit could not read it.
  private struct Parsed {
    let data: Data
    let document: PDFDocument?
  }

  var body: some View {
    VStack(spacing: 0) {
      if truncated {
        // A cut PDF is a partial byte stream no reader can open.
        NoticeBar(symbol: "exclamationmark.triangle", text: Self.truncatedBanner)
        note(Self.truncatedMessage)
      } else if let parsed, parsed.data == data {
        if let document = parsed.document {
          toolbar(pages: document.pageCount)
          Divider()
          // A group, so the pages keep PDFKit's own accessibility under the identifier.
          PDFPages(
            document: document, scale: scale, path: path, marks: marks,
            select: { selection = $0 }, open: { selectedCommentID.wrappedValue = $0 }
          )
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("workspace.pdf")
        } else {
          note(Self.unreadableMessage)
        }
      } else {
        note("Loading PDF\u{2026}")
      }
    }
    .onChange(of: data, initial: true) { _, data in
      scale = 1
      parsed = truncated ? nil : Parsed(data: data, document: PDFDocument(data: data))
    }
  }

  private func toolbar(pages: Int) -> some View {
    HStack(spacing: 4) {
      Text(Self.pageCount(pages))
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("workspace.pdf.pages")
      Spacer()
      if let review, review.canComment, let comment {
        Button("Comment", systemImage: "text.bubble") {
          if let selection { comment(selection) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(selection == nil)
        .help(selection == nil ? "Select text to comment on it" : "Add a comment")
        .accessibilityIdentifier("workspace.pdf.comment")
      }
      Button {
        scale = 1
      } label: {
        Text(Self.percent(scale))
          .monospacedDigit()
          .frame(minWidth: 40)
      }
      .buttonStyle(.borderless)
      .disabled(scale == 1)
      .help("Reset zoom")
      .accessibilityLabel("Reset zoom")
      // Zoom out and in as one control, as Preview's toolbar pairs them.
      ControlGroup {
        Button("Zoom Out", systemImage: "minus.magnifyingglass") {
          scale = Self.zoomedOut(scale)
        }
        .disabled(scale <= Self.minimumScale)
        Button("Zoom In", systemImage: "plus.magnifyingglass") { scale = Self.zoomedIn(scale) }
          .disabled(scale >= Self.maximumScale)
      }
      .labelStyle(.iconOnly)
      .controlSize(.small)
      .fixedSize()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
  }

  private func note(_ message: String) -> some View {
    Text(message)
      .foregroundStyle(.secondary)
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("workspace.pdf.note")
  }

  /// The open comments' highlights; the panel's comment stands out.
  private var marks: [PDFCommentMark] {
    (review?.openComments ?? []).compactMap { comment in
      comment.pdfMark.map {
        PDFCommentMark(
          commentID: comment.id, mark: $0,
          isSelected: comment.id == selectedCommentID.wrappedValue)
      }
    }
  }

  /// "1 page", "12 pages"; nothing before the count is known.
  static func pageCount(_ pages: Int) -> String {
    pages > 0 ? "\(pages) page\(pages == 1 ? "" : "s")" : ""
  }

  /// "125%".
  static func percent(_ scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }

  /// One step smaller, not below the minimum.
  static func zoomedOut(_ scale: Double) -> Double { max(minimumScale, scale - scaleStep) }

  /// One step larger, not above the maximum.
  static func zoomedIn(_ scale: Double) -> Double { min(maximumScale, scale + scaleStep) }

  /// What a PDF the server cut shows, as on the web.
  static let truncatedMessage = "PDF is too large to preview (truncated by the server)."
  /// What a PDF that does not open shows.
  static let unreadableMessage = "Unable to render PDF."
  /// The web's `TruncatedBanner`.
  static let truncatedBanner =
    "This file is too large to load fully \u{2014} showing a truncated preview. Editing is "
    + "disabled to avoid overwriting the rest of the file; download it to view or edit the "
    + "full content."
}

/// PDFKit's view: continuous pages, fit to the width at 100%, with the comments' highlights.
private struct PDFPages {
  let document: PDFDocument
  let scale: Double
  let path: String
  let marks: [PDFCommentMark]
  let select: (FileTextSpan?) -> Void
  let open: (String) -> Void

  func makeCoordinator() -> PDFCommentCoordinator { PDFCommentCoordinator() }

  func make(_ coordinator: PDFCommentCoordinator) -> PDFView {
    let view = PDFView()
    coordinator.observe(view)
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.displaysPageBreaks = true
    view.document = document
    view.autoScales = true
    return view
  }

  func update(_ view: PDFView, _ coordinator: PDFCommentCoordinator) {
    if view.document !== document { view.document = document }
    coordinator.path = path
    coordinator.selected = select
    coordinator.opened = open
    coordinator.draw(marks, on: document)
    // 100% fits the page to the width, as the web's page column does.
    view.autoScales = scale == 1
    if scale != 1 { view.scaleFactor = view.scaleFactorForSizeToFit * scale }
  }
}

#if os(macOS)
  extension PDFPages: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { make(context.coordinator) }
    func updateNSView(_ view: PDFView, context: Context) { update(view, context.coordinator) }
  }
#else
  extension PDFPages: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { make(context.coordinator) }
    func updateUIView(_ view: PDFView, context: Context) { update(view, context.coordinator) }
  }
#endif
