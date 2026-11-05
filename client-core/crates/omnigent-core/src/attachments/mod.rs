//! Attachment drafts and upload validation.
//!
//! - [`policy`]: which files may be attached (filename, media type, size caps) and bounded reads.
//! - [`draft`]: per-session drafts, upload state and send batches.
//! - [`upload`]: the multipart upload request and its response mapping.
//! - [`preview`]: resolving attachment references and reading attachments back.
//!
//! Everything is sans-IO: requests come back as [`crate::http::HttpRequest`] values and responses
//! go in as [`crate::http::HttpResponse`] values. Authentication and scope headers are the session
//! client's job.

pub mod draft;
pub mod policy;
pub mod preview;
pub mod upload;

use url::Url;

pub use draft::{
    AttachmentDraft, AttachmentDraftStore, AttachmentSubmission, DraftError, DraftItem,
    DraftItemId, DraftKey, HoldId, UploadAttempt, UploadState,
};
pub use policy::{FileProbe, UploadFile, UploadFileReader, byte_limit, resolve_media_type};
pub use preview::{
    AttachmentPreview, PreviewError, attachment_file_id, preview_extension, preview_from_response,
    preview_request,
};
pub use upload::{UploadError, UploadTarget, UploadUncertainty, UploadedAttachment};

/// Why a file cannot be attached.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AttachmentError {
    /// Not an image, PDF, or text/code file, or the declared media type is unsafe.
    #[error("attach an image, PDF, or text/code file")]
    UnsupportedType,
    /// Empty, over-long, path-like, or containing control or format characters.
    #[error("this file needs a valid filename before it can be attached")]
    InvalidFilename,
    /// A folder, link or other non-regular file.
    #[error("choose a file rather than a folder or link")]
    NotRegularFile,
    /// Over the media type's cap.
    #[error("this file exceeds the {} MB upload limit", limit / 1024 / 1024)]
    TooLarge {
        /// The cap in bytes.
        limit: usize,
    },
}

/// `<scheme>://<host>[:port]` of `url` (default port omitted), or `None` without a host.
fn origin_of(url: &Url) -> Option<String> {
    url.has_host().then(|| url.origin().ascii_serialization())
}

/// `<base>/v1/sessions/<session_id>/<segments...>`, keeping the base's mount path and dropping its
/// query and fragment. Callers validate every segment as an identifier first.
fn session_resource_url(base: &Url, session_id: &str, segments: &[&str]) -> Url {
    let mut url = base.clone();
    let mut path = format!(
        "{}/v1/sessions/{session_id}",
        base.path().trim_end_matches('/')
    );
    for segment in segments {
        path.push('/');
        path.push_str(segment);
    }
    url.set_path(&path);
    url.set_query(None);
    url.set_fragment(None);
    url
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    fn path(name: &str) -> String {
        format!(
            "{}/../../fixtures/attachments/{name}",
            env!("CARGO_MANIFEST_DIR")
        )
    }

    /// `template` with the fixtures' `{port}` placeholder replaced.
    #[allow(
        clippy::literal_string_with_formatting_args,
        reason = "the fixtures spell the placeholder this way"
    )]
    pub(super) fn with_port(template: &str, port: &str) -> String {
        template.replace("{port}", port)
    }

    /// One JSON fixture from `fixtures/attachments/`.
    pub(super) fn fixture_json(name: &str) -> Value {
        let path = path(name);
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("reading {path}: {error}"));
        serde_json::from_str(&text).unwrap_or_else(|error| panic!("parsing {path}: {error}"))
    }

    /// Every line of a JSONL fixture from `fixtures/attachments/`.
    pub(super) fn fixture_lines(name: &str) -> Vec<Value> {
        let path = path(name);
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("reading {path}: {error}"));
        text.lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                serde_json::from_str(line).unwrap_or_else(|error| panic!("parsing {path}: {error}"))
            })
            .collect()
    }
}
