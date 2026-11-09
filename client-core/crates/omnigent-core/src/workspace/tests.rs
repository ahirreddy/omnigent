//! Workspace requests and decoding against the recorded server responses in
//! `client-core/fixtures/workspace/`.

#![allow(
    clippy::string_slice,
    clippy::too_many_lines,
    reason = "the asserted ranges are checked char boundaries; one test per recorded flow"
)]

use futures::executor::block_on;

use super::*;
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;
use crate::auth::hosted::HostedConnection;
use crate::client::SessionError;
use crate::client::test_support::{
    Envelope, LOCAL, MOUNT, Reply, RouteTransport, TOKEN, connected, connected_hosted, envelopes,
    header, path_of, query_value,
};
use crate::http::{HttpHeader, HttpResponse, TransportError};

const SESSION: &str = "207c660071e248e198c634aec763bb75";

fn fixture(name: &str) -> Envelope {
    envelopes(&format!("workspace/{name}.json"))
        .into_iter()
        .next()
        .unwrap()
}

fn response(envelope: &Envelope) -> HttpResponse {
    let Reply::Response { status, body } = &envelope.reply else {
        panic!("fixture is a transport failure");
    };
    HttpResponse {
        status: *status,
        headers: vec![HttpHeader::new("Content-Type", "application/json")],
        body: body.clone().into_bytes(),
    }
}

fn request(operation: WorkspaceOperation) -> WorkspaceRequest {
    WorkspaceRequest::new(SESSION, DEFAULT_ENVIRONMENT_ID, operation).unwrap()
}

/// Builds `operation` on a local endpoint, checks it is the fixture's request, and decodes
/// the fixture's response.
fn exchange(
    name: &str,
    operation: WorkspaceOperation,
) -> Result<WorkspaceResponse, WorkspaceError> {
    let envelope = fixture(name);
    let request = request(operation);
    let http = request
        .build_for_endpoint(&ServerEndpoint::new(LOCAL).unwrap(), None)
        .unwrap();
    assert_eq!(path_of(&http), envelope.path, "{name}");
    assert_eq!(http.method, "GET");
    request.decode(&response(&envelope))
}

fn path(raw: &str) -> WorkspacePath {
    WorkspacePath::parse(raw).unwrap()
}

#[test]
fn root_listing_and_pagination_follow_cursors() {
    let WorkspaceResponse::Directory(root) = exchange(
        "recorded-filesystem-root",
        WorkspaceOperation::ListDirectory(DirectoryQuery::first_page(WorkspacePath::root())),
    )
    .unwrap() else {
        panic!()
    };
    let names: Vec<_> = root
        .entries
        .iter()
        .map(|entry| entry.name.as_str())
        .collect();
    assert_eq!(
        names,
        [
            ".git",
            ".gitignore",
            "README.md",
            "assets",
            "build.log",
            "docs",
            "src"
        ]
    );
    assert!(!root.has_more());
    let mut sorted = root.entries.clone();
    sort_for_tree(&mut sorted);
    assert_eq!(sorted[0].name, ".git");
    assert!(
        sorted[..4]
            .iter()
            .all(|entry| entry.kind == EntryKind::Directory)
    );

    let mut after = None;
    let mut seen = Vec::new();
    for page in 1..=4 {
        let query = DirectoryQuery {
            path: WorkspacePath::root(),
            limit: 2,
            after: after.clone(),
        };
        let WorkspaceResponse::Directory(listing) = exchange(
            &format!("recorded-filesystem-page-{page}"),
            WorkspaceOperation::ListDirectory(query),
        )
        .unwrap() else {
            panic!()
        };
        seen.extend(listing.entries.iter().map(|entry| entry.name.clone()));
        after = listing.next_cursor.clone();
        assert_eq!(listing.has_more(), page < 4, "page {page}");
    }
    assert_eq!(seen, names);
}

#[test]
fn subdirectory_listing_is_root_relative() {
    let WorkspaceResponse::Directory(src) = exchange(
        "recorded-filesystem-src",
        WorkspaceOperation::ListDirectory(DirectoryQuery::first_page(path("src"))),
    )
    .unwrap() else {
        panic!()
    };
    let paths: Vec<_> = src
        .entries
        .iter()
        .map(|entry| entry.path.as_str())
        .collect();
    assert_eq!(paths, ["src/lib.rs", "src/main.rs", "src/util"]);
    assert_eq!(src.entries[0].size, Some(99));
    assert_eq!(src.entries[2].kind, EntryKind::Directory);
    assert_eq!(src.entries[2].size, None);
    assert_eq!(src.entries[0].modified_at, Some(1_793_502_799));
}

#[test]
fn text_binary_and_non_ascii_files() {
    let WorkspaceResponse::File(text) = exchange(
        "recorded-file-text",
        WorkspaceOperation::ReadFile(path("src/main.rs")),
    )
    .unwrap() else {
        panic!()
    };
    let FilePreview::Text(preview) = text.preview(&PreviewLimits::default()) else {
        panic!()
    };
    assert_eq!(
        preview.language,
        Some(SyntaxLanguage::Rust),
        "by extension, not MIME"
    );
    assert_eq!(preview.line_count, 4);
    assert!(!preview.clipped && !preview.server_truncated);
    assert_eq!(
        text.content_type.as_deref(),
        Some("application/rls-services+xml")
    );

    let WorkspaceResponse::File(binary) = exchange(
        "recorded-file-binary",
        WorkspaceOperation::ReadFile(path("assets/logo.png")),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(binary.byte_count, 165);
    let FilePreview::Image { format, bytes } = binary.preview(&PreviewLimits::default()) else {
        panic!()
    };
    assert_eq!(format, ImageFormat::Png);
    assert_eq!(bytes.len(), 165);

    let WorkspaceResponse::File(unicode) = exchange(
        "recorded-file-nonascii",
        WorkspaceOperation::ReadFile(path("docs/café notes.md")),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(unicode.path.as_str(), "docs/café notes.md");
    assert!(matches!(unicode.body, FileBody::Text(_)));
}

#[test]
fn missing_and_traversal_paths() {
    assert_eq!(
        exchange(
            "recorded-file-missing",
            WorkspaceOperation::ReadFile(path("missing.txt"))
        ),
        Err(WorkspaceError::NotFound {
            path: "missing.txt".into(),
            message: "Path 'missing.txt' not found".into(),
        })
    );
    // The client never sends these; the recorded server answer shows the server agrees.
    assert_eq!(
        WorkspacePath::parse("src/../../etc/passwd"),
        Err(PathError::Traversal)
    );
    let envelope = fixture("recorded-file-traversal-dotdot");
    let request = request(WorkspaceOperation::ReadFile(path("src/x")));
    assert_eq!(
        request.decode(&response(&envelope)),
        Err(WorkspaceError::Rejected {
            status: 400,
            code: Some("invalid_input".into()),
            message: "Parent path segments are not permitted".into(),
        })
    );
}

#[test]
fn special_characters_are_one_encoded_segment_each() {
    let request = request(WorkspaceOperation::ReadFile(path("a dir/100% #1?.txt")));
    let http = request
        .build_for_endpoint(&ServerEndpoint::new(LOCAL).unwrap(), None)
        .unwrap();
    assert_eq!(
        http.url,
        format!(
            "{LOCAL}/v1/sessions/{SESSION}/resources/environments/default/filesystem/a%20dir/100%25%20%231%3F.txt"
        )
    );
    let listing = WorkspaceRequest::new(
        SESSION,
        "default",
        WorkspaceOperation::ListDirectory(DirectoryQuery {
            path: path("src"),
            limit: 50,
            after: Some("src/b".into()),
        }),
    )
    .unwrap()
    .build_for_endpoint(&ServerEndpoint::new(LOCAL).unwrap(), None)
    .unwrap();
    assert_eq!(
        path_of(&listing),
        format!("/v1/sessions/{SESSION}/resources/environments/default/filesystem/src")
    );
    assert_eq!(query_value(&listing, "after").as_deref(), Some("src/b"));
    assert_eq!(query_value(&listing, "order").as_deref(), Some("asc"));
    assert_eq!(query_value(&listing, "limit").as_deref(), Some("50"));
}

#[test]
fn hosted_requests_carry_mount_org_and_bearer() {
    let endpoint =
        ServerEndpoint::new("https://adb-1.2.azuredatabricks.net/api/2.0/omnigent?o=42").unwrap();
    let http = request(WorkspaceOperation::ListChanges)
        .build_for_endpoint(&endpoint, Some(&SecretString::new(TOKEN)))
        .unwrap();
    assert_eq!(
        http.url,
        format!(
            "https://adb-1.2.azuredatabricks.net/api/2.0/omnigent/v1/sessions/{SESSION}/resources/environments/default/changes"
        )
    );
    assert_eq!(header(&http, "X-Databricks-Org-Id"), Some("42"));
    assert_eq!(
        header(&http, "Authorization"),
        Some(format!("Bearer {TOKEN}").as_str())
    );
    assert_eq!(header(&http, "Cookie"), None);
}

#[test]
fn invalid_inputs_never_reach_the_network() {
    for id in ["", "../x", "a/b", "a b"] {
        assert!(matches!(
            WorkspaceRequest::new(id, "default", WorkspaceOperation::ListChanges),
            Err(WorkspaceError::InvalidIdentifier { .. })
        ));
        assert!(matches!(
            WorkspaceRequest::new(SESSION, id, WorkspaceOperation::ListChanges),
            Err(WorkspaceError::InvalidIdentifier { .. })
        ));
    }
    assert_eq!(
        WorkspaceRequest::new(
            SESSION,
            "default",
            WorkspaceOperation::ReadFile(WorkspacePath::root())
        ),
        Err(WorkspaceError::InvalidPath(PathError::Root))
    );
    for limit in [0, 1001] {
        assert!(matches!(
            WorkspaceRequest::new(
                SESSION,
                "default",
                WorkspaceOperation::ListDirectory(DirectoryQuery {
                    path: WorkspacePath::root(),
                    limit,
                    after: None
                })
            ),
            Err(WorkspaceError::InvalidQuery { .. })
        ));
    }
    assert!(matches!(
        WorkspaceRequest::new(
            SESSION,
            "default",
            WorkspaceOperation::SearchContent(ContentSearchQuery::new(" "))
        ),
        Err(WorkspaceError::InvalidQuery { .. })
    ));
}

#[test]
fn path_search_results_are_rooted_at_the_searched_directory() {
    let WorkspaceResponse::PathSearch(root) = exchange(
        "recorded-search-root",
        WorkspaceOperation::SearchPaths(PathSearchQuery::new("main")),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(root.entries[0].path.as_str(), "src/main.rs");
    assert!(!root.truncated && !root.has_more);

    let mut under = PathSearchQuery::new("lib");
    under.under = path("src");
    let WorkspaceResponse::PathSearch(src) = exchange(
        "recorded-search-src",
        WorkspaceOperation::SearchPaths(under),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(src.entries[0].path.as_str(), "src/lib.rs");
}

#[test]
fn content_search_matches_are_sorted_with_both_range_units() {
    let WorkspaceResponse::ContentSearch(result) = exchange(
        "recorded-content-search",
        WorkspaceOperation::SearchContent(ContentSearchQuery::new("fixture needle")),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(result.matches.len(), 7);
    assert!(!result.truncated);
    assert_eq!(result.warning, None);
    for found in &result.matches {
        let start = usize::try_from(found.match_utf8.start).unwrap();
        let end = usize::try_from(found.match_utf8.end).unwrap();
        assert!(
            found.text[start..end].eq_ignore_ascii_case("fixture needle"),
            "{found:?}"
        );
    }
    let files = result.files();
    let paths: Vec<_> = files.iter().map(|file| file.path.as_str()).collect();
    assert_eq!(
        paths,
        [
            "README.md",
            "docs/café notes.md",
            "src/lib.rs",
            "src/main.rs"
        ]
    );
    assert!(files.iter().all(|file| {
        file.matches
            .windows(2)
            .all(|pair| pair[0].line <= pair[1].line)
    }));

    let WorkspaceResponse::ContentSearch(unicode) = exchange(
        "recorded-content-search-unicode",
        WorkspaceOperation::SearchContent(ContentSearchQuery::new("needle again")),
    )
    .unwrap() else {
        panic!()
    };
    let found = &unicode.matches[0];
    assert_eq!(found.match_utf16, TextRange { start: 11, end: 23 });
    assert_eq!(found.match_utf8, TextRange { start: 13, end: 25 });
    assert_eq!(&found.text[13..25], "needle again");
    assert_eq!(found.column, 12);

    let mut regex = ContentSearchQuery::new(r"fixture\s+needle");
    regex.regex = true;
    let WorkspaceResponse::ContentSearch(regex_result) = exchange(
        "recorded-content-search-regex",
        WorkspaceOperation::SearchContent(regex),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(
        regex_result.matches, result.matches,
        "same matches, whatever rg's order"
    );

    let mut globs = ContentSearchQuery::new("fixture needle");
    globs.include = split_globs("src/**");
    globs.exclude = split_globs("**/main.rs");
    let WorkspaceResponse::ContentSearch(filtered) = exchange(
        "recorded-content-search-globs",
        WorkspaceOperation::SearchContent(globs),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(filtered.matches.len(), 1);
    assert_eq!(filtered.matches[0].path.as_str(), "src/lib.rs");
}

#[test]
fn content_search_failures_are_typed() {
    let mut invalid = ContentSearchQuery::new("(unclosed");
    invalid.regex = true;
    let Err(WorkspaceError::SearchFailed { message }) = exchange(
        "recorded-content-search-invalid-regex",
        WorkspaceOperation::SearchContent(invalid),
    ) else {
        panic!()
    };
    assert!(message.starts_with("regex parse error"), "{message}");
    assert_eq!(
        exchange(
            "recorded-content-search-flag-off",
            WorkspaceOperation::SearchContent(ContentSearchQuery::new("fixture needle"))
        ),
        Err(WorkspaceError::ContentSearchDisabled)
    );
}

#[test]
fn changes_and_diffs() {
    let WorkspaceResponse::Changes(list) =
        exchange("recorded-changes", WorkspaceOperation::ListChanges).unwrap()
    else {
        panic!()
    };
    let statuses: Vec<_> = list
        .entries
        .iter()
        .map(|entry| (entry.path.as_str(), entry.status.clone()))
        .collect();
    assert_eq!(
        statuses,
        [
            ("src/new_file.rs", ChangeStatus::Created),
            ("src/main.rs", ChangeStatus::Modified),
            ("src/library.rs", ChangeStatus::Modified),
            ("src/util/mod.rs", ChangeStatus::Deleted),
        ]
    );
    assert_eq!(
        list.totals(),
        ChangeTotals {
            created: 1,
            modified: 2,
            deleted: 1,
            lines_added: 8,
            lines_removed: 3,
        }
    );
    assert_eq!(list.entries[0].lines_added, None);
    assert_eq!(list.entries[3].size, None);

    let WorkspaceResponse::FileDiff(modified) = exchange(
        "recorded-diff-modified",
        WorkspaceOperation::FileDiff(path("src/main.rs")),
    )
    .unwrap() else {
        panic!()
    };
    let diff = modified.diff(&DiffOptions::default());
    assert_eq!(diff.change, FileChangeKind::Modified);
    assert_eq!(
        diff.stats(),
        DiffStats {
            added: 2,
            removed: 0
        },
        "matches the list's numstat"
    );
    assert_eq!(diff.hunks.len(), 1);
    assert_eq!(diff.hunks[0].header(), "@@ -2,3 +2,5 @@");

    let WorkspaceResponse::FileDiff(created) = exchange(
        "recorded-diff-created",
        WorkspaceOperation::FileDiff(path("src/new_file.rs")),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(created.before, None);
    let diff = created.diff(&DiffOptions::default());
    assert_eq!(diff.change, FileChangeKind::Added);
    assert_eq!(diff.old_path, None);
    assert_eq!(diff.hunks[0].old_start, 0);

    let WorkspaceResponse::FileDiff(deleted) = exchange(
        "recorded-diff-deleted",
        WorkspaceOperation::FileDiff(path("src/util/mod.rs")),
    )
    .unwrap() else {
        panic!()
    };
    let diff = deleted.diff(&DiffOptions::default());
    assert_eq!(diff.change, FileChangeKind::Deleted);
    assert_eq!(
        diff.stats(),
        DiffStats {
            added: 0,
            removed: 3
        },
        "matches the list's numstat"
    );

    let WorkspaceResponse::FileDiff(renamed) = exchange(
        "recorded-diff-renamed-new",
        WorkspaceOperation::FileDiff(path("src/library.rs")),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(
        renamed.diff(&DiffOptions::default()).change,
        FileChangeKind::Added
    );

    assert_eq!(
        exchange(
            "recorded-diff-unchanged",
            WorkspaceOperation::FileDiff(path(".gitignore"))
        ),
        Err(WorkspaceError::NotChanged {
            path: ".gitignore".into()
        })
    );
}

#[test]
fn environments_and_session_files() {
    let WorkspaceResponse::Environments(list) = exchange(
        "recorded-environments",
        WorkspaceOperation::ListEnvironments,
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].role.as_deref(), Some("terminal"));
    assert!(list[1].is_primary());

    let WorkspaceResponse::Environment(default) = exchange(
        "recorded-environment-default",
        WorkspaceOperation::GetEnvironment,
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(default.root.as_deref(), Some("/workspace/fixture"));
    assert_eq!(default.home.as_deref(), Some("/home/fixture"));
    assert_eq!(default.unconfined, Some(true));
    assert_eq!(
        absolute_location(default.root.as_deref().unwrap(), &path("src/main.rs")),
        "/workspace/fixture/src/main.rs"
    );

    let WorkspaceResponse::SessionFiles(files) = exchange(
        "recorded-session-files",
        WorkspaceOperation::ListSessionFiles(SessionFilesQuery {
            limit: 20,
            after: None,
        }),
    )
    .unwrap() else {
        panic!()
    };
    assert_eq!(files.files[0].filename, "fixture-upload.txt");
    assert_eq!(files.files[0].size, Some(23));
    assert_eq!(files.next_cursor, None);
}

fn local_with(name: &str) -> RouteTransport {
    let transport = RouteTransport::local();
    transport.load(&format!("workspace/{name}.json"));
    transport
}

#[test]
fn client_core_reads_through_the_connection() {
    let core = connected(local_with("recorded-filesystem-src"));
    let page = block_on(core.list_workspace_directory(
        SESSION,
        DEFAULT_ENVIRONMENT_ID,
        DirectoryQuery::first_page(path("src")),
    ))
    .unwrap();
    assert_eq!(page.entries.len(), 3);
    let last = core.transport().taken().pop().unwrap();
    assert_eq!(query_value(&last, "limit").as_deref(), Some("1000"));
    assert_eq!(header(&last, "Authorization"), None);
}

#[test]
fn client_core_keeps_server_reasons_and_ends_the_connection_on_401() {
    let transport = RouteTransport::local();
    let changes = format!("/v1/sessions/{SESSION}/resources/environments/default/changes");
    transport.respond(
        None,
        &changes,
        None,
        Reply::json(
            500,
            r#"{"error":{"code":"git_status_failed","message":"git status timed out after 5.0s"}}"#,
        ),
    );
    let core = connected(transport);
    assert_eq!(
        block_on(core.workspace_changes(SESSION, DEFAULT_ENVIRONMENT_ID)),
        Err(WorkspaceError::ChangesUnavailable {
            message: "git status timed out after 5.0s".into()
        })
    );
    assert!(core.is_connected());

    core.transport().respond(
        None,
        &changes,
        None,
        Reply::json(401, r#"{"error":"expired"}"#),
    );
    let error = block_on(core.workspace_changes(SESSION, DEFAULT_ENVIRONMENT_ID)).unwrap_err();
    assert!(error.ends_connection(), "{error:?}");
    assert!(!core.is_connected());
    assert_eq!(
        block_on(core.workspace_changes(SESSION, DEFAULT_ENVIRONMENT_ID)),
        Err(WorkspaceError::Session(SessionError::NotConnected)),
        "nothing is sent after the connection ended"
    );
}

#[test]
fn client_core_maps_transport_failures() {
    let transport = RouteTransport::local();
    let changes = format!("/v1/sessions/{SESSION}/resources/environments/default/changes");
    transport.respond(None, &changes, None, Reply::Fail(TransportError::Cancelled));
    let core = connected(transport);
    assert_eq!(
        block_on(core.workspace_changes(SESSION, DEFAULT_ENVIRONMENT_ID)),
        Err(WorkspaceError::Session(SessionError::Cancelled))
    );
    core.transport().respond(
        None,
        &changes,
        None,
        Reply::Fail(TransportError::Offline {
            message: "no route".into(),
        }),
    );
    assert!(matches!(
        block_on(core.workspace_changes(SESSION, DEFAULT_ENVIRONMENT_ID)),
        Err(WorkspaceError::Session(SessionError::Transport(
            TransportError::Offline { .. }
        )))
    ));
}

#[test]
fn client_core_hosted_reads_use_the_mount() {
    let transport = RouteTransport::with_prefix(MOUNT, false);
    let envelope = fixture("recorded-file-text");
    transport.respond(
        None,
        &format!("{MOUNT}{}", envelope.path),
        None,
        envelope.reply,
    );
    let core = connected_hosted(transport);
    let file =
        block_on(core.read_workspace_file(SESSION, DEFAULT_ENVIRONMENT_ID, path("src/main.rs")))
            .unwrap();
    assert_eq!(file.byte_count, 90);
    let last = core.transport().taken().pop().unwrap();
    assert_eq!(
        header(&last, "Authorization"),
        Some(format!("Bearer {TOKEN}").as_str())
    );
}

fn file_reply(content: &str) -> Reply {
    Reply::json(
        200,
        serde_json::json!({
            "object": "session.environment.filesystem.file_content",
            "path": "notes.md", "bytes": content.len(), "truncated": false,
            "encoding": "utf-8", "content": content,
        })
        .to_string(),
    )
}

fn notes_route() -> String {
    format!("/v1/sessions/{SESSION}/resources/environments/default/filesystem/notes.md")
}

#[test]
fn saving_puts_the_text_after_checking_nobody_changed_the_file() {
    let transport = RouteTransport::local();
    transport.respond(Some("GET"), &notes_route(), None, file_reply("old"));
    transport.respond(
        Some("PUT"),
        &notes_route(),
        None,
        Reply::json(
            200,
            r#"{"object":"session.environment.filesystem.write_result","operation":"write","path":"notes.md","created":false,"bytes_written":3}"#,
        ),
    );
    let core = connected(transport);
    let saved = block_on(core.save_workspace_file(
        SESSION,
        DEFAULT_ENVIRONMENT_ID,
        path("notes.md"),
        "new".into(),
        Some("old"),
    ))
    .unwrap();
    assert_eq!(
        saved,
        FileSave::Saved(FileWritten {
            path: path("notes.md"),
            created: false,
            bytes_written: Some(3),
        })
    );
    let writes = core.transport().writes();
    assert_eq!(writes.len(), 1);
    assert_eq!(writes[0].method, "PUT");
    assert_eq!(
        crate::client::test_support::body_json(&writes[0]),
        serde_json::json!({"content": "new", "encoding": "utf-8"})
    );
}

#[test]
fn saving_over_someone_elses_change_is_a_conflict_until_forced() {
    let transport = RouteTransport::local();
    transport.respond(Some("GET"), &notes_route(), None, file_reply("theirs"));
    transport.respond(
        Some("PUT"),
        &notes_route(),
        None,
        Reply::json(200, r#"{"created":false}"#),
    );
    let core = connected(transport);
    let save = |base: Option<&str>| {
        block_on(core.save_workspace_file(
            SESSION,
            DEFAULT_ENVIRONMENT_ID,
            path("notes.md"),
            "mine".into(),
            base,
        ))
    };
    assert_eq!(
        save(Some("old")),
        Ok(FileSave::Conflict {
            latest: Some("theirs".into())
        })
    );
    assert!(core.transport().writes().is_empty(), "nothing was written");
    assert!(matches!(save(None), Ok(FileSave::Saved(_))));
    assert_eq!(core.transport().writes().len(), 1);

    core.transport().respond(
        Some("GET"),
        &notes_route(),
        None,
        Reply::json(
            404,
            r#"{"error":{"code":"not_found","message":"No such file"}}"#,
        ),
    );
    assert_eq!(save(Some("old")), Ok(FileSave::Conflict { latest: None }));
    core.transport().respond(
        Some("PUT"),
        &notes_route(),
        None,
        Reply::json(403, r#"{"error":{"message":"Read-only share"}}"#),
    );
    assert_eq!(
        save(None),
        Err(WorkspaceError::Forbidden {
            message: "Read-only share".into()
        })
    );
    assert!(matches!(
        WorkspaceRequest::new(
            SESSION,
            DEFAULT_ENVIRONMENT_ID,
            WorkspaceOperation::WriteFile(FileWrite {
                path: WorkspacePath::root(),
                content: String::new(),
            }),
        ),
        Err(WorkspaceError::InvalidPath(_))
    ));
}

#[test]
fn the_client_reaches_the_environment_search_and_session_file_routes() {
    let core = connected(local_with("recorded-environments"));
    let environments = block_on(core.workspace_environments(SESSION)).unwrap();
    assert_ne!(environments.len(), 0);

    let core = connected(local_with("recorded-search-root"));
    let found = block_on(core.search_workspace_paths(
        SESSION,
        DEFAULT_ENVIRONMENT_ID,
        PathSearchQuery::new("main"),
    ))
    .unwrap();
    assert_ne!(found.entries.len(), 0);

    let core = connected(local_with("recorded-content-search"));
    let lines = block_on(core.search_workspace_content(
        SESSION,
        DEFAULT_ENVIRONMENT_ID,
        ContentSearchQuery::new("fixture needle"),
    ))
    .unwrap();
    assert_ne!(lines.matches.len(), 0);

    let core = connected(local_with("recorded-session-files"));
    let files = block_on(core.session_files(
        SESSION,
        SessionFilesQuery {
            limit: 100,
            after: None,
        },
    ))
    .unwrap();
    assert_ne!(files.files.len(), 0);
}

#[test]
fn invalid_identifiers_fail_before_any_request() {
    let core = connected(RouteTransport::local());
    let invalid =
        |error: &WorkspaceError| matches!(error, WorkspaceError::InvalidIdentifier { .. });
    for session in ["", "../x", "a/b"] {
        assert!(invalid(
            &block_on(core.workspace_environments(session)).unwrap_err()
        ));
        assert!(invalid(
            &block_on(core.workspace_environment(session, DEFAULT_ENVIRONMENT_ID)).unwrap_err()
        ));
        assert!(invalid(
            &block_on(core.list_workspace_directory(
                session,
                DEFAULT_ENVIRONMENT_ID,
                DirectoryQuery::first_page(path("src")),
            ))
            .unwrap_err()
        ));
        assert!(invalid(
            &block_on(core.read_workspace_file(session, DEFAULT_ENVIRONMENT_ID, path("a.txt")))
                .unwrap_err()
        ));
        assert!(invalid(
            &block_on(core.write_workspace_file(
                session,
                DEFAULT_ENVIRONMENT_ID,
                path("a.txt"),
                String::new()
            ))
            .unwrap_err()
        ));
        assert!(invalid(
            &block_on(core.workspace_file_diff(session, DEFAULT_ENVIRONMENT_ID, path("a.txt")))
                .unwrap_err()
        ));
        assert!(invalid(
            &block_on(core.search_workspace_paths(
                session,
                DEFAULT_ENVIRONMENT_ID,
                PathSearchQuery::new("x")
            ))
            .unwrap_err()
        ));
        assert!(invalid(
            &block_on(core.search_workspace_content(
                session,
                DEFAULT_ENVIRONMENT_ID,
                ContentSearchQuery::new("x")
            ))
            .unwrap_err()
        ));
        assert!(invalid(
            &block_on(core.session_files(
                session,
                SessionFilesQuery {
                    limit: 1,
                    after: None
                }
            ))
            .unwrap_err()
        ));
    }
    assert_eq!(
        core.transport()
            .taken()
            .iter()
            .filter(|request| path_of(request).contains("/sessions/"))
            .count(),
        0
    );
}

#[test]
fn a_save_stops_when_the_latest_read_fails() {
    let transport = RouteTransport::local();
    transport.respond(
        Some("GET"),
        &format!("/v1/sessions/{SESSION}/resources/environments/{DEFAULT_ENVIRONMENT_ID}/filesystem/a.txt"),
        None,
        Reply::json(500, "{}"),
    );
    let core = connected(transport);
    let result = block_on(core.save_workspace_file(
        SESSION,
        DEFAULT_ENVIRONMENT_ID,
        path("a.txt"),
        "new".to_owned(),
        Some("base"),
    ));
    assert!(result.is_err(), "{result:?}");
    assert!(
        core.transport().writes().is_empty(),
        "nothing is written over a file that could not be read"
    );
}

#[test]
fn a_request_exposes_what_it_asks_for() {
    let listing = request(WorkspaceOperation::ListChanges);
    assert_eq!(listing.session_id(), SESSION);
    assert_eq!(listing.environment_id(), DEFAULT_ENVIRONMENT_ID);
    assert_eq!(listing.operation(), &WorkspaceOperation::ListChanges);
}

#[test]
fn an_empty_page_cursor_is_refused_and_a_real_one_is_sent() {
    let files = |after: Option<&str>| {
        WorkspaceRequest::new(
            SESSION,
            DEFAULT_ENVIRONMENT_ID,
            WorkspaceOperation::ListSessionFiles(SessionFilesQuery {
                limit: 5,
                after: after.map(str::to_owned),
            }),
        )
    };
    assert!(matches!(
        files(Some("")),
        Err(WorkspaceError::InvalidQuery { .. })
    ));
    let built = files(Some("file_9"))
        .unwrap()
        .build_for_endpoint(&ServerEndpoint::new(LOCAL).unwrap(), None)
        .unwrap();
    assert_eq!(query_value(&built, "after").as_deref(), Some("file_9"));
}

#[test]
fn a_path_search_sends_its_globs() {
    let search = request(WorkspaceOperation::SearchPaths(PathSearchQuery {
        query: "main".into(),
        under: WorkspacePath::root(),
        limit: 5,
        include: vec!["src/**".into()],
        exclude: vec!["*.lock".into()],
    }))
    .build_for_endpoint(&ServerEndpoint::new(LOCAL).unwrap(), None)
    .unwrap();
    assert_eq!(query_value(&search, "include").as_deref(), Some("src/**"));
    assert_eq!(query_value(&search, "exclude").as_deref(), Some("*.lock"));
}

#[test]
fn a_hosted_connection_builds_the_same_route_with_its_bearer() {
    let connection = HostedConnection::new(
        ServerEndpoint::new("https://example.com/omni").unwrap(),
        Some(SecretString::new("token")),
        None,
    )
    .unwrap();
    let write = request(WorkspaceOperation::WriteFile(FileWrite {
        path: path("a.txt"),
        content: "x".into(),
    }));
    assert!(matches!(
        write.build(&connection),
        Err(WorkspaceError::Session(SessionError::NotConnected))
    ));
}
