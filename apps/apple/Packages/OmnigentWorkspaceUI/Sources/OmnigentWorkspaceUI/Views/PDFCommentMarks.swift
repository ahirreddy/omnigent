import PDFKit
import SwiftUI

/// A saved comment's place on a PDF, as a highlight over the text it is on.
struct PDFCommentMark: Hashable {
  let commentID: String
  let mark: PdfMark
  let isSelected: Bool
}

/// The PDF's text selection and comment highlights, kept on a `PDFView` (the web's PDF text
/// layer and comment layer): a selection becomes a span to comment on, and a highlight's click
/// selects its comment. Highlights are drawn over the pages, never written into the file.
@MainActor
final class PDFCommentCoordinator {
  /// Told the selected text as a span, or `nil` when nothing is selected.
  var selected: (FileTextSpan?) -> Void = { _ in }
  /// Told a clicked highlight's comment.
  var opened: (String) -> Void = { _ in }
  var path = ""
  private var drawn: [PDFCommentMark: [PDFAnnotation]] = [:]
  private var observers: [any NSObjectProtocol] = []

  /// Watches `view` for selections and highlight clicks.
  func observe(_ view: PDFView) {
    let center = NotificationCenter.default
    let selectionChanged: @Sendable (Notification) -> Void = { [weak self, weak view] _ in
      MainActor.assumeIsolated {
        guard let self, let view else { return }
        self.selected(Self.span(view.currentSelection, in: view.document, path: self.path))
      }
    }
    let annotationHit: @Sendable (Notification) -> Void = { [weak self] note in
      let id = (note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation)?.userName
      MainActor.assumeIsolated {
        if let id, id.hasPrefix(Self.markPrefix) {
          self?.opened(String(id.dropFirst(Self.markPrefix.count)))
        }
      }
    }
    observers = [
      center.addObserver(
        forName: .PDFViewSelectionChanged, object: view, queue: .main, using: selectionChanged),
      center.addObserver(
        forName: .PDFViewAnnotationHit, object: view, queue: .main, using: annotationHit),
    ]
  }

  /// Draws `marks` over `document`, replacing the ones drawn before.
  func draw(_ marks: [PDFCommentMark], on document: PDFDocument) {
    let wanted = Set(marks)
    for (mark, annotations) in drawn where !wanted.contains(mark) {
      for annotation in annotations { annotation.page?.removeAnnotation(annotation) }
      drawn[mark] = nil
    }
    for mark in marks where drawn[mark] == nil {
      guard let page = document.page(at: mark.mark.page - 1) else { continue }
      let box = page.bounds(for: .cropBox)
      drawn[mark] = mark.mark.rects.map { rect in
        let annotation = PDFAnnotation(
          bounds: Self.pageRect(rect, in: box), forType: .highlight, withProperties: nil)
        annotation.color = Self.highlight(selected: mark.isSelected)
        annotation.userName = Self.markPrefix + mark.commentID
        page.addAnnotation(annotation)
        return annotation
      }
    }
  }

  private static let markPrefix = "omnigent.comment."

  #if os(macOS)
    private static func highlight(selected: Bool) -> NSColor {
      NSColor.systemYellow.withAlphaComponent(selected ? 0.6 : 0.3)
    }
  #else
    private static func highlight(selected: Bool) -> UIColor {
      UIColor.systemYellow.withAlphaComponent(selected ? 0.6 : 0.3)
    }
  #endif

  /// `rect`, as fractions from the page's top left, in the page's own coordinates.
  static func pageRect(_ rect: CGRect, in box: CGRect) -> CGRect {
    CGRect(
      x: box.minX + rect.minX * box.width, y: box.maxY - rect.maxY * box.height,
      width: rect.width * box.width, height: rect.height * box.height)
  }

  /// `bounds` on the page as fractions from its top left, as the web stores them.
  static func fraction(_ bounds: CGRect, in box: CGRect) -> CGRect? {
    guard box.width > 0, box.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
    return CGRect(
      x: (bounds.minX - box.minX) / box.width, y: (box.maxY - bounds.maxY) / box.height,
      width: bounds.width / box.width, height: bounds.height / box.height)
  }

  /// The selection's text and lines on its first page; `nil` for a blank selection.
  static func span(_ selection: PDFSelection?, in document: PDFDocument?, path: String)
    -> FileTextSpan?
  {
    guard let selection, let document, let page = selection.pages.first,
      let text = selection.string,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    let box = page.bounds(for: .cropBox)
    let rects = selection.selectionsByLine().compactMap { line in
      line.pages.contains(page) ? fraction(line.bounds(for: page), in: box) : nil
    }
    guard !rects.isEmpty else { return nil }
    let mark = PdfMark(page: document.index(for: page) + 1, rects: rects)
    return .pdf(text, mark: mark, path: path)
  }
}
