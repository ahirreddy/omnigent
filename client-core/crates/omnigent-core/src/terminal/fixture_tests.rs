//! Decoders against REST captures from a local server (`fixtures/terminal/README.md`).

use serde_json::Value;
use url::Url;

use super::*;
use crate::http::HttpResponse;

fn capture(name: &str) -> Value {
    let path = format!(
        "{}/../../fixtures/terminal/{name}",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("{path}: {error}"));
    serde_json::from_str(&text).unwrap()
}

/// The recorded response, as the host transport would hand it over.
#[allow(
    clippy::unnecessary_wraps,
    reason = "mirrors the host transport result the decoders take"
)]
fn response(capture: &Value) -> Result<HttpResponse, crate::http::TransportError> {
    Ok(HttpResponse {
        status: u16::try_from(capture["status"].as_u64().unwrap()).unwrap(),
        headers: Vec::new(),
        body: capture["body"].to_string().into_bytes(),
    })
}

fn endpoint(capture: &Value) -> TerminalEndpoint {
    let path = capture["request"]["path"].as_str().unwrap();
    let session = path
        .trim_start_matches("/v1/sessions/")
        .split('/')
        .next()
        .unwrap();
    TerminalEndpoint::new(Url::parse("http://127.0.0.1:6798").unwrap(), session).unwrap()
}

#[test]
fn recorded_requests_match_the_builders() {
    let create = capture("recorded-create.json");
    let endpoint = endpoint(&create);
    let request = endpoint
        .create_request(&CreateTerminal {
            terminal: "shell".into(),
            session_key: "u-cap001".into(),
        })
        .unwrap();
    assert!(
        request
            .url
            .ends_with(create["request"]["path"].as_str().unwrap())
    );
    let body: Value = serde_json::from_slice(request.body.as_deref().unwrap()).unwrap();
    assert_eq!(body, create["request"]["body"]);
    let list = capture("recorded-list.json");
    let request = endpoint.list_request(&ListTerminals::default()).unwrap();
    assert!(
        request
            .url
            .ends_with(list["request"]["path"].as_str().unwrap())
    );
}

#[test]
fn recorded_create_get_and_list_decode() {
    let created = resource_response(response(&capture("recorded-create.json"))).unwrap();
    assert_eq!(created.id, "terminal_shell_u-cap001");
    assert_eq!(created.terminal_name, "shell");
    assert_eq!(created.session_key, "u-cap001");
    assert_eq!(created.running, Some(true));
    let again = resource_response(response(&capture("recorded-create-idempotent.json"))).unwrap();
    assert_eq!(
        again.id, created.id,
        "the same key returns the running terminal"
    );
    let got = resource_response(response(&capture("recorded-get.json"))).unwrap();
    assert_eq!(got.id, created.id);

    let page = list_response(response(&capture("recorded-list.json"))).unwrap();
    let ids: Vec<&str> = page.terminals.iter().map(|t| t.id.as_str()).collect();
    assert_eq!(ids, ["terminal_shell_u-cap001", "terminal_tui_main"]);
    assert!(!page.has_more);
    assert!(page.terminals[1].is_agent_terminal());
    assert!(
        page.terminals[0]
            .direct_attach_url
            .as_deref()
            .is_some_and(|url| url.starts_with("ws://127.0.0.1:"))
    );
    let mut inventory = TerminalInventory::new(created.session_id.unwrap());
    inventory.apply_snapshot(page.terminals);
    let shells = inventory.user_shells(0);
    assert_eq!(shells.len(), 1);
    assert_eq!(shells[0].status, TerminalStatus::Idle);
}

#[test]
fn recorded_errors_and_delete_decode() {
    assert_eq!(
        resource_response(response(&capture("recorded-create-undeclared.json"))),
        Err(TerminalError::Rejected {
            status: 400,
            message: "Terminal 'fish' is not declared by this agent. Terminals can only be created for agents whose spec declares them; this agent declares: ['shell', 'zsh'].".into()
        })
    );
    assert!(matches!(
        resource_response(response(&capture("recorded-get-missing.json"))),
        Err(TerminalError::NotFound { reason }) if reason == "Terminal 'terminal_nope_x' not found"
    ));
    assert_eq!(
        delete_response(
            "terminal_shell_u-cap001",
            response(&capture("recorded-delete.json"))
        ),
        Ok(DeleteOutcome::Deleted)
    );
    assert_eq!(
        delete_response(
            "terminal_shell_u-cap001",
            response(&capture("recorded-delete-missing.json"))
        ),
        Ok(DeleteOutcome::AlreadyGone)
    );
}
