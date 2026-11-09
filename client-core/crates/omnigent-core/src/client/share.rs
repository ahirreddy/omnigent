//! Session sharing: the grants on a session, `GET`, `PUT` and `DELETE
//! /v1/sessions/{id}/permissions` (`omnigent/server/routes/sessions/routes_permissions.py`).
//!
//! Levels are the server's: 1 read, 2 edit, 3 manage, 4 owner. `__public__` is anyone with the
//! link, capped by the server's public ceiling. Grants are writes: never retried.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::json::{as_object, opt_array, opt_str, opt_u64, req_str};
use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// The grantee that means anyone with the link.
pub const PUBLIC_GRANTEE: &str = "__public__";

/// The most grants read from one session.
const MAX_GRANT_PAGES: usize = 10;

/// One grant on a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionGrant {
    /// The grantee: a user id or email, or [`PUBLIC_GRANTEE`].
    pub user_id: String,
    /// 1 read, 2 edit, 3 manage, 4 owner.
    pub level: u8,
}

impl SessionGrant {
    /// The owner's own grant, which cannot be changed here.
    #[must_use]
    pub const fn is_owner(&self) -> bool {
        self.level >= 4
    }
}

/// `value` can be sent as a grantee: non-blank, no path or query characters.
fn validate_grantee(value: &str) -> Result<(), SessionError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > 320
        || trimmed.contains(['/', '?', '#', '%', '\\'])
        || trimmed.chars().any(char::is_whitespace)
        || trimmed == "."
        || trimmed == ".."
    {
        return Err(SessionError::InvalidIdentifier {
            value: value.to_owned(),
        });
    }
    Ok(())
}

fn decode_grant(value: &Value) -> Result<SessionGrant, String> {
    let object = as_object(value, "permission")?;
    let level = opt_u64(object, "level")?.ok_or("`level` is missing")?;
    Ok(SessionGrant {
        user_id: req_str(object, "user_id")?,
        level: u8::try_from(level).map_err(|_| "`level` is out of range".to_owned())?,
    })
}

impl<T: HttpTransport> ClientCore<T> {
    /// Every grant on `session_id`, following `next_cursor` (needs manage access).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, the read errors (`Forbidden`
    /// below manage access), [`SessionError::MalformedResponse`] and
    /// [`SessionError::InvalidPagination`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_grants(
        &self,
        session_id: &str,
    ) -> Result<Vec<SessionGrant>, SessionError> {
        let result = async {
            validate_identifier(session_id)?;
            let path = format!("/v1/sessions/{session_id}/permissions");
            let malformed = |detail: String| SessionError::MalformedResponse {
                detail: format!("{path}: {detail}"),
            };
            let mut grants = Vec::new();
            let mut cursors = BTreeSet::new();
            let mut after: Option<String> = None;
            for _ in 0..MAX_GRANT_PAGES {
                let mut query = vec![("limit", "100".to_owned())];
                if let Some(cursor) = &after {
                    query.push(("after", cursor.clone()));
                }
                let value = self.get_json(&path, &query).await?;
                let object = as_object(&value, "permissions").map_err(malformed)?;
                for row in opt_array(object, "permissions")
                    .map_err(malformed)?
                    .ok_or_else(|| malformed("`permissions` is missing".into()))?
                {
                    grants.push(decode_grant(row).map_err(malformed)?);
                }
                match opt_str(object, "next_cursor").map_err(malformed)? {
                    None => return Ok(grants),
                    Some(cursor) if cursors.insert(cursor.clone()) => after = Some(cursor),
                    Some(_) => return Err(SessionError::InvalidPagination),
                }
            }
            Ok(grants)
        }
        .await;
        self.dispatch();
        result
    }

    /// Grants `user_id` `level` (1 read, 2 edit, 3 manage) on `session_id`, or changes it.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request (also for a level outside 1 to 3),
    /// and the write errors: `Rejected` with the server's reason (sharing off, a home-folder
    /// workspace), `Forbidden`, `DeliveryUncertain`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn grant_session_access(
        &self,
        session_id: &str,
        user_id: &str,
        level: u8,
    ) -> Result<SessionGrant, SessionError> {
        let result = async {
            validate_identifier(session_id)?;
            validate_grantee(user_id)?;
            if !(1..=3).contains(&level) {
                return Err(SessionError::InvalidIdentifier {
                    value: level.to_string(),
                });
            }
            let path = format!("/v1/sessions/{session_id}/permissions");
            let body = json!({"user_id": user_id.trim(), "level": level});
            let value = self.write_json("PUT", &path, &body).await?;
            decode_grant(&value).map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable acknowledgement from {path}: {detail}"),
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Removes `user_id`'s grant on `session_id` (your own leaves the session).
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request, and the write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn revoke_session_access(
        &self,
        session_id: &str,
        user_id: &str,
    ) -> Result<(), SessionError> {
        let result = async {
            validate_identifier(session_id)?;
            validate_grantee(user_id)?;
            let path = format!("/v1/sessions/{session_id}/permissions/{}", user_id.trim());
            self.write(self.prepare("DELETE", &path, &[], None)?)
                .await
                .map(|_| ())
        }
        .await;
        self.dispatch();
        result
    }
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::super::test_support::{Reply, RouteTransport, body_json, connected, path_of};
    use super::*;

    #[test]
    fn an_unreadable_grant_acknowledgement_is_uncertain() {
        let transport = RouteTransport::local();
        transport.ok("/v1/sessions/s1/permissions", r#"{"user_id":5}"#);
        let core = connected(transport);
        assert!(matches!(
            block_on(core.grant_session_access("s1", "ada", 2)),
            Err(SessionError::DeliveryUncertain { detail }) if detail.contains("unreadable")
        ));
    }

    #[test]
    fn a_repeated_cursor_is_refused_and_a_runaway_listing_stops_at_its_cap() {
        let page = |cursor: &str| {
            Reply::json(
                200,
                format!(r#"{{"permissions":[],"next_cursor":"{cursor}"}}"#),
            )
        };
        let transport = RouteTransport::local();
        transport.enqueue(
            "GET",
            "/v1/sessions/conv_a/permissions",
            vec![page("a"), page("a")],
        );
        let core = connected(transport);
        assert_eq!(
            block_on(core.session_grants("conv_a")),
            Err(SessionError::InvalidPagination)
        );

        let transport = RouteTransport::local();
        transport.enqueue(
            "GET",
            "/v1/sessions/conv_a/permissions",
            (0..=MAX_GRANT_PAGES)
                .map(|index| page(&format!("c{index}")))
                .collect(),
        );
        let core = connected(transport);
        assert_eq!(block_on(core.session_grants("conv_a")).unwrap().len(), 0);
        let reads = core
            .transport()
            .taken()
            .iter()
            .filter(|request| path_of(request).ends_with("/permissions"))
            .count();
        assert_eq!(reads, MAX_GRANT_PAGES);
    }

    #[test]
    fn unreadable_grant_replies_are_reported_by_route() {
        let transport = RouteTransport::local();
        transport.ok("/v1/sessions/conv_a/permissions", "[]");
        let core = connected(transport);
        assert!(matches!(
            block_on(core.session_grants("conv_a")),
            Err(SessionError::MalformedResponse { detail }) if detail.contains("/permissions")
        ));
    }

    #[test]
    fn grants_page_and_writes_send_the_servers_shape() {
        let transport = RouteTransport::local();
        transport.enqueue(
            "GET",
            "/v1/sessions/conv_a/permissions",
            vec![
                Reply::json(
                    200,
                    r#"{"permissions":[{"user_id":"owner@x.com","conversation_id":"conv_a","level":4}],
                        "next_cursor":"owner@x.com"}"#,
                ),
                Reply::json(
                    200,
                    r#"{"permissions":[{"user_id":"__public__","conversation_id":"conv_a","level":1}],
                        "next_cursor":null}"#,
                ),
            ],
        );
        transport.ok(
            "/v1/sessions/conv_a/permissions",
            r#"{"user_id":"bob@x.com","conversation_id":"conv_a","level":2}"#,
        );
        transport.respond(
            Some("DELETE"),
            "/v1/sessions/conv_a/permissions/bob@x.com",
            None,
            Reply::json(204, ""),
        );
        let core = connected(transport);
        let grants = block_on(core.session_grants("conv_a")).unwrap();
        assert_eq!(grants.len(), 2);
        assert!(grants[0].is_owner());
        assert_eq!(grants[1].user_id, PUBLIC_GRANTEE);
        let granted = block_on(core.grant_session_access("conv_a", " bob@x.com ", 2)).unwrap();
        assert_eq!(granted.level, 2);
        block_on(core.revoke_session_access("conv_a", "bob@x.com")).unwrap();
        let writes = core.transport().writes();
        assert_eq!(
            body_json(&writes[0]),
            json!({"user_id": "bob@x.com", "level": 2})
        );
        assert_eq!(writes[1].method, "DELETE");
        assert_eq!(
            path_of(&writes[1]),
            "/v1/sessions/conv_a/permissions/bob@x.com"
        );
    }

    #[test]
    fn bad_grantees_and_levels_send_nothing() {
        let core = connected(RouteTransport::local());
        for (user, level) in [("", 1), ("a/b", 1), ("a b", 1), ("ok", 4), ("ok", 0)] {
            assert!(matches!(
                block_on(core.grant_session_access("conv_a", user, level)),
                Err(SessionError::InvalidIdentifier { .. })
            ));
        }
        assert_eq!(core.transport().writes().len(), 0);
    }
}
