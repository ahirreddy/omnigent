//! Which files play as video or show as a PDF, and a recording's chapters.
//!
//! As the web decides it: `isVideoFile` and `allowedVideoType` (`web/src/lib/video.ts`,
//! `videoFetch.ts`), `isPdfFile` (`web/src/shell/codeViewerHelpers.ts`) and
//! `parseVideoChapters` (`web/src/lib/videoChapters.ts`). The server's `content_type` wins over
//! the name, except a missing or `application/octet-stream` type for video.

/// Video types the player accepts.
const VIDEO_TYPES: [&str; 5] = [
    "video/mp4",
    "video/webm",
    "video/quicktime",
    "video/ogg",
    "video/x-m4v",
];

/// The video type each recognized extension stands for.
const VIDEO_TYPE_BY_EXTENSION: [(&str, &str); 5] = [
    ("mp4", "video/mp4"),
    ("m4v", "video/x-m4v"),
    ("webm", "video/webm"),
    ("mov", "video/quicktime"),
    ("ogv", "video/ogg"),
];

const OCTET_STREAM: &str = "application/octet-stream";
/// TypeScript's extension (`.ts`) maps to MPEG transport streams; such a file is not video here.
const TRANSPORT_STREAM: &str = "video/mp2t";

/// A content type's media type, lower-cased, without parameters; `None` when blank.
fn media_type(content_type: Option<&str>) -> Option<String> {
    let essence = content_type?.split(';').next()?.trim().to_ascii_lowercase();
    (!essence.is_empty()).then_some(essence)
}

/// The lower-cased extension of `name`'s last segment.
fn extension(name: &str) -> Option<String> {
    let base = name.rsplit('/').next().unwrap_or(name);
    base.rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
}

/// Whether `path` plays as a video (web `isVideoFile`): a `video/` type other than MPEG transport
/// streams, or with no useful type, a `.mp4`, `.webm`, `.mov`, `.m4v` or `.ogv` name.
#[must_use]
pub fn is_video_file(path: &str, content_type: Option<&str>) -> bool {
    if let Some(kind) = media_type(content_type)
        && kind != OCTET_STREAM
    {
        return kind.starts_with("video/") && kind != TRANSPORT_STREAM;
    }
    // The web reads the name up to a `?` or `#`, as for a URL.
    let name = path.split(['?', '#']).next().unwrap_or(path);
    extension(name).is_some_and(|extension| {
        VIDEO_TYPE_BY_EXTENSION
            .iter()
            .any(|(known, _)| *known == extension)
    })
}

/// The type a downloaded video plays as (web `allowedVideoType`), or `None` when not accepted.
///
/// A missing or `application/octet-stream` type falls back to the extension of the path's last
/// segment, read literally (a `?` or `#` is part of a file name).
#[must_use]
pub fn allowed_video_type(content_type: Option<&str>, path: &str) -> Option<&'static str> {
    if let Some(kind) = media_type(content_type)
        && kind != OCTET_STREAM
    {
        return VIDEO_TYPES.into_iter().find(|known| *known == kind);
    }
    let extension = extension(path)?;
    VIDEO_TYPE_BY_EXTENSION
        .into_iter()
        .find(|(known, _)| *known == extension)
        .map(|(_, kind)| kind)
}

/// Whether `path` shows as a PDF (web `isPdfFile`): exactly `application/pdf` when the server
/// gave a type, else a `.pdf` name.
#[must_use]
pub fn is_pdf_file(path: &str, content_type: Option<&str>) -> bool {
    // Without a type: the text after the last dot, or the whole path without one.
    content_type.filter(|kind| !kind.is_empty()).map_or_else(
        || {
            path.rsplit('.')
                .next()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("pdf"))
        },
        |kind| kind == "application/pdf",
    )
}

/// What follows a recording's path to name its chapters file (`demo.mp4.chapters.vtt`).
pub const CHAPTERS_SUFFIX: &str = ".chapters.vtt";
/// A chapters file larger than this is ignored, as the web ignores it.
const MAX_CHAPTERS_BYTES: usize = 65_536;
/// More cues than this and none are shown.
const MAX_CHAPTERS: usize = 200;
/// A chapter title longer than this, in UTF-16 code units, is skipped.
const MAX_CHAPTER_TITLE: usize = 500;

/// One chapter of a recording: where it starts and ends, in seconds, and its title.
#[derive(Debug, Clone, PartialEq)]
pub struct VideoChapter {
    /// Start, in seconds.
    pub time: f64,
    /// End, in seconds.
    pub end: f64,
    /// The cue's text, trimmed.
    pub title: String,
}

/// `[hh:]mm:ss.ttt` in seconds, as `WebVTT` writes times.
fn timestamp(text: &str) -> Option<f64> {
    let (clock, millis) = text.split_once('.')?;
    let parts: Vec<&str> = clock.split(':').collect();
    let (hours, minutes, seconds) = match parts.as_slice() {
        [minutes, seconds] => ("0", *minutes, *seconds),
        [hours, minutes, seconds] if hours.len() >= 2 => (*hours, *minutes, *seconds),
        _ => return None,
    };
    let number = |digits: &str, exact: Option<usize>| -> Option<f64> {
        let fits = exact.is_none_or(|length| digits.len() == length);
        (fits && !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit()))
            .then(|| digits.parse::<f64>().ok())
            .flatten()
    };
    let (hours, minutes, seconds, millis) = (
        number(hours, None)?,
        number(minutes, Some(2))?,
        number(seconds, Some(2))?,
        number(millis, Some(3))?,
    );
    (minutes < 60.0 && seconds < 60.0)
        .then_some(hours.mul_add(3600.0, minutes.mul_add(60.0, seconds + millis / 1000.0)))
}

/// A cue's `start --> end [settings]` line.
fn timing(line: &str) -> Option<(f64, f64)> {
    let (start, rest) = line.split_once("-->")?;
    let end = rest.split_whitespace().next()?;
    Some((timestamp(start.trim())?, timestamp(end)?))
}

/// The chapters a recording's `WebVTT` file lists, by start (web `parseVideoChapters`).
///
/// Each cue's trimmed text, without blank or overlong titles or repeats (`readChapterCues`).
/// Nothing for a file that is not `WebVTT`, is over 64 KiB, or has over 200 cues.
#[must_use]
pub fn parse_video_chapters(text: &str) -> Vec<VideoChapter> {
    if text.len() > MAX_CHAPTERS_BYTES {
        return vec![];
    }
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut blocks = normalized
        .split("\n\n")
        .filter(|block| !block.trim().is_empty());
    let header = blocks.next().unwrap_or_default();
    let signature = header.lines().next().unwrap_or_default();
    let is_webvtt = signature == "WEBVTT"
        || signature.starts_with("WEBVTT ")
        || signature.starts_with("WEBVTT\t");
    if !is_webvtt {
        return vec![];
    }
    let mut cues = Vec::new();
    for block in blocks {
        let lines: Vec<&str> = block.lines().skip_while(|line| line.is_empty()).collect();
        // A cue's timing line comes first, or after its identifier.
        let (timing_line, payload) = match lines.as_slice() {
            [first, rest @ ..] if first.contains("-->") => (*first, rest),
            [_, second, rest @ ..] if second.contains("-->") => (*second, rest),
            _ => continue,
        };
        if let Some((time, end)) = timing(timing_line) {
            cues.push((time, end, payload.join("\n")));
        }
    }
    if cues.len() > MAX_CHAPTERS {
        return vec![];
    }
    let mut chapters: Vec<VideoChapter> = Vec::new();
    for (time, end, payload) in cues {
        let title = payload.trim();
        if title.is_empty() || title.encode_utf16().count() > MAX_CHAPTER_TITLE {
            continue;
        }
        let repeated = chapters.iter().any(|chapter| {
            chapter.time.to_bits() == time.to_bits()
                && chapter.end.to_bits() == end.to_bits()
                && chapter.title == title
        });
        if !repeated {
            chapters.push(VideoChapter {
                time,
                end,
                title: title.to_owned(),
            });
        }
    }
    chapters.sort_by(|left, right| left.time.total_cmp(&right.time));
    chapters
}

#[cfg(test)]
mod tests {
    use super::{allowed_video_type, is_pdf_file, is_video_file, parse_video_chapters};

    #[test]
    fn chapters_come_from_the_cues_of_a_webvtt_file() {
        let vtt = "WEBVTT - recording actions\r\n\r\nNOTE written by the agent\r\n\r\n2\r\n00:05.250 --> 00:09.000 align:start\r\n  Open the settings  \r\n\r\n1\r\n00:00.000 --> 00:05.250\r\nSign in\r\n\r\n01:00:00.000 --> 01:00:01.500\r\nLast\nstep\r\n\r\n00:09.000 --> 00:10.000\r\n   \r\n\r\n00:00.000 --> 00:05.250\r\nSign in\r\n";
        let chapters = parse_video_chapters(vtt);
        let titles: Vec<&str> = chapters
            .iter()
            .map(|chapter| chapter.title.as_str())
            .collect();
        assert_eq!(titles, ["Sign in", "Open the settings", "Last\nstep"]);
        assert!((chapters[1].time - 5.25).abs() < 1e-9 && (chapters[1].end - 9.0).abs() < 1e-9);
        assert!((chapters[2].time - 3600.0).abs() < 1e-9);
    }

    #[test]
    fn a_file_that_is_not_webvtt_or_too_large_has_no_chapters() {
        let count = |text: &str| parse_video_chapters(text).len();
        assert_eq!(count("00:00.000 --> 00:01.000\nHi\n"), 0);
        assert_eq!(count("WEBVTTX\n\n00:00.000 --> 00:01.000\nHi\n"), 0);
        assert_eq!(count("WEBVTT\n\n0:00.000 --> 00:01.000\nBad minutes\n"), 0);
        let many = (0..201)
            .map(|index| format!("\n\n00:00.{index:03} --> 00:01.000\nStep {index}"))
            .collect::<Vec<_>>()
            .concat();
        assert_eq!(count(&format!("WEBVTT{many}")), 0);
        let huge = format!("WEBVTT\n\n00:00.000 --> 00:01.000\n{}", "a".repeat(70_000));
        assert_eq!(count(&huge), 0);
        let long_title = format!("WEBVTT\n\n00:00.000 --> 00:01.000\n{}", "a".repeat(501));
        assert_eq!(count(&long_title), 0);
    }

    #[test]
    fn video_is_recognized_by_type_first_then_by_name() {
        assert!(is_video_file("demo.mp4", None));
        assert!(is_video_file("rec/Run.MOV", None));
        assert!(is_video_file("clip.webm?raw#t=3", None));
        assert!(!is_video_file("notes.md", None));
        assert!(is_video_file("recording", Some("video/mp4; codecs=avc1")));
        assert!(is_video_file("clip.mp4", Some("application/octet-stream")));
        // A TypeScript file is reported as an MPEG transport stream.
        assert!(!is_video_file("main.ts", Some("video/mp2t")));
        // A declared type that is not video wins over the name.
        assert!(!is_video_file("clip.mp4", Some("text/plain")));
        assert!(is_video_file("clip.mp4", Some("")));
    }

    #[test]
    fn only_allowlisted_video_types_play() {
        assert_eq!(
            allowed_video_type(Some("video/mp4"), "x"),
            Some("video/mp4")
        );
        assert_eq!(
            allowed_video_type(Some("Video/QuickTime; x=1"), "x"),
            Some("video/quicktime")
        );
        assert_eq!(allowed_video_type(Some("video/x-matroska"), "a.mp4"), None);
        assert_eq!(allowed_video_type(None, "dir/a.M4V"), Some("video/x-m4v"));
        assert_eq!(
            allowed_video_type(Some("application/octet-stream"), "a.ogv"),
            Some("video/ogg")
        );
        // The path is a file name, so `?` belongs to the extension.
        assert_eq!(allowed_video_type(None, "a.mp4?x"), None);
        assert_eq!(allowed_video_type(None, "noextension"), None);
    }

    #[test]
    fn pdf_is_recognized_by_exact_type_or_by_name() {
        assert!(is_pdf_file("report.pdf", None));
        assert!(is_pdf_file("docs/Report.PDF", None));
        assert!(is_pdf_file("report", Some("application/pdf")));
        assert!(!is_pdf_file("report.pdf", Some("application/octet-stream")));
        assert!(is_pdf_file("report.pdf", Some("")));
        assert!(!is_pdf_file("report.txt", None));
    }
}
