//! Session grants over the fake host.

use serde_json::json as value;

use crate::share::{SessionGrant, public_grantee};
use crate::test_support::{connected, json};

const PATH: &str = "/v1/sessions/conv_a/permissions";

#[test]
fn grants_read_each_field_and_mark_the_owner() {
    assert_eq!(public_grantee(), "__public__");
    let mut harness = connected();
    harness.http.route(
        PATH,
        json(
            200,
            r#"{"permissions":[
              {"user_id":"owner@x.com","conversation_id":"conv_a","level":4},
              {"user_id":"__public__","conversation_id":"conv_a","level":1}
            ],"next_cursor":null}"#,
        ),
    );
    let grants = harness
        .call(|core| async move { core.session_grants("conv_a".into()).await })
        .unwrap();
    assert_eq!(
        grants,
        [
            SessionGrant {
                user_id: "owner@x.com".into(),
                level: 4,
                is_owner: true,
            },
            SessionGrant {
                user_id: "__public__".into(),
                level: 1,
                is_owner: false,
            },
        ]
    );
    assert_eq!(harness.last_request_line(), format!("GET {PATH}"));
}

#[test]
fn granting_and_revoking_send_the_grantee_and_level() {
    let mut harness = connected();
    harness.http.route_method(
        "PUT",
        PATH,
        json(
            200,
            r#"{"user_id":"bob@x.com","conversation_id":"conv_a","level":2}"#,
        ),
    );
    let granted = harness
        .call(|core| async move {
            core.grant_session_access("conv_a".into(), " bob@x.com ".into(), 2)
                .await
        })
        .unwrap();
    assert_eq!(
        granted,
        SessionGrant {
            user_id: "bob@x.com".into(),
            level: 2,
            is_owner: false,
        }
    );
    assert_eq!(
        harness.last_request(),
        (
            format!("PUT {PATH}"),
            value!({"user_id": "bob@x.com", "level": 2})
        )
    );

    harness
        .http
        .route_method("DELETE", &format!("{PATH}/bob@x.com"), json(204, ""));
    harness
        .call(|core| async move {
            core.revoke_session_access("conv_a".into(), "bob@x.com".into())
                .await
        })
        .unwrap();
    assert_eq!(
        harness.last_request_line(),
        format!("DELETE {PATH}/bob@x.com")
    );
}

#[test]
fn each_call_reports_a_failure() {
    let mut harness = connected();
    harness.http.route(PATH, json(403, r#"{"detail":"no"}"#));
    assert!(
        harness
            .call(|core| async move { core.session_grants("conv_a".into()).await })
            .is_err()
    );
    assert!(
        harness
            .call(|core| async move {
                core.grant_session_access("conv_a".into(), "bob".into(), 2)
                    .await
            })
            .is_err()
    );
    assert!(
        harness
            .call(|core| async move {
                core.revoke_session_access("conv_a".into(), "bob".into())
                    .await
            })
            .is_err()
    );
}
