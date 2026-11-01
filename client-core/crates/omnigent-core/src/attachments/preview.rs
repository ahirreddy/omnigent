//! Reading attachments back: resolving a reference to a session file id, and
//! `GET /v1/sessions/{id}/resources/files/{file_id}/content` with its MIME and size limits.

use url::Url;

use super::policy::is_identifier;
use super::session_resource_url;
use crate::http::{HttpHeader, HttpRequest, HttpResponse};

/// Largest attachment previewed natively.
pub const MAX_PREVIEW_BYTES: usize = 10 * 1024 * 1024;

/// Media types that may be previewed, with the fixed extension used for the local copy. Active
/// content (HTML, SVG, JavaScript) and unknown types are never previewed.
pub const PREVIEW_EXTENSIONS: &[(&str, &str)] = &[
    ("application/pdf", "pdf"),
    ("text/plain", "txt"),
    ("application/json", "json"),
    ("text/markdown", "txt"),
    ("text/csv", "csv"),
    ("image/png", "png"),
    ("image/jpeg", "jpg"),
    ("image/gif", "gif"),
    ("image/webp", "webp"),
    ("image/heic", "heic"),
    ("image/tiff", "tiff"),
    ("audio/mpeg", "mp3"),
    ("audio/wav", "wav"),
    ("audio/x-wav", "wav"),
    ("audio/mp4", "m4a"),
    ("video/mp4", "mp4"),
    ("video/quicktime", "mov"),
];

/// A previewable attachment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentPreview {
    /// The exact bytes the server returned.
    pub data: Vec<u8>,
    /// Safe extension for the media type, from [`PREVIEW_EXTENSIONS`].
    pub file_extension: &'static str,
}

/// Why an attachment cannot be previewed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PreviewError {
    /// A session or file id is not an identifier. Nothing was sent.
    #[error("invalid identifier {value:?}")]
    InvalidIdentifier {
        /// The rejected value.
        value: String,
    },
    /// The server redirected; redirects are never followed.
    #[error("the server redirected the attachment request (HTTP {status})")]
    RedirectNotAllowed {
        /// The 3xx status.
        status: u16,
    },
    /// HTTP 401. The caller must drop the connection and ask for sign-in again.
    #[error("not signed in")]
    Unauthorized,
    /// HTTP 403.
    #[error("not allowed to read this attachment")]
    Forbidden,
    /// Any other non-200 status.
    #[error("attachment request failed with HTTP {status}")]
    HttpStatus {
        /// The status.
        status: u16,
    },
    /// The media type is missing, active content, or not in [`PREVIEW_EXTENSIONS`].
    #[error("this file type cannot be safely previewed here; open it in the web app")]
    UnsupportedMedia {
        /// The `Content-Type` as received, if any.
        content_type: Option<String>,
    },
    /// The advertised or actual size exceeds [`MAX_PREVIEW_BYTES`].
    #[error("this file exceeds the 10 MB native preview limit; open it in the web app")]
    TooLarge,
    /// `Content-Length` is not a number.
    #[error("malformed Content-Length {value:?}")]
    MalformedContentLength {
        /// The header value.
        value: String,
    },
}

/// The file id `reference` names, if it is exactly a file of `session_id` on the server at
/// `base_url` (including its mount path).
///
/// A reference is a bare file id, a logical path (`/v1/...` or `v1/...`) under the server, or an
/// absolute URL with the same scheme, host and port. Credentials, fragments, percent escapes,
/// dot segments and any query other than exactly `o=<org_id>` are refused. Returns `None` for
/// anything else; such a reference is simply not a session attachment.
#[must_use]
pub fn attachment_file_id(
    base_url: &Url,
    org_id: Option<&str>,
    reference: Option<&str>,
    session_id: &str,
) -> Option<String> {
    let reference = reference.filter(|reference| !reference.is_empty())?;
    if !is_identifier(session_id) {
        return None;
    }
    if is_identifier(reference) {
        return Some(reference.to_owned());
    }
    let base_path = base_url.path().trim_end_matches('/');
    let target = if reference.starts_with("/v1/") || reference.starts_with("v1/") {
        let mut root = base_url.clone();
        root.set_query(None);
        root.set_fragment(None);
        format!(
            "{}{base_path}/{}",
            super::origin_of(&root)?,
            reference.trim_start_matches('/')
        )
    } else {
        reference.to_owned()
    };
    // `Url` resolves dot segments and re-encodes some characters; refuse both up front so the
    // parsed path is exactly what was written.
    let raw_path = target.split(['?', '#']).next().unwrap_or_default();
    if raw_path.contains('%')
        || raw_path
            .split('/')
            .any(|segment| segment == "." || segment == "..")
    {
        return None;
    }
    let url = Url::parse(&target).ok()?;
    let same_origin = url.scheme() == base_url.scheme()
        && url.host_str() == base_url.host_str()
        && url.port_or_known_default() == base_url.port_or_known_default();
    let query_allowed = url
        .query()
        .is_none_or(|query| org_id.is_some_and(|org| query == format!("o={org}")));
    if !same_origin
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || !query_allowed
        || url.path().contains('%')
    {
        return None;
    }
    let path = url.path().strip_prefix(base_path)?;
    let mut parts = path.strip_prefix("/v1/sessions/")?.split('/');
    let file_id = match (
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
    ) {
        (Some(session), Some("resources"), Some("files"), Some(file), Some("content"), None)
            if session == session_id && is_identifier(file) =>
        {
            file
        }
        _ => return None,
    };
    Some(file_id.to_owned())
}

/// `GET` for one session file's content. The caller adds authentication and scope headers.
///
/// # Errors
///
/// [`PreviewError::InvalidIdentifier`] for a bad session or file id; nothing must be sent then.
pub fn preview_request(
    base_url: &Url,
    session_id: &str,
    file_id: &str,
) -> Result<HttpRequest, PreviewError> {
    for value in [session_id, file_id] {
        if !is_identifier(value) {
            return Err(PreviewError::InvalidIdentifier {
                value: value.to_owned(),
            });
        }
    }
    let url = session_resource_url(
        base_url,
        session_id,
        &["resources", "files", file_id, "content"],
    );
    Ok(HttpRequest {
        method: "GET".into(),
        url: url.into(),
        headers: vec![HttpHeader::new("Accept", "*/*")],
        body: None,
    })
}

/// The safe extension for a `Content-Type` value; parameters such as `charset` are ignored.
#[must_use]
pub fn preview_extension(content_type: &str) -> Option<&'static str> {
    let media_type = content_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    PREVIEW_EXTENSIONS
        .iter()
        .find(|(candidate, _)| *candidate == media_type)
        .map(|(_, extension)| *extension)
}

/// Maps the response to [`preview_request`]. Status is checked first, then the media type, then
/// the advertised `Content-Length`, then the actual body length (which never trusts the header).
///
/// # Errors
///
/// See [`PreviewError`].
pub fn preview_from_response(response: HttpResponse) -> Result<AttachmentPreview, PreviewError> {
    match response.status {
        200 => {}
        300..=399 => {
            return Err(PreviewError::RedirectNotAllowed {
                status: response.status,
            });
        }
        401 => return Err(PreviewError::Unauthorized),
        403 => return Err(PreviewError::Forbidden),
        status => return Err(PreviewError::HttpStatus { status }),
    }
    let content_type = response.header("Content-Type");
    let file_extension =
        content_type
            .and_then(preview_extension)
            .ok_or_else(|| PreviewError::UnsupportedMedia {
                content_type: content_type.map(str::to_owned),
            })?;
    if let Some(value) = response.header("Content-Length") {
        let length: u64 =
            value
                .trim()
                .parse()
                .map_err(|_| PreviewError::MalformedContentLength {
                    value: value.to_owned(),
                })?;
        if !usize::try_from(length).is_ok_and(|length| length <= MAX_PREVIEW_BYTES) {
            return Err(PreviewError::TooLarge);
        }
    }
    if response.body.len() > MAX_PREVIEW_BYTES {
        return Err(PreviewError::TooLarge);
    }
    Ok(AttachmentPreview {
        data: response.body,
        file_extension,
    })
}

#[cfg(test)]
mod tests {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde_json::Value;

    use super::*;
    use crate::attachments::tests::{fixture_json, fixture_lines, with_port};

    fn local() -> Url {
        Url::parse("http://127.0.0.1:6767").unwrap()
    }

    fn response(status: u16, headers: &[(&str, &str)], body: Vec<u8>) -> HttpResponse {
        HttpResponse {
            status,
            headers: headers
                .iter()
                .map(|(name, value)| HttpHeader::new(*name, *value))
                .collect(),
            body,
        }
    }

    fn envelope_response(envelope: &Value) -> HttpResponse {
        let headers: Vec<(String, String)> = envelope["headers"]
            .as_object()
            .map(|headers| {
                headers
                    .iter()
                    .map(|(name, value)| (name.clone(), value.as_str().unwrap().to_owned()))
                    .collect()
            })
            .unwrap_or_default();
        let body = envelope_body(envelope);
        HttpResponse {
            status: u16::try_from(envelope["status"].as_u64().unwrap()).unwrap(),
            headers: headers
                .into_iter()
                .map(|(name, value)| HttpHeader::new(name, value))
                .collect(),
            body,
        }
    }

    fn envelope_body(envelope: &Value) -> Vec<u8> {
        if let Some(encoded) = envelope.get("response_base64") {
            return STANDARD.decode(encoded.as_str().unwrap()).unwrap();
        }
        if let Some(generated) = envelope.get("response_generated") {
            let fill = generated["fill"].as_str().unwrap().as_bytes()[0];
            return vec![fill; usize::try_from(generated["length"].as_u64().unwrap()).unwrap()];
        }
        envelope["response"].as_str().unwrap().as_bytes().to_vec()
    }

    #[test]
    fn reference_resolution_accepts_only_exact_session_resources() {
        let fixture = fixture_json(
            "LocalAttachment--ReferenceResolutionAcceptsOnlyExactSessionResources.json",
        );
        let base = Url::parse(fixture["base_url"].as_str().unwrap()).unwrap();
        let default_session = fixture["session_id"].as_str().unwrap();
        let cases = fixture["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 21);
        for case in cases {
            let session = case["session_id"].as_str().unwrap_or(default_session);
            assert_eq!(
                attachment_file_id(&base, None, case["reference"].as_str(), session).as_deref(),
                case["expected_file_id"].as_str(),
                "{case}"
            );
        }
        for reference in [
            "/v1/sessions/other/../fixture/resources/files/file/content",
            "/v1/sessions/fixture/resources/files/./file/content",
            "/v1/sessions/fixture/resources/files/file/content?",
            "/v1/sessions/fixture/resources/files/file/content#",
            "http://127.0.0.1:6767/v1/sessions/fixture/resources/files/file/content?o=1",
        ] {
            assert_eq!(
                attachment_file_id(&base, None, Some(reference), "fixture"),
                None,
                "{reference}"
            );
        }
        assert_eq!(
            attachment_file_id(
                &local(),
                None,
                Some("http://127.0.0.1:80/v1/sessions/fixture/resources/files/f/content"),
                "fixture"
            ),
            None
        );
        let default_port = Url::parse("http://127.0.0.1").unwrap();
        assert_eq!(
            attachment_file_id(
                &default_port,
                None,
                Some("http://127.0.0.1:80/v1/sessions/fixture/resources/files/f/content"),
                "fixture"
            )
            .as_deref(),
            Some("f")
        );
    }

    #[test]
    fn attachment_references_resolve_with_scope_query_and_reject_different_org() {
        let fixture = fixture_json(
            "DatabricksRouting--AttachmentReferencesResolveWithScopeQueryAndRejectDifferentOrg.json",
        );
        let port = "8443";
        let root = with_port(fixture["server_root"].as_str().unwrap(), port);
        let base = Url::parse(&format!("{root}?o=123")).unwrap();
        let org = fixture["org_id"].as_str();
        let session = fixture["session_id"].as_str().unwrap();
        let expected = fixture["expected_file_id"].as_str();
        for reference in fixture["accepted"].as_array().unwrap() {
            let reference = with_port(reference.as_str().unwrap(), port);
            assert_eq!(
                attachment_file_id(&base, org, Some(&reference), session).as_deref(),
                expected,
                "{reference}"
            );
        }
        for reference in fixture["rejected"].as_array().unwrap() {
            let reference = with_port(reference.as_str().unwrap(), port);
            assert_eq!(
                attachment_file_id(&base, org, Some(&reference), session),
                None,
                "{reference}"
            );
        }
    }

    #[test]
    fn explicit_fetch_uses_session_resource_get_and_preserves_bytes_without_credentials() {
        let fixture = fixture_json(
            "LocalAttachment--ExplicitFetchUsesSessionResourceGETAndPreservesBytesWithoutCredentials.json",
        );
        let request = preview_request(&local(), "fixture", "file_1").unwrap();
        assert_eq!(
            request.method,
            fixture["request"]["method"].as_str().unwrap()
        );
        assert_eq!(
            request.url,
            format!(
                "http://127.0.0.1:6767{}",
                fixture["request"]["path"].as_str().unwrap()
            )
        );
        assert_eq!(request.body, None);
        assert_eq!(request.headers, vec![HttpHeader::new("Accept", "*/*")]);

        let bytes = vec![0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a];
        let preview = preview_from_response(envelope_response(&fixture)).unwrap();
        assert_eq!(preview.data, bytes);
        assert_eq!(preview.file_extension, "png");
    }

    #[test]
    fn disconnected_and_malformed_identifiers_make_no_attachment_requests() {
        for (session, file) in [
            ("../other", "file"),
            ("fixture", "../file"),
            ("fixture", ""),
        ] {
            assert!(
                matches!(
                    preview_request(&local(), session, file),
                    Err(PreviewError::InvalidIdentifier { .. })
                ),
                "{session} {file}"
            );
        }
    }

    #[test]
    fn supported_mime_types_have_fixed_safe_extensions() {
        let fixture = fixture_json(
            "LocalAttachment--SupportedMIMETypesHaveFixedSafeExtensions--mime-table.json",
        );
        let body = fixture["response_text"]
            .as_str()
            .unwrap()
            .as_bytes()
            .to_vec();
        let cases = fixture["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 17);
        for case in cases {
            let content_type = case["content_type"].as_str().unwrap();
            let preview = preview_from_response(response(
                200,
                &[("Content-Type", content_type)],
                body.clone(),
            ))
            .unwrap();
            assert_eq!(
                preview.file_extension,
                case["expected_extension"].as_str().unwrap(),
                "{content_type}"
            );
            assert_eq!(preview.data, body, "{content_type}");
        }
    }

    #[test]
    fn unsupported_active_or_unknown_mime_is_rejected() {
        let envelopes =
            fixture_lines("LocalAttachment--UnsupportedActiveOrUnknownMIMEIsRejected.jsonl");
        assert_eq!(envelopes.len(), 5);
        for envelope in &envelopes {
            let response = envelope_response(envelope);
            let content_type = response.header("Content-Type").map(str::to_owned);
            assert_eq!(
                preview_from_response(response),
                Err(PreviewError::UnsupportedMedia { content_type }),
                "{envelope}"
            );
        }
    }

    #[test]
    fn advertised_content_length_over_limit_is_rejected() {
        let fixture =
            fixture_json("LocalAttachment--AdvertisedContentLengthOverLimitIsRejected.json");
        assert_eq!(
            preview_from_response(envelope_response(&fixture)),
            Err(PreviewError::TooLarge)
        );
        let at_limit = MAX_PREVIEW_BYTES.to_string();
        assert!(
            preview_from_response(response(
                200,
                &[
                    ("Content-Type", "text/plain"),
                    ("Content-Length", &at_limit)
                ],
                Vec::new()
            ))
            .is_ok()
        );
        assert_eq!(
            preview_from_response(response(
                200,
                &[("Content-Type", "text/plain"), ("Content-Length", "ten")],
                Vec::new()
            )),
            Err(PreviewError::MalformedContentLength {
                value: "ten".into()
            })
        );
    }

    #[test]
    fn streaming_length_limit_does_not_trust_missing_content_length() {
        let fixture = fixture_json(
            "LocalAttachment--StreamingLengthLimitDoesNotTrustMissingContentLength.json",
        );
        let oversized = envelope_response(&fixture);
        assert_eq!(oversized.body.len(), MAX_PREVIEW_BYTES + 1);
        assert_eq!(
            preview_from_response(oversized),
            Err(PreviewError::TooLarge)
        );
        // A lying Content-Length does not let a larger body through either.
        assert_eq!(
            preview_from_response(response(
                200,
                &[("Content-Type", "text/plain"), ("Content-Length", "1")],
                vec![b'A'; MAX_PREVIEW_BYTES + 1]
            )),
            Err(PreviewError::TooLarge)
        );
    }

    #[test]
    fn redirects_different_response_origins_and_http_failures_are_explicit() {
        let envelopes = fixture_lines(
            "LocalAttachment--RedirectsDifferentResponseOriginsAndHTTPFailuresAreExplicit.jsonl",
        );
        let mut errors = Vec::new();
        for envelope in &envelopes {
            if envelope.get("response_url").is_some() {
                // Hosts never follow redirects, so a response from another origin cannot reach
                // the core; the 3xx that would have caused it is mapped below.
                continue;
            }
            errors.push(preview_from_response(envelope_response(envelope)).unwrap_err());
        }
        assert_eq!(
            errors,
            vec![
                PreviewError::RedirectNotAllowed { status: 302 },
                PreviewError::Unauthorized,
                PreviewError::Forbidden,
                PreviewError::HttpStatus { status: 404 },
                PreviewError::HttpStatus { status: 500 },
            ]
        );
    }
}
