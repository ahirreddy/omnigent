//! Server discovery from `/.well-known/omnigent.json`.

use omnigent_protocol::manifest::MANIFEST_PATH;
use omnigent_protocol::{AuthMode, ServerManifest};
use url::Url;

use crate::error::CoreError;
use crate::http::{HttpHeader, HttpRequest, HttpResponse};
use crate::server_url;

/// What the client learned about a server before signing in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerDiscovery {
    /// The normalized server URL, mount path included.
    pub base_url: String,
    /// Operator display name; display only.
    pub server_name: Option<String>,
    /// Server package version; informational.
    pub server_version: Option<String>,
    /// The manifest's `min_desktop_version`.
    pub min_client_version: Option<String>,
    /// `None` when the server predates the manifest or its `auth` block.
    pub auth_mode: Option<AuthMode>,
    /// Private-use-scheme redirects the server accepts for native sign-in.
    pub native_redirect_uris: Vec<String>,
}

impl ServerDiscovery {
    /// What a server older than the manifest route implies: sign in as before.
    fn baseline(base_url: &Url) -> Self {
        Self {
            base_url: server_url::display(base_url),
            server_name: None,
            server_version: None,
            min_client_version: None,
            auth_mode: None,
            native_redirect_uris: Vec::new(),
        }
    }

    fn from_manifest(base_url: &Url, manifest: ServerManifest) -> Self {
        let (auth_mode, native_redirect_uris) = match manifest.auth {
            Some(auth) => (Some(auth.mode), auth.native_redirect_uris),
            None => (None, Vec::new()),
        };
        Self {
            base_url: server_url::display(base_url),
            server_name: manifest.server_name,
            server_version: manifest.server_version,
            min_client_version: manifest.min_desktop_version,
            auth_mode,
            native_redirect_uris,
        }
    }
}

/// `GET <origin>/.well-known/omnigent.json`; the manifest lives at the origin, not under the mount.
#[must_use]
pub fn manifest_request(server: &Url) -> HttpRequest {
    HttpRequest {
        method: "GET".into(),
        url: format!("{}{MANIFEST_PATH}", server_url::origin(server)),
        headers: vec![HttpHeader::new("Accept", "application/json")],
        body: None,
    }
}

/// Maps the response to [`manifest_request`].
///
/// Per the server contract a 404 (and an older server's SPA catch-all answering with HTML) is the
/// pre-manifest baseline, not an error; every other non-2xx status and undecodable body is.
///
/// # Errors
///
/// [`CoreError::HttpStatus`] for an unexpected status, [`CoreError::Decode`] for a body that is not
/// a manifest.
pub fn discovery_from_response(
    server: &Url,
    response: &HttpResponse,
) -> Result<ServerDiscovery, CoreError> {
    if response.status == 404 {
        return Ok(ServerDiscovery::baseline(server));
    }
    if !(200..300).contains(&response.status) {
        return Err(CoreError::HttpStatus {
            status: response.status,
            body: String::from_utf8_lossy(&response.body).into_owned(),
        });
    }
    let content_type = response
        .header("Content-Type")
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    if content_type.contains("text/html") {
        return Ok(ServerDiscovery::baseline(server));
    }
    if !content_type.contains("json") {
        return Err(CoreError::Decode {
            message: format!(
                "expected a JSON manifest, got content-type {:?}",
                response.header("Content-Type").unwrap_or("<none>")
            ),
        });
    }
    let manifest =
        ServerManifest::from_json(&response.body).map_err(|error| CoreError::Decode {
            message: format!("{MANIFEST_PATH}: {error}"),
        })?;
    Ok(ServerDiscovery::from_manifest(server, manifest))
}
