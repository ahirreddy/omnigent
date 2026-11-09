//! Remote browser REST calls and the attach upgrade on [`ClientCore`]'s connection.
//!
//! The requests come from [`BrowserEndpoint`]; the connection adds its bearer and Databricks
//! org header. As for terminals: nothing is sent while disconnected, a result that arrives
//! after the connection ended is [`RemoteBrowserError::NotConnected`], a `401` ends the
//! connection, and redirects are never followed.

use std::collections::BTreeSet;

use super::ClientCore;
use super::terminals::Credentialed;
use crate::http::{HttpRequest, HttpResponse, HttpTransport, TransportError};
use crate::remote_browser::AttachOptions;
use crate::remote_browser::rest::{
    BrowserEndpoint, BrowserProfile, BrowserTab, DeleteOutcome, MAX_PAGE, RemoteBrowserError,
    create_response, delete_response, list_response, profiles_response,
};

pub(super) const fn invalid_request(detail: String) -> RemoteBrowserError {
    RemoteBrowserError::InvalidRequest { detail }
}

impl<T: HttpTransport> ClientCore<T> {
    fn browser_request(
        &self,
        session_id: &str,
        build: impl FnOnce(&BrowserEndpoint) -> Result<HttpRequest, RemoteBrowserError>,
    ) -> Result<Credentialed, RemoteBrowserError> {
        self.credentialed_request(
            |root| build(&BrowserEndpoint::new(root, session_id)?),
            RemoteBrowserError::NotConnected,
            invalid_request,
        )
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn send_browser<R>(
        &self,
        (request, epoch, addressing): Credentialed,
        decode: impl FnOnce(Result<HttpResponse, TransportError>) -> Result<R, RemoteBrowserError>,
    ) -> Result<R, RemoteBrowserError> {
        let result = self.send_routed(request, addressing).await;
        if !self.is_current_epoch(epoch) {
            return Err(RemoteBrowserError::NotConnected);
        }
        let decoded = decode(result);
        if matches!(decoded, Err(RemoteBrowserError::Unauthorized { .. })) {
            self.disconnect();
        }
        decoded
    }

    /// Every remote browser tab of `session_id`, oldest first.
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError`]; [`RemoteBrowserError::MalformedResponse`] for a cursor that does
    /// not advance.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn list_remote_browsers(
        &self,
        session_id: &str,
    ) -> Result<Vec<BrowserTab>, RemoteBrowserError> {
        let mut tabs = Vec::new();
        let mut after: Option<String> = None;
        let mut cursors = BTreeSet::new();
        loop {
            let prepared = self.browser_request(session_id, |endpoint| {
                endpoint.list_request(MAX_PAGE, after.as_deref())
            })?;
            let page = self.send_browser(prepared, list_response).await?;
            tabs.extend(page.tabs);
            match page.last_id {
                Some(last) if page.has_more => {
                    if !cursors.insert(last.clone()) {
                        return Err(RemoteBrowserError::MalformedResponse {
                            detail: format!("the browser list cursor {last:?} repeated"),
                        });
                    }
                    after = Some(last);
                }
                _ => return Ok(tabs),
            }
        }
    }

    /// Opens a remote browser tab in `session_id`, at `url` (or a blank page), in `profile`
    /// (or `default`).
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError`]; [`RemoteBrowserError::BrowserUnavailable`] when the session's
    /// machine has no browser host.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn create_remote_browser(
        &self,
        session_id: &str,
        url: Option<&str>,
        profile: Option<&str>,
    ) -> Result<BrowserTab, RemoteBrowserError> {
        let prepared =
            self.browser_request(session_id, |endpoint| endpoint.create_request(url, profile))?;
        self.send_browser(prepared, create_response).await
    }

    /// Closes a remote browser tab.
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError`]. A tab that is already gone is [`DeleteOutcome::AlreadyGone`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn delete_remote_browser(
        &self,
        session_id: &str,
        tab_id: &str,
    ) -> Result<DeleteOutcome, RemoteBrowserError> {
        let prepared =
            self.browser_request(session_id, |endpoint| endpoint.delete_request(tab_id))?;
        self.send_browser(prepared, |result| delete_response(tab_id, result))
            .await
    }

    /// The browser profiles on `session_id`'s machine; only `default` on servers without the
    /// profiles route.
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn list_remote_browser_profiles(
        &self,
        session_id: &str,
    ) -> Result<Vec<BrowserProfile>, RemoteBrowserError> {
        let prepared =
            self.browser_request(session_id, |endpoint| Ok(endpoint.profiles_request()))?;
        self.send_browser(prepared, profiles_response).await
    }

    /// The attach WebSocket upgrade for `tab_id`, with the connection's current bearer and org
    /// header (a rotated bearer is used from the next attempt on).
    ///
    /// # Errors
    ///
    /// [`RemoteBrowserError::NotConnected`], [`RemoteBrowserError::InvalidIdentifier`].
    pub fn remote_browser_attach_request(
        &self,
        session_id: &str,
        tab_id: &str,
        options: &AttachOptions,
    ) -> Result<HttpRequest, RemoteBrowserError> {
        self.browser_request(session_id, |endpoint| {
            endpoint.attach_request(tab_id, options)
        })
        .map(|(request, _, _)| request)
    }
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;
    use omnigent_protocol::remote_browser::AttachMode;

    use super::*;
    use crate::client::test_support::{
        MOUNT, Reply, RouteTransport, connected_hosted, header, still_pending,
    };

    const BROWSERS: &str = "/api/2.0/omnigent/v1/sessions/conv_a/resources/browsers";

    fn tab(id: &str) -> String {
        format!(r#"{{"id":"{id}","type":"browser","metadata":{{"url":"about:blank"}}}}"#)
    }

    #[test]
    fn tabs_list_every_page_then_close_and_read_profiles() {
        let transport = RouteTransport::with_prefix(MOUNT, false);
        transport.enqueue(
            "GET",
            BROWSERS,
            vec![
                Reply::json(
                    200,
                    format!(
                        r#"{{"data":[{}],"has_more":true,"last_id":"btab_1"}}"#,
                        tab("btab_1")
                    ),
                ),
                Reply::json(
                    200,
                    format!(r#"{{"data":[{}],"has_more":false}}"#, tab("btab_2")),
                ),
            ],
        );
        let closed = format!("{BROWSERS}/btab_1");
        transport.enqueue(
            "DELETE",
            &closed,
            vec![
                Reply::json(200, r#"{"id":"btab_1","deleted":true}"#),
                Reply::json(404, r#"{"detail":"gone"}"#),
            ],
        );
        let core = connected_hosted(transport);
        let ids: Vec<String> = block_on(core.list_remote_browsers("conv_a"))
            .unwrap()
            .into_iter()
            .map(|tab| tab.id)
            .collect();
        assert_eq!(ids, ["btab_1", "btab_2"]);
        assert_eq!(
            block_on(core.delete_remote_browser("conv_a", "btab_1")),
            Ok(DeleteOutcome::Deleted)
        );
        assert_eq!(
            block_on(core.delete_remote_browser("conv_a", "btab_1")),
            Ok(DeleteOutcome::AlreadyGone)
        );
        let profiles = block_on(core.list_remote_browser_profiles("conv_a")).unwrap();
        assert_eq!(profiles.len(), 1, "an older server only has the default");
        assert_eq!(profiles[0].name, "default");
    }

    #[test]
    fn a_rejected_token_ends_the_connection_and_a_late_reply_is_dropped() {
        let transport = RouteTransport::with_prefix(MOUNT, false);
        transport.enqueue(
            "GET",
            BROWSERS,
            vec![Reply::json(401, r#"{"detail":"expired"}"#)],
        );
        let core = connected_hosted(transport);
        assert!(matches!(
            block_on(core.list_remote_browsers("conv_a")),
            Err(RemoteBrowserError::Unauthorized { .. })
        ));
        assert_eq!(
            block_on(core.list_remote_browsers("conv_a")),
            Err(RemoteBrowserError::NotConnected)
        );

        let transport = RouteTransport::with_prefix(MOUNT, false);
        transport.ok(BROWSERS, r#"{"data":[],"has_more":false}"#);
        let gate = transport.gate("GET", BROWSERS);
        let core = connected_hosted(transport);
        let mut listing = std::pin::pin!(core.list_remote_browsers("conv_a"));
        assert!(still_pending(listing.as_mut()));
        core.disconnect();
        gate.open();
        assert_eq!(block_on(listing), Err(RemoteBrowserError::NotConnected));
    }

    #[test]
    fn a_browser_list_cursor_that_comes_back_ends_the_listing() {
        let path = format!("{MOUNT}/v1/sessions/conv_a/resources/browsers");
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
                block_on(core.list_remote_browsers("conv_a")),
                Err(RemoteBrowserError::MalformedResponse { detail }) if detail.contains("repeated")
            ),
            "a cycle of cursors must not page forever"
        );
    }

    #[test]
    fn browser_calls_carry_the_connection_credentials() {
        let transport = RouteTransport::with_prefix(MOUNT, false);
        transport.ok(
            &format!("{MOUNT}/v1/sessions/conv_a/resources/browsers"),
            r#"{"object":"list","data":[{"object":"session.resource","id":"btab_1","type":"browser","metadata":{"url":"about:blank","owner":"agent","profile":"default"}}],"has_more":false}"#,
        );
        let core = connected_hosted(transport);
        let tabs = block_on(core.list_remote_browsers("conv_a")).unwrap();
        assert_eq!(tabs[0].id, "btab_1");
        let requests = core.transport().taken();
        assert!(header(requests.last().unwrap(), "Authorization").is_some());
        let attach = core
            .remote_browser_attach_request(
                "conv_a",
                "btab_1",
                &AttachOptions {
                    mode: AttachMode::View,
                    slice_key: None,
                },
            )
            .unwrap();
        assert!(attach.url.starts_with("wss://"), "{}", attach.url);
        assert!(
            attach
                .url
                .ends_with("/browsers/btab_1/attach?mode=view&v=1")
        );
        assert!(header(&attach, "Authorization").is_some());
        core.disconnect();
        assert_eq!(
            block_on(core.list_remote_browsers("conv_a")),
            Err(RemoteBrowserError::NotConnected)
        );
    }
}
