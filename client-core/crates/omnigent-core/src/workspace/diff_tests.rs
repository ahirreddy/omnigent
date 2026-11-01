#![allow(
    clippy::format_collect,
    reason = "test inputs are built line by line for readability"
)]

use proptest::prelude::*;

use super::*;

fn diff(before: &str, after: &str) -> FileDiff {
    diff_texts(
        Some("f.txt"),
        Some("f.txt"),
        Some(before),
        Some(after),
        &DiffOptions::default(),
    )
}

fn lines(hunk: &DiffHunk) -> Vec<String> {
    hunk.lines
        .iter()
        .map(|line| {
            let mark = match line.kind {
                DiffLineKind::Context => ' ',
                DiffLineKind::Added => '+',
                DiffLineKind::Removed => '-',
            };
            format!("{mark}{}", line.text)
        })
        .collect()
}

/// Applies `diff` to `before`, from its hunks alone.
fn apply(before: &str, diff: &FileDiff) -> String {
    let old: Vec<(&str, bool)> = split_lines(before);
    let mut out: Vec<(String, bool)> = Vec::new();
    let mut next = 0_usize;
    for hunk in &diff.hunks {
        let first_old = hunk
            .lines
            .iter()
            .find_map(|line| line.old_number)
            .map_or_else(
                || usize::try_from(hunk.old_start).unwrap(),
                |n| usize::try_from(n).unwrap() - 1,
            );
        for (text, missing) in &old[next..first_old] {
            out.push(((*text).to_owned(), *missing));
        }
        next = first_old;
        for line in &hunk.lines {
            match line.kind {
                DiffLineKind::Context => {
                    out.push((line.text.clone(), line.missing_newline));
                    next += 1;
                }
                DiffLineKind::Removed => next += 1,
                DiffLineKind::Added => out.push((line.text.clone(), line.missing_newline)),
            }
        }
    }
    for (text, missing) in &old[next..] {
        out.push(((*text).to_owned(), *missing));
    }
    out.iter()
        .map(|(text, missing)| {
            if *missing {
                text.clone()
            } else {
                format!("{text}\n")
            }
        })
        .collect()
}

#[test]
fn identical_texts_have_no_hunks() {
    let same = diff("a\nb\n", "a\nb\n");
    assert!(same.is_identical());
    assert_eq!(same.stats(), DiffStats::default());
}

#[test]
fn a_change_is_shown_with_three_lines_of_context() {
    let before = "1\n2\n3\n4\n5\n6\n7\n8\n9\n";
    let after = "1\n2\n3\n4\nfive\n6\n7\n8\n9\n";
    let result = diff(before, after);
    assert_eq!(result.hunks.len(), 1);
    let hunk = &result.hunks[0];
    assert_eq!(hunk.header(), "@@ -2,7 +2,7 @@");
    assert_eq!(
        lines(hunk),
        [" 2", " 3", " 4", "-5", "+five", " 6", " 7", " 8"]
    );
    assert_eq!(hunk.lines[3].old_number, Some(5));
    assert_eq!(hunk.lines[4].new_number, Some(5));
    assert_eq!(apply(before, &result), after);
}

#[test]
fn distant_changes_make_separate_hunks_and_near_ones_merge() {
    let before: String = (1..=30).map(|n| format!("{n}\n")).collect();
    let far = before
        .replace("\n2\n", "\ntwo\n")
        .replace("\n25\n", "\ntwenty-five\n");
    assert_eq!(diff(&before, &far).hunks.len(), 2);
    let near = before
        .replace("\n5\n", "\nfive\n")
        .replace("\n11\n", "\neleven\n");
    let merged = diff(&before, &near);
    assert_eq!(merged.hunks.len(), 1, "a gap of 2 * context lines merges");
    assert_eq!(apply(&before, &merged), near);
}

#[test]
fn added_and_deleted_files() {
    let added = diff_texts(
        None,
        Some("new.rs"),
        None,
        Some("a\nb\n"),
        &DiffOptions::default(),
    );
    assert_eq!(added.change, FileChangeKind::Added);
    assert_eq!(added.old_path, None);
    assert_eq!(added.hunks[0].header(), "@@ -0,0 +1,2 @@");
    let deleted = diff_texts(
        Some("old.rs"),
        Some("old.rs"),
        Some("a\n"),
        None,
        &DiffOptions::default(),
    );
    assert_eq!(deleted.change, FileChangeKind::Deleted);
    assert_eq!(deleted.new_path, None);
    assert_eq!(deleted.hunks[0].header(), "@@ -1 +0,0 @@");
    let unknown = diff_texts(Some("x"), Some("x"), None, None, &DiffOptions::default());
    assert_eq!(unknown.change, FileChangeKind::Deleted);
    assert_eq!(unknown.hunks, Vec::new());
}

#[test]
fn a_missing_final_newline_is_a_change() {
    let result = diff("a\nb", "a\nb\n");
    assert_eq!(lines(&result.hunks[0]), [" a", "-b", "+b"]);
    assert!(result.hunks[0].lines[1].missing_newline);
    assert!(!result.hunks[0].lines[2].missing_newline);
    assert!(
        result
            .to_unified()
            .contains("-b\n\\ No newline at end of file\n+b\n"),
        "{}",
        result.to_unified()
    );
}

#[test]
fn crlf_is_kept_in_line_text() {
    let result = diff("a\r\nb\r\n", "a\r\nc\r\n");
    assert_eq!(lines(&result.hunks[0]), [" a\r", "-b\r", "+c\r"]);
}

#[test]
fn over_budget_diffs_are_approximate_and_huge_ones_too_large() {
    let before: String = (0..400).map(|n| format!("old {n}\n")).collect();
    let after: String = (0..400).map(|n| format!("new {n}\n")).collect();
    let options = DiffOptions {
        max_edit_cost: 50,
        ..DiffOptions::default()
    };
    let approximate = diff_texts(Some("f"), Some("f"), Some(&before), Some(&after), &options);
    assert!(approximate.approximate);
    assert_eq!(
        approximate.stats(),
        DiffStats {
            added: 400,
            removed: 400
        }
    );
    assert_eq!(apply(&before, &approximate), after);

    let options = DiffOptions {
        max_lines: 100,
        ..DiffOptions::default()
    };
    let large = diff_texts(Some("f"), Some("f"), Some(&before), Some(&after), &options);
    assert!(large.too_large && large.hunks.is_empty() && !large.is_identical());

    let mut edited = before.clone();
    edited.push_str("tail\n");
    let trimmed = diff_texts(Some("f"), Some("f"), Some(&before), Some(&edited), &options);
    assert!(
        !trimmed.too_large,
        "the limit applies after common lines are trimmed"
    );
    assert_eq!(
        trimmed.stats(),
        DiffStats {
            added: 1,
            removed: 0
        }
    );
}

#[test]
fn side_by_side_pairs_removals_with_additions() {
    let result = diff(
        "keep\nold one\nold two\nend\n",
        "keep\nnew one\nend\nextra\n",
    );
    let rows = result.side_by_side();
    let SplitRow::Hunk { index: 0, .. } = &rows[0] else {
        panic!("{rows:?}")
    };
    let pairs: Vec<(Option<String>, Option<String>)> = rows[1..]
        .iter()
        .map(|row| match row {
            SplitRow::Line { left, right } => (
                left.as_ref().map(|cell| cell.text.clone()),
                right.as_ref().map(|cell| cell.text.clone()),
            ),
            SplitRow::Hunk { .. } => panic!("one hunk"),
        })
        .collect();
    assert_eq!(
        pairs,
        [
            (Some("keep".into()), Some("keep".into())),
            (Some("old one".into()), Some("new one".into())),
            (Some("old two".into()), None),
            (Some("end".into()), Some("end".into())),
            (None, Some("extra".into())),
        ]
    );
    let SplitRow::Line {
        left: Some(left),
        right: Some(right),
    } = &rows[2]
    else {
        panic!()
    };
    assert_eq!(left.changed, Some(TextRange { start: 0, end: 3 }));
    assert_eq!(right.changed, Some(TextRange { start: 0, end: 3 }));
    assert_eq!((left.number, right.number), (2, 2));
}

#[test]
fn changed_spans_respect_char_boundaries() {
    assert_eq!(
        changed_spans("café latte", "cafe latte"),
        (
            Some(TextRange { start: 3, end: 5 }),
            Some(TextRange { start: 3, end: 4 })
        )
    );
    assert_eq!(
        changed_spans("aaa", "aaaa"),
        (
            Some(TextRange { start: 3, end: 3 }),
            Some(TextRange { start: 3, end: 4 })
        )
    );
}

const GIT_PATCH: &str = "From 1234 Mon Sep 17 00:00:00 2001
Subject: [PATCH] example

diff --git a/src/main.rs b/src/main.rs
index 83db48f..bf269f4 100644
--- a/src/main.rs
+++ b/src/main.rs
@@ -1,3 +1,4 @@ fn main() {
 fn main() {
-    println!(\"hi\");
+    println!(\"hello\");
+    println!(\"world\");
 }
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..3b18e51
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+hello
\\ No newline at end of file
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-a
-b
diff --git a/old name.txt b/new name.txt
similarity index 100%
rename from old name.txt
rename to new name.txt
diff --git a/logo.png b/logo.png
index 1111111..2222222 100644
Binary files a/logo.png and b/logo.png differ
diff --git \"a/caf\\303\\251.md\" \"b/caf\\303\\251.md\"
--- \"a/caf\\303\\251.md\"
+++ \"b/caf\\303\\251.md\"
@@ -1 +1 @@
-x
+y
";

#[test]
fn parses_a_multi_file_git_patch() {
    let files = parse_unified(GIT_PATCH).unwrap();
    let summary: Vec<_> = files
        .iter()
        .map(|file| {
            (
                file.display_path().to_owned(),
                file.change,
                file.stats().added,
                file.stats().removed,
            )
        })
        .collect();
    assert_eq!(
        summary,
        [
            ("src/main.rs".to_owned(), FileChangeKind::Modified, 2, 1),
            ("new.txt".to_owned(), FileChangeKind::Added, 1, 0),
            ("gone.txt".to_owned(), FileChangeKind::Deleted, 0, 2),
            ("new name.txt".to_owned(), FileChangeKind::Renamed, 0, 0),
            ("logo.png".to_owned(), FileChangeKind::Modified, 0, 0),
            ("café.md".to_owned(), FileChangeKind::Modified, 1, 1),
        ]
    );
    assert_eq!(files[0].hunks[0].section, "fn main() {");
    assert_eq!(files[0].hunks[0].lines[3].new_number, Some(3));
    assert!(files[1].hunks[0].lines[0].missing_newline);
    assert_eq!(files[1].old_path, None);
    assert_eq!(files[2].new_path, None);
    assert_eq!(files[3].old_path.as_deref(), Some("old name.txt"));
    assert!(files[4].binary && files[4].hunks.is_empty());
}

#[test]
fn parses_a_plain_unified_diff_and_empty_context_lines() {
    let patch = "--- a.txt\t2024-01-01 00:00:00\n+++ b.txt\t2024-01-02 00:00:00\n@@ -1,3 +1,3 @@\n a\n\n-c\n+d\n";
    let files = parse_unified(patch).unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].old_path.as_deref(), Some("a.txt"));
    assert_eq!(files[0].new_path.as_deref(), Some("b.txt"));
    assert_eq!(lines(&files[0].hunks[0]), [" a", " ", "-c", "+d"]);
    assert_eq!(parse_unified("").unwrap(), Vec::new());
}

#[test]
fn malformed_patches_fail_with_the_line() {
    let short = "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a\n";
    let error = parse_unified(short).unwrap_err();
    assert_eq!(error.line, 4, "the last line of the patch");
    let bad_header = "--- a/x\n+++ b/x\n@@ -1,x +1 @@\n";
    assert_eq!(parse_unified(bad_header).unwrap_err().line, 3);
    let stray = "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a\n?b\n";
    assert_eq!(parse_unified(stray).unwrap_err().line, 5);
    let long = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n+c\n";
    assert_eq!(parse_unified(long).unwrap_err().line, 6);
    let marker_first = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n\\ No newline at end of file\n";
    assert_eq!(parse_unified(marker_first).unwrap_err().line, 4);
}

#[test]
fn git_path_quoting() {
    assert_eq!(unquote(r#""a\tb\303\251\"""#), "a\tbé\"");
    assert_eq!(unquote("plain"), "plain");
    assert_eq!(
        split_git_paths("a/x b/y b/x b/y"),
        Some(("x b/y".into(), "x b/y".into()))
    );
    assert_eq!(split_git_paths("a/x b/z"), Some(("x".into(), "z".into())));
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(200))]

    #[test]
    fn computed_diffs_apply_and_round_trip(
        before in proptest::collection::vec("[abc]{0,2}", 0..30),
        after in proptest::collection::vec("[abc]{0,2}", 0..30),
        trailing_before in any::<bool>(),
        trailing_after in any::<bool>(),
    ) {
        let join = |lines: &[String], trailing: bool| {
            let mut text = lines.join("\n");
            if trailing && !lines.is_empty() {
                text.push('\n');
            }
            text
        };
        let before = join(&before, trailing_before);
        let after = join(&after, trailing_after);
        let result = diff(&before, &after);
        prop_assert!(!result.approximate);
        prop_assert_eq!(apply(&before, &result), after.as_str());
        if !result.hunks.is_empty() {
            let parsed = parse_unified(&result.to_unified()).unwrap();
            prop_assert_eq!(parsed.len(), 1);
            prop_assert_eq!(&parsed[0].hunks, &result.hunks);
        }
        // Myers is minimal: no diff has more edits than replacing everything.
        let stats = result.stats();
        prop_assert!(stats.added <= u64::try_from(split_lines(&after).len()).unwrap());
        prop_assert!(stats.removed <= u64::try_from(split_lines(&before).len()).unwrap());
    }
}

#[test]
fn large_files_with_scattered_edits_diff_exactly() {
    let before: Vec<String> = (0..100_000).map(|n| format!("line {n}")).collect();
    let mut after = before.clone();
    for index in (0..100_000).step_by(9_973) {
        after[index] = format!("edited {index}");
    }
    after.insert(50_000, "inserted".to_owned());
    let before = before.join("\n") + "\n";
    let after = after.join("\n") + "\n";
    let result = diff(&before, &after);
    assert!(!result.approximate && !result.too_large);
    assert_eq!(
        result.stats(),
        DiffStats {
            added: 12,
            removed: 11
        }
    );
    assert_eq!(result.hunks.len(), 12);
    assert_eq!(apply(&before, &result), after);
}
