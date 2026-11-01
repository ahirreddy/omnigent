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
use crate::reconcile::{ConversationSync, HydrationRequest, SyncUpdate};
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
            if state.live_session.as_deref() == Some(request.session_id.as_str()) {
                state.live_session = None;
            }
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
        let update = sync.finish_hydration(request, &page.snapshot, &page.items)?;
        lock(&self.state).live_session = Some(request.session_id.clone());
        Ok(update)
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
    use crate::client::test_support::{RouteTransport, connected};
    use crate::http::TransportError;

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
        assert_eq!(core.live_session(), None);
        block_on(core.hydrate(&mut sync, &request)).unwrap();
        assert_eq!(core.live_session().as_deref(), Some("conv_a"));
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

    #[test]
    fn failed_hydration_reports_to_the_sync_and_keeps_sends_blocked() {
        let transport = transport();
        transport.respond(
            None,
            "/v1/sessions/conv_a/items",
            None,
            crate::client::test_support::Reply::Fail(TransportError::Offline {
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
        assert_eq!(core.live_session(), None);
        // The failed read is no longer current; a stale finish changes nothing.
        assert!(!sync.hydration_failed(&request));
    }
}
