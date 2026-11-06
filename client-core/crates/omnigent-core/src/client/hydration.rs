//! The REST half of the hydration handoff: the history read a
//! [`ConversationSync`](crate::reconcile::ConversationSync) asks for, and changed-file results
//! folded into it.
//!
//! The stream driver opens the stream, takes the [`HydrationRequest`] from
//! [`ConversationSync::open_stream`] (or a later [`SyncUpdate::hydrate`]), and calls
//! [`ClientCore::hydrate`]. On success the session becomes the core's live session, so sends and
//! configuration changes are allowed; on failure the sync is told
//! ([`ConversationSync::hydration_failed`]) and the driver reconnects.

use super::events::ChangedFilesUpdate;
use super::sessions::DEFAULT_PAGE_LIMIT;
use super::{ClientCore, SessionError, lock};
use crate::http::HttpTransport;
use crate::reconcile::{ConversationSync, HydrationRequest, OlderHistoryRequest, SyncUpdate};
use crate::reducer::{ChangedFile, ChangedFiles};

impl From<ChangedFilesUpdate> for ChangedFiles {
    fn from(update: ChangedFilesUpdate) -> Self {
        match update {
            ChangedFilesUpdate::Loaded(files) => Self::Loaded {
                entries: files
                    .into_iter()
                    .map(|file| ChangedFile {
                        path: file.path,
                        status: file.status,
                    })
                    .collect(),
            },
            ChangedFilesUpdate::Unavailable(message) => Self::Failed { message },
        }
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// Reads `request`'s session (`include_items=false`) and newest history page, and folds them
    /// into `sync`. The session then becomes the live session.
    ///
    /// # Errors
    ///
    /// The read errors, or [`SessionError::Sync`] when the history cannot be applied.
    /// Either way `sync` has been told the read failed, and the session is not live.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn hydrate(
        &self,
        sync: &mut ConversationSync,
        request: &HydrationRequest,
    ) -> Result<SyncUpdate, SessionError> {
        let result = self.read_history(sync, request).await;
        if result.is_err() {
            sync.hydration_failed(request);
            let mut state = lock(&self.state);
            state.live_sessions.remove(&request.session_id);
        }
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn read_history(
        &self,
        sync: &mut ConversationSync,
        request: &HydrationRequest,
    ) -> Result<SyncUpdate, SessionError> {
        let page = self
            .conversation(&request.session_id, DEFAULT_PAGE_LIMIT)
            .await?;
        let update = sync.finish_hydration_page(
            request,
            &page.snapshot,
            &page.items,
            page.next_cursor.as_deref(),
        )?;
        lock(&self.state)
            .live_sessions
            .insert(request.session_id.clone());
        Ok(update)
    }

    /// Reads the page of history above what `sync` holds and prepends it.
    ///
    /// # Errors
    ///
    /// The read errors, or [`SessionError::Sync`] when the page cannot be shown. Either way
    /// `sync` stops loading and the reader can try again.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn load_older_history(
        &self,
        sync: &mut ConversationSync,
        request: &OlderHistoryRequest,
    ) -> Result<SyncUpdate, SessionError> {
        let result = match self
            .history_page(
                &request.session_id,
                Some(&request.cursor),
                DEFAULT_PAGE_LIMIT,
            )
            .await
        {
            Ok(page) => sync
                .finish_older_history(request, &page.items, page.next_cursor.as_deref())
                .map_err(SessionError::from),
            Err(error) => Err(error),
        };
        if result.is_err() {
            sync.older_history_failed(request);
        }
        result
    }

    /// [`ClientCore::invalidate_changed_files`] for the watched session, folded into `sync`.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn refresh_changed_files(
        &self,
        sync: &mut ConversationSync,
        environment_id: &str,
    ) -> Option<SyncUpdate> {
        let session_id = sync.session_id().to_owned();
        let before = lock(&self.state).events.len();
        self.load_changed_files(&session_id, environment_id).await;
        let update = {
            let state = lock(&self.state);
            state.events.get(before..).and_then(|events| {
                events.iter().rev().find_map(|event| match event {
                    super::ClientEvent::ChangedFiles {
                        session_id: id,
                        environment_id: environment,
                        update,
                    } if *id == session_id && environment == environment_id => Some(update.clone()),
                    _ => None,
                })
            })
        };
        self.dispatch();
        update.map(|update| sync.set_changed_files(environment_id, update.into()))
    }
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::*;
    use crate::client::test_support::{Reply, RouteTransport, connected};
    use crate::http::TransportError;
    use crate::reconcile::HistoryPaging;
    use omnigent_protocol::{ConversationItem, FromWire};

    fn transport() -> RouteTransport {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions/conv_a",
            r#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#,
        );
        transport.ok(
            "/v1/sessions/conv_a/items",
            r#"{"data":[{"id":"msg_1","type":"message","role":"assistant","content":"Ready"}],"has_more":false}"#,
        );
        transport.ok(
            "/v1/sessions/conv_a/resources/environments/default/changes",
            r#"{"entries":[{"path":"Sources/App.swift","status":"modified"}]}"#,
        );
        transport
    }

    #[test]
    fn hydration_makes_the_session_live_and_feeds_changed_files_to_the_reducer() {
        let core = connected(transport());
        let mut sync = ConversationSync::new("conv_a");
        let request = sync.open_stream();
        assert!(!core.is_live_session("conv_a"));
        block_on(core.hydrate(&mut sync, &request)).unwrap();
        assert!(core.is_live_session("conv_a"));
        assert!(sync.reducer().is_some());
        let update = block_on(core.refresh_changed_files(&mut sync, "default")).unwrap();
        assert!(update.revision > 0);
        let files = sync
            .published()
            .and_then(|snapshot| snapshot.event_state.changed_files.clone())
            .unwrap();
        assert_eq!(
            files.get("default"),
            Some(&ChangedFiles::Loaded {
                entries: vec![ChangedFile {
                    path: "Sources/App.swift".into(),
                    status: "modified".into(),
                }]
            })
        );
        assert_eq!(core.transport().writes(), []);
    }

    fn message(id: &str) -> String {
        format!(r#"{{"id":"{id}","type":"message","role":"assistant","content":"{id}"}}"#)
    }

    /// A newest-first `/items` page.
    fn page(ids: &[&str], has_more: bool) -> String {
        let data: Vec<String> = ids.iter().map(|id| message(id)).collect();
        let last = ids
            .last()
            .map_or(String::new(), |id| format!(r#","last_id":"{id}""#));
        format!(
            r#"{{"data":[{}],"has_more":{has_more}{last}}}"#,
            data.join(",")
        )
    }

    fn row_ids(sync: &ConversationSync) -> Vec<String> {
        sync.published()
            .map(|snapshot| snapshot.rows.iter().map(|row| row.id.clone()).collect())
            .unwrap_or_default()
    }

    fn paged_transport() -> RouteTransport {
        let transport = transport();
        transport.ok("/v1/sessions/conv_a/items", page(&["msg_3", "msg_2"], true));
        transport.respond(
            None,
            "/v1/sessions/conv_a/items",
            Some("msg_2"),
            Reply::json(200, page(&["msg_1"], false)),
        );
        transport
    }

    #[test]
    fn older_history_prepends_and_survives_rehydration_and_reconnect() {
        let core = connected(paged_transport());
        let mut sync = ConversationSync::new("conv_a");
        let request = sync.open_stream();
        block_on(core.hydrate(&mut sync, &request)).unwrap();
        assert_eq!(row_ids(&sync), ["msg_2", "msg_3"]);
        assert!(sync.history_paging().has_older);

        let older = sync.begin_older_history().unwrap();
        assert_eq!(older.cursor, "msg_2");
        assert!(sync.history_paging().is_loading);
        assert_eq!(sync.begin_older_history(), None);
        let update = block_on(core.load_older_history(&mut sync, &older)).unwrap();
        assert_eq!(update.changes.rows.len(), 1);
        assert_eq!(row_ids(&sync), ["msg_1", "msg_2", "msg_3"]);
        assert_eq!(sync.history_paging(), HistoryPaging::default());

        let again = sync.request_hydration().unwrap();
        block_on(core.hydrate(&mut sync, &again)).unwrap();
        assert_eq!(row_ids(&sync), ["msg_1", "msg_2", "msg_3"]);
        let reconnect = sync.open_stream();
        block_on(core.hydrate(&mut sync, &reconnect)).unwrap();
        assert_eq!(row_ids(&sync), ["msg_1", "msg_2", "msg_3"]);
        assert!(!sync.history_paging().has_older);
    }

    /// A newest-first `/items` page of messages created at the given times.
    fn dated_page(items: &[(&str, i64)], has_more: bool) -> String {
        let data: Vec<String> = items
            .iter()
            .map(|(id, created)| {
                format!(
                    r#"{{"id":"{id}","type":"message","role":"assistant","content":"{id}","created_at":{created}}}"#
                )
            })
            .collect();
        let last = items.last().map_or("", |(id, _)| id);
        format!(
            r#"{{"data":[{}],"has_more":{has_more},"last_id":"{last}"}}"#,
            data.join(",")
        )
    }

    #[test]
    fn a_side_chat_shows_only_its_own_turns() {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions/conv_a",
            r#"{"id":"conv_a","status":"idle","created_at":10,"permission_level":4,
                "harness":"claude-native","labels":{"omnigent.side_chat":"1"}}"#,
        );
        // The newest page holds only the side chat's turns; the next reaches the parent's.
        transport.ok(
            "/v1/sessions/conv_a/items",
            dated_page(&[("msg_4", 13), ("msg_3", 12)], true),
        );
        transport.respond(
            None,
            "/v1/sessions/conv_a/items",
            Some("msg_3"),
            Reply::json(200, dated_page(&[("msg_2", 11), ("msg_1", 5)], true)),
        );
        let core = connected(transport);
        let mut sync = ConversationSync::new("conv_a");
        let request = sync.open_stream();
        block_on(core.hydrate(&mut sync, &request)).unwrap();
        assert_eq!(row_ids(&sync), ["msg_3", "msg_4"]);
        let older = sync.begin_older_history().unwrap();
        block_on(core.load_older_history(&mut sync, &older)).unwrap();
        assert_eq!(row_ids(&sync), ["msg_2", "msg_3", "msg_4"]);
        assert!(!sync.history_paging().has_older);

        core.transport().ok(
            "/v1/sessions/conv_a/items",
            dated_page(&[("msg_2", 11), ("msg_1", 5)], true),
        );
        let reconnect = sync.open_stream();
        block_on(core.hydrate(&mut sync, &reconnect)).unwrap();
        assert_eq!(row_ids(&sync), ["msg_2"]);
        assert!(!sync.history_paging().has_older);
    }

    #[test]
    fn a_newest_page_that_no_longer_reaches_older_history_restarts_paging() {
        let core = connected(paged_transport());
        let mut sync = ConversationSync::new("conv_a");
        let request = sync.open_stream();
        block_on(core.hydrate(&mut sync, &request)).unwrap();
        let older = sync.begin_older_history().unwrap();
        block_on(core.load_older_history(&mut sync, &older)).unwrap();

        core.transport()
            .ok("/v1/sessions/conv_a/items", page(&["msg_9", "msg_8"], true));
        let again = sync.request_hydration().unwrap();
        block_on(core.hydrate(&mut sync, &again)).unwrap();
        assert_eq!(row_ids(&sync), ["msg_8", "msg_9"]);
        assert_eq!(sync.begin_older_history().unwrap().cursor, "msg_8");
    }

    #[test]
    fn a_failed_or_superseded_older_read_changes_nothing() {
        let transport = paged_transport();
        transport.respond(
            None,
            "/v1/sessions/conv_a/items",
            Some("msg_2"),
            Reply::Fail(TransportError::Offline {
                message: "lost".into(),
            }),
        );
        let core = connected(transport);
        let mut sync = ConversationSync::new("conv_a");
        let request = sync.open_stream();
        block_on(core.hydrate(&mut sync, &request)).unwrap();
        let older = sync.begin_older_history().unwrap();
        assert!(block_on(core.load_older_history(&mut sync, &older)).is_err());
        assert_eq!(
            sync.history_paging(),
            HistoryPaging {
                has_older: true,
                is_loading: false
            }
        );

        // Paging restarted by a rehydration makes the read in flight stale.
        let stale = sync.begin_older_history().unwrap();
        core.transport()
            .ok("/v1/sessions/conv_a/items", page(&["msg_9", "msg_8"], true));
        let again = sync.request_hydration().unwrap();
        block_on(core.hydrate(&mut sync, &again)).unwrap();
        let items = [ConversationItem::from_json(message("msg_1").as_bytes()).unwrap()];
        let update = sync.finish_older_history(&stale, &items, None).unwrap();
        assert!(update.changes.is_empty());
        assert_eq!(row_ids(&sync), ["msg_8", "msg_9"]);
        assert!(!sync.older_history_failed(&stale));
    }

    #[test]
    fn failed_hydration_reports_to_the_sync_and_keeps_sends_blocked() {
        let transport = transport();
        transport.respond(
            None,
            "/v1/sessions/conv_a/items",
            None,
            Reply::Fail(TransportError::Offline {
                message: "lost".into(),
            }),
        );
        let core = connected(transport);
        let mut sync = ConversationSync::new("conv_a");
        let request = sync.open_stream();
        assert!(matches!(
            block_on(core.hydrate(&mut sync, &request)),
            Err(SessionError::Transport(_))
        ));
        assert!(!core.is_live_session("conv_a"));
        // The failed read is no longer current; a stale finish changes nothing.
        assert!(!sync.hydration_failed(&request));
    }
}
