//! A project's kanban board: its sessions as cards in five status lanes. Port of the web's
//! `projectHome/projectKanban.ts`.
//!
//! Lanes follow live status, as the sidebar's Status grouping files sessions; a session family is
//! one card, in its most urgent member's lane. Only the read state can move a card, so a drag
//! between Unread and Done marks it read or unread and any other drop snaps back.

use std::collections::{BTreeMap, BTreeSet};

use crate::client::projects::ProjectSummary;
use crate::client::sessions::SessionSummary;
use crate::session_attention::{AttentionState, SessionAttention};
use crate::session_query::fold;

/// How recently a session must have been created to count as a new arrival, in seconds.
pub const ARRIVAL_WINDOW_SECONDS: i64 = 60;

/// How many sentences of the last reply a card previews.
pub const REPLY_PREVIEW_SENTENCES: usize = 2;

/// One of the board's lanes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
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

impl BoardLane {
    /// The lanes left to right, so a finished turn moves right into Unread beside Done.
    pub const ALL: [Self; 5] = [
        Self::Draft,
        Self::NeedsAttention,
        Self::Working,
        Self::Unread,
        Self::Done,
    ];

    /// The sidebar's Status groups, most urgent first: a family takes the first of its members'.
    const URGENCY: [Self; 5] = [
        Self::NeedsAttention,
        Self::Unread,
        Self::Working,
        Self::Draft,
        Self::Done,
    ];

    /// The lane's title.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::Draft => "Draft",
            Self::NeedsAttention => "Needs attention",
            Self::Working => "Working",
            Self::Unread => "Unread",
            Self::Done => "Done",
        }
    }

    fn urgency(self) -> usize {
        Self::URGENCY
            .iter()
            .position(|lane| *lane == self)
            .unwrap_or(Self::URGENCY.len())
    }
}

/// The lane `session` goes in: the sidebar's status bucket. `is_unread` is the host's read
/// state and `has_draft` whether its composer holds an unsent message.
#[must_use]
pub const fn lane_of(session: &SessionSummary, is_unread: bool, has_draft: bool) -> BoardLane {
    match SessionAttention::of(session, is_unread).state {
        AttentionState::NeedsYou | AttentionState::Failed => BoardLane::NeedsAttention,
        AttentionState::Working => BoardLane::Working,
        AttentionState::Unread => BoardLane::Unread,
        AttentionState::Idle if has_draft => BoardLane::Draft,
        AttentionState::Idle => BoardLane::Done,
    }
}

/// One card: a family, or a session on its own.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BoardCard {
    /// The family's head, or the lone session: what the card shows and opens.
    pub session_id: String,
    /// Every session the card stands for, head first.
    pub member_ids: Vec<String>,
    /// Its lane.
    pub lane: BoardLane,
}

/// One lane and its cards, in the board's order.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BoardColumn {
    /// The lane.
    pub lane: BoardLane,
    /// Its cards that match the filter.
    pub cards: Vec<BoardCard>,
}

/// The board's sessions: `project`'s unarchived ones as its sidebar folder files them, most
/// recently updated first (ties by id), each once.
#[must_use]
pub fn board_sessions<'a>(
    project: &ProjectSummary,
    sessions: impl IntoIterator<Item = &'a SessionSummary>,
    viewer_id: Option<&str>,
) -> Vec<&'a SessionSummary> {
    let mut seen = BTreeSet::new();
    let mut rows: Vec<&SessionSummary> = sessions
        .into_iter()
        .filter(|session| !session.is_archived && project.contains(session, viewer_id))
        .filter(|session| seen.insert(session.id.clone()))
        .collect();
    rows.sort_by(|a, b| {
        b.updated_at
            .cmp(&a.updated_at)
            .then_with(|| a.id.cmp(&b.id))
    });
    rows
}

/// Each loaded family's members, head first: the representative (else the oldest), then the
/// others newest first, as the web's `sessionFamilyGroups`.
fn family_groups<'a>(rows: &[&'a SessionSummary]) -> BTreeMap<&'a str, Vec<&'a SessionSummary>> {
    let mut families: BTreeMap<&str, Vec<&SessionSummary>> = BTreeMap::new();
    for &row in rows {
        if let Some(family) = &row.family {
            families.entry(family.id.as_str()).or_default().push(row);
        }
    }
    for (family_id, members) in &mut families {
        let representative = members
            .iter()
            .find(|row| {
                row.family
                    .as_ref()
                    .and_then(|family| family.representative_id.as_deref())
                    == Some(row.id.as_str())
            })
            .map(|row| row.id.clone());
        members.sort_by(|a, b| {
            let leads = |row: &SessionSummary| representative.as_deref() == Some(row.id.as_str());
            leads(b)
                .cmp(&leads(a))
                .then_with(|| a.created_at.cmp(&b.created_at))
                .then_with(|| (b.id == *family_id).cmp(&(a.id == *family_id)))
                .then_with(|| a.id.cmp(&b.id))
        });
        if let Some((_, rest)) = members.split_first_mut() {
            rest.reverse();
        }
    }
    families
}

/// One card per family (or lone session) in each lane, keeping `rows`' order. A family sits in
/// its most urgent member's lane.
#[must_use]
pub fn board_columns(
    rows: &[&SessionSummary],
    lane_of: impl Fn(&SessionSummary) -> BoardLane,
) -> Vec<BoardColumn> {
    let families = family_groups(rows);
    let mut placed: BTreeSet<String> = BTreeSet::new();
    let mut columns: Vec<BoardColumn> = BoardLane::ALL
        .iter()
        .map(|lane| BoardColumn {
            lane: *lane,
            cards: Vec::new(),
        })
        .collect();
    for row in rows {
        if placed.contains(&row.id) {
            continue;
        }
        let members: Vec<&SessionSummary> = row
            .family
            .as_ref()
            .and_then(|family| families.get(family.id.as_str()))
            .cloned()
            .unwrap_or_else(|| vec![*row]);
        let Some(head) = members.first() else {
            continue;
        };
        let lane = members
            .iter()
            .map(|member| lane_of(member))
            .min_by_key(|lane| lane.urgency())
            .unwrap_or(BoardLane::Done);
        placed.extend(members.iter().map(|member| member.id.clone()));
        let card = BoardCard {
            session_id: head.id.clone(),
            member_ids: members.iter().map(|member| member.id.clone()).collect(),
            lane,
        };
        if let Some(column) = columns.iter_mut().find(|column| column.lane == lane) {
            column.cards.push(card);
        }
    }
    columns
}

/// Whether `session` matches the board's filter: its title or id contains `query`, ignoring
/// case (the sidebar search's title-or-id rule). An empty query matches everything.
#[must_use]
pub fn matches_filter(session: &SessionSummary, query: &str) -> bool {
    let query = fold(query.trim());
    query.is_empty() || fold(&session.title).contains(&query) || fold(&session.id).contains(&query)
}

/// `columns` keeping only the cards with a member that matches `query`.
#[must_use]
pub fn filter_columns(
    columns: Vec<BoardColumn>,
    query: &str,
    session: impl Fn(&str) -> Option<SessionSummary>,
) -> Vec<BoardColumn> {
    if query.trim().is_empty() {
        return columns;
    }
    columns
        .into_iter()
        .map(|mut column| {
            column.cards.retain(|card| {
                card.member_ids
                    .iter()
                    .filter_map(|id| session(id))
                    .any(|member| matches_filter(&member, query))
            });
            column
        })
        .collect()
}

/// The lane a phone opens on: the first with cards, else the first.
#[must_use]
pub fn opening_lane(columns: &[BoardColumn]) -> BoardLane {
    columns
        .iter()
        .find(|column| !column.cards.is_empty())
        .map_or(BoardLane::Draft, |column| column.lane)
}

/// What dropping a card on a lane does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BoardDropAction {
    /// Its unread sessions become read: Unread to Done.
    MarkRead,
    /// Its head becomes unread: Done to Unread.
    MarkUnread,
}

/// What dropping a card from lane `from` on lane `to` does; `None` snaps it back. Lanes follow
/// live status, so only the read state can move a card: Unread to Done and back.
#[must_use]
pub const fn drop_action(from: BoardLane, to: BoardLane) -> Option<BoardDropAction> {
    match (from, to) {
        (BoardLane::Unread, BoardLane::Done) => Some(BoardDropAction::MarkRead),
        (BoardLane::Done, BoardLane::Unread) => Some(BoardDropAction::MarkUnread),
        _ => None,
    }
}

/// The sessions whose read state `action` on `card` changes: marking read clears every unread
/// member, marking unread flags the head alone.
#[must_use]
pub fn read_marks(
    card: &BoardCard,
    action: BoardDropAction,
    is_unread: impl Fn(&str) -> bool,
) -> Vec<String> {
    match action {
        BoardDropAction::MarkRead => card
            .member_ids
            .iter()
            .filter(|id| is_unread(id))
            .cloned()
            .collect(),
        BoardDropAction::MarkUnread => vec![card.session_id.clone()],
    }
}

/// The ids among `sessions` that just joined the board: not in `known` and created within
/// [`ARRIVAL_WINDOW_SECONDS`] of `now`. Older sessions revealed by paging don't count.
#[must_use]
pub fn arrivals<'a>(
    sessions: impl IntoIterator<Item = &'a SessionSummary>,
    known: &BTreeSet<String>,
    now: i64,
) -> Vec<String> {
    sessions
        .into_iter()
        .filter(|session| !known.contains(&session.id))
        .filter(|session| now.saturating_sub(session.created_at) <= ARRIVAL_WINDOW_SECONDS)
        .map(|session| session.id.clone())
        .collect()
}

/// The first `count` sentences of a reply as plain prose: code blocks and heading lines are
/// dropped, and list and quote markers and emphasis are stripped (the web's `leadingSentences`).
#[must_use]
pub fn leading_sentences(text: &str, count: usize) -> String {
    let prose = without_code_blocks(text)
        .lines()
        .filter(|line| !is_heading(line))
        .map(|line| without_marker(line).trim())
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
        .replace("**", "")
        .replace("__", "")
        .replace('`', "");
    prose
        .lines()
        .flat_map(sentences)
        .take(count)
        .collect::<Vec<_>>()
        .join(" ")
}

/// `text` with each fenced code block, and an unclosed one to the end, replaced by a line break.
fn without_code_blocks(text: &str) -> String {
    let mut kept = String::with_capacity(text.len());
    let mut rest = text;
    while let Some((before, after)) = rest.split_once("```") {
        kept.push_str(before);
        kept.push('\n');
        rest = after.split_once("```").map_or("", |(_, tail)| tail);
    }
    kept.push_str(rest);
    kept
}

fn is_heading(line: &str) -> bool {
    let trimmed = line.trim_start();
    let hashes = trimmed
        .chars()
        .take_while(|character| *character == '#')
        .count();
    (1..=6).contains(&hashes) && trimmed.chars().nth(hashes).is_some_and(char::is_whitespace)
}

/// `line` without a leading quote, bullet or numbered-list marker.
fn without_marker(line: &str) -> &str {
    let trimmed = line.trim_start();
    if let Some(rest) = trimmed.strip_prefix('>') {
        return rest.strip_prefix(' ').unwrap_or(rest);
    }
    for bullet in ['-', '*', '+'] {
        if let Some(rest) = trimmed.strip_prefix(bullet)
            && rest.starts_with(char::is_whitespace)
        {
            return rest.trim_start();
        }
    }
    let digits = trimmed.chars().take_while(char::is_ascii_digit).count();
    if digits > 0
        && let Some(rest) = trimmed.get(digits..)
        && let Some(rest) = rest.strip_prefix(['.', ')'])
        && rest.starts_with(char::is_whitespace)
    {
        return rest.trim_start();
    }
    line
}

/// One line's sentences, each trimmed: a break follows `.`, `!` or `?` (and any closing quotes
/// or brackets) before a space, except a `.` that runs on into lower case ("e.g. this").
/// Ideographic full stops end a sentence at once.
fn sentences(line: &str) -> Vec<&str> {
    let mut found = Vec::new();
    let mut start = 0;
    let mut characters = line.char_indices().peekable();
    while let Some((index, character)) = characters.next() {
        let ends = match character {
            '。' | '！' | '？' => true,
            '.' | '!' | '?' => {
                let mut end = index + character.len_utf8();
                while let Some((next, closer)) = characters.peek().copied() {
                    if matches!(closer, ')' | ']' | '"' | '\'' | '\u{2019}' | '\u{201D}') {
                        end = next + closer.len_utf8();
                        characters.next();
                    } else {
                        break;
                    }
                }
                let rest = line.get(end..).unwrap_or("");
                let spaced = rest.starts_with(char::is_whitespace);
                let next = rest.trim_start().chars().next();
                spaced && !(character == '.' && next.is_some_and(char::is_lowercase))
            }
            _ => false,
        };
        if ends {
            let end = characters.peek().map_or(line.len(), |(next, _)| *next);
            if let Some(sentence) = line.get(start..end).map(str::trim)
                && !sentence.is_empty()
            {
                found.push(sentence);
            }
            start = end;
        }
    }
    if let Some(sentence) = line.get(start..).map(str::trim)
        && !sentence.is_empty()
    {
        found.push(sentence);
    }
    found
}

#[cfg(test)]
#[path = "project_board_tests.rs"]
mod tests;
