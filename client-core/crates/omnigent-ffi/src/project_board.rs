//! A project's kanban board: its sessions as cards in five status lanes, with the drag between
//! Unread and Done and each card's reply preview. The rules are `omnigent_core::project_board`.

use std::collections::{BTreeSet, HashMap, HashSet};

use omnigent_core::project_board as core;
use omnigent_core::projects::ProjectSummary as CoreProject;
use omnigent_core::sessions::SessionSummary as CoreSummary;

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::sessions::{ProjectSummary, SessionSummary};

/// One of the board's lanes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum BoardLane {
    /// Idle with an unsent draft.
    Draft,
    /// A decision is pending, the last turn failed, or the agent waits in its terminal.
    NeedsAttention,
    /// A turn or background work is in progress.
    Working,
    /// Finished with activity the user has not seen.
    Unread,
    /// Finished and seen.
    Done,
}

impl From<core::BoardLane> for BoardLane {
    fn from(lane: core::BoardLane) -> Self {
        match lane {
            core::BoardLane::Draft => Self::Draft,
            core::BoardLane::NeedsAttention => Self::NeedsAttention,
            core::BoardLane::Working => Self::Working,
            core::BoardLane::Unread => Self::Unread,
            core::BoardLane::Done => Self::Done,
        }
    }
}

impl From<BoardLane> for core::BoardLane {
    fn from(lane: BoardLane) -> Self {
        match lane {
            BoardLane::Draft => Self::Draft,
            BoardLane::NeedsAttention => Self::NeedsAttention,
            BoardLane::Working => Self::Working,
            BoardLane::Unread => Self::Unread,
            BoardLane::Done => Self::Done,
        }
    }
}

/// One card: a family, or a session on its own.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct BoardCard {
    /// The family's head, or the lone session: what the card shows and opens.
    pub session_id: String,
    /// Every session the card stands for, head first.
    pub member_ids: Vec<String>,
    /// Its lane.
    pub lane: BoardLane,
}

impl From<core::BoardCard> for BoardCard {
    fn from(card: core::BoardCard) -> Self {
        Self {
            session_id: card.session_id,
            member_ids: card.member_ids,
            lane: card.lane.into(),
        }
    }
}

impl From<BoardCard> for core::BoardCard {
    fn from(card: BoardCard) -> Self {
        Self {
            session_id: card.session_id,
            member_ids: card.member_ids,
            lane: card.lane.into(),
        }
    }
}

/// One lane and its cards.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct BoardColumn {
    /// The lane.
    pub lane: BoardLane,
    /// Its cards that match the filter, in the board's order.
    pub cards: Vec<BoardCard>,
}

/// What dropping a card on a lane does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum BoardDropAction {
    /// Its unread sessions become read.
    MarkRead,
    /// Its head becomes unread.
    MarkUnread,
}

impl From<core::BoardDropAction> for BoardDropAction {
    fn from(action: core::BoardDropAction) -> Self {
        match action {
            core::BoardDropAction::MarkRead => Self::MarkRead,
            core::BoardDropAction::MarkUnread => Self::MarkUnread,
        }
    }
}

impl From<BoardDropAction> for core::BoardDropAction {
    fn from(action: BoardDropAction) -> Self {
        match action {
            BoardDropAction::MarkRead => Self::MarkRead,
            BoardDropAction::MarkUnread => Self::MarkUnread,
        }
    }
}

/// `project`'s board from the loaded `sessions`, its lanes left to right.
///
/// Its own unarchived sessions are cards, one per family, kept when a member's title or id
/// contains `query`. `unread_ids` and `draft_ids` are the host's read marks and unsent drafts.
#[must_use]
#[uniffi::export]
pub fn project_board(
    project: ProjectSummary,
    sessions: Vec<SessionSummary>,
    unread_ids: Vec<String>,
    draft_ids: Vec<String>,
    viewer_id: Option<String>,
    query: String,
) -> Vec<BoardColumn> {
    let project = CoreProject::from(project);
    let unread: HashSet<String> = unread_ids.into_iter().collect();
    let drafts: HashSet<String> = draft_ids.into_iter().collect();
    let summaries: Vec<CoreSummary> = sessions.iter().map(Into::into).collect();
    let rows = core::board_sessions(&project, &summaries, viewer_id.as_deref());
    let columns = core::board_columns(&rows, |session| {
        core::lane_of(
            session,
            unread.contains(&session.id),
            drafts.contains(&session.id),
        )
    });
    let by_id: HashMap<&str, &CoreSummary> = rows
        .iter()
        .map(|session| (session.id.as_str(), *session))
        .collect();
    core::filter_columns(columns, &query, |id| {
        by_id.get(id).map(|row| (*row).clone())
    })
    .into_iter()
    .map(|column| BoardColumn {
        lane: column.lane.into(),
        cards: column.cards.into_iter().map(Into::into).collect(),
    })
    .collect()
}

/// A lane's title ("Needs attention").
#[must_use]
#[uniffi::export]
pub fn board_lane_title(lane: BoardLane) -> String {
    core::BoardLane::from(lane).title().to_owned()
}

/// What dropping a card from lane `from` on lane `to` does; `None` snaps it back.
#[must_use]
#[uniffi::export]
pub fn board_drop_action(from: BoardLane, to: BoardLane) -> Option<BoardDropAction> {
    core::drop_action(from.into(), to.into()).map(Into::into)
}

/// The sessions whose read state `action` on `card` changes; `unread_ids` are the host's marks.
#[must_use]
#[uniffi::export]
pub fn board_read_marks(
    card: BoardCard,
    action: BoardDropAction,
    unread_ids: Vec<String>,
) -> Vec<String> {
    let unread: HashSet<String> = unread_ids.into_iter().collect();
    core::read_marks(&card.into(), action.into(), |id| unread.contains(id))
}

/// The sessions among `sessions` that just joined the board: not in `known_ids` and created
/// within a minute of `now` (Unix seconds).
#[must_use]
#[uniffi::export]
pub fn board_arrivals(
    sessions: Vec<SessionSummary>,
    known_ids: Vec<String>,
    now: i64,
) -> Vec<String> {
    let known: BTreeSet<String> = known_ids.into_iter().collect();
    let summaries: Vec<CoreSummary> = sessions.iter().map(Into::into).collect();
    core::arrivals(&summaries, &known, now)
}

/// The lane a phone opens on: the first with cards, else the first.
#[must_use]
#[uniffi::export]
pub fn board_opening_lane(columns: Vec<BoardColumn>) -> BoardLane {
    let columns: Vec<core::BoardColumn> = columns
        .into_iter()
        .map(|column| core::BoardColumn {
            lane: column.lane.into(),
            cards: column.cards.into_iter().map(Into::into).collect(),
        })
        .collect();
    core::opening_lane(&columns).into()
}

#[uniffi::export]
impl ClientCore {
    /// The opening sentences of `session_id`'s last agent reply, as plain prose, for its board
    /// card; `None` when its newest items hold no reply.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the history read's errors.
    pub async fn board_reply_preview(
        &self,
        session_id: String,
    ) -> Result<Option<String>, CoreError> {
        let reply = self
            .sessions()
            .last_reply(&session_id)
            .await
            .map_err(CoreError::from)?;
        Ok(reply
            .map(|text| core::leading_sentences(&text, core::REPLY_PREVIEW_SENTENCES))
            .filter(|preview| !preview.is_empty()))
    }
}

#[cfg(test)]
#[path = "project_board_tests.rs"]
mod tests;
