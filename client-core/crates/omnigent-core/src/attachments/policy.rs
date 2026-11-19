//! What may be attached: filename and media-type validation, size caps, and bounded file reads.
//!
//! Archives, Office documents and databases go to the agent as files under the server's
//! `filesystem_attachments` policy (the web's `classifyAttachment`).

use serde_json::Value;

use super::AttachmentError;

/// One MiB.
const MIB: usize = 1024 * 1024;

/// Most files one draft may hold.
pub const MAX_FILES_PER_DRAFT: usize = 8;
/// Most bytes one draft may hold: one file delivered as a file at its cap.
pub const MAX_DRAFT_BYTES: usize = 50 * MIB;
/// Most bytes all drafts together may hold.
pub const MAX_STORED_BYTES: usize = 100 * MIB;
/// Cap for `image/*` files.
pub const MAX_IMAGE_BYTES: usize = 5 * MIB;
/// Cap for PDFs.
pub const MAX_PDF_BYTES: usize = 20 * MIB;
/// Cap for text and code files.
pub const MAX_TEXT_BYTES: usize = 10 * MIB;
/// Cap for a file the agent opens with its filesystem tools (the server's
/// `MAX_FILESYSTEM_ATTACHMENT_UPLOAD_BYTES`).
pub const MAX_FILESYSTEM_BYTES: usize = 50 * MIB;
/// The media type a file delivered as a file uploads with; the server types it by extension.
pub const FILESYSTEM_MEDIA_TYPE: &str = "application/octet-stream";
/// Extensions delivered as files when the server reports no policy (the server's
/// `DEFAULT_FILESYSTEM_ATTACHMENT_EXTENSIONS`).
pub const DEFAULT_FILESYSTEM_EXTENSIONS: &[&str] = &[
    ".zip", ".docx", ".xlsx", ".pptx", ".db", ".sqlite", ".sqlite3",
];

/// Which uploads the server delivers to the agent as files (`/v1/info.filesystem_attachments`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilesystemAttachments {
    /// Lowercase extensions with their dot, such as `.zip`, always delivered as files.
    pub extensions: Vec<String>,
    /// Every other file that cannot be inlined is delivered as a file too.
    pub all_types: bool,
}

impl Default for FilesystemAttachments {
    fn default() -> Self {
        Self {
            extensions: DEFAULT_FILESYSTEM_EXTENSIONS
                .iter()
                .map(|extension| (*extension).to_owned())
                .collect(),
            all_types: false,
        }
    }
}

impl FilesystemAttachments {
    /// The policy a `/v1/info` body reports; older servers, which send none (or an unreadable
    /// one), get the default extensions, as on the web.
    #[must_use]
    pub fn from_info(info: &Value) -> Self {
        let Some(policy) = info
            .get("filesystem_attachments")
            .and_then(Value::as_object)
        else {
            return Self::default();
        };
        let Some(extensions) = policy.get("extensions").and_then(Value::as_array) else {
            return Self::default();
        };
        Self {
            extensions: extensions
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect(),
            all_types: policy.get("all_types").and_then(Value::as_bool) == Some(true),
        }
    }

    fn delivers(&self, extension: &str) -> bool {
        self.extensions.iter().any(|listed| listed == extension)
    }

    /// The file types this policy accepts, for the refusal message (the web's
    /// `supportedAttachmentTypes`).
    #[must_use]
    pub fn supported_types(&self) -> String {
        let mut extensions = self.extensions.clone();
        extensions.sort();
        let mut defaults: Vec<&str> = DEFAULT_FILESYSTEM_EXTENSIONS.to_vec();
        defaults.sort_unstable();
        if extensions == defaults {
            "images, PDF, text/code, archives, office documents, and databases".to_owned()
        } else if extensions.is_empty() {
            "images, PDF, and text/code files".to_owned()
        } else {
            format!(
                "images, PDF, text/code, and {} files",
                extensions.join(", ")
            )
        }
    }
}
/// Longest filename, in UTF-8 bytes.
pub const MAX_FILENAME_BYTES: usize = 255;
/// Largest chunk [`UploadFileReader::next_read_len`] asks for.
pub const READ_CHUNK_BYTES: usize = 64 * 1024;

/// Extensions accepted as `text/plain` when the declared media type says nothing more specific.
pub const TEXT_EXTENSIONS: &[&str] = &[
    "txt",
    "log",
    "md",
    "markdown",
    "csv",
    "json",
    "jsonl",
    "ndjson",
    "yaml",
    "yml",
    "toml",
    "ini",
    "cfg",
    "env",
    "lock",
    "proto",
    "graphql",
    "gql",
    "html",
    "htm",
    "xml",
    "css",
    "js",
    "jsx",
    "mjs",
    "cjs",
    "ts",
    "tsx",
    "py",
    "rb",
    "go",
    "rs",
    "java",
    "kt",
    "scala",
    "swift",
    "c",
    "h",
    "cc",
    "cpp",
    "hpp",
    "cs",
    "php",
    "pl",
    "r",
    "jl",
    "lua",
    "ex",
    "exs",
    "erl",
    "hs",
    "clj",
    "dart",
    "vue",
    "svelte",
    "sh",
    "bash",
    "zsh",
    "fish",
    "sql",
    "tf",
    "hcl",
    "gradle",
    "dockerfile",
    "ipynb",
];

const IMAGE_EXTENSIONS: &[(&str, &str)] = &[
    ("png", "image/png"),
    ("jpg", "image/jpeg"),
    ("jpeg", "image/jpeg"),
    ("gif", "image/gif"),
    ("webp", "image/webp"),
    ("heic", "image/heic"),
    ("heif", "image/heif"),
    ("tif", "image/tiff"),
    ("tiff", "image/tiff"),
    ("bmp", "image/bmp"),
    ("avif", "image/avif"),
    ("svg", "image/svg+xml"),
];

const TEXT_APPLICATION_TYPES: &[&str] = &[
    "application/json",
    "application/javascript",
    "application/jsonl",
    "application/x-ndjson",
    "application/x-ipynb+json",
];

/// Unicode format characters (category Cf). Swift's `CharacterSet.controlCharacters` covers Cc and
/// Cf; Rust's `char::is_control` covers only Cc. Cf includes bidi overrides that can disguise an
/// extension, so filenames reject both.
const FORMAT_RANGES: &[(char, char)] = &[
    ('\u{00AD}', '\u{00AD}'),
    ('\u{0600}', '\u{0605}'),
    ('\u{061C}', '\u{061C}'),
    ('\u{06DD}', '\u{06DD}'),
    ('\u{070F}', '\u{070F}'),
    ('\u{0890}', '\u{0891}'),
    ('\u{08E2}', '\u{08E2}'),
    ('\u{180E}', '\u{180E}'),
    ('\u{200B}', '\u{200F}'),
    ('\u{202A}', '\u{202E}'),
    ('\u{2060}', '\u{2064}'),
    ('\u{2066}', '\u{206F}'),
    ('\u{FEFF}', '\u{FEFF}'),
    ('\u{FFF9}', '\u{FFFB}'),
    ('\u{110BD}', '\u{110BD}'),
    ('\u{110CD}', '\u{110CD}'),
    ('\u{13430}', '\u{1343F}'),
    ('\u{1BCA0}', '\u{1BCA3}'),
    ('\u{1D173}', '\u{1D17A}'),
    ('\u{E0001}', '\u{E0001}'),
    ('\u{E0020}', '\u{E007F}'),
];

fn is_control_or_format(character: char) -> bool {
    character.is_control()
        || FORMAT_RANGES
            .iter()
            .any(|(low, high)| (*low..=*high).contains(&character))
}

fn validate_filename(filename: &str) -> Result<(), AttachmentError> {
    let valid = !filename.is_empty()
        && filename.len() <= MAX_FILENAME_BYTES
        && !filename.chars().any(is_control_or_format)
        && !filename.contains('/')
        && !filename.contains('\\')
        && filename != "."
        && filename != "..";
    if valid {
        Ok(())
    } else {
        Err(AttachmentError::InvalidFilename)
    }
}

fn is_safe_media_type_byte(byte: u8) -> bool {
    byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"!#$&^_.+-/".contains(&byte)
}

/// [`resolve_media_type_under`] the default filesystem policy, as for a server that reports none.
///
/// # Errors
///
/// As [`resolve_media_type_under`].
pub fn resolve_media_type(
    filename: &str,
    declared: Option<&str>,
) -> Result<String, AttachmentError> {
    resolve_media_type_under(filename, declared, &FilesystemAttachments::default())
}

/// The media type an upload of `filename` is sent with, from its declared type (any parameters
/// such as `charset` are dropped), its extension and the server's filesystem `policy`.
///
/// An extension the policy lists is delivered as a file ([`FILESYSTEM_MEDIA_TYPE`]), whatever
/// type was declared; a default one it leaves out is refused rather than inlined. Images keep
/// their declared `image/*` type; a known image extension with no declared type (or
/// `application/octet-stream`) gets its standard type. PDFs, `text/*` and the JSON/JavaScript/
/// notebook application types are kept. Anything else with a known text or code extension is sent
/// as `text/plain`. Any other file is delivered as a file when the policy takes all types.
///
/// # Errors
///
/// [`AttachmentError::InvalidFilename`] for an empty, over-long, path-like or control-character
/// name; [`AttachmentError::UnsupportedType`] for an unsafe declared type or an unsupported file.
pub fn resolve_media_type_under(
    filename: &str,
    declared: Option<&str>,
    policy: &FilesystemAttachments,
) -> Result<String, AttachmentError> {
    validate_filename(filename)?;
    let extension = filename
        .rsplit('.')
        .next()
        .unwrap_or_default()
        .to_lowercase();
    let mime = declared
        .and_then(|value| value.split(';').next())
        .map(|value| value.trim().to_lowercase())
        .unwrap_or_default();
    let unsupported = || AttachmentError::UnsupportedType {
        filename: filename.to_owned(),
        supported: policy.supported_types(),
    };
    if !mime.bytes().all(is_safe_media_type_byte) {
        return Err(unsupported());
    }
    // The last extension, as the server matches it (`PurePath.suffix`).
    let suffix = filename
        .rfind('.')
        .filter(|&dot| dot > 0)
        .and_then(|dot| filename.get(dot..))
        .map(str::to_lowercase);
    if let Some(suffix) = &suffix {
        if policy.delivers(suffix) {
            return Ok(FILESYSTEM_MEDIA_TYPE.to_owned());
        }
        if DEFAULT_FILESYSTEM_EXTENSIONS.contains(&suffix.as_str()) {
            return Err(unsupported());
        }
    }
    if mime.starts_with("image/") {
        return Ok(mime);
    }
    if (mime.is_empty() || mime == "application/octet-stream")
        && let Some((_, image)) = IMAGE_EXTENSIONS
            .iter()
            .find(|(candidate, _)| *candidate == extension)
    {
        return Ok((*image).to_owned());
    }
    if mime == "application/pdf" || extension == "pdf" {
        return Ok("application/pdf".to_owned());
    }
    if mime.starts_with("text/") || TEXT_APPLICATION_TYPES.contains(&mime.as_str()) {
        return Ok(mime);
    }
    if TEXT_EXTENSIONS.contains(&extension.as_str()) {
        return Ok("text/plain".to_owned());
    }
    if policy.all_types {
        return Ok(FILESYSTEM_MEDIA_TYPE.to_owned());
    }
    Err(unsupported())
}

/// Largest upload accepted for `media_type`: 5 MiB for images, 20 MiB for PDFs, 50 MiB for a
/// file delivered as a file, 10 MiB otherwise.
#[must_use]
pub fn byte_limit(media_type: &str) -> usize {
    if media_type.starts_with("image/") {
        MAX_IMAGE_BYTES
    } else if media_type == "application/pdf" {
        MAX_PDF_BYTES
    } else if media_type == FILESYSTEM_MEDIA_TYPE {
        MAX_FILESYSTEM_BYTES
    } else {
        MAX_TEXT_BYTES
    }
}

/// A validated file ready to upload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadFile {
    filename: String,
    media_type: String,
    data: Vec<u8>,
}

impl UploadFile {
    /// [`Self::under`] the default filesystem policy.
    ///
    /// # Errors
    ///
    /// As [`Self::under`].
    pub fn new(
        filename: &str,
        declared_media_type: Option<&str>,
        data: Vec<u8>,
    ) -> Result<Self, AttachmentError> {
        Self::under(
            filename,
            declared_media_type,
            data,
            &FilesystemAttachments::default(),
        )
    }

    /// Validates `filename`, resolves its media type under the server's filesystem `policy`
    /// and enforces the type's size cap.
    ///
    /// # Errors
    ///
    /// See [`resolve_media_type_under`]; [`AttachmentError::TooLarge`] when `data` exceeds the
    /// cap.
    pub fn under(
        filename: &str,
        declared_media_type: Option<&str>,
        data: Vec<u8>,
        policy: &FilesystemAttachments,
    ) -> Result<Self, AttachmentError> {
        let media_type = resolve_media_type_under(filename, declared_media_type, policy)?;
        let limit = byte_limit(&media_type);
        if data.len() > limit {
            return Err(AttachmentError::TooLarge { limit });
        }
        Ok(Self {
            filename: filename.to_owned(),
            media_type,
            data,
        })
    }

    /// The filename as chosen by the user.
    #[must_use]
    pub fn filename(&self) -> &str {
        &self.filename
    }

    /// The resolved media type.
    #[must_use]
    pub fn media_type(&self) -> &str {
        &self.media_type
    }

    /// The file's bytes.
    #[must_use]
    pub fn data(&self) -> &[u8] {
        &self.data
    }

    /// Whether the file uploads as an image (`input_image` rather than `input_file`).
    #[must_use]
    pub fn is_image(&self) -> bool {
        self.media_type.starts_with("image/")
    }
}

/// What the host learned from `stat`-ing a file before reading it. Use `lstat` semantics: a
/// symlink reports `is_symlink`, not its target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileProbe {
    /// The path is a regular file.
    pub is_regular_file: bool,
    /// The path is a symbolic link.
    pub is_symlink: bool,
    /// Reported size, if the file provider knows one. It may be stale, so reads are bounded too.
    pub size: Option<u64>,
}

/// Reads a local file into an [`UploadFile`] without buffering more than its cap plus one byte.
///
/// The host stats the file, calls [`Self::begin`], then reads chunks of at most
/// [`Self::next_read_len`] bytes, passing each to [`Self::push`], until end of file or an error,
/// and finally calls [`Self::finish`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadFileReader {
    filename: String,
    media_type: String,
    limit: usize,
    data: Vec<u8>,
}

impl UploadFileReader {
    /// Validates the name, media type and probe before any bytes are read.
    ///
    /// # Errors
    ///
    /// See [`resolve_media_type`]; [`AttachmentError::NotRegularFile`] for folders, links and
    /// other non-regular files; [`AttachmentError::TooLarge`] when the reported size exceeds the
    /// cap.
    pub fn begin(
        filename: &str,
        declared_media_type: Option<&str>,
        probe: FileProbe,
    ) -> Result<Self, AttachmentError> {
        let media_type = resolve_media_type(filename, declared_media_type)?;
        let limit = byte_limit(&media_type);
        if !probe.is_regular_file || probe.is_symlink {
            return Err(AttachmentError::NotRegularFile);
        }
        let reported = probe.size.unwrap_or(0);
        if !usize::try_from(reported).is_ok_and(|size| size <= limit) {
            return Err(AttachmentError::TooLarge { limit });
        }
        Ok(Self {
            filename: filename.to_owned(),
            media_type,
            limit,
            data: Vec::new(),
        })
    }

    /// Most bytes the host should read next. Reading one byte past the cap is how an oversize
    /// file with a stale reported size is detected.
    #[must_use]
    pub fn next_read_len(&self) -> usize {
        self.limit
            .saturating_add(1)
            .saturating_sub(self.data.len())
            .min(READ_CHUNK_BYTES)
    }

    /// Appends one chunk read from the file.
    ///
    /// # Errors
    ///
    /// [`AttachmentError::TooLarge`] once the bytes read exceed the cap; stop reading then.
    pub fn push(&mut self, chunk: &[u8]) -> Result<(), AttachmentError> {
        if self.data.len().saturating_add(chunk.len()) > self.limit {
            return Err(AttachmentError::TooLarge { limit: self.limit });
        }
        self.data.extend_from_slice(chunk);
        Ok(())
    }

    /// The file read so far, after end of file.
    ///
    /// # Errors
    ///
    /// Whatever [`UploadFile::new`] reports.
    pub fn finish(self) -> Result<UploadFile, AttachmentError> {
        UploadFile::new(&self.filename, Some(&self.media_type), self.data)
    }
}

/// Whether `value` is a server identifier: non-empty ASCII letters, digits, `_` and `-`.
#[must_use]
pub fn is_identifier(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::*;
    use crate::attachments::tests::fixture_json;

    #[test]
    fn supported_types_exact_caps_and_filename_validation() {
        let fixture: Value =
            fixture_json("AttachmentDraft--SupportedTypesExactCapsAndFilenameValidation.json");
        let supported = fixture["supportedTypes"].as_array().unwrap();
        assert_eq!(supported.len(), 7);
        for case in supported {
            let filename = case["filename"].as_str().unwrap();
            let declared = case["mediaType"].as_str().unwrap();
            let limit = usize::try_from(case["limitMiB"].as_u64().unwrap()).unwrap() * MIB;
            let accepted = UploadFile::new(filename, Some(declared), vec![1; limit]).unwrap();
            assert_eq!(accepted.data().len(), limit, "{filename}");
            assert_eq!(
                UploadFile::new(filename, Some(declared), vec![1; limit + 1]),
                Err(AttachmentError::TooLarge { limit }),
                "{filename}"
            );
        }
        let filesystem_limit =
            usize::try_from(fixture["filesystemLimitMiB"].as_u64().unwrap()).unwrap() * MIB;
        for name in fixture["filesystemNames"].as_array().unwrap() {
            let name = name.as_str().unwrap();
            // A browser or picker may mislabel these; the extension decides.
            let file =
                UploadFile::new(name, Some("text/plain"), vec![1; filesystem_limit]).unwrap();
            assert_eq!(file.media_type(), FILESYSTEM_MEDIA_TYPE, "{name}");
            assert!(!file.is_image(), "{name}");
            assert_eq!(
                UploadFile::new(name, None, vec![1; filesystem_limit + 1]),
                Err(AttachmentError::TooLarge {
                    limit: filesystem_limit
                }),
                "{name}"
            );
        }
        for name in fixture["unsupportedNames"].as_array().unwrap() {
            let name = name.as_str().unwrap();
            assert!(
                matches!(
                    UploadFile::new(name, None, Vec::new()),
                    Err(AttachmentError::UnsupportedType { filename, .. }) if filename == name
                ),
                "{name}"
            );
        }
        for name in fixture["invalidNames"].as_array().unwrap() {
            let name = name.as_str().unwrap();
            assert_eq!(
                UploadFile::new(name, None, Vec::new()),
                Err(AttachmentError::InvalidFilename),
                "{name:?}"
            );
        }
        let invalid = &fixture["invalidMediaType"];
        assert!(matches!(
            UploadFile::new(
                invalid["filename"].as_str().unwrap(),
                Some(invalid["mediaType"].as_str().unwrap()),
                Vec::new()
            ),
            Err(AttachmentError::UnsupportedType { .. })
        ));
    }

    /// The policy main's server reports: `.gz`, `.har` and `.zip` as files, nothing else.
    fn main_policy() -> FilesystemAttachments {
        let envelope =
            crate::client::test_support::fixture_json("sessions/ComposerParity--v1-info-main.json");
        FilesystemAttachments::from_info(&envelope["response"])
    }

    fn resolved(name: &str, declared: Option<&str>, policy: &FilesystemAttachments) -> String {
        resolve_media_type_under(name, declared, policy)
            .unwrap_or_else(|error| format!("refused: {error}"))
    }

    #[test]
    fn the_servers_filesystem_policy_decides_which_files_go_as_files() {
        let policy = main_policy();
        assert_eq!(policy.extensions, [".gz", ".har", ".zip"]);
        assert!(!policy.all_types);
        assert_eq!(resolved("trace.HAR", None, &policy), FILESYSTEM_MEDIA_TYPE);
        assert_eq!(
            resolved("logs.tar.gz", Some("application/gzip"), &policy),
            FILESYSTEM_MEDIA_TYPE
        );
        // A default filesystem type the server leaves out is refused, not inlined.
        assert_eq!(
            resolved("report.docx", Some("text/plain"), &policy),
            "refused: \"report.docx\" can't be attached: only images, PDF, text/code, and .gz, \
             .har, .zip files are supported."
        );
        assert_eq!(resolved("photo.png", None, &policy), "image/png");
        assert!(resolved("movie.mp4", None, &policy).starts_with("refused"));
        let everything = FilesystemAttachments {
            all_types: true,
            ..policy
        };
        assert_eq!(
            resolved("movie.mp4", None, &everything),
            FILESYSTEM_MEDIA_TYPE
        );
        assert_eq!(resolved("notes.md", None, &everything), "text/plain");
    }

    #[test]
    fn an_older_or_odd_info_keeps_the_default_extensions() {
        for info in [
            serde_json::json!({}),
            serde_json::json!({"filesystem_attachments": null}),
            serde_json::json!({"filesystem_attachments": {"all_types": true}}),
        ] {
            assert_eq!(
                FilesystemAttachments::from_info(&info),
                FilesystemAttachments::default(),
                "{info}"
            );
        }
        let none = FilesystemAttachments::from_info(&serde_json::json!({
            "filesystem_attachments": {"extensions": [], "all_types": false}
        }));
        assert_eq!(none.extensions, Vec::<String>::new());
        assert_eq!(none.supported_types(), "images, PDF, and text/code files");
        assert!(resolved("a.zip", None, &none).starts_with("refused"));
        assert_eq!(
            FilesystemAttachments::default().supported_types(),
            "images, PDF, text/code, archives, office documents, and databases"
        );
    }

    #[test]
    fn media_types_resolve_like_the_swift_policy() {
        let cases = [
            ("a.ts", Some("video/mp2t"), "text/plain"),
            ("a.csv", Some("application/vnd.ms-excel"), "text/plain"),
            (".env", Some(""), "text/plain"),
            ("Dockerfile", None, "text/plain"),
            ("photo.PNG", None, "image/png"),
            ("photo.jpg", Some("application/octet-stream"), "image/jpeg"),
            ("photo.bin", Some("image/png; charset=binary"), "image/png"),
            (
                "notes.md",
                Some("Text/Markdown; charset=utf-8"),
                "text/markdown",
            ),
            (
                "book.ipynb",
                Some("application/x-ipynb+json"),
                "application/x-ipynb+json",
            ),
            ("paper", Some("application/pdf"), "application/pdf"),
        ];
        for (filename, declared, expected) in cases {
            assert_eq!(
                resolve_media_type(filename, declared).as_deref(),
                Ok(expected),
                "{filename}"
            );
        }
        for name in ["a\u{202E}gnp.txt", "a\u{200B}.txt", "a\u{7}.txt", ".", ".."] {
            assert_eq!(
                resolve_media_type(name, None),
                Err(AttachmentError::InvalidFilename),
                "{name:?}"
            );
        }
        let too_long = format!("{}.txt", "a".repeat(MAX_FILENAME_BYTES - 3));
        assert_eq!(
            resolve_media_type(&too_long, None),
            Err(AttachmentError::InvalidFilename)
        );
        let longest = format!("{}.txt", "a".repeat(MAX_FILENAME_BYTES - 4));
        assert!(resolve_media_type(&longest, None).is_ok());
    }

    fn regular(size: Option<u64>) -> FileProbe {
        FileProbe {
            is_regular_file: true,
            is_symlink: false,
            size,
        }
    }

    fn read_all(
        mut reader: UploadFileReader,
        contents: &[u8],
    ) -> Result<UploadFile, AttachmentError> {
        let mut rest = contents;
        while !rest.is_empty() {
            let take = reader.next_read_len().min(rest.len());
            assert!(take > 0);
            let (chunk, tail) = rest.split_at(take);
            reader.push(chunk)?;
            rest = tail;
        }
        reader.finish()
    }

    #[test]
    fn file_reader_rejects_oversize_folders_and_links_before_buffering() {
        let reader = UploadFileReader::begin("notes.txt", None, regular(Some(8))).unwrap();
        let file = read_all(reader, b"contents").unwrap();
        assert_eq!(file.data(), b"contents");
        assert_eq!(file.media_type(), "text/plain");

        let link = FileProbe {
            is_regular_file: true,
            is_symlink: true,
            size: Some(8),
        };
        assert_eq!(
            UploadFileReader::begin("link.txt", None, link),
            Err(AttachmentError::NotRegularFile)
        );
        let directory = FileProbe {
            is_regular_file: false,
            is_symlink: false,
            size: None,
        };
        assert_eq!(
            UploadFileReader::begin("directory.txt", None, directory),
            Err(AttachmentError::NotRegularFile)
        );

        let limit = MAX_TEXT_BYTES;
        let oversize = u64::try_from(limit + 1).unwrap();
        assert_eq!(
            UploadFileReader::begin("notes.txt", None, regular(Some(oversize))),
            Err(AttachmentError::TooLarge { limit })
        );

        // A stale or missing reported size is still bounded while reading.
        let reader = UploadFileReader::begin("notes.txt", None, regular(None)).unwrap();
        assert_eq!(
            read_all(reader, &vec![b'A'; limit + 1]),
            Err(AttachmentError::TooLarge { limit })
        );
        let mut reader = UploadFileReader::begin("notes.txt", None, regular(Some(1))).unwrap();
        assert_eq!(reader.next_read_len(), READ_CHUNK_BYTES);
        reader.push(&vec![0; limit]).unwrap();
        assert_eq!(reader.next_read_len(), 1);
        assert_eq!(reader.push(&[0]), Err(AttachmentError::TooLarge { limit }));
    }

    #[test]
    fn identifiers_are_ascii_word_characters() {
        for valid in ["file_123-abc", "a", "Z9"] {
            assert!(is_identifier(valid), "{valid}");
        }
        for invalid in ["", "../file", "file name", "file/name", "fïle", "%2F"] {
            assert!(!is_identifier(invalid), "{invalid}");
        }
    }
}
