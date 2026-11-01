//! File content: decoding the server's capped JSON envelope, binary and image detection, and
//! the preview a viewer shows.
//!
//! `GET .../filesystem/{path}` answers `{object: "session.environment.filesystem.file_content",
//! path, content_type, bytes, truncated, encoding, content}`:
//!
//! - `encoding: "utf-8"`: `content` is the text;
//! - `encoding: "base64"`: `content` is the raw bytes, base64 (the file is not UTF-8);
//! - `bytes` is the size of what was returned, capped at the server's 10 MiB read limit, and
//!   `truncated` says the file is longer.
//!
//! `content_type` comes from Python's `mimetypes` on the runner host, so it is host-dependent
//! (`.rs` maps to `application/rls-services+xml` on macOS). Images are therefore recognized by
//! their magic bytes, and syntax by the file extension.

use base64::Engine as _;
use serde_json::Value;

use super::error::WorkspaceError;
use super::path::WorkspacePath;
use crate::client::json::{as_object, opt_bool, opt_str, opt_u64, req_str};

/// The server's read cap: larger files arrive truncated.
pub const SERVER_READ_CAP_BYTES: u64 = 10 * 1024 * 1024;

/// How much of a file the server returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileBody {
    /// UTF-8 text.
    Text(String),
    /// Bytes that are not UTF-8.
    Binary(Vec<u8>),
}

/// A file read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileContent {
    /// Environment-root-relative path.
    pub path: WorkspacePath,
    /// The runner's MIME guess. Host-dependent; see the module documentation.
    pub content_type: Option<String>,
    /// Bytes returned.
    pub byte_count: u64,
    /// The file is longer than what was returned.
    pub truncated: bool,
    /// The content.
    pub body: FileBody,
}

/// Limits for what a viewer renders as text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreviewLimits {
    /// Text beyond this many UTF-8 bytes is clipped at a line boundary.
    pub max_text_bytes: u64,
    /// Text beyond this many lines is clipped.
    pub max_text_lines: u64,
    /// Lines longer than this many bytes are not syntax highlighted (minified files).
    pub max_highlight_line_bytes: u64,
}

impl Default for PreviewLimits {
    fn default() -> Self {
        Self {
            max_text_bytes: 4 * 1024 * 1024,
            max_text_lines: 50_000,
            max_highlight_line_bytes: 2_000,
        }
    }
}

/// Line terminators found in a text file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineEnding {
    /// `\n` only, or no line break at all.
    Lf,
    /// `\r\n` only.
    CrLf,
    /// Both.
    Mixed,
}

/// Recognized raster image formats.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    /// PNG.
    Png,
    /// JPEG.
    Jpeg,
    /// GIF.
    Gif,
    /// WebP.
    Webp,
    /// BMP.
    Bmp,
    /// TIFF.
    Tiff,
    /// HEIC or HEIF.
    Heic,
    /// ICO.
    Ico,
}

impl ImageFormat {
    /// The MIME type.
    #[must_use]
    pub const fn mime_type(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
            Self::Gif => "image/gif",
            Self::Webp => "image/webp",
            Self::Bmp => "image/bmp",
            Self::Tiff => "image/tiff",
            Self::Heic => "image/heic",
            Self::Ico => "image/x-icon",
        }
    }

    /// The format of `bytes`, by magic number.
    #[must_use]
    pub fn sniff(bytes: &[u8]) -> Option<Self> {
        let starts = |prefix: &[u8]| bytes.starts_with(prefix);
        if starts(b"\x89PNG\r\n\x1a\n") {
            Some(Self::Png)
        } else if starts(&[0xFF, 0xD8, 0xFF]) {
            Some(Self::Jpeg)
        } else if starts(b"GIF87a") || starts(b"GIF89a") {
            Some(Self::Gif)
        } else if starts(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
            Some(Self::Webp)
        } else if starts(b"BM") && bytes.len() > 14 {
            Some(Self::Bmp)
        } else if starts(b"II*\0") || starts(b"MM\0*") {
            Some(Self::Tiff)
        } else if bytes.get(4..8) == Some(b"ftyp")
            && bytes
                .get(8..12)
                .is_some_and(|brand| [&b"heic"[..], b"heix", b"mif1", b"msf1"].contains(&brand))
        {
            Some(Self::Heic)
        } else if starts(&[0, 0, 1, 0]) && bytes.len() > 6 {
            Some(Self::Ico)
        } else {
            None
        }
    }
}

/// A syntax-highlighting hint, from the file name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[allow(missing_docs, reason = "variant names are the language names")]
pub enum SyntaxLanguage {
    Bash,
    C,
    Cpp,
    CSharp,
    Css,
    Dockerfile,
    Go,
    Html,
    Java,
    JavaScript,
    Json,
    Kotlin,
    Makefile,
    Markdown,
    ObjectiveC,
    Php,
    Python,
    Ruby,
    Rust,
    Scala,
    Sql,
    Swift,
    Toml,
    TypeScript,
    Xml,
    Yaml,
}

impl SyntaxLanguage {
    /// The language of `path`, by extension or well-known file name.
    #[must_use]
    pub fn detect(path: &WorkspacePath) -> Option<Self> {
        let name = path.name();
        match name {
            "Dockerfile" | "Containerfile" => return Some(Self::Dockerfile),
            "Makefile" | "GNUmakefile" | "justfile" => return Some(Self::Makefile),
            "Gemfile" | "Rakefile" => return Some(Self::Ruby),
            "Package.swift" => return Some(Self::Swift),
            ".bashrc" | ".zshrc" | ".profile" => return Some(Self::Bash),
            _ => {}
        }
        let extension = path.extension()?.to_ascii_lowercase();
        Some(match extension.as_str() {
            "sh" | "bash" | "zsh" | "fish" => Self::Bash,
            "c" | "h" => Self::C,
            "cc" | "cpp" | "cxx" | "hpp" | "hh" | "hxx" => Self::Cpp,
            "cs" => Self::CSharp,
            "css" | "scss" | "less" => Self::Css,
            "go" => Self::Go,
            "html" | "htm" => Self::Html,
            "java" => Self::Java,
            "js" | "mjs" | "cjs" | "jsx" => Self::JavaScript,
            "json" | "jsonl" | "jsonc" => Self::Json,
            "kt" | "kts" => Self::Kotlin,
            "md" | "markdown" | "mdx" => Self::Markdown,
            "m" | "mm" => Self::ObjectiveC,
            "php" => Self::Php,
            "py" | "pyi" => Self::Python,
            "rb" => Self::Ruby,
            "rs" => Self::Rust,
            "scala" | "sc" => Self::Scala,
            "sql" => Self::Sql,
            "swift" => Self::Swift,
            "toml" => Self::Toml,
            "ts" | "tsx" | "mts" | "cts" => Self::TypeScript,
            "xml" | "plist" | "svg" | "xib" | "storyboard" | "entitlements" => Self::Xml,
            "yaml" | "yml" => Self::Yaml,
            _ => return None,
        })
    }
}

/// Why a file is not shown as text or an image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinaryReason {
    /// The bytes are not UTF-8.
    NotText,
    /// The text contains NUL bytes, as binary files do.
    NulBytes,
    /// An image the server truncated, which cannot be decoded.
    TruncatedImage,
}

/// What a viewer shows for a file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FilePreview {
    /// Text, possibly clipped.
    Text(TextPreview),
    /// A complete image.
    Image {
        /// The format, by magic number.
        format: ImageFormat,
        /// The image bytes.
        bytes: Vec<u8>,
    },
    /// Neither; offer to open or download it.
    Binary {
        /// Why.
        reason: BinaryReason,
        /// Bytes returned.
        byte_count: u64,
    },
}

/// Text ready for a monospaced viewer.
#[allow(
    clippy::struct_excessive_bools,
    reason = "independent facts a viewer shows; mirrored one to one as an FFI record"
)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextPreview {
    /// The text shown, without a byte-order mark.
    pub text: String,
    /// Lines in [`TextPreview::text`].
    pub line_count: u64,
    /// Line terminators in the shown text.
    pub line_ending: LineEnding,
    /// The file started with a UTF-8 byte-order mark.
    pub has_bom: bool,
    /// The highlighting hint.
    pub language: Option<SyntaxLanguage>,
    /// Highlighting should be skipped (a line is longer than the limit).
    pub skip_highlighting: bool,
    /// This client cut the text at [`PreviewLimits`].
    pub clipped: bool,
    /// The server returned only part of the file.
    pub server_truncated: bool,
}

impl FileContent {
    /// What a viewer should show under `limits`.
    #[must_use]
    pub fn preview(&self, limits: &PreviewLimits) -> FilePreview {
        match &self.body {
            FileBody::Binary(bytes) => match ImageFormat::sniff(bytes) {
                Some(_) if self.truncated => FilePreview::Binary {
                    reason: BinaryReason::TruncatedImage,
                    byte_count: self.byte_count,
                },
                Some(format) => FilePreview::Image {
                    format,
                    bytes: bytes.clone(),
                },
                None => FilePreview::Binary {
                    reason: BinaryReason::NotText,
                    byte_count: self.byte_count,
                },
            },
            FileBody::Text(text) if looks_binary(text) => FilePreview::Binary {
                reason: BinaryReason::NulBytes,
                byte_count: self.byte_count,
            },
            FileBody::Text(text) => FilePreview::Text(self.text_preview(text, limits)),
        }
    }

    fn text_preview(&self, text: &str, limits: &PreviewLimits) -> TextPreview {
        let (text, has_bom) = text
            .strip_prefix('\u{feff}')
            .map_or((text, false), |rest| (rest, true));
        let (shown, clipped) = clip(text, limits);
        let skip_highlighting = shown.split('\n').any(|line| {
            u64::try_from(line.len()).unwrap_or(u64::MAX) > limits.max_highlight_line_bytes
        });
        TextPreview {
            line_count: line_count(shown),
            line_ending: line_ending(shown),
            text: shown.to_owned(),
            has_bom,
            language: SyntaxLanguage::detect(&self.path),
            skip_highlighting,
            clipped,
            server_truncated: self.truncated,
        }
    }
}

/// Git's heuristic: a NUL in the first 8000 bytes.
fn looks_binary(text: &str) -> bool {
    text.bytes().take(8000).any(|byte| byte == 0)
}

/// `text` cut to the limits at a line boundary (or a character boundary for one huge line).
fn clip<'a>(text: &'a str, limits: &PreviewLimits) -> (&'a str, bool) {
    let max_bytes = usize::try_from(limits.max_text_bytes).unwrap_or(usize::MAX);
    let max_lines = usize::try_from(limits.max_text_lines).unwrap_or(usize::MAX);
    let mut end = text
        .match_indices('\n')
        .nth(max_lines.saturating_sub(1))
        .map_or(text.len(), |(index, _)| index + 1);
    if end > max_bytes {
        let mut boundary = max_bytes;
        while !text.is_char_boundary(boundary) {
            boundary -= 1;
        }
        let head = text.get(..boundary).unwrap_or_default();
        end = head.rfind('\n').map_or(boundary, |index| index + 1);
    }
    if end >= text.len() {
        (text, false)
    } else {
        (text.get(..end).unwrap_or(text), true)
    }
}

/// Lines in `text`: a final line without a terminator counts; an empty text has none.
#[must_use]
pub fn line_count(text: &str) -> u64 {
    let breaks = u64::try_from(text.matches('\n').count()).unwrap_or(u64::MAX);
    if text.is_empty() || text.ends_with('\n') {
        breaks
    } else {
        breaks + 1
    }
}

fn line_ending(text: &str) -> LineEnding {
    let total = text.matches('\n').count();
    let crlf = text.matches("\r\n").count();
    match (crlf, total) {
        (0, _) => LineEnding::Lf,
        (crlf, total) if crlf == total => LineEnding::CrLf,
        _ => LineEnding::Mixed,
    }
}

pub(super) fn file_content(
    value: &Value,
    requested: &WorkspacePath,
) -> Result<FileContent, WorkspaceError> {
    let context = "file content";
    let object = as_object(value, context).map_err(|e| WorkspaceError::malformed(context, e))?;
    let kind = opt_str(object, "object").map_err(|e| WorkspaceError::malformed(context, e))?;
    if kind.as_deref() == Some("list") {
        return Err(WorkspaceError::UnexpectedKind {
            path: requested.to_string(),
            expected: "file",
            actual: "directory",
        });
    }
    let decode = || -> Result<FileContent, String> {
        let encoding = req_str(object, "encoding")?;
        let payload = req_str(object, "content")?;
        let body = match encoding.to_ascii_lowercase().as_str() {
            "utf-8" | "utf8" => FileBody::Text(payload),
            "base64" => FileBody::Binary(
                base64::engine::general_purpose::STANDARD
                    .decode(payload.as_bytes())
                    .map_err(|error| format!("`content` is not base64: {error}"))?,
            ),
            other => return Err(format!("unsupported encoding {other:?}")),
        };
        let actual = match &body {
            FileBody::Text(text) => text.len(),
            FileBody::Binary(bytes) => bytes.len(),
        };
        Ok(FileContent {
            path: requested.clone(),
            content_type: opt_str(object, "content_type")?,
            byte_count: opt_u64(object, "bytes")?
                .unwrap_or_else(|| u64::try_from(actual).unwrap_or(u64::MAX)),
            truncated: opt_bool(object, "truncated")?.unwrap_or(false),
            body,
        })
    };
    decode().map_err(|error| WorkspaceError::malformed(context, error))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_file(path: &str, text: &str, truncated: bool) -> FileContent {
        FileContent {
            path: WorkspacePath::parse(path).unwrap(),
            content_type: None,
            byte_count: u64::try_from(text.len()).unwrap(),
            truncated,
            body: FileBody::Text(text.to_owned()),
        }
    }

    fn text(preview: FilePreview) -> TextPreview {
        match preview {
            FilePreview::Text(text) => text,
            other => panic!("expected text, got {other:?}"),
        }
    }

    #[test]
    fn line_counting_and_endings() {
        assert_eq!(line_count(""), 0);
        assert_eq!(line_count("a"), 1);
        assert_eq!(line_count("a\n"), 1);
        assert_eq!(line_count("a\nb"), 2);
        assert_eq!(line_count("\n\n"), 2);
        assert_eq!(line_ending("a\nb\n"), LineEnding::Lf);
        assert_eq!(line_ending("a\r\nb\r\n"), LineEnding::CrLf);
        assert_eq!(line_ending("a\r\nb\n"), LineEnding::Mixed);
    }

    #[test]
    fn text_is_clipped_at_line_boundaries() {
        let limits = PreviewLimits {
            max_text_bytes: 10,
            max_text_lines: 3,
            max_highlight_line_bytes: 4,
        };
        let preview = text(text_file("a.rs", "1\n2\n3\n4\n", false).preview(&limits));
        assert_eq!(preview.text, "1\n2\n3\n");
        assert!(preview.clipped);
        assert_eq!(preview.line_count, 3);
        assert_eq!(preview.language, Some(SyntaxLanguage::Rust));

        let preview = text(text_file("a.txt", "aaaa\nbbbb\ncccc\n", true).preview(&limits));
        assert_eq!(
            preview.text, "aaaa\nbbbb\n",
            "ten bytes end on a line break"
        );
        assert!(preview.clipped && preview.server_truncated);
        assert_eq!(preview.language, None);

        let preview = text(text_file("a.txt", "ééééééééé", false).preview(&limits));
        assert_eq!(
            preview.text, "ééééé",
            "one huge line is cut on a char boundary"
        );
        assert!(preview.skip_highlighting);

        let preview = text(text_file("a.txt", "\u{feff}hi\r\n", false).preview(&limits));
        assert_eq!(preview.text, "hi\r\n");
        assert!(preview.has_bom && !preview.clipped);
        assert_eq!(preview.line_ending, LineEnding::CrLf);
    }

    #[test]
    fn binary_detection() {
        assert_eq!(
            text_file("a.bin", "ab\0cd", false).preview(&PreviewLimits::default()),
            FilePreview::Binary {
                reason: BinaryReason::NulBytes,
                byte_count: 5
            }
        );
        let png = b"\x89PNG\r\n\x1a\n rest".to_vec();
        let mut content = FileContent {
            path: WorkspacePath::parse("logo.dat").unwrap(),
            content_type: Some("application/octet-stream".into()),
            byte_count: 14,
            truncated: false,
            body: FileBody::Binary(png.clone()),
        };
        assert_eq!(
            content.preview(&PreviewLimits::default()),
            FilePreview::Image {
                format: ImageFormat::Png,
                bytes: png
            }
        );
        content.truncated = true;
        assert!(matches!(
            content.preview(&PreviewLimits::default()),
            FilePreview::Binary {
                reason: BinaryReason::TruncatedImage,
                ..
            }
        ));
        content.body = FileBody::Binary(vec![1, 2, 3]);
        assert!(matches!(
            content.preview(&PreviewLimits::default()),
            FilePreview::Binary {
                reason: BinaryReason::NotText,
                ..
            }
        ));
        assert_eq!(ImageFormat::sniff(b"GIF89a...."), Some(ImageFormat::Gif));
        assert_eq!(
            ImageFormat::sniff(&[0xFF, 0xD8, 0xFF, 0xE0]),
            Some(ImageFormat::Jpeg)
        );
        assert_eq!(
            ImageFormat::sniff(b"RIFF\0\0\0\0WEBPVP8 "),
            Some(ImageFormat::Webp)
        );
        assert_eq!(
            ImageFormat::sniff(b"\0\0\0\x18ftypheic\0\0"),
            Some(ImageFormat::Heic)
        );
        assert_eq!(ImageFormat::sniff(b"BM"), None);
    }

    #[test]
    fn languages_by_name_and_extension() {
        let detect = |raw: &str| SyntaxLanguage::detect(&WorkspacePath::parse(raw).unwrap());
        assert_eq!(detect("Dockerfile"), Some(SyntaxLanguage::Dockerfile));
        assert_eq!(detect("App/Package.swift"), Some(SyntaxLanguage::Swift));
        assert_eq!(detect("web/x.TSX"), Some(SyntaxLanguage::TypeScript));
        assert_eq!(detect("notes.txt"), None);
        assert_eq!(detect(".gitignore"), None);
    }
}
