//! `POST /v1/sessions/{id}/resources/files`: the multipart request and the response mapping.
//!
//! The upload endpoint has no idempotency key. Any outcome the client cannot prove (a transport
//! failure, a redirect, a 5xx, an unreadable 201) is [`UploadError::Uncertain`]: the file may be
//! stored, so it is never re-posted automatically.

use serde_json::{Map, Value};
use url::Url;

use super::policy::{MAX_FILES_PER_DRAFT, UploadFile, is_identifier};
use super::session_resource_url;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, TransportError};

/// Largest upload acknowledgement read; a bigger body is not a valid acknowledgement.
pub const MAX_UPLOAD_RESPONSE_BYTES: usize = 64 * 1024;
/// Longest multipart boundary RFC 2046 allows.
pub const MAX_BOUNDARY_LEN: usize = 70;

/// A file the server has stored, bound to the server, account and session it was uploaded to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadedAttachment {
    /// Server base URL (including any mount path) the file was uploaded to.
    pub server_url: Url,
    /// Confirmed account the upload was made as; `None` on a local single-user server.
    pub user_id: Option<String>,
    /// Session the file belongs to.
    pub session_id: String,
    /// Server file id.
    pub id: String,
    /// Filename the server reported, or the requested one when it reported none.
    pub filename: String,
    /// Referenced as `input_image` rather than `input_file`.
    pub is_image: bool,
}

/// Why the outcome of an upload is unknown.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UploadUncertainty {
    /// The host got no response.
    #[error("{0}")]
    Transport(TransportError),
    /// The server answered with a redirect, which is never followed.
    #[error("the server redirected the upload (HTTP {status})")]
    Redirect {
        /// The 3xx status.
        status: u16,
    },
    /// A status that neither confirms nor rejects the upload (5xx, or a 2xx other than 201).
    #[error("unexpected upload status HTTP {status}")]
    UnexpectedStatus {
        /// The status.
        status: u16,
    },
    /// The acknowledgement body exceeds [`MAX_UPLOAD_RESPONSE_BYTES`].
    #[error(
        "upload acknowledgement is {len} bytes, over the {MAX_UPLOAD_RESPONSE_BYTES}-byte limit"
    )]
    BodyTooLarge {
        /// Body length.
        len: usize,
    },
    /// The acknowledgement is not the expected JSON.
    #[error("malformed upload acknowledgement: {message}")]
    MalformedBody {
        /// What was wrong.
        message: String,
    },
    /// The returned file id is not an identifier.
    #[error("upload acknowledgement has an invalid file id {id:?}")]
    InvalidFileId {
        /// The id as returned.
        id: String,
    },
    /// The acknowledgement names another session.
    #[error("upload acknowledgement names session {returned:?}")]
    SessionMismatch {
        /// The session id as returned.
        returned: String,
    },
    /// Neither the server nor the request had a filename.
    #[error("upload acknowledgement has an empty filename")]
    EmptyFilename,
}

/// A failed upload, or a reference that cannot be sent.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UploadError {
    /// A session or file id is not an identifier. Nothing was sent.
    #[error("invalid identifier {value:?}")]
    InvalidIdentifier {
        /// The rejected value.
        value: String,
    },
    /// The injected multipart boundary is not a valid RFC 2046 boundary. Nothing was sent.
    #[error("invalid multipart boundary {boundary:?}")]
    InvalidBoundary {
        /// The rejected boundary.
        boundary: String,
    },
    /// The file contains the boundary delimiter; build the request again with another boundary.
    #[error("the file contains the multipart boundary")]
    BoundaryInBody,
    /// HTTP 401. The caller must drop the connection and ask for sign-in again.
    #[error("not signed in")]
    Unauthorized,
    /// HTTP 403.
    #[error("not allowed to upload to this session")]
    Forbidden,
    /// Any other 4xx: the server definitely did not store the file (for example 413 or 415).
    #[error("upload rejected with HTTP {status}")]
    Rejected {
        /// The status.
        status: u16,
    },
    /// The file may or may not be stored. Do not retry automatically.
    #[error(
        "upload confirmation was lost and the file may already be stored; automatic retry is disabled: {0}"
    )]
    Uncertain(UploadUncertainty),
    /// More attachments than one message may carry.
    #[error("a message can carry at most {MAX_FILES_PER_DRAFT} attachments, not {count}")]
    TooManyAttachments {
        /// Attachments offered.
        count: usize,
    },
    /// An attachment belongs to another session, server or account.
    #[error("these attachments belong to a different session or server")]
    WrongSession,
}

impl UploadError {
    /// Whether the file may already be stored, so the upload must not be retried automatically.
    #[must_use]
    pub const fn is_uncertain(&self) -> bool {
        matches!(self, Self::Uncertain(_))
    }
}

/// The server, account and session an upload goes to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadTarget {
    /// Server base URL, including any mount path. Its query and fragment are not used.
    pub server_url: Url,
    /// Session to upload into.
    pub session_id: String,
    /// The connection's confirmed account; `None` on a local single-user server.
    pub user_id: Option<String>,
}

fn is_boundary(boundary: &str) -> bool {
    (1..=MAX_BOUNDARY_LEN).contains(&boundary.len())
        && boundary
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"'()+_,-./:=?".contains(&byte))
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

impl UploadTarget {
    /// The multipart upload request for `file`, with the given `boundary` (inject a random one in
    /// production and a fixed one in tests). The caller adds authentication and scope headers.
    ///
    /// # Errors
    ///
    /// [`UploadError::InvalidIdentifier`], [`UploadError::InvalidBoundary`] or
    /// [`UploadError::BoundaryInBody`]; nothing must be sent then.
    pub fn request(&self, file: &UploadFile, boundary: &str) -> Result<HttpRequest, UploadError> {
        if !is_identifier(&self.session_id) {
            return Err(UploadError::InvalidIdentifier {
                value: self.session_id.clone(),
            });
        }
        if !is_boundary(boundary) {
            return Err(UploadError::InvalidBoundary {
                boundary: boundary.to_owned(),
            });
        }
        let delimiter = format!("--{boundary}");
        if contains(file.data(), delimiter.as_bytes()) {
            return Err(UploadError::BoundaryInBody);
        }
        let filename = file.filename().replace('"', "%22");
        let mut body = format!(
            "{delimiter}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\nContent-Type: {}\r\n\r\n",
            file.media_type()
        )
        .into_bytes();
        body.extend_from_slice(file.data());
        body.extend_from_slice(format!("\r\n{delimiter}--\r\n").as_bytes());
        let url = session_resource_url(&self.server_url, &self.session_id, &["resources", "files"]);
        Ok(HttpRequest {
            method: "POST".into(),
            url: url.into(),
            headers: vec![
                HttpHeader::new("Accept", "application/json"),
                HttpHeader::new(
                    "Content-Type",
                    format!("multipart/form-data; boundary={boundary}"),
                ),
            ],
            body: Some(body),
        })
    }

    /// Maps the host's result for [`Self::request`]. Only a 201 whose body names a valid file in
    /// this session is success.
    ///
    /// # Errors
    ///
    /// [`UploadError::Unauthorized`], [`UploadError::Forbidden`] and [`UploadError::Rejected`]
    /// when the server refused the file; [`UploadError::Uncertain`] when the outcome is unknown.
    pub fn response(
        &self,
        file: &UploadFile,
        result: Result<HttpResponse, TransportError>,
    ) -> Result<UploadedAttachment, UploadError> {
        let response =
            result.map_err(|error| UploadError::Uncertain(UploadUncertainty::Transport(error)))?;
        match response.status {
            201 => {}
            300..=399 => {
                return Err(UploadError::Uncertain(UploadUncertainty::Redirect {
                    status: response.status,
                }));
            }
            401 => return Err(UploadError::Unauthorized),
            403 => return Err(UploadError::Forbidden),
            400..=499 => {
                return Err(UploadError::Rejected {
                    status: response.status,
                });
            }
            status => {
                return Err(UploadError::Uncertain(
                    UploadUncertainty::UnexpectedStatus { status },
                ));
            }
        }
        self.acknowledged(file, &response.body)
            .map_err(UploadError::Uncertain)
    }

    fn acknowledged(
        &self,
        file: &UploadFile,
        body: &[u8],
    ) -> Result<UploadedAttachment, UploadUncertainty> {
        if body.len() > MAX_UPLOAD_RESPONSE_BYTES {
            return Err(UploadUncertainty::BodyTooLarge { len: body.len() });
        }
        let malformed = |message: String| UploadUncertainty::MalformedBody { message };
        let value: Value =
            serde_json::from_slice(body).map_err(|error| malformed(error.to_string()))?;
        let object = value
            .as_object()
            .ok_or_else(|| malformed("expected a JSON object".into()))?;
        let id = optional_string(object, "id")
            .map_err(malformed)?
            .ok_or_else(|| malformed("missing \"id\"".into()))?;
        if !is_identifier(id) {
            return Err(UploadUncertainty::InvalidFileId { id: id.to_owned() });
        }
        if let Some(returned) = optional_string(object, "session_id").map_err(malformed)?
            && returned != self.session_id
        {
            return Err(UploadUncertainty::SessionMismatch {
                returned: returned.to_owned(),
            });
        }
        let metadata_filename = match object.get("metadata") {
            None | Some(Value::Null) => None,
            Some(Value::Object(metadata)) => optional_string(metadata, "filename")
                .map_err(|message| malformed(format!("metadata: {message}")))?,
            Some(_) => return Err(malformed("\"metadata\" is not an object".into())),
        };
        let filename = metadata_filename
            .or(optional_string(object, "name").map_err(malformed)?)
            .unwrap_or_else(|| file.filename());
        if filename.is_empty() {
            return Err(UploadUncertainty::EmptyFilename);
        }
        Ok(UploadedAttachment {
            server_url: self.server_url.clone(),
            user_id: self.user_id.clone(),
            session_id: self.session_id.clone(),
            id: id.to_owned(),
            filename: filename.to_owned(),
            is_image: file.is_image(),
        })
    }

    /// Checks that `attachments` may be referenced by a message to this target's session: at most
    /// [`MAX_FILES_PER_DRAFT`], each uploaded to this server and session as this account (or with
    /// no account when `local_single_user`), with valid ids.
    ///
    /// # Errors
    ///
    /// [`UploadError::InvalidIdentifier`], [`UploadError::TooManyAttachments`] or
    /// [`UploadError::WrongSession`]; nothing must be sent then.
    pub fn validate_message_attachments(
        &self,
        attachments: &[UploadedAttachment],
        local_single_user: bool,
    ) -> Result<(), UploadError> {
        if !is_identifier(&self.session_id) {
            return Err(UploadError::InvalidIdentifier {
                value: self.session_id.clone(),
            });
        }
        if attachments.len() > MAX_FILES_PER_DRAFT {
            return Err(UploadError::TooManyAttachments {
                count: attachments.len(),
            });
        }
        let belongs = |attachment: &UploadedAttachment| {
            attachment.session_id == self.session_id
                && attachment.server_url == self.server_url
                && (attachment.user_id == self.user_id
                    || (local_single_user && attachment.user_id.is_none()))
        };
        if !attachments.iter().all(belongs) {
            return Err(UploadError::WrongSession);
        }
        if let Some(bad) = attachments
            .iter()
            .find(|attachment| !is_identifier(&attachment.id))
        {
            return Err(UploadError::InvalidIdentifier {
                value: bad.id.clone(),
            });
        }
        Ok(())
    }
}

/// `object[key]` as a string: `Ok(None)` when absent or null, an error for any other type.
fn optional_string<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<Option<&'a str>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(other) => Err(format!("{key:?} is not a string: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;

    use super::*;
    use crate::attachments::tests::{fixture_json, fixture_lines, with_port};

    const BOUNDARY: &str = "NativeLab-fixture";

    fn target(server: &str, user_id: Option<&str>) -> UploadTarget {
        UploadTarget {
            server_url: Url::parse(server).unwrap(),
            session_id: "session_a".into(),
            user_id: user_id.map(str::to_owned),
        }
    }

    fn local() -> UploadTarget {
        target("http://127.0.0.1:6767", None)
    }

    #[allow(
        clippy::unnecessary_wraps,
        reason = "shaped like the transport result the mapper takes"
    )]
    fn reply(status: u16, body: &Value) -> Result<HttpResponse, TransportError> {
        let body = match body {
            Value::String(text) => text.clone().into_bytes(),
            other => other.to_string().into_bytes(),
        };
        Ok(HttpResponse {
            status,
            headers: vec![HttpHeader::new("Content-Type", "application/json")],
            body,
        })
    }

    fn header<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
        request
            .headers
            .iter()
            .find(|header| header.name.eq_ignore_ascii_case(name))
            .map(|header| header.value.as_str())
    }

    fn notes() -> UploadFile {
        UploadFile::new("notes.txt", None, Vec::new()).unwrap()
    }

    #[test]
    fn an_upload_reply_with_wrongly_typed_fields_is_uncertain() {
        let target = local();
        let file = UploadFile::new("a.txt", None, b"a".to_vec()).unwrap();
        let reply = |body: Value| {
            target.response(
                &file,
                Ok(HttpResponse {
                    status: 201,
                    headers: Vec::new(),
                    body: serde_json::to_vec(&body).unwrap(),
                }),
            )
        };
        for fields in [
            serde_json::json!({"id": "f", "session_id": "session_a", "metadata": 5}),
            serde_json::json!({"id": "f", "session_id": "session_a", "metadata": {"filename": 5}}),
        ] {
            assert!(
                matches!(
                    reply(fields.clone()),
                    Err(UploadError::Uncertain(
                        UploadUncertainty::MalformedBody { .. }
                    ))
                ),
                "{fields}"
            );
        }
    }

    #[test]
    fn a_session_id_that_is_not_an_identifier_stops_a_send() {
        let target = UploadTarget {
            session_id: "../x".into(),
            ..local()
        };
        assert_eq!(
            target.validate_message_attachments(&[], true),
            Err(UploadError::InvalidIdentifier {
                value: "../x".into()
            })
        );
    }

    #[test]
    fn upload201_uses_exact_multipart_field_bytes_and_safe_session_transport() {
        let fixture = fixture_json(
            "LocalServerUpload--Upload201UsesExactMultipartFieldBytesAndSafeSessionTransport.json",
        );
        let part = &fixture["request"]["body"]["multipart"]["part"];
        let prefix = fixture["request"]["body"]["multipart"]["boundary_prefix"]
            .as_str()
            .unwrap();
        assert!(BOUNDARY.starts_with(prefix));
        let bytes = STANDARD
            .decode(part["bytes_base64"].as_str().unwrap())
            .unwrap();
        assert_eq!(bytes, [0, 1, 2, 255]);
        let file = UploadFile::new(part["raw_filename"].as_str().unwrap(), None, bytes).unwrap();
        let target = local();

        let request = target.request(&file, BOUNDARY).unwrap();
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
        for forbidden in ["Authorization", "Cookie", "Origin"] {
            assert_eq!(header(&request, forbidden), None, "{forbidden}");
        }
        assert_eq!(
            header(&request, "Content-Type"),
            Some("multipart/form-data; boundary=NativeLab-fixture")
        );
        let mut expected = format!(
            "--{BOUNDARY}\r\nContent-Disposition: form-data; name=\"{}\"; filename=\"{}\"\r\nContent-Type: {}\r\n\r\n",
            part["name"].as_str().unwrap(),
            part["filename"].as_str().unwrap(),
            part["content_type"].as_str().unwrap(),
        )
        .into_bytes();
        expected.extend_from_slice(file.data());
        expected.extend_from_slice(format!("\r\n--{BOUNDARY}--\r\n").as_bytes());
        assert_eq!(request.body, Some(expected));

        let status = u16::try_from(fixture["status"].as_u64().unwrap()).unwrap();
        let uploaded = target
            .response(&file, reply(status, &fixture["response"]))
            .unwrap();
        assert_eq!(
            uploaded,
            UploadedAttachment {
                server_url: target.server_url,
                user_id: None,
                session_id: "session_a".into(),
                id: "file_exact".into(),
                filename: "server-name.png".into(),
                is_image: true,
            }
        );
    }

    #[test]
    fn upload_fallback_filename_matches_web_contract() {
        let fixture =
            fixture_json("LocalServerUpload--UploadFallbackFilenameMatchesWebContract.json");
        let part = &fixture["request"]["body"]["multipart"]["part"];
        let file = UploadFile::new(part["filename"].as_str().unwrap(), None, Vec::new()).unwrap();
        let uploaded = local()
            .response(&file, reply(201, &fixture["response"]))
            .unwrap();
        assert_eq!(uploaded.id, "file_fallback");
        assert_eq!(uploaded.filename, "actual.swift");
        assert!(!uploaded.is_image);
        // The legacy `{id, name, session_id}` shape names the file through `name`.
        let legacy =
            serde_json::json!({"id": "file_text", "name": "notes.txt", "session_id": "session_a"});
        assert_eq!(
            local()
                .response(&file, reply(201, &legacy))
                .unwrap()
                .filename,
            "notes.txt"
        );
    }

    #[test]
    fn indeterminate_upload_failures_do_not_retry_post() {
        let envelopes =
            fixture_lines("LocalServerUpload--IndeterminateUploadFailuresDoNotRetryPOST.jsonl");
        assert_eq!(envelopes.len(), 6);
        let file = notes();
        let target = local();
        let mut outcomes = Vec::new();
        for envelope in &envelopes {
            let result = match envelope["error"].as_str() {
                Some("networkConnectionLost") => Err(TransportError::Offline {
                    message: "The network connection was lost.".into(),
                }),
                Some("cancelled") => Err(TransportError::Cancelled),
                Some(other) => panic!("unknown transport error {other}"),
                None => {
                    if envelope.get("response_url").is_some() {
                        // The host contract forbids following redirects, so a response from
                        // another URL cannot reach the core; the redirect itself is uncertain.
                        reply(302, &Value::String(String::new()))
                    } else {
                        let status = u16::try_from(envelope["status"].as_u64().unwrap()).unwrap();
                        reply(status, &envelope["response"])
                    }
                }
            };
            let error = target.response(&file, result).unwrap_err();
            assert!(error.is_uncertain(), "{envelope}: {error:?}");
            outcomes.push(error);
        }
        assert_eq!(
            outcomes,
            vec![
                UploadError::Uncertain(UploadUncertainty::UnexpectedStatus { status: 500 }),
                UploadError::Uncertain(UploadUncertainty::MalformedBody {
                    message: "expected value at line 1 column 1".into()
                }),
                UploadError::Uncertain(UploadUncertainty::InvalidFileId {
                    id: "../wrong".into()
                }),
                UploadError::Uncertain(UploadUncertainty::Transport(TransportError::Offline {
                    message: "The network connection was lost.".into()
                })),
                UploadError::Uncertain(UploadUncertainty::Transport(TransportError::Cancelled)),
                UploadError::Uncertain(UploadUncertainty::Redirect { status: 302 }),
            ]
        );

        let more = [
            (
                200,
                serde_json::json!({"id": "file"}),
                UploadUncertainty::UnexpectedStatus { status: 200 },
            ),
            (
                201,
                serde_json::json!({"id": "file", "session_id": "session_b"}),
                UploadUncertainty::SessionMismatch {
                    returned: "session_b".into(),
                },
            ),
            (
                201,
                serde_json::json!({"id": "file", "metadata": {"filename": ""}}),
                UploadUncertainty::EmptyFilename,
            ),
            (
                201,
                Value::String(" ".repeat(MAX_UPLOAD_RESPONSE_BYTES + 1)),
                UploadUncertainty::BodyTooLarge {
                    len: MAX_UPLOAD_RESPONSE_BYTES + 1,
                },
            ),
        ];
        for (status, body, expected) in more {
            assert_eq!(
                target.response(&file, reply(status, &body)),
                Err(UploadError::Uncertain(expected))
            );
        }
    }

    #[test]
    fn rejected_upload_can_be_reported_without_sending_transcript_message() {
        let envelopes = fixture_lines(
            "LocalServerUpload--RejectedUploadCanBeReportedWithoutSendingTranscriptMessage.jsonl",
        );
        let file = notes();
        let target = local();
        let errors: Vec<_> = envelopes
            .iter()
            .map(|envelope| {
                let status = u16::try_from(envelope["status"].as_u64().unwrap()).unwrap();
                target
                    .response(&file, reply(status, &envelope["response"]))
                    .unwrap_err()
            })
            .collect();
        assert_eq!(
            errors,
            vec![
                UploadError::Forbidden,
                UploadError::Rejected { status: 413 },
                UploadError::Rejected { status: 415 },
                UploadError::Unauthorized,
            ]
        );
        assert!(errors.iter().all(|error| !error.is_uncertain()));
    }

    #[test]
    fn upload_request_rejects_bad_identifiers_and_boundaries_before_sending() {
        let file =
            UploadFile::new("notes.txt", None, b"x\r\n--NativeLab-fixture--".to_vec()).unwrap();
        let mut wrong = local();
        wrong.session_id = "../wrong".into();
        assert_eq!(
            wrong.request(&notes(), BOUNDARY),
            Err(UploadError::InvalidIdentifier {
                value: "../wrong".into()
            })
        );
        for boundary in [
            "",
            "has space",
            "crlf\r\n",
            &"b".repeat(MAX_BOUNDARY_LEN + 1),
        ] {
            assert!(matches!(
                local().request(&notes(), boundary),
                Err(UploadError::InvalidBoundary { .. })
            ));
        }
        assert_eq!(
            local().request(&file, BOUNDARY),
            Err(UploadError::BoundaryInBody)
        );
        assert!(local().request(&file, "other-boundary").is_ok());

        let mounted = target(
            "https://h.example.com/api/2.0/omnigent/?o=123#x",
            Some("alice"),
        );
        assert_eq!(
            mounted.request(&notes(), BOUNDARY).unwrap().url,
            "https://h.example.com/api/2.0/omnigent/v1/sessions/session_a/resources/files"
        );
    }

    #[test]
    fn attachment_references_stay_within_mount_and_identity() {
        let fixture = fixture_json(
            "HostedServerAuthentication--AttachmentReferencesStayWithinMountAndIdentity.json",
        );
        let server = format!(
            "{}{}",
            with_port(fixture["server_root"].as_str().unwrap(), "8443"),
            fixture["mount"].as_str().unwrap()
        );
        let session = fixture["session_id"].as_str().unwrap();
        let expected = fixture["expected_file_id"].as_str().unwrap();
        let base = Url::parse(&server).unwrap();
        let resolve = |reference: &str| {
            crate::attachments::attachment_file_id(&base, None, Some(reference), session)
        };
        for reference in fixture["accepted"].as_array().unwrap() {
            let reference = with_port(reference.as_str().unwrap(), "8443");
            assert_eq!(
                resolve(&reference).as_deref(),
                Some(expected),
                "{reference}"
            );
        }
        for reference in fixture["rejected"].as_array().unwrap() {
            let reference = with_port(reference.as_str().unwrap(), "8443");
            assert_eq!(resolve(&reference), None, "{reference}");
        }

        let hosted = UploadTarget {
            server_url: base.clone(),
            session_id: session.into(),
            user_id: Some("alice".into()),
        };
        for case in fixture["identity_cases"].as_array().unwrap() {
            let attachment = UploadedAttachment {
                server_url: base.clone(),
                user_id: case["user_id"].as_str().map(str::to_owned),
                session_id: session.into(),
                id: expected.into(),
                filename: "example.txt".into(),
                is_image: false,
            };
            assert_eq!(
                hosted.validate_message_attachments(&[attachment], false),
                Err(UploadError::WrongSession),
                "{case}"
            );
        }
    }

    #[test]
    fn message_attachments_must_match_session_server_and_account() {
        let target = local();
        let attachment = UploadedAttachment {
            server_url: target.server_url.clone(),
            user_id: None,
            session_id: "session_a".into(),
            id: "file_x".into(),
            filename: "notes.txt".into(),
            is_image: false,
        };
        assert_eq!(
            target.validate_message_attachments(std::slice::from_ref(&attachment), true),
            Ok(())
        );
        let other_session = UploadedAttachment {
            session_id: "session_b".into(),
            ..attachment.clone()
        };
        let other_server = UploadedAttachment {
            server_url: Url::parse("http://127.0.0.1:1").unwrap(),
            ..attachment.clone()
        };
        for wrong in [other_session, other_server] {
            assert_eq!(
                target.validate_message_attachments(&[wrong], true),
                Err(UploadError::WrongSession)
            );
        }
        let bad_id = UploadedAttachment {
            id: "../file".into(),
            ..attachment.clone()
        };
        assert!(matches!(
            target.validate_message_attachments(&[bad_id], true),
            Err(UploadError::InvalidIdentifier { .. })
        ));
        let many = vec![attachment; MAX_FILES_PER_DRAFT + 1];
        assert_eq!(
            target.validate_message_attachments(&many, true),
            Err(UploadError::TooManyAttachments {
                count: MAX_FILES_PER_DRAFT + 1
            })
        );
    }
}
