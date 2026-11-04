//! Session list search, filters and ordering.
//!
//! Port of `NativeLab`'s `SessionQuery.swift`. Pinned sessions come first, in pin order (the web's
//! `orderByPinnedTimestamp`), then the most recently updated; equal timestamps order by id so the list never reshuffles. A session that needs a
//! response stays in the attention filter even when archived.

use std::cmp::Ordering;

use crate::client::pin_order;
use crate::client::sessions::SessionSummary;
use crate::session_attention::{AttentionState, SessionAttention};

/// Which sessions a list shows.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum SessionFilter {
    /// Every session that is not archived.
    #[default]
    All,
    /// Working ([`AttentionState::Working`]), not archived.
    Running,
    /// Needs you ([`AttentionState::NeedsYou`]), archived or not.
    NeedsResponse,
    /// Archived.
    Archived,
}

impl SessionFilter {
    /// Every filter, in display order.
    pub const ALL: [Self; 4] = [
        Self::All,
        Self::Running,
        Self::NeedsResponse,
        Self::Archived,
    ];

    /// The filter's display title.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::All => "All sessions",
            Self::Running => "Running",
            Self::NeedsResponse => "Needs you",
            Self::Archived => "Archived",
        }
    }

    fn includes(self, session: &SessionSummary) -> bool {
        match self {
            Self::All => !session.is_archived,
            Self::Running => {
                !session.is_archived
                    && SessionAttention::of(session, false).state == AttentionState::Working
            }
            Self::NeedsResponse => {
                SessionAttention::of(session, false).state == AttentionState::NeedsYou
            }
            Self::Archived => session.is_archived,
        }
    }
}

/// Folds case and diacritics the way Foundation's `localizedStandardContains` does for the
/// Latin text session titles use: lower case, and accented Latin letters reduced to their base.
fn fold(text: &str) -> String {
    text.chars()
        .flat_map(char::to_lowercase)
        .map(|character| match character {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' => 'a',
            'ç' | 'ć' | 'č' => 'c',
            'è' | 'é' | 'ê' | 'ë' | 'ē' => 'e',
            'ì' | 'í' | 'î' | 'ï' | 'ī' => 'i',
            'ñ' | 'ń' => 'n',
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' => 'o',
            'ù' | 'ú' | 'û' | 'ü' | 'ū' => 'u',
            'ý' | 'ÿ' => 'y',
            'š' => 's',
            'ž' => 'z',
            other => other,
        })
        .collect()
}

fn order(left: &SessionSummary, right: &SessionSummary) -> Ordering {
    right
        .is_pinned
        .cmp(&left.is_pinned)
        .then_with(|| {
            if left.is_pinned && right.is_pinned {
                pin_order::compare(left, right)
            } else {
                Ordering::Equal
            }
        })
        .then_with(|| right.updated_at.cmp(&left.updated_at))
        .then_with(|| left.id.cmp(&right.id))
}

/// The sessions matching `text` (title, preview, workspace or agent; case- and
/// diacritic-insensitive; trimmed) and `filter`, pinned first in pin order, then most recent, then
/// by id.
#[must_use]
pub fn matching(
    sessions: &[SessionSummary],
    text: &str,
    filter: SessionFilter,
) -> Vec<SessionSummary> {
    let query = fold(text.trim());
    let mut result: Vec<SessionSummary> = sessions
        .iter()
        .filter(|session| filter.includes(session))
        .filter(|session| {
            query.is_empty()
                || [
                    &session.title,
                    &session.preview,
                    &session.workspace,
                    &session.agent_name,
                ]
                .iter()
                .any(|field| fold(field).contains(&query))
        })
        .cloned()
        .collect();
    result.sort_by(order);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::sessions::SummaryStatus;

    fn session(id: &str, title: &str, preview: &str, updated_at: i64) -> SessionSummary {
        SessionSummary {
            updated_at,
            ..SessionSummary::new(id, title, preview)
        }
    }

    fn ids(sessions: &[SessionSummary]) -> Vec<&str> {
        sessions.iter().map(|session| session.id.as_str()).collect()
    }

    #[test]
    fn queries_search_context_and_group_pins_before_recents() {
        let older_pin = SessionSummary {
            workspace: "Omni / iOS".into(),
            agent_name: "Codex".into(),
            is_pinned: true,
            ..session("pin", "Café design", "Review", 1)
        };
        let recent = session("new", "Build", "Fix the keyboard", 3);
        let earlier = session("old", "Notes", "", 2);
        let sessions = [earlier, recent, older_pin];
        assert_eq!(
            ids(&matching(&sessions, "", SessionFilter::All)),
            ["pin", "new", "old"]
        );
        for query in [" café ", "iOS", "Codex", "review", "cafe"] {
            assert_eq!(
                ids(&matching(&sessions, query, SessionFilter::All)),
                ["pin"],
                "{query}"
            );
        }
        assert_eq!(
            ids(&matching(&sessions, "keyboard", SessionFilter::All)),
            ["new"]
        );
        assert_eq!(matching(&sessions, "unmatched", SessionFilter::All), []);
    }

    #[test]
    fn archived_decisions_stay_in_attention_and_filters_are_exclusive() {
        let archived = SessionSummary {
            status: SummaryStatus::NeedsResponse,
            pending_requests: 1,
            is_archived: true,
            ..session("archive", "Waiting", "", 0)
        };
        let running = SessionSummary {
            status: SummaryStatus::Running,
            ..session("running", "Busy", "", 0)
        };
        let sessions = [archived, running];
        assert_eq!(
            ids(&matching(&sessions, "", SessionFilter::All)),
            ["running"]
        );
        assert_eq!(
            ids(&matching(&sessions, "", SessionFilter::Running)),
            ["running"]
        );
        assert_eq!(
            ids(&matching(&sessions, "", SessionFilter::NeedsResponse)),
            ["archive"]
        );
        assert_eq!(
            ids(&matching(&sessions, "", SessionFilter::Archived)),
            ["archive"]
        );
        assert_eq!(SessionFilter::ALL.map(SessionFilter::title)[2], "Needs you");
    }

    #[test]
    fn equal_timestamps_have_stable_ordering() {
        let sessions: Vec<SessionSummary> = ["z", "a", "b"]
            .iter()
            .map(|id| session(id, id, "", 10))
            .collect();
        assert_eq!(
            ids(&matching(&sessions, "", SessionFilter::All)),
            ["a", "b", "z"]
        );
    }
}
