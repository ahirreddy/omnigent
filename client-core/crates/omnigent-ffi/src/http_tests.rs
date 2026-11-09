//! The HTTP records and errors as they cross to the host and back.

use super::core;
use super::*;

#[test]
fn debug_text_keeps_secrets_out_of_logs() {
    let header = HttpHeader {
        name: "Authorization".into(),
        value: "Bearer secret".into(),
    };
    let text = format!("{header:?}");
    assert!(text.contains("Authorization"), "{text}");
    assert!(!text.contains("secret"), "{text}");
    let response = HttpResponse {
        status: 401,
        headers: vec![header],
        body: b"secret body".to_vec(),
    };
    let text = format!("{response:?}");
    assert!(text.contains("401"), "{text}");
    assert!(!text.contains("secret"), "{text}");
}

#[test]
fn a_core_response_reaches_the_host_whole() {
    let response = HttpResponse::from(core::http::HttpResponse {
        status: 201,
        headers: vec![core::http::HttpHeader::new("Etag", "v1")],
        body: b"body".to_vec(),
    });
    assert_eq!(response.status, 201);
    assert_eq!(response.headers[0].name, "Etag");
    assert_eq!(response.headers[0].value, "v1");
    assert_eq!(response.body, b"body");
}

#[test]
fn every_transport_error_keeps_its_kind_both_ways() {
    use core::http::TransportError as Core;
    let message = || "why".to_owned();
    for (on_host, in_core) in [
        (
            TransportError::Offline { message: message() },
            Core::Offline { message: message() },
        ),
        (
            TransportError::Timeout { message: message() },
            Core::Timeout { message: message() },
        ),
        (TransportError::Cancelled, Core::Cancelled),
        (
            TransportError::Tls { message: message() },
            Core::Tls { message: message() },
        ),
        (
            TransportError::Other { message: message() },
            Core::Other { message: message() },
        ),
    ] {
        assert_eq!(TransportError::from(in_core.clone()), on_host);
        assert_eq!(Core::from(on_host), in_core);
    }
}

#[test]
fn something_a_foreign_transport_throws_outside_its_contract_keeps_its_reason() {
    assert_eq!(
        TransportError::from(uniffi::UnexpectedUniFFICallbackError::new("boom")),
        TransportError::Other {
            message: "unexpected transport error: boom".into()
        }
    );
}
