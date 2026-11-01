//! Databricks workspace mount discovery by probe.
//!
//! Port of `WorkspaceURLExpander.expandIfNeeded` and `SameOriginRedirectHandler`. A bare https
//! root whose `HEAD /` answers `server: databricks` is a workspace, so the Omnigent UI lives
//! under [`server_url::WORKSPACE_UI_PATH`]. The host transport never follows redirects, so the
//! core follows only same-origin ones itself: a cross-origin 3xx is the final answer and the
//! probe never talks to a host the user did not approve.

use url::Url;

use super::mode::ServerAuthentication;
use crate::http::{HttpRequest, HttpResponse, HttpTransport, TransportError};
use crate::server_url;

/// Same-origin redirects followed before giving up.
pub const MAX_PROBE_REDIRECTS: usize = 5;

/// The workspace UI URL for `url`, or `url` unchanged.
///
/// No probe is sent for non-https URLs, URLs that already carry a path, or Databricks Apps hosts
/// (which share the workspace server header but serve their UI at the root).
///
/// # Errors
///
/// The host transport's error: an unreachable server is reported, not mistaken for "not a
/// workspace".
#[allow(
    clippy::future_not_send,
    reason = "Send-ness follows the host transport; WASM transports are !Send by design"
)]
pub async fn expand_if_needed<T: HttpTransport>(
    transport: &T,
    url: &Url,
) -> Result<Url, TransportError> {
    if url.scheme() != "https"
        || !server_url::is_bare_root(url)
        || ServerAuthentication::for_url(url) == ServerAuthentication::DatabricksApp
    {
        return Ok(url.clone());
    }
    let origin = server_url::origin(url);
    let mut target = format!("{origin}/");
    for _ in 0..=MAX_PROBE_REDIRECTS {
        let response = transport.send(probe_request(&target)).await?;
        match next_probe_target(&origin, &target, &response) {
            Some(next) => target = next,
            None => {
                return Ok(if is_databricks_response(&response) {
                    server_url::with_workspace_mount(url)
                } else {
                    url.clone()
                });
            }
        }
    }
    Ok(url.clone())
}

/// `HEAD target`, no cookies.
#[must_use]
pub fn probe_request(target: &str) -> HttpRequest {
    HttpRequest {
        method: "HEAD".into(),
        url: target.to_owned(),
        headers: Vec::new(),
        body: None,
    }
}

/// The same-origin target a 3xx points at, or `None` when the response is final (not a
/// redirect, no usable `Location`, or a different origin).
#[must_use]
pub fn next_probe_target(origin: &str, current: &str, response: &HttpResponse) -> Option<String> {
    if !(300..=399).contains(&response.status) {
        return None;
    }
    let location = response.header("Location")?;
    let next = Url::parse(current).ok()?.join(location).ok()?;
    (server_url::origin(&next) == origin).then(|| next.into())
}

/// Whether the response came from Databricks: `server: databricks`, any case.
#[must_use]
pub fn is_databricks_response(response: &HttpResponse) -> bool {
    response
        .header("server")
        .is_some_and(|server| server.eq_ignore_ascii_case("databricks"))
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::*;
    use crate::auth::testing::ScriptedTransport;
    use crate::http::HttpHeader;

    #[allow(
        clippy::unnecessary_wraps,
        reason = "shaped like a transport reply for ScriptedTransport::push"
    )]
    fn head(status: u16, headers: &[(&str, &str)]) -> Result<HttpResponse, TransportError> {
        Ok(HttpResponse {
            status,
            headers: headers
                .iter()
                .map(|(name, value)| HttpHeader::new(*name, *value))
                .collect(),
            body: Vec::new(),
        })
    }

    fn expand(transport: &ScriptedTransport, raw: &str) -> String {
        block_on(expand_if_needed(transport, &Url::parse(raw).unwrap()))
            .unwrap()
            .to_string()
    }

    #[test]
    fn probe_expands_bare_workspace_root() {
        let transport = ScriptedTransport::new();
        transport.push(head(200, &[("server", "databricks")]));
        assert_eq!(
            expand(&transport, "https://workspace.example.com"),
            "https://workspace.example.com/omnigent"
        );
        let request = transport.take().remove(0);
        assert_eq!(request.method, "HEAD");
        assert_eq!(request.url, "https://workspace.example.com/");
        assert_eq!(request.headers.len(), 0, "no cookies or credentials");
    }

    #[test]
    fn probe_leaves_non_workspace_root() {
        let transport = ScriptedTransport::new();
        transport.push(head(200, &[("server", "nginx")]));
        assert_eq!(
            expand(&transport, "https://app.example.com"),
            "https://app.example.com/"
        );
    }

    #[test]
    fn probe_skipped_for_path_urls() {
        let transport = ScriptedTransport::new();
        assert_eq!(
            expand(&transport, "https://workspace.example.com/omnigent"),
            "https://workspace.example.com/omnigent"
        );
        assert_eq!(transport.take().len(), 0);
    }

    #[test]
    fn probe_skipped_for_apps_hosts() {
        let transport = ScriptedTransport::new();
        for raw in [
            "https://my-app-123.aws.databricksapps.com",
            "https://databricksapps.com",
            "https://MY-APP.AZURE.DATABRICKSAPPS.COM",
        ] {
            let expanded = expand(&transport, raw);
            assert_eq!(expanded, Url::parse(raw).unwrap().to_string());
        }
        assert_eq!(transport.take().len(), 0);
    }

    #[test]
    fn probe_runs_for_apps_lookalikes() {
        for raw in [
            "https://databricksapps.com.example.org",
            "https://notdatabricksapps.com",
        ] {
            let transport = ScriptedTransport::new();
            transport.push(head(200, &[("server", "databricks")]));
            assert_eq!(expand(&transport, raw), format!("{raw}/omnigent"));
            assert_eq!(transport.take()[0].method, "HEAD");
        }
    }

    // In Swift the stub answers from another origin (a followed redirect). Here the transport
    // never follows, so the equivalent is a cross-origin Location the core refuses to chase: only
    // the approved origin's own answer is read.
    #[test]
    fn probe_rejects_response_from_other_origin() {
        let transport = ScriptedTransport::new();
        transport.push(head(302, &[("location", "http://192.168.1.5:8080/")]));
        transport.push(head(200, &[("server", "databricks")]));
        assert_eq!(
            expand(&transport, "https://workspace.example.com"),
            "https://workspace.example.com/"
        );
        assert_eq!(
            transport.take().len(),
            1,
            "the other origin is never contacted"
        );
        // A redirect the approved origin itself marks as Databricks is still its own answer.
        let transport = ScriptedTransport::new();
        transport.push(head(
            302,
            &[
                ("location", "http://192.168.1.5:8080/"),
                ("server", "databricks"),
            ],
        ));
        assert_eq!(
            expand(&transport, "https://workspace.example.com"),
            "https://workspace.example.com/omnigent"
        );
        assert_eq!(transport.take().len(), 1);
    }

    #[test]
    fn probe_blocks_cross_origin_redirect() {
        let transport = ScriptedTransport::new();
        // Another port is another origin.
        transport.push(head(302, &[("location", "https://localhost:9999/")]));
        transport.push(head(200, &[("server", "databricks")]));
        assert_eq!(
            expand(&transport, "https://localhost:8443"),
            "https://localhost:8443/"
        );
        assert_eq!(transport.take().len(), 1, "the redirect was not followed");
        assert_eq!(transport.remaining(), 1);
    }

    #[test]
    fn probe_follows_same_origin_redirect() {
        let transport = ScriptedTransport::new();
        transport.push(head(302, &[("location", "/elsewhere")]));
        transport.push(head(200, &[("server", "databricks")]));
        assert_eq!(
            expand(&transport, "https://localhost:8443"),
            "https://localhost:8443/omnigent"
        );
        let requests = transport.take();
        assert_eq!(requests[1].url, "https://localhost:8443/elsewhere");
    }

    #[test]
    fn probe_gives_up_after_a_redirect_loop_and_reports_transport_errors() {
        let transport = ScriptedTransport::new();
        for _ in 0..=MAX_PROBE_REDIRECTS {
            transport.push(head(302, &[("location", "/loop")]));
        }
        assert_eq!(
            expand(&transport, "https://h.example.com"),
            "https://h.example.com/"
        );
        transport.fail(TransportError::Timeout {
            message: "8s".into(),
        });
        assert_eq!(
            block_on(expand_if_needed(
                &transport,
                &Url::parse("https://h.example.com").unwrap()
            )),
            Err(TransportError::Timeout {
                message: "8s".into()
            })
        );
    }
}
