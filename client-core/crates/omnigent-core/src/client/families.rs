//! Writes to session families: a nested member is never pinned or moved on its own; pinning or
//! moving a representative carries its whole family on the server; a session moves into or out
//! of a nest by itself; and after any family write the members this client holds are read
//! again, so their `family` is the server's.

use std::collections::{BTreeMap, BTreeSet};

use futures::future::join_all;
use serde_json::json;

use super::requests::{acknowledgement, validate_identifier};
use super::sessions::{SessionChange, SessionSummary, decode_snapshot_value};
use super::{ClientCore, ClientEvent, SessionError, State, lock};
use crate::http::HttpTransport;
use crate::session_families::NESTED_MEMBER_EDIT_REFUSAL;

/// The refusal of a pin or move of a nested member.
pub(super) fn nested_member_refusal() -> SessionError {
    SessionError::InvalidInput {
        reason: NESTED_MEMBER_EDIT_REFUSAL.to_owned(),
    }
}

/// The family whose other members a write of `change` to `row` changes on the server: a
/// representative's pin or move carries its family, and archiving or restoring any member can
/// promote another representative. `None` for a standalone row or a rename.
pub(super) fn family_changed_by(
    change: &SessionChange,
    row: Option<&SessionSummary>,
) -> Option<String> {
    let row = row?;
    let family = row.family.as_ref()?;
    let represents = family.representative_id.as_deref() == Some(row.id.as_str());
    match change {
        SessionChange::Pinned { .. } | SessionChange::PinnedAt(_) | SessionChange::Project(_) => {
            represents.then(|| family.id.clone())
        }
        SessionChange::Archived { .. } => Some(family.id.clone()),
        SessionChange::Title(_) => None,
    }
}

/// How one edit of a batch goes out (see [`batch_routes`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum BatchRoute {
    /// Sent as its own write.
    Send,
    /// A nested member's move, carried by its representative's move at this index.
    CarriedBy(usize),
    /// A move refused before any request: a nested member was selected without its
    /// representative.
    Refused,
}

/// How each edit of a batch goes out. A nested member's move rides on its representative's move
/// in the same batch; when one is selected without its representative, every move of the batch
/// is refused, as the web's bulk move is.
pub(super) fn batch_routes(
    edits: &[(String, SessionChange)],
    cached: impl Fn(&str) -> Option<SessionSummary>,
) -> Vec<BatchRoute> {
    let moves = |index: usize| matches!(edits.get(index), Some((_, SessionChange::Project(_))));
    let routes: Vec<BatchRoute> = edits
        .iter()
        .enumerate()
        .map(|(index, (session_id, _))| {
            let representative = cached(session_id)
                .filter(|row| moves(index) && row.is_nested_member())
                .and_then(|row| row.family.and_then(|family| family.representative_id));
            let Some(representative) = representative else {
                return BatchRoute::Send;
            };
            edits
                .iter()
                .enumerate()
                .position(|(other, (id, _))| *id == representative && moves(other))
                .map_or(BatchRoute::Refused, BatchRoute::CarriedBy)
        })
        .collect();
    if !routes.contains(&BatchRoute::Refused) {
        return routes;
    }
    (0..edits.len())
        .map(|index| {
            if moves(index) {
                BatchRoute::Refused
            } else {
                BatchRoute::Send
            }
        })
        .collect()
}

impl State {
    /// The members of `family_id` this client holds, but `except`.
    pub(super) fn family_members(&self, family_id: &str, except: &str) -> Vec<String> {
        self.summaries
            .values()
            .filter(|row| row.id != except)
            .filter(|row| {
                row.family
                    .as_ref()
                    .is_some_and(|family| family.id == family_id)
            })
            .map(|row| row.id.clone())
            .collect()
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Reads the members of `family_id` this client holds (but `except`, just written) again
    /// after a family write, and publishes them. A member that is gone is forgotten; one that
    /// cannot be read is left to the updates stream and the next list read
    /// (`InventoryInvalidated`). Returns the rows read, by id.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub(super) async fn refresh_family(
        &self,
        family_id: &str,
        except: &str,
    ) -> BTreeMap<String, SessionSummary> {
        let members = lock(&self.state).family_members(family_id, except);
        let reads = join_all(members.iter().map(|id| self.fetch_snapshot(id))).await;
        let mut state = lock(&self.state);
        let mut refreshed = BTreeMap::new();
        let mut unread = false;
        for (member, read) in members.into_iter().zip(reads) {
            let accepted = read
                .and_then(|(decoded, epoch)| state.accept_projection(&decoded.projection, epoch));
            match accepted {
                Ok(summary) => {
                    state.settle_intents(&summary);
                    refreshed.insert(member, summary);
                }
                Err(SessionError::SessionNotFound { .. }) => state.forget_session(&member),
                Err(_) => unread = true,
            }
        }
        if !refreshed.is_empty() {
            state.events.push(ClientEvent::SessionsChanged {
                sessions: refreshed.values().cloned().collect(),
            });
        }
        if unread {
            state.events.push(ClientEvent::InventoryInvalidated);
        }
        refreshed
    }

    /// Moves `session_id` into the nest of `destination_id`, or out of its nest with `None`
    /// (`PATCH /v1/sessions/{id}` with `nest_source_id`, servers that report
    /// `session_nest_moves`). The members of the nests it left and joined that this client holds
    /// are read again, so their `family` is the server's.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; [`SessionError::ReadOnly`] for a
    /// session the caller doesn't own; [`SessionError::DeliveryUncertain`] for an unreadable
    /// acknowledgement; the write errors, such as the server's refusal of a session it can't
    /// move.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn move_to_nest(
        &self,
        session_id: &str,
        destination_id: Option<&str>,
    ) -> Result<SessionSummary, SessionError> {
        let result = self.write_nest(session_id, destination_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn write_nest(
        &self,
        session_id: &str,
        destination_id: Option<&str>,
    ) -> Result<SessionSummary, SessionError> {
        validate_identifier(session_id)?;
        if let Some(destination) = destination_id {
            validate_identifier(destination)?;
        }
        let (left, epoch) = {
            let state = lock(&self.state);
            let cached = state.summaries.get(session_id);
            // Moving a session is its owner's, as filing it is.
            if cached.is_some_and(|row| !row.can_archive()) {
                return Err(SessionError::ReadOnly);
            }
            let left = cached.and_then(|row| row.family.as_ref().map(|family| family.id.clone()));
            (left, state.metadata_epoch(session_id))
        };
        let path = format!("/v1/sessions/{session_id}");
        let body = json!({ "nest_source_id": destination_id });
        let response = self
            .write(self.prepare("PATCH", &path, &[], Some(&body))?)
            .await?;
        let decoded =
            decode_snapshot_value(acknowledgement(&path, &response)?).map_err(|detail| {
                SessionError::DeliveryUncertain {
                    detail: format!("unreadable {path} acknowledgement: {detail}"),
                }
            })?;
        let moved = {
            let mut state = lock(&self.state);
            let moved = state.accept_projection(&decoded.projection, epoch)?;
            state.settle_intents(&moved);
            state.events.push(ClientEvent::SessionsChanged {
                sessions: vec![moved.clone()],
            });
            moved
        };
        let joined = moved.family.as_ref().map(|family| family.id.clone());
        let families: BTreeSet<String> = [left, joined].into_iter().flatten().collect();
        for family in families {
            self.refresh_family(&family, session_id).await;
        }
        Ok(moved)
    }
}

#[cfg(test)]
#[path = "families_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "families_edit_tests.rs"]
mod edit_tests;
