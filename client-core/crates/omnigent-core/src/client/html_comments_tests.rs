//! HTML preview comments anchored to the source, as the web's `htmlCommentBridge` anchors them.

use super::{comment_html_occurrence, html_anchor_occurrence, html_anchor_range, previews_as_html};
use crate::client::comments::FileComment;

fn slice(source: &str, range: (u64, u64)) -> String {
    let (start, end) = range;
    source
        .chars()
        .skip(usize::try_from(start).unwrap_or_default())
        .take(usize::try_from(end - start).unwrap_or_default())
        .collect()
}

#[test]
fn a_selection_spanning_tags_and_folded_whitespace_maps_to_its_source() {
    let source = "<p>Hello\n    <b>wide</b>   world</p>";
    // The rendered text drops the tags: "Hello\n    wide   world".
    assert_eq!(html_anchor_range(source, "wide", 0), Some((16, 20)));
    let range = html_anchor_range(source, "Hello wide", 0);
    assert_eq!(range, None, "a tag between the words isn't whitespace");
    let source = "<p>Hello\n    world</p>";
    let range = html_anchor_range(source, "Hello world", 0).expect("found");
    assert_eq!(slice(source, range), "Hello\n    world");
}

#[test]
fn the_chosen_copy_is_found_and_copies_in_markup_are_skipped() {
    let source = concat!(
        "<html><head><title>Aurora Sync</title>",
        "<style>.a::after{content:'Aurora Sync'}</style></head>",
        "<body><!-- Aurora Sync --><h1 title=\"Aurora Sync\">Aurora Sync</h1>",
        "<p>Use Aurora Sync daily.</p>",
        "<script>var name = 'Aurora Sync';</script></body></html>"
    );
    let first = html_anchor_range(source, "Aurora Sync", 0).expect("heading");
    let second = html_anchor_range(source, "Aurora Sync", 1).expect("paragraph");
    assert_eq!(slice(source, first), "Aurora Sync");
    let heading = source
        .find(">Aurora Sync</h1>")
        .expect("heading in the source");
    assert_eq!(u64::try_from(heading + 1).ok(), Some(first.0));
    assert!(second.0 > first.0);
    assert_eq!(html_anchor_range(source, "Aurora Sync", 2), None);
    assert_eq!(html_anchor_occurrence(source, "Aurora Sync", first.0), 0);
    assert_eq!(html_anchor_occurrence(source, "Aurora Sync", second.0), 1);
}

#[test]
fn offsets_count_characters_not_bytes() {
    let source = "<p>café — naïve</p>";
    let range = html_anchor_range(source, "naïve", 0).expect("found");
    assert_eq!(range, (10, 15));
    assert_eq!(slice(source, range), "naïve");
}

#[test]
fn hidden_elements_match_any_case_and_need_their_closing_tag() {
    let source = "<SCRIPT type=x>alpha</Script ><scripts>alpha</scripts><p>alpha</p>";
    // `<scripts>` isn't a script element, so its text renders.
    let range = html_anchor_range(source, "alpha", 0).expect("found");
    assert_eq!(slice(source, range), "alpha");
    assert!(range.0 > 30);
    assert_eq!(
        html_anchor_range(source, "alpha", 1).map(|(start, _)| start > range.0),
        Some(true)
    );
    assert_eq!(html_anchor_range(source, "alpha", 2), None);
    let unclosed = "<style>beta";
    assert_eq!(html_anchor_range(unclosed, "beta", 0), Some((7, 11)));
}

#[test]
fn blank_anchors_and_missing_text_resolve_to_nothing() {
    assert_eq!(html_anchor_range("<p>text</p>", "  \n ", 0), None);
    assert_eq!(html_anchor_range("<p>text</p>", "absent", 0), None);
    assert_eq!(html_anchor_occurrence("<p>text</p>", " ", 5), 0);
    assert_eq!(html_anchor_occurrence("<p>a a a</p>", "a", 100), 3);
}

#[test]
fn html_files_preview_as_html() {
    assert!(previews_as_html("site/index.html"));
    assert!(previews_as_html("page.HTM"));
    assert!(previews_as_html("logo.svg"));
    assert!(!previews_as_html("notes.md"));
    assert!(!previews_as_html("dir.html/readme"));
    assert!(!previews_as_html(".html"));
}

#[test]
fn only_html_comments_carry_an_occurrence() {
    let comment = |path: &str, anchor: Option<&str>, start: u64| FileComment {
        id: "c1".into(),
        session_id: "s1".into(),
        path: path.into(),
        body: "Rename".into(),
        is_open: true,
        anchor: anchor.map(Into::into),
        start_index: Some(start),
        author: None,
        created_at: 0,
        updated_at_micros: 0,
    };
    let source = "<p>go</p><p>go</p>";
    assert_eq!(
        comment_html_occurrence(&comment("a.html", Some("go"), 12), source),
        Some(1)
    );
    assert_eq!(
        comment_html_occurrence(&comment("a.md", Some("go"), 12), source),
        None
    );
    assert_eq!(
        comment_html_occurrence(&comment("a.html", None, 12), source),
        None
    );
}
