//! Read state in the engine (`omnigent_core::read_state`): every session summary feeds it, the
//! view marks the open session seen, and `UnreadChanged` reports the unread sessions.
//!
//! - **Opened:** `set_view` naming another session in a focused window marks it seen and clears
//!   an explicit unread.
//! - **Viewing:** focus returning, the app returning to the foreground, or new activity in the
//!   open session while the window is focused marks it seen (an explicit unread stays).
//! - The write goes to the server only when its rows report read state; a failed write is an
//!   `Error` event for the session (or the `mark_session_seen` result) and the device-local mark
//!   stays as the fallback.

use futures::channel::oneshot;
use omnigent_core::SessionError;
use omnigent_core::read_state::{ReadMark, SeenReason};
use omnigent_core::sessions::SessionSummary;

use crate::client::ClientCore;
use crate::engine::{Engine, Msg, View};
use crate::errors::CoreError;
use crate::events::{CoreEvent, ErrorScope};
use crate::runtime::post;

/// Where a mark's outcome goes: the `mark_session_seen` caller, or an `Error` event.
pub(crate) type ReadReply = Option<oneshot::Sender<Result<(), CoreError>>>;

/// A read-state input for the engine.
pub(crate) enum ReadMsg {
    /// Mark a session seen for a caller (`mark_session_seen`).
    MarkSeen {
        session_id: String,
        reply: oneshot::Sender<Result<(), CoreError>>,
    },
    /// A write finished.
    Written {
        mark: ReadMark,
        result: Result<(), SessionError>,
        reply: ReadReply,
    },
}

fn answer(reply: ReadReply, result: Result<(), CoreError>) {
    if let Some(reply) = reply {
        // A dropped receiver is a caller that stopped waiting; the mark is kept either way.
        if let Err(unheard) = reply.send(result) {
            drop(unheard);
        }
    }
}

impl Engine {
    pub(crate) fn read_message(&mut self, message: ReadMsg) {
        match message {
            ReadMsg::MarkSeen { session_id, reply } => {
                self.mark(&session_id, SeenReason::Opened, Some(reply));
            }
            ReadMsg::Written {
                mark,
                result,
                reply,
            } => self.read_written(&mark, result, reply),
        }
    }

    /// The view changed: mark the newly viewed session, then update notifications.
    pub(crate) fn set_view(&mut self, view: View) {
        let previous = std::mem::replace(&mut self.attention.view, view);
        self.read_view_changed(&previous);
        self.observe_attention();
    }

    /// New or changed summaries.
    pub(crate) fn read_observe(&mut self, sessions: &[SessionSummary]) {
        for session in sessions {
            self.read.observe(session);
        }
        self.mark_viewed(SeenReason::Viewing);
        self.publish_unread();
    }

    /// Sessions that were deleted or lost access.
    pub(crate) fn read_removed(&mut self, ids: &[String]) {
        self.read.remove(ids);
        self.publish_unread();
    }

    /// A new connection starts from the server's state.
    pub(crate) fn read_reset(&mut self) {
        self.read.clear();
        self.publish_unread();
    }

    /// The view changed from `previous`.
    fn read_view_changed(&mut self, previous: &View) {
        let view = &self.attention.view;
        let Some(id) = view.active_session_id.clone().filter(|_| view.focused) else {
            return;
        };
        if previous.active_session_id.as_deref() != Some(id.as_str()) {
            self.mark(&id, SeenReason::Opened, None);
        } else if !previous.focused {
            self.mark(&id, SeenReason::Viewing, None);
        }
    }

    /// Marks the open session seen when its window is focused.
    pub(crate) fn mark_viewed(&mut self, reason: SeenReason) {
        let view = &self.attention.view;
        if let Some(id) = view.active_session_id.clone().filter(|_| view.focused) {
            self.mark(&id, reason, None);
        }
    }

    /// Marks `session_id` seen and writes it to the server.
    pub(crate) fn mark(&mut self, session_id: &str, reason: SeenReason, reply: ReadReply) {
        let now = i64::try_from(self.host.unix_ms() / 1_000).unwrap_or(i64::MAX);
        let Some(mark) = self.read.mark_seen(session_id, now, reason) else {
            answer(reply, Ok(()));
            return;
        };
        self.publish_unread();
        if !self.read.server_tracks_reads() || !self.is_connected() {
            answer(reply, Ok(()));
            return;
        }
        let sessions = std::sync::Arc::clone(&self.sessions);
        let tx = self.sender();
        self.host.spawn(async move {
            let result = sessions.put_read_state(&mark).await;
            post(
                &tx,
                Msg::Read(ReadMsg::Written {
                    mark,
                    result,
                    reply,
                }),
            );
        });
    }

    /// A read-state write finished.
    pub(crate) fn read_written(
        &mut self,
        mark: &ReadMark,
        result: Result<(), SessionError>,
        reply: ReadReply,
    ) {
        match result {
            Ok(()) => {
                self.read.mark_written(mark);
                answer(reply, Ok(()));
            }
            Err(error) => {
                let error = CoreError::from(error);
                if reply.is_some() {
                    answer(reply, Err(error));
                } else {
                    self.error(
                        ErrorScope::Session {
                            session_id: mark.session_id.clone(),
                        },
                        error,
                    );
                }
            }
        }
    }

    /// Emits `UnreadChanged` and the badge when the unread sessions changed.
    pub(crate) fn publish_unread(&mut self) {
        let unread = self.read.unread_ids();
        if unread != self.unread {
            self.unread.clone_from(&unread);
            self.emit(CoreEvent::UnreadChanged {
                session_ids: unread.into_iter().collect(),
            });
            self.publish_badge();
        }
    }
}

#[uniffi::export]
impl ClientCore {
    /// Marks `session_id` seen now and clears an explicit unread, as opening it does. The view
    /// (`set_view`) already does this for the open session; call it for a session read
    /// elsewhere, for example from a notification. Succeeds without a request when nothing is
    /// unread or the server keeps no read state.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, `NotConnected`, `Unauthorized`, `Forbidden`,
    /// `Rejected` or `DeliveryUncertain` from `PUT /v1/sessions/{id}/read-state`. The mark is
    /// kept on this device either way.
    pub async fn mark_session_seen(&self, session_id: String) -> Result<(), CoreError> {
        let (reply, outcome) = oneshot::channel();
        self.post(Msg::Read(ReadMsg::MarkSeen { session_id, reply }));
        // The engine drops the reply only when it has shut down.
        outcome
            .await
            .map_err(|_| CoreError::from(SessionError::NotConnected))?
    }
}
