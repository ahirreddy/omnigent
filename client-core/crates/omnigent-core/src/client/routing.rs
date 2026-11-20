//! Replica routing for host-sharded deployments (Databricks workspaces).
//!
//! A host's control tunnel and its runners' tunnels register on one replica, keyed by the host id,
//! so a request for a session or host must carry that id
//! ([`SLICE_KEY_HEADER`], or [`SLICE_KEY_QUERY`] on a WebSocket) to reach the replica holding the
//! tunnel. A request that reached the wrong one answers 400 `wrong_replica`. Port of the web
//! client's rules (`web/src/lib/identity.ts`, `sessionHost.ts`):
//!
//! - Session routes key by the session's host (or the requested sandbox host, or the nearest
//!   ancestor's for a side chat); host routes by the host in the path; a create, import or managed
//!   fork by the host in its body; anything else by the modal host (the host most of the user's
//!   sessions run on), frozen after the first successful session list.
//! - A keyed request answered `wrong_replica` is retried once without the key; when that works,
//!   the host is remembered as keyless (its tunnels dialed in without a key and live on the
//!   default replica). A keyless one answered `wrong_replica` for a session whose host was unknown
//!   learns the host from the session snapshot and is retried once with it.
//! - A sub-agent or side chat has no host of its own: it is keyed by its parent's, so the parent
//!   link is recorded wherever a child is seen (its snapshot, its parent's child list and stream
//!   events), and a session whose host is unknown is looked up before its first request.

#![allow(
    clippy::redundant_pub_crate,
    reason = "crate-internal helpers of a private module; `pub` would trip rustc's unreachable_pub"
)]

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

#[cfg(test)]
use super::session_tools::SIDE_CHAT_SOURCE_LABEL;
use super::session_tools::side_chat_source_id;

/// The header that carries the host id on REST and event-stream requests.
pub const SLICE_KEY_HEADER: &str = "X-Databricks-Omnigent-Slice-Key";
/// The query parameter that carries the host id on WebSocket URLs.
pub const SLICE_KEY_QUERY: &str = "omnigent_slice_key";
/// The label a managed create records the host id it chose in, until that host binds.
const REQUESTED_HOST_LABEL: &str = "omnigent.sandbox.requested_host_id";
const WRONG_REPLICA: &str = "wrong_replica";

/// What the client knows about where sessions run. Reset with the connection.
#[derive(Debug, Default)]
pub(crate) struct ReplicaRouting {
    hosts: BTreeMap<String, String>,
    parents: BTreeMap<String, String>,
    keyless: BTreeSet<String>,
    /// Sessions whose snapshots were read up the parent chain and named no host.
    hostless: BTreeSet<String>,
    modal: Modal,
}

/// The modal host: not yet frozen, or frozen (to nothing when no session had a host).
#[derive(Debug, Default)]
enum Modal {
    #[default]
    Unresolved,
    Frozen(Option<String>),
}

/// What a session payload said about a field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Reported<'a> {
    /// The payload did not carry it: keep what is known.
    Unsaid,
    /// It was `null`: clear it.
    Cleared,
    /// Its value.
    Value(&'a str),
}

/// How a request was addressed, for the `wrong_replica` retry.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Addressing {
    /// The host the request is for, if known.
    pub(crate) host: Option<String>,
    /// Whether the key was sent.
    pub(crate) keyed: bool,
    /// The session whose host was unknown, for a session route.
    pub(crate) unresolved_session: Option<String>,
}

impl ReplicaRouting {
    /// Records a session's host and routing parent from a session row or snapshot. A bound host
    /// wins; else the host a managed create requested (label); a side chat's parent comes from
    /// its labels when the payload names none.
    pub(crate) fn record(
        &mut self,
        session_id: &str,
        host: Reported<'_>,
        parent: Reported<'_>,
        labels: Option<&BTreeMap<String, String>>,
    ) {
        let requested = labels
            .and_then(|labels| labels.get(REQUESTED_HOST_LABEL))
            .map(String::as_str)
            .filter(|id| !id.is_empty());
        match (host, requested) {
            (Reported::Value(host), _) if !host.is_empty() => {
                self.hosts.insert(session_id.to_owned(), host.to_owned());
            }
            (_, Some(requested)) => {
                self.hosts
                    .insert(session_id.to_owned(), requested.to_owned());
            }
            (Reported::Cleared | Reported::Value(_), None) => {
                self.hosts.remove(session_id);
            }
            (Reported::Unsaid, None) => {}
        }
        let label_parent = labels.and_then(side_chat_source_id).map(str::to_owned);
        let parent = match parent {
            Reported::Value(parent) if !parent.is_empty() => Some(parent.to_owned()),
            Reported::Unsaid if label_parent.is_none() => return,
            Reported::Unsaid | Reported::Cleared | Reported::Value(_) => label_parent,
        };
        match parent {
            Some(parent) if parent != session_id => {
                self.parents.insert(session_id.to_owned(), parent);
            }
            Some(_) | None => {
                self.parents.remove(session_id);
            }
        }
    }

    /// The host a session routes by: its own, else the nearest host-bound ancestor's.
    pub(crate) fn session_host(&self, session_id: &str) -> Option<&str> {
        let mut visited = BTreeSet::new();
        let mut id = Some(session_id);
        while let Some(current) = id {
            if !visited.insert(current) {
                return None;
            }
            if let Some(host) = self.hosts.get(current) {
                return Some(host);
            }
            id = self.parents.get(current).map(String::as_str);
        }
        None
    }

    /// The routing parent recorded for `session_id`, if any.
    pub(crate) fn parent(&self, session_id: &str) -> Option<&str> {
        self.parents.get(session_id).map(String::as_str)
    }

    /// Records that `child` runs on `parent`'s runner: a row of the parent's child list, or a
    /// child event on the parent's stream. Such rows carry no host, so the link is all there is.
    pub(crate) fn record_parent(&mut self, child: &str, parent: &str) {
        if child.is_empty() || parent.is_empty() || child == parent {
            return;
        }
        self.parents.insert(child.to_owned(), parent.to_owned());
        self.hostless.remove(child);
    }

    /// Records that `child` runs under `ancestor` when no nearer parent is known: a request
    /// mirrored into `ancestor`'s chat is answered on the child, on the ancestor's replica.
    pub(crate) fn record_ancestor(&mut self, child: &str, ancestor: &str) {
        if !self.parents.contains_key(child) {
            self.record_parent(child, ancestor);
        }
    }

    /// A lookup up `session_id`'s parent chain found no host, so the next request for it goes
    /// straight out instead of repeating the lookup.
    pub(crate) fn mark_hostless(&mut self, session_id: &str) {
        self.hostless.insert(session_id.to_owned());
    }

    /// Whether a request for `session_id` should first look its host up: none is known and no
    /// lookup has come back empty yet.
    pub(crate) fn needs_lookup(&self, session_id: &str) -> bool {
        self.session_host(session_id).is_none() && !self.hostless.contains(session_id)
    }

    /// How a request for `host`, learned after the request was built, is addressed.
    pub(crate) fn addressed_to(&self, host: &str) -> Addressing {
        Addressing {
            host: Some(host.to_owned()),
            keyed: !self.keyless.contains(host),
            unresolved_session: None,
        }
    }

    /// Freezes the modal host after the first successful session list; later calls do nothing.
    pub(crate) fn resolve_modal(&mut self) {
        if matches!(self.modal, Modal::Frozen(_)) {
            return;
        }
        let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
        let mut best: Option<(&str, usize)> = None;
        for host in self.hosts.values() {
            let count = counts.entry(host.as_str()).or_default();
            *count += 1;
            if best.is_none_or(|(_, top)| *count > top) {
                best = Some((host.as_str(), *count));
            }
        }
        self.modal = Modal::Frozen(best.map(|(host, _)| host.to_owned()));
    }

    /// The modal host, once frozen.
    pub(crate) fn modal(&self) -> Option<&str> {
        match &self.modal {
            Modal::Frozen(host) => host.as_deref(),
            Modal::Unresolved => None,
        }
    }

    /// How to address `method path?query` with `body`: the host it is for and whether to key it.
    pub(crate) fn address(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, String)],
        body: Option<&Value>,
    ) -> Addressing {
        let mut unresolved_session = None;
        let host = if path == "/v1/skills" {
            let param = |name: &str| {
                query
                    .iter()
                    .find(|(key, _)| *key == name)
                    .map(|(_, value)| value.as_str())
                    .filter(|value| !value.is_empty())
            };
            param("session_id").map_or_else(
                || param("host_id").map(str::to_owned),
                |session| {
                    let host = self.session_host(session).map(str::to_owned);
                    if host.is_none() {
                        unresolved_session = Some(session.to_owned());
                    }
                    host
                },
            )
        } else if let Some(host) = segment_after(path, "/v1/hosts/") {
            Some(host.to_owned())
        } else if let Some(session) = segment_after(path, "/v1/sessions/") {
            // A managed fork or a move into a sandbox goes where the new sandbox will live.
            if (is_fork(path) && body_str(body, "host_type") == Some("managed"))
                || is_managed_host(path)
            {
                body_str(body, "host_id").map(str::to_owned)
            } else {
                let host = self.session_host(session).map(str::to_owned);
                if host.is_none() && path.len() > "/v1/sessions/".len() + session.len() {
                    unresolved_session = Some(session.to_owned());
                }
                host
            }
        } else if is_body_host_keyed(method, path) {
            body_str(body, "host_id").map(str::to_owned)
        } else {
            self.modal().map(str::to_owned)
        };
        let keyed = host
            .as_ref()
            .is_some_and(|host| !self.keyless.contains(host));
        Addressing {
            host,
            keyed,
            unresolved_session,
        }
    }

    /// A keyless retry of a keyed request to `host` worked: its tunnels live on the default
    /// replica.
    pub(crate) fn mark_keyless(&mut self, host: &str) {
        self.keyless.insert(host.to_owned());
    }

    /// A request sent keyless because `host` was demoted still reached the wrong replica.
    pub(crate) fn clear_keyless(&mut self, host: &str) {
        self.keyless.remove(host);
    }
}

/// Whether a response body is the server's `wrong_replica` refusal.
pub(crate) fn is_wrong_replica(status: u16, body: &[u8]) -> bool {
    if status != 400 {
        return false;
    }
    serde_json::from_slice::<Value>(body).is_ok_and(|value| {
        value
            .get("error")
            .and_then(|error| error.get("code"))
            .or_else(|| value.get("code"))
            .and_then(Value::as_str)
            == Some(WRONG_REPLICA)
    })
}

/// The path segment after `prefix`, for `prefix<segment>[/...]`.
fn segment_after<'a>(path: &'a str, prefix: &str) -> Option<&'a str> {
    let rest = path.strip_prefix(prefix)?;
    let segment = rest.split('/').next().unwrap_or_default();
    (!segment.is_empty()).then_some(segment)
}

fn is_fork(path: &str) -> bool {
    session_tail(path) == Some("fork")
}

fn is_managed_host(path: &str) -> bool {
    session_tail(path) == Some("managed-host")
}

/// The part of `/v1/sessions/{id}/<tail>` after the id.
fn session_tail(path: &str) -> Option<&str> {
    path.strip_prefix("/v1/sessions/")
        .and_then(|rest| rest.split_once('/'))
        .map(|(_, tail)| tail)
}

/// A create or local import, which names its host in the body.
fn is_body_host_keyed(method: &str, path: &str) -> bool {
    method == "POST"
        && (path == "/v1/sessions"
            || path == "/v1/imports/local"
            || path.starts_with("/v1/imports/local/"))
}

fn body_str<'a>(body: Option<&'a Value>, key: &str) -> Option<&'a str> {
    body?.get(key)?.as_str().filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn a_folder_skill_read_is_addressed_to_the_host_it_names() {
        let routing = ReplicaRouting::default();
        let addressing = routing.address(
            "GET",
            "/v1/skills",
            &[
                ("host_id", "host_b".to_owned()),
                ("session_id", String::new()),
            ],
            None,
        );
        assert_eq!(addressing.host.as_deref(), Some("host_b"));
    }

    #[test]
    fn a_move_into_a_sandbox_goes_where_the_new_sandbox_lives() {
        let mut routing = ReplicaRouting::default();
        routing.record("conv_a", Reported::Value("host_a"), Reported::Unsaid, None);
        let body = serde_json::json!({"sandbox_provider": "modal", "host_id": "host_new"});
        let moved = routing.address("POST", "/v1/sessions/conv_a/managed-host", &[], Some(&body));
        assert_eq!(moved.host.as_deref(), Some("host_new"));
        let unminted = serde_json::json!({"sandbox_provider": "modal"});
        let moved = routing.address(
            "POST",
            "/v1/sessions/conv_a/managed-host",
            &[],
            Some(&unminted),
        );
        assert_eq!(moved.host, None);
        let released = routing.address("PATCH", "/v1/sessions/conv_a", &[], Some(&body));
        assert_eq!(released.host.as_deref(), Some("host_a"));
    }

    #[test]
    fn creates_and_imports_name_their_host_in_the_body() {
        assert!(is_body_host_keyed("POST", "/v1/sessions"));
        assert!(is_body_host_keyed("POST", "/v1/imports/local"));
        assert!(is_body_host_keyed("POST", "/v1/imports/local/scan"));
        assert!(!is_body_host_keyed("GET", "/v1/sessions"));
        assert!(!is_body_host_keyed("POST", "/v1/imports"));
    }

    #[test]
    fn session_routes_key_by_the_sessions_host_or_its_ancestors() {
        let mut routing = ReplicaRouting::default();
        routing.record("conv_a", Reported::Value("host_a"), Reported::Unsaid, None);
        routing.record(
            "conv_child",
            Reported::Cleared,
            Reported::Value("conv_a"),
            None,
        );
        routing.record(
            "conv_side",
            Reported::Unsaid,
            Reported::Unsaid,
            Some(&labels(&[(SIDE_CHAT_SOURCE_LABEL, "conv_child")])),
        );
        routing.record(
            "conv_new",
            Reported::Cleared,
            Reported::Unsaid,
            Some(&labels(&[(REQUESTED_HOST_LABEL, "host_new")])),
        );
        for (session, host) in [
            ("conv_a", Some("host_a")),
            ("conv_child", Some("host_a")),
            ("conv_side", Some("host_a")),
            ("conv_new", Some("host_new")),
            ("conv_unknown", None),
        ] {
            let address =
                routing.address("GET", &format!("/v1/sessions/{session}/items"), &[], None);
            assert_eq!(address.host.as_deref(), host, "{session}");
            assert_eq!(address.keyed, host.is_some(), "{session}");
        }
        let unknown = routing.address("GET", "/v1/sessions/conv_unknown/items", &[], None);
        assert_eq!(unknown.unresolved_session.as_deref(), Some("conv_unknown"));
        let snapshot = routing.address("GET", "/v1/sessions/conv_unknown", &[], None);
        assert_eq!(
            snapshot.unresolved_session, None,
            "the snapshot is host-agnostic"
        );

        // A cycle ends the walk.
        routing.record("conv_x", Reported::Cleared, Reported::Value("conv_y"), None);
        routing.record("conv_y", Reported::Cleared, Reported::Value("conv_x"), None);
        assert_eq!(routing.session_host("conv_x"), None);
    }

    #[test]
    fn a_child_listed_under_its_parent_routes_by_the_parents_host() {
        let mut routing = ReplicaRouting::default();
        routing.record("conv_a", Reported::Value("host_a"), Reported::Unsaid, None);
        assert!(routing.needs_lookup("conv_child"));
        routing.mark_hostless("conv_child");
        assert!(
            !routing.needs_lookup("conv_child"),
            "an empty lookup is not repeated"
        );

        routing.record_parent("conv_child", "conv_a");
        assert_eq!(routing.session_host("conv_child"), Some("host_a"));
        assert!(!routing.needs_lookup("conv_child"));
        let address = routing.address("GET", "/v1/sessions/conv_child/stream", &[], None);
        assert_eq!(address.host.as_deref(), Some("host_a"));
        assert!(address.keyed);
        assert_eq!(address.unresolved_session, None);

        // A child of an unknown parent is looked up again; nonsense links are ignored.
        routing.mark_hostless("conv_grandchild");
        routing.record_parent("conv_grandchild", "conv_unknown");
        assert!(routing.needs_lookup("conv_grandchild"));
        routing.record_parent("conv_a", "conv_a");
        routing.record_parent("", "conv_a");
        routing.record_parent("conv_x", "");
        assert_eq!(routing.parent("conv_a"), None);
        assert_eq!(routing.parent("conv_x"), None);

        // A mirrored request's carrying session stands in only while no parent is known.
        routing.record_ancestor("conv_child", "conv_other");
        assert_eq!(routing.parent("conv_child"), Some("conv_a"));
        routing.record_ancestor("conv_deep", "conv_a");
        assert_eq!(routing.session_host("conv_deep"), Some("host_a"));

        // A host learned later is addressed with or without the key, as the host stands.
        assert!(routing.addressed_to("host_a").keyed);
        routing.mark_keyless("host_a");
        let demoted = routing.addressed_to("host_a");
        assert_eq!(demoted.host.as_deref(), Some("host_a"));
        assert!(!demoted.keyed);
    }

    #[test]
    fn a_skill_read_for_a_session_with_no_known_host_names_the_session_to_look_up() {
        let routing = ReplicaRouting::default();
        let query = [("session_id", "conv_child".to_owned())];
        let address = routing.address("GET", "/v1/skills", &query, None);
        assert_eq!(address.host, None);
        assert_eq!(address.unresolved_session.as_deref(), Some("conv_child"));
        let by_host = [("host_id", "host_b".to_owned())];
        let address = routing.address("GET", "/v1/skills", &by_host, None);
        assert_eq!(address.unresolved_session, None);
    }

    #[test]
    fn host_body_and_unscoped_routes() {
        let mut routing = ReplicaRouting::default();
        routing.record("conv_1", Reported::Value("host_b"), Reported::Unsaid, None);
        routing.record("conv_2", Reported::Value("host_b"), Reported::Unsaid, None);
        routing.record("conv_3", Reported::Value("host_c"), Reported::Unsaid, None);
        assert_eq!(
            routing.address("GET", "/v1/sessions", &[], None).host,
            None,
            "nothing before the modal is frozen"
        );
        routing.resolve_modal();
        routing.record("conv_4", Reported::Value("host_c"), Reported::Unsaid, None);
        routing.record("conv_5", Reported::Value("host_c"), Reported::Unsaid, None);
        routing.resolve_modal();
        assert_eq!(routing.modal(), Some("host_b"), "frozen at the first list");
        assert_eq!(
            routing
                .address("GET", "/v1/sessions", &[], None)
                .host
                .as_deref(),
            Some("host_b")
        );
        assert_eq!(
            routing
                .address("GET", "/v1/hosts/host_z/runners", &[], None)
                .host
                .as_deref(),
            Some("host_z")
        );
        let create = serde_json::json!({"host_id": "host_q"});
        assert_eq!(
            routing
                .address("POST", "/v1/sessions", &[], Some(&create))
                .host
                .as_deref(),
            Some("host_q")
        );
        assert_eq!(
            routing
                .address("POST", "/v1/sessions", &[], Some(&serde_json::json!({})))
                .host,
            None,
            "a create without a host stays unkeyed, never the modal"
        );
        let managed = serde_json::json!({"host_type": "managed", "host_id": "host_m"});
        assert_eq!(
            routing
                .address("POST", "/v1/sessions/conv_1/fork", &[], Some(&managed))
                .host
                .as_deref(),
            Some("host_m")
        );
        assert_eq!(
            routing
                .address("POST", "/v1/sessions/conv_1/fork", &[], None)
                .host
                .as_deref(),
            Some("host_b")
        );
        let skills = [("session_id", "conv_3".to_owned())];
        assert_eq!(
            routing
                .address("GET", "/v1/skills", &skills, None)
                .host
                .as_deref(),
            Some("host_c")
        );
    }

    #[test]
    fn keyless_hosts_are_addressed_without_the_key() {
        let mut routing = ReplicaRouting::default();
        routing.record("conv_a", Reported::Value("host_a"), Reported::Unsaid, None);
        routing.mark_keyless("host_a");
        let address = routing.address("GET", "/v1/sessions/conv_a/items", &[], None);
        assert_eq!(address.host.as_deref(), Some("host_a"));
        assert!(!address.keyed);
        routing.clear_keyless("host_a");
        assert!(
            routing
                .address("GET", "/v1/sessions/conv_a/items", &[], None)
                .keyed
        );
    }

    #[test]
    fn wrong_replica_is_the_400_code_only() {
        let body = br#"{"error":{"code":"wrong_replica","message":"host shell inventory is on another replica"}}"#;
        assert!(is_wrong_replica(400, body));
        assert!(!is_wrong_replica(409, body));
        assert!(!is_wrong_replica(
            400,
            br#"{"error":{"code":"runner_unavailable"}}"#
        ));
        assert!(!is_wrong_replica(400, b"not json"));
    }
}
