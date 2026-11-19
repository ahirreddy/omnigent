//! Raw downloads of a workspace file (`GET …/filesystem/{path}?download=true`).
//!
//! As the web's Download button and video player read them: the whole file with no size cap,
//! or one byte range (`Range: bytes=a-b`, answered `206` with `Content-Range`). Ground truth:
//! the server's `_stream_download_from_runner` and the runner's `_fs_download`, which always
//! send `Content-Disposition: attachment` with the bytes.

use super::error::{NotFoundMeaning, WorkspaceError, check};
use super::path::WorkspacePath;
use crate::http::HttpResponse;

/// Bytes `offset..offset + length` of a file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ByteRange {
    /// The first byte.
    pub offset: u64,
    /// How many bytes, at least one.
    pub length: u64,
}

impl ByteRange {
    /// The `Range` header value, `bytes=<first>-<last>` (both inclusive).
    #[must_use]
    pub fn header_value(&self) -> String {
        let last = self.offset.saturating_add(self.length.saturating_sub(1));
        format!("bytes={}-{last}", self.offset)
    }
}

/// What a download returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDownload {
    /// Environment-root-relative path.
    pub path: WorkspacePath,
    /// The runner's MIME guess for the file's name.
    pub content_type: Option<String>,
    /// Where [`FileDownload::bytes`] start in the file: the range's start, or 0 for the whole
    /// file (also when the server ignored the range).
    pub offset: u64,
    /// The file's size, when the server said: the `Content-Range` total, or the whole body.
    pub total_length: Option<u64>,
    /// The bytes.
    pub bytes: Vec<u8>,
}

/// The `first`, `last` and total of `Content-Range: bytes <first>-<last>/<total|*>`.
fn content_range(value: &str) -> Option<(u64, u64, Option<u64>)> {
    let (unit, rest) = value.trim().split_once(' ')?;
    if !unit.eq_ignore_ascii_case("bytes") {
        return None;
    }
    let (span, total) = rest.split_once('/')?;
    let (first, last) = span.split_once('-')?;
    let first = first.trim().parse().ok()?;
    let last = last.trim().parse().ok()?;
    let total = match total.trim() {
        "*" => None,
        total => Some(total.parse().ok()?),
    };
    (first <= last && total.is_none_or(|total| last < total)).then_some((first, last, total))
}

/// Decodes the answer to a download of `requested`.
pub(super) fn file_download(
    response: &HttpResponse,
    requested: &WorkspacePath,
) -> Result<FileDownload, WorkspaceError> {
    let context = "the file download";
    let malformed = |detail: String| WorkspaceError::malformed(context, detail);
    let status = response.status;
    if status == 416 {
        return Err(WorkspaceError::Rejected {
            status,
            code: None,
            message: format!("The requested part of {requested} is past its end."),
        });
    }
    if status != 200 && status != 206 {
        check(response, NotFoundMeaning::Path, requested.as_str(), context)?;
        return Err(malformed(format!("unexpected status {status}")));
    }
    if response.header("content-disposition").is_none() {
        // A server that predates downloads answers the capped JSON envelope instead.
        return Err(WorkspaceError::Server {
            status,
            code: None,
            message: "This server cannot download whole files. Update it and try again.".into(),
        });
    }
    let length = u64::try_from(response.body.len()).unwrap_or(u64::MAX);
    let (offset, total_length) = if status == 206 {
        let header = response
            .header("content-range")
            .ok_or_else(|| malformed("a 206 response without Content-Range".into()))?;
        let (first, last, total) = content_range(header)
            .ok_or_else(|| malformed(format!("unreadable Content-Range {header:?}")))?;
        if last.checked_sub(first).and_then(|span| span.checked_add(1)) != Some(length) {
            return Err(malformed(format!(
                "Content-Range {header:?} does not match the {length} bytes sent"
            )));
        }
        (first, total)
    } else {
        (0, Some(length))
    };
    Ok(FileDownload {
        path: requested.clone(),
        content_type: response.header("content-type").map(str::to_owned),
        offset,
        total_length,
        bytes: response.body.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::{ByteRange, content_range, file_download};
    use crate::http::{HttpHeader, HttpResponse};
    use crate::workspace::{WorkspaceError, WorkspacePath};

    fn response(status: u16, headers: &[(&str, &str)], body: &[u8]) -> HttpResponse {
        HttpResponse {
            status,
            headers: headers
                .iter()
                .map(|(name, value)| HttpHeader::new(*name, *value))
                .collect(),
            body: body.to_vec(),
        }
    }

    fn path() -> WorkspacePath {
        WorkspacePath::parse("rec/demo.mp4").unwrap()
    }

    const ATTACHMENT: (&str, &str) = ("Content-Disposition", "attachment; filename=\"demo.mp4\"");

    #[test]
    fn a_range_asks_for_its_inclusive_bytes() {
        let range = ByteRange {
            offset: 10,
            length: 5,
        };
        assert_eq!(range.header_value(), "bytes=10-14");
        let first = ByteRange {
            offset: 0,
            length: 2,
        };
        assert_eq!(first.header_value(), "bytes=0-1");
    }

    #[test]
    fn content_range_reads_the_span_and_total() {
        assert_eq!(content_range("bytes 0-1/10"), Some((0, 1, Some(10))));
        assert_eq!(content_range("bytes 4-9/*"), Some((4, 9, None)));
        assert_eq!(content_range("bytes 9-4/10"), None);
        assert_eq!(content_range("bytes 0-10/10"), None);
        assert_eq!(content_range("items 0-1/2"), None);
        assert_eq!(content_range("bytes */10"), None);
    }

    #[test]
    fn a_whole_file_and_a_range_decode_with_their_place() {
        let whole = file_download(
            &response(200, &[ATTACHMENT, ("Content-Type", "video/mp4")], b"abcdef"),
            &path(),
        )
        .unwrap();
        assert_eq!(
            (whole.offset, whole.total_length, whole.bytes.as_slice()),
            (0, Some(6), &b"abcdef"[..])
        );
        assert_eq!(whole.content_type.as_deref(), Some("video/mp4"));
        let part = file_download(
            &response(206, &[ATTACHMENT, ("Content-Range", "bytes 2-4/6")], b"cde"),
            &path(),
        )
        .unwrap();
        assert_eq!((part.offset, part.total_length), (2, Some(6)));
    }

    #[test]
    fn a_range_that_disagrees_with_its_body_or_runs_past_the_end_fails() {
        let short = file_download(
            &response(206, &[ATTACHMENT, ("Content-Range", "bytes 2-4/6")], b"cd"),
            &path(),
        );
        assert!(matches!(
            short,
            Err(WorkspaceError::MalformedResponse { .. })
        ));
        let past = file_download(
            &response(416, &[("Content-Range", "bytes */6")], b""),
            &path(),
        );
        assert!(matches!(
            past,
            Err(WorkspaceError::Rejected { status: 416, .. })
        ));
    }

    #[test]
    fn an_envelope_without_an_attachment_is_not_taken_for_the_file() {
        let envelope = file_download(
            &response(200, &[("Content-Type", "application/json")], b"{}"),
            &path(),
        );
        assert!(matches!(
            envelope,
            Err(WorkspaceError::Server { status: 200, .. })
        ));
    }

    #[test]
    fn errors_keep_the_workspace_status_policy() {
        let missing = file_download(
            &response(
                404,
                &[],
                br#"{"error": {"code": "not_found", "message": "No such file"}}"#,
            ),
            &path(),
        );
        assert!(matches!(missing, Err(WorkspaceError::NotFound { .. })));
        let offline = file_download(
            &response(
                503,
                &[],
                br#"{"error": {"code": "runner_unavailable", "message": "Session runner does not support file downloads; restart the session"}}"#,
            ),
            &path(),
        );
        assert!(matches!(offline, Err(WorkspaceError::RunnerOffline { .. })));
    }
}
