//! PDF comment anchors, as the web encodes and reads them.

use super::{PdfAnchor, PdfRect, anchor_display_text, decode_pdf_anchor, encode_pdf_anchor};

fn anchor() -> PdfAnchor {
    PdfAnchor {
        page: 2,
        rects: vec![
            PdfRect {
                x: 0.125,
                y: 0.5,
                w: 0.25,
                h: 0.02,
            },
            PdfRect {
                x: 0.1,
                y: 0.52,
                w: 0.3,
                h: 0.02,
            },
        ],
        text: "naïve 😀".into(),
    }
}

#[test]
fn a_selection_encodes_with_the_webs_offsets_and_reads_back() {
    let encoded = encode_pdf_anchor(&anchor());
    // (2 - 1) * 1_000_000 + 5_000 * 10_000 + 1_250, as the web's `computePdfStartIndex`.
    assert_eq!(encoded.start_index, 51_001_250);
    assert_eq!(
        encoded.end_index,
        51_001_250 + 8,
        "UTF-16 units, as the web counts"
    );
    assert!(encoded.anchor_content.starts_with("__pdf__{"));
    assert_eq!(decode_pdf_anchor(&encoded.anchor_content), Some(anchor()));
}

#[test]
fn the_web_s_anchor_reads_and_shows_its_text() {
    let web = r#"__pdf__{"page":1,"rects":[{"x":0.1,"y":0.2,"w":0.3,"h":0.04}],"text":"Total"}"#;
    let decoded = decode_pdf_anchor(web).expect("the web's anchor");
    assert_eq!(decoded.page, 1);
    assert_eq!(decoded.rects.len(), 1);
    assert_eq!(anchor_display_text(web), "Total");
    assert_eq!(
        anchor_display_text("  let x = 1  "),
        "let x = 1",
        "file text, trimmed"
    );
    assert_eq!(decode_pdf_anchor("__pdf__{broken"), None);
    assert_eq!(anchor_display_text("__pdf__{broken"), "__pdf__{broken");
}
