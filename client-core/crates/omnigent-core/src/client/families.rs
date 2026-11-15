//! Writes to session families: a nested member is never pinned or moved on its own; pinning or
//! moving a representative carries its whole family on the server; and after any family write
//! the members this client holds are read again, so their `family` is the server's.

use std::collections::BTreeMap;

use futures::future::join_all;

use super::sessions::{SessionChange, SessionSummary};
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
}

#[cfg(test)]
#[path = "families_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "families_edit_tests.rs"]
mod edit_tests;
