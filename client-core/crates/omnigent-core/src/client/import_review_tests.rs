//! The import review lists each brand harness's credential and what it carries over.

use futures::executor::block_on;

use crate::client::SessionError;
use crate::client::test_support::{Reply, RouteTransport, connected};

fn hosts(status: &str) -> String {
    format!(
        r#"{{"hosts":[{{"host_id":"h1","name":"Work Mac","status":"{status}",
            "configured_harnesses":{{"claude-native":true,"codex-native":"needs-auth",
                "cursor-native":"binary-missing"}},
            "gateway_inference":{{"claude-native":true}}}}]}}"#
    )
}

#[test]
fn each_installed_harness_shows_its_credential_and_what_carries_over() {
    let core = connected(RouteTransport::local());
    core.transport().ok("/v1/hosts", hosts("online"));
    core.transport().ok(
        "/v1/hosts/h1/mcp-servers",
        r#"{"mcp_servers":[{"name":"docs","harness":"claude","transport":"http","scope":"user"}]}"#,
    );
    core.transport().ok(
        "/v1/skills",
        r#"{"skills":[{"name":"review","description":"Review a diff"}],"warnings":[]}"#,
    );
    core.transport().respond(
        Some("GET"),
        "/v1/hosts/h1/plugins",
        None,
        Reply::json(200, r#"{"plugins":[]}"#),
    );
    let review = block_on(core.import_review("h1")).unwrap();
    assert!(review.online);
    assert_eq!(review.host_name, "Work Mac");
    let labels: Vec<_> = review.harnesses.iter().map(|h| h.label.as_str()).collect();
    assert_eq!(labels, ["Claude Code", "Codex"], "Cursor isn't installed");
    let claude = &review.harnesses[0];
    assert_eq!(
        claude.credential.as_deref(),
        Some("Databricks Unity Gateway")
    );
    assert_eq!(claude.mcp_servers, ["docs"]);
    assert_eq!(claude.skills.len(), 1);
    let codex = &review.harnesses[1];
    assert_eq!(codex.credential, None, "not signed in");
    assert_eq!(codex.skills.len(), 1, "it still carries its skills over");
}

#[test]
fn an_offline_host_has_nothing_to_read_and_an_unknown_one_is_refused() {
    let core = connected(RouteTransport::local());
    core.transport().ok("/v1/hosts", hosts("offline"));
    let review = block_on(core.import_review("h1")).unwrap();
    assert!(!review.online);
    assert_eq!(review.harnesses.len(), 0);
    assert!(matches!(
        block_on(core.import_review("h2")),
        Err(SessionError::InvalidInput { .. })
    ));
}
