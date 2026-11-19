//! The session journal reads behind the Tasks tab (web `useSessionJournal`).
//!
//! One bounded page of the newest entries; when older pages exist, the current plan and each of
//! its steps' newest status are read too, so every step shows where it stands; and for a current
//! plan, the run boundary (and, for a saved workflow's run, the plan that started it). The
//! stream pushes later entries (`session.journal.appended`); after the stream was down,
//! [`ClientCore::session_journal_since`] catches up.

use futures::future::join_all;

use super::requests::validate_identifier;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;
use crate::session_journal::{JournalEntry, JournalPage, current_plan, merge_journal_entries};

/// Entries per page, as the web reads them.
const PAGE_SIZE: &str = "100";
/// A catch-up reads at most this many pages; past that the journal is read again.
const CATCH_UP_MAX_PAGES: usize = 5;

impl<T: HttpTransport> ClientCore<T> {
    /// The session's journal as the Tasks tab reads it, in position order.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidIdentifier`] before any request; the read errors (`404` on servers
    /// without journals); [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_journal(
        &self,
        session_id: &str,
    ) -> Result<Vec<JournalEntry>, SessionError> {
        let result = self.read_session_journal(session_id).await;
        self.dispatch();
        result
    }

    /// The entries after `after_id`, oldest first; `None` when more than a few pages were
    /// missed, so the caller reads the journal again.
    ///
    /// # Errors
    ///
    /// As [`ClientCore::session_journal`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn session_journal_since(
        &self,
        session_id: &str,
        after_id: &str,
    ) -> Result<Option<Vec<JournalEntry>>, SessionError> {
        let result = self.catch_up_journal(session_id, after_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn journal_page(
        &self,
        session_id: &str,
        query: &[(&str, String)],
    ) -> Result<JournalPage, SessionError> {
        validate_identifier(session_id)?;
        let path = format!("/v1/sessions/{session_id}/journal");
        let value = self.get_json(&path, query).await?;
        JournalPage::from_value(&value).map_err(|detail| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        })
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_session_journal(
        &self,
        session_id: &str,
    ) -> Result<Vec<JournalEntry>, SessionError> {
        let newest = self
            .journal_page(
                session_id,
                &[("order", "desc".into()), ("limit", PAGE_SIZE.into())],
            )
            .await?;
        let mut pages = vec![newest.data];
        if newest.has_more {
            pages.extend(self.plan_and_statuses(session_id).await?);
        }
        let lists: Vec<&[JournalEntry]> = pages.iter().map(Vec::as_slice).collect();
        let entries = merge_journal_entries(&lists);
        if current_plan(&entries).is_none() {
            return Ok(entries);
        }
        let boundary = self.run_boundary(session_id).await?;
        Ok(merge_journal_entries(&[&entries, &boundary]))
    }

    /// The newest plan and each of its steps' newest status, which older pages may hold: a busy
    /// step must not crowd another's last status out of the newest page.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn plan_and_statuses(
        &self,
        session_id: &str,
    ) -> Result<Vec<Vec<JournalEntry>>, SessionError> {
        let plan = self
            .journal_page(
                session_id,
                &[
                    ("kind", "plan".into()),
                    ("order", "desc".into()),
                    ("limit", "1".into()),
                ],
            )
            .await?;
        let steps = plan
            .data
            .first()
            .map(|plan| plan.steps.clone())
            .unwrap_or_default();
        let statuses = join_all(steps.iter().map(|step| async move {
            let query = [
                ("kind", "status".to_owned()),
                ("step", step.id.clone()),
                ("order", "desc".to_owned()),
                ("limit", "1".to_owned()),
            ];
            self.journal_page(session_id, &query).await
        }))
        .await;
        let mut pages = vec![plan.data];
        for status in statuses {
            pages.push(status?.data);
        }
        Ok(pages)
    }

    /// The current run's start, which the live plan event does not carry and older pages may
    /// hold; for a saved workflow's run, also the plan that started it, which names the workflow.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn run_boundary(&self, session_id: &str) -> Result<Vec<JournalEntry>, SessionError> {
        let boundary = self
            .journal_page(
                session_id,
                &[
                    ("kind", "plan_status".into()),
                    ("order", "desc".into()),
                    ("limit", "1".into()),
                ],
            )
            .await?;
        let Some(start) = boundary
            .data
            .first()
            .filter(|start| start.workflow_id.is_some())
        else {
            return Ok(boundary.data);
        };
        let origin = self
            .journal_page(
                session_id,
                &[
                    ("kind", "plan".into()),
                    ("order", "asc".into()),
                    ("after", start.id.clone()),
                    ("limit", "1".into()),
                ],
            )
            .await?;
        Ok(merge_journal_entries(&[&boundary.data, &origin.data]))
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn catch_up_journal(
        &self,
        session_id: &str,
        after_id: &str,
    ) -> Result<Option<Vec<JournalEntry>>, SessionError> {
        let mut entries = Vec::new();
        let mut cursor = after_id.to_owned();
        for _ in 0..CATCH_UP_MAX_PAGES {
            let page = self
                .journal_page(
                    session_id,
                    &[
                        ("order", "asc".into()),
                        ("after", cursor.clone()),
                        ("limit", PAGE_SIZE.into()),
                    ],
                )
                .await?;
            entries.extend(page.data);
            match page.last_id.filter(|_| page.has_more) {
                Some(next) => cursor = next,
                None => return Ok(Some(entries)),
            }
        }
        Ok(None)
    }
}
