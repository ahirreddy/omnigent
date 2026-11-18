import PDFKit
import SwiftUI

/// A PDF, as the web's `PdfViewer` shows it: its pages in a column fit to the width, a toolbar
/// with the page count and zoom, and a note when the server cut the file or it does not open.
struct PDFPreviewView: View {
  let data: Data
  let truncated: Bool
  @State private var scale = 1.0
  @State private var parsed: Parsed?

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
          PDFPages(document: document, scale: scale)
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
      Button("Zoom Out", systemImage: "minus") { scale = Self.zoomedOut(scale) }
        .labelStyle(.iconOnly)
        .disabled(scale <= Self.minimumScale)
      Button {
        scale = 1
      } label: {
        Text(Self.percent(scale))
          .monospacedDigit()
          .frame(minWidth: 40)
      }
      .disabled(scale == 1)
      .help("Reset zoom")
      .accessibilityLabel("Reset zoom")
      Button("Zoom In", systemImage: "plus") { scale = Self.zoomedIn(scale) }
        .labelStyle(.iconOnly)
        .disabled(scale >= Self.maximumScale)
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private func note(_ message: String) -> some View {
    Text(message)
      .foregroundStyle(.secondary)
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("workspace.pdf.note")
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

/// PDFKit's view: continuous pages, fit to the width at 100%.
private struct PDFPages {
  let document: PDFDocument
  let scale: Double

  func make() -> PDFView {
    let view = PDFView()
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.displaysPageBreaks = true
    view.document = document
    view.autoScales = true
    return view
  }

  func update(_ view: PDFView) {
    if view.document !== document { view.document = document }
    // 100% fits the page to the width, as the web's page column does.
    view.autoScales = scale == 1
    if scale != 1 { view.scaleFactor = view.scaleFactorForSizeToFit * scale }
  }
}

#if os(macOS)
  extension PDFPages: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { make() }
    func updateNSView(_ view: PDFView, context: Context) { update(view) }
  }
#else
  extension PDFPages: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { make() }
    func updateUIView(_ view: PDFView, context: Context) { update(view) }
  }
#endif
