//! Terminal REST calls and the attach upgrade on [`ClientCore`]'s connection.
//!
//! The requests come from [`TerminalEndpoint`]; the connection adds its bearer and Databricks
//! org header. The session client's rules hold: nothing is sent while disconnected, a result
//! that arrives after the connection ended is [`TerminalError::NotConnected`], a `401` ends the
//! connection, and redirects are never followed.

use std::collections::BTreeSet;

use url::Url;

use super::{ClientCore, lock};
use crate::auth::endpoint::DATABRICKS_ORG_HEADER;
use crate::http::{HttpRequest, HttpResponse, HttpTransport, TransportError};
use crate::terminal::{
    AttachOptions, CreateTerminal, DeleteOutcome, ListTerminals, TerminalEndpoint, TerminalError,
    TerminalResource, delete_response, list_response, resource_response,
};

/// Credential headers a terminal request carries.
const CREDENTIAL_HEADERS: [&str; 2] = ["Authorization", DATABRICKS_ORG_HEADER];

/// A request built with the connection's credentials, the epoch it belongs to, and how it was
/// addressed on a host-sharded server.
pub(super) type Credentialed = (HttpRequest, u64, Option<super::routing::Addressing>);

impl<T: HttpTransport> ClientCore<T> {
    /// Builds a request against the connected server's root URL with the connection's
    /// credential headers, and the connection epoch it belongs to. Shared by the terminal and
    /// remote browser calls.
    pub(super) fn credentialed_request<E>(
        &self,
        build: impl FnOnce(Url) -> Result<HttpRequest, E>,
        not_connected: E,
        invalid: impl Fn(String) -> E,
    ) -> Result<Credentialed, E> {
        let state = lock(&self.state);
        let Some(connection) = state
            .connection
            .as_ref()
            .filter(|connection| connection.is_connected())
        else {
            return Err(not_connected);
        };
        let server = connection.endpoint();
        let root = Url::parse(&format!("{}{}", server.origin(), server.mount()))
            .map_err(|error| invalid(format!("the server URL cannot be parsed: {error}")))?;
        let mut request = build(root)?;
        let credentials = connection
            .request("GET", "/v1/info", &[], "application/json")
            .map_err(|error| invalid(error.to_string()))?;
        request.headers.extend(
            credentials
                .headers
                .into_iter()
                .filter(|header| CREDENTIAL_HEADERS.contains(&header.name.as_str())),
        );
        let addressing = super::requests::address_built_request(&state, &mut request);
        Ok((request, state.epoch, addressing))
    }

    /// Whether a result that arrived for `epoch` still belongs to the live connection.
    pub(super) fn is_current_epoch(&self, epoch: u64) -> bool {
        let state = lock(&self.state);
        state.epoch == epoch && state.is_connected()
    }

    /// Builds a terminal request for `session_id` with the connection's credentials, and the
    /// connection epoch it belongs to.
    fn terminal_request(
        &self,
        session_id: &str,
        build: impl FnOnce(&TerminalEndpoint) -> Result<HttpRequest, TerminalError>,
    ) -> Result<Credentialed, TerminalError> {
        self.credentialed_request(
            |root| build(&TerminalEndpoint::new(root, session_id)?),
            TerminalError::NotConnected,
            |detail| TerminalError::InvalidRequest { detail },
        )
    }

    /// Sends a prepared terminal request; a result from an ended connection is discarded.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn send_terminal<R>(
        &self,
        (request, epoch, addressing): Credentialed,
        decode: impl FnOnce(Result<HttpResponse, TransportError>) -> Result<R, TerminalError>,
    ) -> Result<R, TerminalError> {
        let result = self.send_routed(request, addressing).await;
        if !self.is_current_epoch(epoch) {
            return Err(TerminalError::NotConnected);
        }
        let decoded = decode(result);
        if matches!(decoded, Err(TerminalError::Unauthorized { .. })) {
            self.disconnect();
        }
        decoded
    }

    /// Every terminal of `session_id`, oldest first (the agent's own terminal leads).
    ///
    /// # Errors
    ///
    /// [`TerminalError`]; [`TerminalError::MalformedResponse`] for a cursor that does not advance.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn list_terminals(
        &self,
        session_id: &str,
    ) -> Result<Vec<TerminalResource>, TerminalError> {
        let mut terminals = Vec::new();
        let mut query = ListTerminals::default();
        let mut cursors = BTreeSet::new();
        loop {
            let prepared =
                self.terminal_request(session_id, |endpoint| endpoint.list_request(&query))?;
            let page = self.send_terminal(prepared, list_response).await?;
            terminals.extend(page.terminals);
            match page.last_id {
                Some(last) if page.has_more => {
                    if !cursors.insert(last.clone()) {
                        return Err(TerminalError::MalformedResponse {
                            detail: format!("the terminal list cursor {last:?} repeated"),
                        });
                    }
                    query.after = Some(last);
                }
                _ => return Ok(terminals),
            }
        }
    }

    /// Launches (or, for a known session key, returns) a terminal of `session_id`.
    ///
    /// # Errors
    ///
    /// [`TerminalError`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_terminal(
        &self,
        session_id: &str,
        create: &CreateTerminal,
    ) -> Result<TerminalResource, TerminalError> {
        let prepared =
            self.terminal_request(session_id, |endpoint| endpoint.create_request(create))?;
        self.send_terminal(prepared, resource_response).await
    }

    /// Closes a terminal of `session_id`.
    ///
    /// # Errors
    ///
    /// [`TerminalError`]. A terminal that is already gone is [`DeleteOutcome::AlreadyGone`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_terminal(
        &self,
        session_id: &str,
        terminal_id: &str,
    ) -> Result<DeleteOutcome, TerminalError> {
        let prepared =
            self.terminal_request(session_id, |endpoint| endpoint.delete_request(terminal_id))?;
        self.send_terminal(prepared, |result| delete_response(terminal_id, result))
            .await
    }

    /// The attach WebSocket upgrade for `terminal_id`, with the connection's current bearer and
    /// org header (a rotated bearer is used from the next attempt on).
    ///
    /// # Errors
    ///
    /// [`TerminalError::NotConnected`], [`TerminalError::InvalidIdentifier`].
    pub fn terminal_attach_request(
        &self,
        session_id: &str,
        terminal_id: &str,
        options: &AttachOptions,
    ) -> Result<HttpRequest, TerminalError> {
        self.terminal_request(session_id, |endpoint| {
            endpoint.attach_request(terminal_id, options)
        })
        .map(|(request, _, _)| request)
    }
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::*;
    use crate::client::test_support::{
        MOUNT, Reply, RouteTransport, connected_hosted, header, still_pending,
    };
    use crate::terminal::attach_options;

    const TERMINALS: &str = "/api/2.0/omnigent/v1/sessions/conv_a/resources/terminals";

    #[test]
    fn terminals_list_every_page_then_create_and_close() {
        let transport = RouteTransport::with_prefix(MOUNT, false);
        transport.enqueue(
            "GET",
            TERMINALS,
            vec![
                Reply::json(
                    200,
                    r#"{"data":[{"id":"terminal_a"}],"has_more":true,"last_id":"terminal_a"}"#,
                ),
                Reply::json(200, r#"{"data":[{"id":"terminal_b"}],"has_more":false}"#),
            ],
        );
        transport.respond(
            Some("POST"),
            TERMINALS,
            None,
            Reply::json(201, r#"{"id":"terminal_new","type":"terminal"}"#),
        );
        let closed = format!("{TERMINALS}/terminal_new");
        transport.enqueue(
            "DELETE",
            &closed,
            vec![
                Reply::json(200, r#"{"id":"terminal_new","deleted":true}"#),
                Reply::json(404, r#"{"detail":"gone"}"#),
            ],
        );
        let core = connected_hosted(transport);
        let ids: Vec<String> = block_on(core.list_terminals("conv_a"))
            .unwrap()
            .into_iter()
            .map(|terminal| terminal.id)
            .collect();
        assert_eq!(ids, ["terminal_a", "terminal_b"]);
        let create = CreateTerminal {
            terminal: "bash".into(),
            session_key: "u-1".into(),
        };
        let created = block_on(core.create_terminal("conv_a", &create)).unwrap();
        assert_eq!(created.id, "terminal_new");
        assert_eq!(
            block_on(core.delete_terminal("conv_a", "terminal_new")),
            Ok(DeleteOutcome::Deleted)
        );
        assert_eq!(
            block_on(core.delete_terminal("conv_a", "terminal_new")),
            Ok(DeleteOutcome::AlreadyGone)
        );
    }

    #[test]
    fn a_rejected_token_ends_the_connection_and_a_late_reply_is_dropped() {
        let transport = RouteTransport::with_prefix(MOUNT, false);
        transport.enqueue(
            "GET",
            TERMINALS,
            vec![Reply::json(401, r#"{"detail":"expired"}"#)],
        );
        let core = connected_hosted(transport);
        assert!(matches!(
            block_on(core.list_terminals("conv_a")),
            Err(TerminalError::Unauthorized { .. })
        ));
        assert_eq!(
            block_on(core.list_terminals("conv_a")),
            Err(TerminalError::NotConnected)
        );

        let transport = RouteTransport::with_prefix(MOUNT, false);
        transport.ok(TERMINALS, r#"{"data":[],"has_more":false}"#);
        let gate = transport.gate("GET", TERMINALS);
        let core = connected_hosted(transport);
        let mut listing = std::pin::pin!(core.list_terminals("conv_a"));
        assert!(still_pending(listing.as_mut()));
        core.disconnect();
        gate.open();
        assert_eq!(block_on(listing), Err(TerminalError::NotConnected));
    }

    #[test]
    fn an_unusable_session_id_is_refused_before_sending() {
        let core = connected_hosted(RouteTransport::with_prefix(MOUNT, false));
        assert!(block_on(core.list_terminals("../x")).is_err());
        assert_eq!(core.transport().writes().len(), 0);
    }

    #[test]
    fn a_terminal_list_cursor_that_comes_back_ends_the_listing() {
        let path = format!("{MOUNT}/v1/sessions/conv_a/resources/terminals");
        let page = |last: &str| {
            Reply::json(
                200,
                format!(r#"{{"object":"list","data":[],"has_more":true,"last_id":"{last}"}}"#),
            )
        };
        let transport = RouteTransport::with_prefix(MOUNT, false);
        transport.enqueue("GET", &path, vec![page("a"), page("b"), page("a")]);
        let core = connected_hosted(transport);
        assert!(
            matches!(
                block_on(core.list_terminals("conv_a")),
                Err(TerminalError::MalformedResponse { detail }) if detail.contains("repeated")
            ),
            "a cycle of cursors must not page forever"
        );
    }

    #[test]
    fn terminal_calls_carry_the_connection_credentials_and_a_401_disconnects() {
        let transport = RouteTransport::with_prefix(MOUNT, false);
        transport.ok(
            &format!("{MOUNT}/v1/sessions/conv_a/resources/terminals"),
            r#"{"object":"list","data":[{"id":"terminal_codex_main","type":"terminal","metadata":{"running":true}}],"has_more":false}"#,
        );
        let core = connected_hosted(transport);
        let terminals = block_on(core.list_terminals("conv_a")).unwrap();
        assert_eq!(terminals[0].id, "terminal_codex_main");
        let requests = core.transport().taken();
        let list = requests.last().unwrap();
        assert!(header(list, "Authorization").is_some());
        let attach = core
            .terminal_attach_request(
                "conv_a",
                "terminal_codex_main",
                &attach_options(Some(2), Some("host_1")),
            )
            .unwrap();
        assert!(attach.url.starts_with("wss://"), "{}", attach.url);
        assert!(attach.url.contains("read_only=true"));
        assert!(attach.url.contains("omnigent_slice_key=host_1"));
        assert!(header(&attach, "Authorization").is_some());
        assert_eq!(
            core.terminal_attach_request("conv_a", "../x", &AttachOptions::default()),
            Err(TerminalError::InvalidIdentifier {
                value: "../x".into()
            })
        );
        core.disconnect();
        assert_eq!(
            block_on(core.list_terminals("conv_a")),
            Err(TerminalError::NotConnected)
        );
    }
}
