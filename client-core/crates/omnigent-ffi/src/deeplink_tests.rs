//! Deep links' records in both directions.

use omnigent_core::deeplink as core;

use crate::deeplink::{
    DeepLinkAcknowledgment, DeepLinkPolicy, DeepLinkRoute, conversation_url, parse_deep_link,
};
use crate::errors::CoreError;

const NONCE: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

#[test]
fn each_policy_and_route_maps() {
    assert_eq!(
        core::DeepLinkPolicy::from(DeepLinkPolicy::Desktop),
        core::DeepLinkPolicy::Desktop
    );
    assert_eq!(
        core::DeepLinkPolicy::from(DeepLinkPolicy::Ios),
        core::DeepLinkPolicy::Ios
    );
    assert_eq!(
        DeepLinkRoute::from(core::DeepLinkRoute::Home),
        DeepLinkRoute::Home
    );
    assert_eq!(
        core::DeepLinkRoute::from(DeepLinkRoute::Home),
        core::DeepLinkRoute::Home
    );
    assert_eq!(
        core::DeepLinkRoute::from(DeepLinkRoute::Conversation {
            session_id: "s".into()
        }),
        core::DeepLinkRoute::Conversation {
            session_id: "s".into()
        }
    );
}

#[test]
fn a_cli_link_carries_its_acknowledgment_and_a_home_route() {
    let link = parse_deep_link(
        format!("omnigent://localhost:6767/?desktop_ack=1234:{NONCE}"),
        DeepLinkPolicy::Desktop,
    )
    .unwrap();
    assert_eq!(link.host, "localhost");
    assert_eq!(link.port, Some(6767));
    assert_eq!(link.route, DeepLinkRoute::Home);
    assert_eq!(link.path, "/");
    assert_eq!(
        link.acknowledgment,
        Some(DeepLinkAcknowledgment {
            port: 1234,
            nonce: NONCE.into(),
            callback_path: format!("/desktop-open/{NONCE}"),
        })
    );
}

#[test]
fn a_bad_server_url_or_one_that_cannot_hold_a_path_is_refused() {
    let invalid = |server: &str| {
        let Err(CoreError::InvalidUrl { message }) =
            conversation_url(server.to_owned(), DeepLinkRoute::Home)
        else {
            panic!("{server} was accepted");
        };
        message
    };
    assert!(invalid("not a url").starts_with("not a url:"));
    assert!(invalid("mailto:a@example.com").contains("mailto:a@example.com"));
}
