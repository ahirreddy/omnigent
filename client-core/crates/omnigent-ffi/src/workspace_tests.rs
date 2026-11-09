//! Workspace records and REST calls over the fake host.

use serde_json::json as value;

use super::*;
use crate::test_support::{Harness, connected, json};

const ROOT: &str = "/v1/sessions/conv_a/resources/environments/default";

fn path(raw: &str) -> core::WorkspacePath {
    core::WorkspacePath::parse(raw).unwrap()
}

#[test]
fn every_entry_kind_maps_and_keeps_its_fields() {
    for (on_core, on_ffi) in [
        (core::EntryKind::File, WorkspaceEntryKind::File),
        (core::EntryKind::Directory, WorkspaceEntryKind::Directory),
        (core::EntryKind::Symlink, WorkspaceEntryKind::Symlink),
        (core::EntryKind::Other, WorkspaceEntryKind::Other),
        (
            core::EntryKind::Unknown("socket".into()),
            WorkspaceEntryKind::Unknown {
                value: "socket".into(),
            },
        ),
    ] {
        let mapped = entry(core::WorkspaceEntry {
            path: path("src/a.rs"),
            name: "a.rs".into(),
            kind: on_core,
            size: Some(9),
            modified_at: Some(77),
        });
        assert_eq!(mapped.kind, on_ffi);
        assert_eq!(mapped.path, "src/a.rs");
        assert_eq!(mapped.name, "a.rs");
        assert_eq!(mapped.size, Some(9));
        assert_eq!(mapped.modified_at, Some(77));
    }
}

#[test]
fn every_syntax_language_maps() {
    use super::core::SyntaxLanguage as L;
    for (on_core, on_ffi) in [
        (L::Bash, SyntaxLanguage::Bash),
        (L::C, SyntaxLanguage::C),
        (L::Cpp, SyntaxLanguage::Cpp),
        (L::CSharp, SyntaxLanguage::CSharp),
        (L::Css, SyntaxLanguage::Css),
        (L::Dockerfile, SyntaxLanguage::Dockerfile),
        (L::Go, SyntaxLanguage::Go),
        (L::Html, SyntaxLanguage::Html),
        (L::Java, SyntaxLanguage::Java),
        (L::JavaScript, SyntaxLanguage::JavaScript),
        (L::Json, SyntaxLanguage::Json),
        (L::Kotlin, SyntaxLanguage::Kotlin),
        (L::Makefile, SyntaxLanguage::Makefile),
        (L::Markdown, SyntaxLanguage::Markdown),
        (L::ObjectiveC, SyntaxLanguage::ObjectiveC),
        (L::Php, SyntaxLanguage::Php),
        (L::Python, SyntaxLanguage::Python),
        (L::Ruby, SyntaxLanguage::Ruby),
        (L::Rust, SyntaxLanguage::Rust),
        (L::Scala, SyntaxLanguage::Scala),
        (L::Sql, SyntaxLanguage::Sql),
        (L::Swift, SyntaxLanguage::Swift),
        (L::Toml, SyntaxLanguage::Toml),
        (L::TypeScript, SyntaxLanguage::TypeScript),
        (L::Xml, SyntaxLanguage::Xml),
        (L::Yaml, SyntaxLanguage::Yaml),
    ] {
        assert_eq!(syntax(on_core), on_ffi);
    }
}

fn text_preview(line_ending: core::LineEnding) -> core::FilePreview {
    core::FilePreview::Text(core::TextPreview {
        text: "t".into(),
        line_count: 2,
        line_ending,
        has_bom: true,
        language: Some(core::SyntaxLanguage::Rust),
        skip_highlighting: true,
        clipped: true,
        server_truncated: true,
    })
}

#[test]
fn every_preview_shape_maps() {
    for (on_core, on_ffi) in [
        (core::LineEnding::Lf, LineEnding::Lf),
        (core::LineEnding::CrLf, LineEnding::CrLf),
        (core::LineEnding::Mixed, LineEnding::Mixed),
    ] {
        assert_eq!(
            preview(text_preview(on_core)),
            FilePreview::Text {
                preview: TextPreview {
                    text: "t".into(),
                    line_count: 2,
                    line_ending: on_ffi,
                    has_bom: true,
                    language: Some(SyntaxLanguage::Rust),
                    skip_highlighting: true,
                    clipped: true,
                    server_truncated: true,
                }
            }
        );
    }
    for (on_core, on_ffi) in [
        (core::ImageFormat::Png, ImageFormat::Png),
        (core::ImageFormat::Jpeg, ImageFormat::Jpeg),
        (core::ImageFormat::Gif, ImageFormat::Gif),
        (core::ImageFormat::Webp, ImageFormat::Webp),
        (core::ImageFormat::Bmp, ImageFormat::Bmp),
        (core::ImageFormat::Tiff, ImageFormat::Tiff),
        (core::ImageFormat::Heic, ImageFormat::Heic),
        (core::ImageFormat::Ico, ImageFormat::Ico),
    ] {
        assert_eq!(
            preview(core::FilePreview::Image {
                format: on_core,
                bytes: vec![1, 2],
            }),
            FilePreview::Image {
                format: on_ffi,
                data: vec![1, 2],
            }
        );
    }
    for (on_core, on_ffi) in [
        (core::BinaryReason::NotText, BinaryReason::NotText),
        (core::BinaryReason::NulBytes, BinaryReason::NulBytes),
        (
            core::BinaryReason::TruncatedImage,
            BinaryReason::TruncatedImage,
        ),
    ] {
        assert_eq!(
            preview(core::FilePreview::Binary {
                reason: on_core,
                byte_count: 12,
            }),
            FilePreview::Binary {
                reason: on_ffi,
                byte_count: 12,
            }
        );
    }
}

#[test]
fn a_changed_file_keeps_an_unknown_status() {
    let list = core::ChangesList {
        entries: vec![core::ChangedFileEntry {
            path: path("a"),
            status: core::ChangeStatus::Unknown("touched".into()),
            size: Some(1),
            modified_at: Some(2),
            lines_added: Some(3),
            lines_removed: Some(4),
        }],
        has_more: true,
    };
    let mapped = changes(&list);
    assert!(mapped.has_more);
    assert_eq!(
        mapped.files[0].status,
        WorkspaceChangeStatus::Unknown {
            value: "touched".into()
        }
    );
    assert_eq!(mapped.files[0].size, Some(1));
    assert_eq!(mapped.files[0].modified_at, Some(2));
    assert_eq!(mapped.files[0].lines_added, Some(3));
    assert_eq!(mapped.files[0].lines_removed, Some(4));
}

#[test]
fn each_kind_of_unified_diff_is_read_and_bad_text_is_refused() {
    for (patch, change) in [
        (
            "--- /dev/null\n+++ b/x\n@@ -0,0 +1 @@\n+new\n",
            FileChangeKind::Added,
        ),
        (
            "--- a/x\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n",
            FileChangeKind::Deleted,
        ),
        (
            "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n",
            FileChangeKind::Modified,
        ),
        (
            "diff --git a/x b/y\nsimilarity index 100%\nrename from x\nrename to y\n",
            FileChangeKind::Renamed,
        ),
        (
            "diff --git a/x b/y\nsimilarity index 100%\ncopy from x\ncopy to y\n",
            FileChangeKind::Copied,
        ),
    ] {
        let diffs = parse_unified_diff(patch.into()).unwrap();
        assert_eq!(diffs[0].change, change, "{patch}");
    }
    assert!(matches!(
        parse_unified_diff("--- a/x\n+++ b/x\n@@ nope @@\n-old\n".into()),
        Err(CoreError::Decode { .. })
    ));
}

#[test]
fn globs_split_on_top_level_commas() {
    assert_eq!(
        split_workspace_globs("*.{js,ts}, src/**".into()),
        ["*.{js,ts}", "src/**"]
    );
}

#[test]
fn a_saved_or_conflicting_file_maps() {
    assert_eq!(
        WorkspaceSave::from(core::FileSave::Saved(core::FileWritten {
            path: path("a"),
            created: true,
            bytes_written: Some(1),
        })),
        WorkspaceSave::Saved { created: true }
    );
    assert_eq!(
        WorkspaceSave::from(core::FileSave::Conflict {
            latest: Some("theirs".into())
        }),
        WorkspaceSave::Conflict {
            latest: Some("theirs".into())
        }
    );
}

fn file_reply(content: &str) -> crate::http::HttpResponse {
    json(
        200,
        &value!({"object": "session.environment.filesystem.file", "path": "notes.md",
            "encoding": "utf-8", "content": content, "bytes": content.len()})
        .to_string(),
    )
}

#[test]
fn environments_read_each_field_and_the_primary_flag() {
    let mut harness = connected();
    harness.http.route(
        "/v1/sessions/conv_a/resources/environments",
        json(
            200,
            r#"{"object":"list","has_more":false,"data":[
              {"id":"env_t","object":"session.resource","type":"environment","session_id":"conv_a",
               "name":"Terminal","metadata":{"environment_type":"caller_process","role":"terminal",
               "root":"/w","sandbox_type":"none"}},
              {"id":"default","object":"session.resource","type":"environment","session_id":"conv_a",
               "name":"Primary","metadata":{"environment_type":"caller_process","role":"primary"}}
            ]}"#,
        ),
    );
    let environments = harness
        .call(|core| async move { core.workspace_environments("conv_a".into()).await })
        .unwrap();
    assert_eq!(environments.len(), 2);
    let terminal = environments
        .iter()
        .find(|found| found.id == "env_t")
        .unwrap();
    assert_eq!(terminal.name.as_deref(), Some("Terminal"));
    assert_eq!(terminal.role.as_deref(), Some("terminal"));
    assert_eq!(terminal.environment_type.as_deref(), Some("caller_process"));
    assert_eq!(terminal.root.as_deref(), Some("/w"));
    assert!(!terminal.is_primary);
    assert!(
        environments
            .iter()
            .any(|found| found.id == "default" && found.is_primary)
    );

    harness.http.route(
        "/v1/sessions/conv_a/resources/environments",
        json(403, r#"{"error":{"message":"no"}}"#),
    );
    assert!(matches!(
        harness.call(|core| async move { core.workspace_environments("conv_a".into()).await }),
        Err(CoreError::Workspace {
            kind: WorkspaceErrorKind::Forbidden,
            ..
        })
    ));
}

#[test]
fn a_directory_page_sends_its_limit_and_a_binary_file_reads_as_bytes() {
    let mut harness = connected();
    harness.http.route(
        &format!("{ROOT}/filesystem"),
        json(200, r#"{"object":"list","data":[],"has_more":false}"#),
    );
    harness
        .call(|core| async move {
            core.list_workspace_directory(
                "conv_a".into(),
                "default".into(),
                String::new(),
                Some("cursor".into()),
                Some(7),
            )
            .await
        })
        .unwrap();
    assert_eq!(harness.last_query("limit").as_deref(), Some("7"));
    assert_eq!(harness.last_query("after").as_deref(), Some("cursor"));

    let bytes = [0x89_u8, b'P', b'N', b'G'];
    harness.http.route(
        &format!("{ROOT}/filesystem/logo.png"),
        json(
            200,
            &value!({"encoding": "base64", "content": "iVBORw==", "content_type": "image/png"})
                .to_string(),
        ),
    );
    let file = harness
        .call(|core| async move {
            core.read_workspace_file_bytes("conv_a".into(), "default".into(), "logo.png".into())
                .await
        })
        .unwrap();
    assert_eq!(file.bytes, bytes);
    assert_eq!(file.path, "logo.png");
    assert_eq!(file.content_type.as_deref(), Some("image/png"));
}

fn notes(harness: &Harness, read: &str) {
    harness.http.route_method(
        "GET",
        &format!("{ROOT}/filesystem/notes.md"),
        file_reply(read),
    );
    harness.http.route_method(
        "PUT",
        &format!("{ROOT}/filesystem/notes.md"),
        json(200, r#"{"created":true,"bytes_written":3}"#),
    );
}

#[test]
fn saving_writes_the_text_or_reports_a_conflict_or_a_failure() {
    let mut harness = connected();
    notes(&harness, "old");
    let save = |base: &str| {
        let base = base.to_owned();
        move |core: std::sync::Arc<ClientCore>| async move {
            core.save_workspace_file(
                "conv_a".into(),
                "default".into(),
                "notes.md".into(),
                "new".into(),
                Some(base),
            )
            .await
        }
    };
    assert_eq!(
        harness.call(save("old")).unwrap(),
        WorkspaceSave::Saved { created: true }
    );
    assert_eq!(
        harness.last_request(),
        (
            format!("PUT {ROOT}/filesystem/notes.md"),
            value!({"content": "new", "encoding": "utf-8"})
        )
    );
    assert_eq!(
        harness.call(save("stale")).unwrap(),
        WorkspaceSave::Conflict {
            latest: Some("old".into())
        }
    );
    assert!(matches!(
        harness.call(|core| async move {
            core.save_workspace_file(
                "conv_a".into(),
                "default".into(),
                String::new(),
                "new".into(),
                None,
            )
            .await
        }),
        Err(CoreError::Workspace {
            kind: WorkspaceErrorKind::InvalidInput,
            ..
        })
    ));
    harness.http.route_method(
        "PUT",
        &format!("{ROOT}/filesystem/notes.md"),
        json(403, r#"{"error":{"message":"Read-only share"}}"#),
    );
    assert!(matches!(
        harness.call(|core| async move {
            core.save_workspace_file(
                "conv_a".into(),
                "default".into(),
                "notes.md".into(),
                "new".into(),
                None,
            )
            .await
        }),
        Err(CoreError::Workspace {
            kind: WorkspaceErrorKind::Forbidden,
            ..
        })
    ));
}

#[test]
fn path_search_sends_its_filters_and_reads_the_results() {
    let mut harness = connected();
    harness.http.route(
        &format!("{ROOT}/search/src"),
        json(
            200,
            r#"{"object":"list","base":"/w","has_more":true,"truncated":true,"data":[
              {"id":"main.rs","name":"main.rs","path":"main.rs","type":"file","bytes":90,"modified_at":17}
            ]}"#,
        ),
    );
    let result = harness
        .call(|core| async move {
            core.search_workspace_paths(
                "conv_a".into(),
                "default".into(),
                PathSearchQuery {
                    query: "main".into(),
                    under: "src".into(),
                    include: vec!["*.rs".into()],
                    exclude: vec!["target".into()],
                    limit: Some(9),
                },
            )
            .await
        })
        .unwrap();
    assert_eq!(harness.last_query("q").as_deref(), Some("main"));
    assert_eq!(harness.last_query("limit").as_deref(), Some("9"));
    assert_eq!(harness.last_query("include").as_deref(), Some("*.rs"));
    assert_eq!(harness.last_query("exclude").as_deref(), Some("target"));
    assert_eq!(result.directory, "src");
    assert!(result.has_more);
    assert!(result.truncated);
    assert_eq!(result.entries[0].path, "src/main.rs");
    assert_eq!(result.entries[0].size, Some(90));

    let unsafe_under = harness.call(|core| async move {
        core.search_workspace_paths(
            "conv_a".into(),
            "default".into(),
            PathSearchQuery {
                query: "main".into(),
                under: "../up".into(),
                include: vec![],
                exclude: vec![],
                limit: None,
            },
        )
        .await
    });
    assert!(matches!(
        unsafe_under,
        Err(CoreError::Workspace {
            kind: WorkspaceErrorKind::InvalidInput,
            ..
        })
    ));

    harness.http.route(
        &format!("{ROOT}/search"),
        json(500, r#"{"error":{"message":"x"}}"#),
    );
    let failed = harness.call(|core| async move {
        core.search_workspace_paths(
            "conv_a".into(),
            "default".into(),
            PathSearchQuery {
                query: "main".into(),
                under: String::new(),
                include: vec![],
                exclude: vec![],
                limit: None,
            },
        )
        .await
    });
    assert!(failed.is_err());
}

#[test]
fn content_search_sends_its_flags_and_groups_matches_by_file() {
    let mut harness = connected();
    harness.http.route(
        &format!("{ROOT}/content-search"),
        json(
            200,
            r#"{"truncated":true,"warning":"partial","matches":[
              {"path":"a.md","line":3,"column":21,"text":"é needle","match_start":2,"match_end":8},
              {"path":"a.md","line":4,"column":1,"text":"needle","match_start":0,"match_end":6},
              {"path":"b.md","line":1,"column":1,"text":"needle","match_start":0,"match_end":6}
            ]}"#,
        ),
    );
    let query = || ContentSearchQuery {
        query: "needle".into(),
        case_sensitive: true,
        regex: true,
        include: vec!["*.md".into()],
        exclude: vec!["vendor".into()],
        limit: Some(11),
    };
    let result = harness
        .call(|core| async move {
            core.search_workspace_content("conv_a".into(), "default".into(), query())
                .await
        })
        .unwrap();
    assert_eq!(
        harness.last_query("case_sensitive").as_deref(),
        Some("true")
    );
    assert_eq!(harness.last_query("regex").as_deref(), Some("true"));
    assert_eq!(harness.last_query("include").as_deref(), Some("*.md"));
    assert_eq!(harness.last_query("exclude").as_deref(), Some("vendor"));
    assert_eq!(harness.last_query("limit").as_deref(), Some("11"));
    assert!(result.truncated);
    assert_eq!(result.warning.as_deref(), Some("partial"));
    assert_eq!(result.files.len(), 2);
    assert_eq!(result.files[0].path, "a.md");
    assert_eq!(result.files[0].matches.len(), 2);
    let first = &result.files[0].matches[0];
    assert_eq!((first.line, first.column), (3, 21));
    assert_eq!(first.text, "é needle");
    assert_eq!((first.match_utf16.start, first.match_utf16.end), (2, 8));
    assert_eq!((first.match_utf8.start, first.match_utf8.end), (3, 9));

    harness.http.route(
        &format!("{ROOT}/content-search"),
        json(
            404,
            r#"{"error":{"code":"search_disabled","message":"off"}}"#,
        ),
    );
    assert!(
        harness
            .call(|core| async move {
                core.search_workspace_content("conv_a".into(), "default".into(), query())
                    .await
            })
            .is_err()
    );
}
