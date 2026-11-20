import CoreGraphics
import Foundation
import OmnigentCoreFFI
import OmnigentWorkspaceUI

/// Comments on a PDF's selected text, stored as the web stores them: the page, its lines and
/// the text, in the comment's anchor.
extension WorkspaceStore {
  /// Where a comment's `anchor` is on a PDF's page; `nil` for a comment on file text.
  static func pdfMark(_ anchor: String?) -> PdfMark? {
    anchor.flatMap(decodePdfAnchor).map { anchor in
      PdfMark(
        page: Int(anchor.page),
        rects: anchor.rects.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) })
    }
  }

  /// What a comment on `span` stores when it is a PDF's selected text; `nil` for file text.
  static func pdfAnchor(_ span: FileTextSpan) -> EncodedPdfAnchor? {
    span.pdfMark.map { mark in
      encodePdfAnchor(
        anchor: PdfCommentAnchor(
          page: UInt32(clamping: mark.page),
          rects: mark.rects.map {
            PdfCommentRect(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height)
          },
          text: span.text))
    }
  }
}
