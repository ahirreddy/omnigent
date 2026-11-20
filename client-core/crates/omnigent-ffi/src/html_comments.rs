//! Comments on an HTML file's rendered preview, anchored to its source as the web anchors them.
//! The rules are `omnigent_core::html_comments`.

use omnigent_core::html_comments as core;

/// A character range of a file's text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct HtmlSourceRange {
    /// The first character, 0-based.
    pub start_index: u64,
    /// The end, exclusive.
    pub end_index: u64,
}

/// Where text selected in an HTML file's preview is in its `source`: the `occurrence` (0-based,
/// counting only rendered text) of `selected`, whitespace-tolerant. `None` when it isn't there.
#[uniffi::export]
#[must_use]
pub fn html_source_range(
    source: String,
    selected: String,
    occurrence: u64,
) -> Option<HtmlSourceRange> {
    core::html_anchor_range(&source, &selected, occurrence).map(|(start_index, end_index)| {
        HtmlSourceRange {
            start_index,
            end_index,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::{HtmlSourceRange, html_source_range};

    #[test]
    fn a_selection_maps_to_its_copy_in_the_source() {
        assert_eq!(
            html_source_range("<p>go</p><p>go</p>".into(), "go".into(), 1),
            Some(HtmlSourceRange {
                start_index: 12,
                end_index: 14
            })
        );
        assert_eq!(
            html_source_range("<p>go</p>".into(), "stay".into(), 0),
            None
        );
    }
}
