//! Comments on a PDF's selected text, anchored as the web's `pdfCommentHelpers` anchors them.
//!
//! A PDF comment keeps the selection's page, its rectangles (fractions of the page, from the
//! top left) and its text in `anchor_content`, behind [`PDF_ANCHOR_PREFIX`], so any client can
//! paint the highlight again.

use serde_json::{Value, json};

/// Marks a comment anchor as a PDF selection rather than file text.
pub const PDF_ANCHOR_PREFIX: &str = "__pdf__";

/// Comment offsets one page apart, as the web's.
const PAGE_STRIDE: f64 = 1_000_000.0;
/// Fraction steps per page side in a comment's offset, as the web's.
const FRACTION_STEPS: f64 = 10_000.0;

/// A rectangle on a page: fractions of its width and height, from its top left corner.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PdfRect {
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
#[derive(Debug, Clone, PartialEq)]
pub struct PdfAnchor {
    /// The 1-based page.
    pub page: u32,
    /// The selected lines on that page.
    pub rects: Vec<PdfRect>,
    /// The selected text.
    pub text: String,
}

/// What a new PDF comment stores: its offsets and anchor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedPdfAnchor {
    /// Where it sorts: by page, then from the top, then from the left.
    pub start_index: u64,
    /// The start plus the text's length in UTF-16 units, as the web counts it.
    pub end_index: u64,
    /// The prefixed anchor.
    pub anchor_content: String,
}

/// The selection `anchor` stands for; `None` for an anchor on file text or one that doesn't
/// parse.
#[must_use]
pub fn decode_pdf_anchor(anchor: &str) -> Option<PdfAnchor> {
    let value: Value = serde_json::from_str(anchor.strip_prefix(PDF_ANCHOR_PREFIX)?).ok()?;
    let page = u32::try_from(value.get("page")?.as_u64()?).ok()?;
    let rects = value
        .get("rects")?
        .as_array()?
        .iter()
        .map(|rect| {
            let side = |key: &str| rect.get(key).and_then(Value::as_f64);
            Some(PdfRect {
                x: side("x")?,
                y: side("y")?,
                w: side("w")?,
                h: side("h")?,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    let text = value.get("text")?.as_str()?.to_owned();
    Some(PdfAnchor { page, rects, text })
}

/// The anchor and offsets a new comment on `anchor` stores (web `encodePdfAnchor`).
#[must_use]
pub fn encode_pdf_anchor(anchor: &PdfAnchor) -> EncodedPdfAnchor {
    let rects: Vec<Value> = anchor
        .rects
        .iter()
        .map(|rect| json!({"x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h}))
        .collect();
    let payload = json!({"page": anchor.page, "rects": rects, "text": anchor.text});
    let page = f64::from(anchor.page.saturating_sub(1)) * PAGE_STRIDE;
    let offset = anchor.rects.first().map_or(0.0, |first| {
        (first.y * FRACTION_STEPS)
            .round()
            .mul_add(FRACTION_STEPS, (first.x * FRACTION_STEPS).round())
    });
    let start_index = whole(page + offset);
    let length = anchor.text.encode_utf16().fold(0_u64, |count, _| count + 1);
    EncodedPdfAnchor {
        start_index,
        end_index: start_index.saturating_add(length),
        anchor_content: format!("{PDF_ANCHOR_PREFIX}{payload}"),
    }
}

/// A comment anchor as the comments panel and messages show it: a PDF selection's text, else
/// the anchor trimmed (web `displayAnchorContent`).
#[must_use]
pub fn anchor_display_text(anchor: &str) -> String {
    decode_pdf_anchor(anchor).map_or_else(|| anchor.trim().to_owned(), |decoded| decoded.text)
}

/// `value` as a whole non-negative number; offsets are never negative or fractional.
#[allow(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "range-checked float to integer conversion; `as` saturates and NaN is rejected first"
)]
fn whole(value: f64) -> u64 {
    if value.is_nan() || value <= 0.0 {
        0
    } else {
        value.round() as u64
    }
}

#[cfg(test)]
#[path = "pdf_comments_tests.rs"]
mod tests;
