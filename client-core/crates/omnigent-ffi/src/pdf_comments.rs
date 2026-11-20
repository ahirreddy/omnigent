//! Comments on a PDF's selected text, anchored as the web anchors them.

use omnigent_core::pdf_comments as core;

/// A rectangle on a page: fractions of its width and height, from its top left corner.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct PdfCommentRect {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Width.
    pub w: f64,
    /// Height.
    pub h: f64,
}

/// A PDF selection a comment is on.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PdfCommentAnchor {
    /// The 1-based page.
    pub page: u32,
    /// The selected lines on that page.
    pub rects: Vec<PdfCommentRect>,
    /// The selected text.
    pub text: String,
}

/// What a new PDF comment stores.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EncodedPdfAnchor {
    /// Where it sorts: by page, then from the top, then from the left.
    pub start_index: u64,
    /// The start plus the text's length.
    pub end_index: u64,
    /// The prefixed anchor.
    pub anchor_content: String,
}

/// The PDF selection a comment `anchor` stands for; `None` for an anchor on file text.
#[uniffi::export]
#[must_use]
pub fn decode_pdf_anchor(anchor: String) -> Option<PdfCommentAnchor> {
    core::decode_pdf_anchor(&anchor).map(|decoded| PdfCommentAnchor {
        page: decoded.page,
        rects: decoded
            .rects
            .into_iter()
            .map(|rect| PdfCommentRect {
                x: rect.x,
                y: rect.y,
                w: rect.w,
                h: rect.h,
            })
            .collect(),
        text: decoded.text,
    })
}

/// The anchor and offsets a new comment on `anchor` stores.
#[uniffi::export]
#[must_use]
pub fn encode_pdf_anchor(anchor: PdfCommentAnchor) -> EncodedPdfAnchor {
    let encoded = core::encode_pdf_anchor(&core::PdfAnchor {
        page: anchor.page,
        rects: anchor
            .rects
            .into_iter()
            .map(|rect| core::PdfRect {
                x: rect.x,
                y: rect.y,
                w: rect.w,
                h: rect.h,
            })
            .collect(),
        text: anchor.text,
    });
    EncodedPdfAnchor {
        start_index: encoded.start_index,
        end_index: encoded.end_index,
        anchor_content: encoded.anchor_content,
    }
}

/// A comment anchor as the comments panel shows it: a PDF selection's text, else the anchor.
#[uniffi::export]
#[must_use]
pub fn anchor_display_text(anchor: String) -> String {
    core::anchor_display_text(&anchor)
}
