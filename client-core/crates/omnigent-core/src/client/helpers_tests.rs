//! The small request helpers, with failures no server response can cause.

use serde_json::Value;

use super::SessionError;
use super::events::{add_connection_headers, malformed_answer};
use super::requests::{connected_base_url, encoded_body};
use crate::auth::SecretString;
use crate::auth::endpoint::ServerEndpoint;
use crate::auth::hosted::HostedConnection;
use crate::decisions::ResolveError;
use crate::http::HttpRequest;

fn encoder_failure() -> serde_json::Error {
    serde_json::from_str::<Value>("{").unwrap_err()
}

#[test]
fn a_body_that_does_not_encode_is_a_malformed_request() {
    let detail = encoder_failure().to_string();
    assert_eq!(
        encoded_body(Err(encoder_failure())),
        Err(SessionError::MalformedResponse {
            detail: format!("could not encode the request body: {detail}"),
        })
    );
    assert_eq!(encoded_body(Ok(vec![1])), Ok(vec![1]));
}

#[test]
fn a_base_url_that_does_not_parse_is_malformed() {
    assert!(matches!(
        connected_base_url("not a url"),
        Err(SessionError::MalformedResponse { detail }) if detail.starts_with("connected base URL")
    ));
    assert_eq!(
        connected_base_url("https://h/").unwrap().as_str(),
        "https://h/"
    );
}

#[test]
fn an_answer_that_does_not_encode_is_malformed() {
    let error = ResolveError::Encode {
        message: "no".to_owned(),
    };
    assert_eq!(
        malformed_answer(&error),
        SessionError::MalformedResponse {
            detail: error.to_string()
        }
    );
}

fn upload_request() -> HttpRequest {
    HttpRequest {
        method: "POST".into(),
        url: "https://h/upload".into(),
        headers: Vec::new(),
        body: None,
    }
}

#[test]
fn an_upload_without_a_connection_gets_no_credentials() {
    let mut request = upload_request();
    add_connection_headers(None, &mut request);
    assert_eq!(request.headers, []);
}

#[test]
fn an_upload_on_a_connection_carries_its_bearer() {
    let endpoint = ServerEndpoint::new("https://h/").unwrap();
    let connection =
        HostedConnection::new(endpoint, Some(SecretString::new("token")), None).unwrap();
    let mut request = upload_request();
    add_connection_headers(Some(&connection), &mut request);
    assert!(
        request
            .headers
            .iter()
            .any(|header| header.name == "Authorization"),
        "the bearer travels with the upload"
    );
}

#[test]
fn a_request_that_cannot_be_credentialed_is_an_invalid_request() {
    assert_eq!(
        super::terminals::invalid_request("no".to_owned()),
        crate::terminal::TerminalError::InvalidRequest {
            detail: "no".to_owned()
        }
    );
    assert_eq!(
        super::remote_browsers::invalid_request("no".to_owned()),
        crate::remote_browser::RemoteBrowserError::InvalidRequest {
            detail: "no".to_owned()
        }
    );
}
