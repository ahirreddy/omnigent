//! Older history for an open session: the page above its rows, read through the REST client
//! and prepended by its `ConversationSync`.

use std::sync::Arc;

use omnigent_core::SessionError;
use omnigent_core::items::HistoryPage;
use omnigent_core::reconcile::OlderHistoryRequest;
use omnigent_core::sessions::DEFAULT_PAGE_LIMIT;

use crate::engine::{Engine, Msg};
use crate::errors::CoreError;
use crate::events::{CoreEvent, ErrorScope};
use crate::runtime::post;

/// Older-history messages for the engine.
pub(crate) enum HistoryMsg {
    /// Load the page above an open session's rows.
    Load(String),
    /// A read finished.
    Loaded {
        session_id: String,
        request: OlderHistoryRequest,
        result: Box<Result<HistoryPage, SessionError>>,
    },
}

impl Engine {
    pub(crate) fn history_message(&mut self, message: HistoryMsg) {
        match message {
            HistoryMsg::Load(session_id) => self.load_older(&session_id),
            HistoryMsg::Loaded {
                session_id,
                request,
                result,
            } => self.older_loaded(&session_id, &request, *result),
        }
    }

    /// Starts reading the page above `session_id`'s rows, unless there is none or one is loading.
    fn load_older(&mut self, session_id: &str) {
        let Some(request) = self
            .drivers
            .get(session_id)
            .and_then(|driver| driver.sync.begin_older_history_raw())
        else {
            return;
        };
        self.emit_paging(session_id);
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        let id = session_id.to_owned();
        self.host.spawn(async move {
            let result = sessions
                .history_page(&id, Some(&request.cursor), DEFAULT_PAGE_LIMIT)
                .await;
            post(
                &tx,
                Msg::History(HistoryMsg::Loaded {
                    session_id: id,
                    request,
                    result: Box::new(result),
                }),
            );
        });
    }

    fn older_loaded(
        &mut self,
        session_id: &str,
        request: &OlderHistoryRequest,
        result: Result<HistoryPage, SessionError>,
    ) {
        let Some(sync) = self
            .drivers
            .get(session_id)
            .map(|driver| Arc::clone(&driver.sync))
        else {
            return;
        };
        let applied = result.map_err(CoreError::from).and_then(|page| {
            sync.finish_older_history_raw(request, &page.items, page.next_cursor.as_deref())
        });
        match applied {
            Ok(applied) => self.publish(session_id, applied),
            Err(error) => {
                if sync.older_history_failed_raw(request) {
                    self.error(
                        ErrorScope::Session {
                            session_id: session_id.to_owned(),
                        },
                        error,
                    );
                }
            }
        }
        self.emit_paging(session_id);
    }

    /// Reports `session_id`'s history paging state when it changed since last reported.
    pub(crate) fn emit_paging(&mut self, session_id: &str) {
        let Some(driver) = self.drivers.get_mut(session_id) else {
            return;
        };
        let paging = driver.sync.history_paging_raw();
        if driver.paging == Some(paging) {
            return;
        }
        driver.paging = Some(paging);
        self.emit(CoreEvent::HistoryPagingChanged {
            session_id: session_id.to_owned(),
            has_older: paging.has_older,
            is_loading: paging.is_loading,
        });
    }
}
