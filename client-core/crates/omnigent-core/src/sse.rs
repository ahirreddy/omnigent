//! Byte-level server-sent events parser.
//!
//! [`SseParser`] turns the raw body of `GET /v1/sessions/{id}/stream` into [`SseEvent`]s. It
//! follows the WHATWG event-stream interpretation rules:
//!
//! - Lines end in LF, CRLF or a lone CR. A CRLF split across two chunks is one line break.
//! - A blank line dispatches the pending event. An event with no `data` lines is dropped, as the
//!   spec requires; that is not an error.
//! - Lines starting with `:` are comments (proxy keepalives) and are skipped.
//! - Several `data` lines join with `\n`. One leading space after the colon is stripped.
//! - `event` and `id` fields are kept; `retry` and unknown fields are ignored. Reconnect timing is
//!   client policy (see [`crate::realtime::backoff`]), not something the server picks.
//! - A UTF-8 byte-order mark at the very start of the stream is skipped, even when it arrives
//!   split across chunks.
//!
//! The parser keeps no state tied to chunk boundaries, so any split of a byte stream yields the
//! same events; the property tests below check this. Lines are decoded as UTF-8 only once they
//! are complete. LF and CR never occur inside a multi-byte sequence, so a code point split
//! across chunks is fine, but an invalid sequence is a typed [`SseError::InvalidUtf8`]. It is
//! never replaced with U+FFFD.
//!
//! [`SseLimits`] caps the bytes of one line and of one event. Going over a cap is a typed
//! error, and so is invalid UTF-8. After an error the parser stays failed and every later
//! [`SseParser::push`] returns the same error. The caller must abandon the stream.
//!
//! The server ends a stream on purpose by sending `data: [DONE]` (see [`SseEvent::is_done`]).
//! Parsing does not stop there: the caller decides, as the stream state machine in
//! [`crate::realtime::stream`] does.

use thiserror::Error;

/// Default cap on one line, in bytes, excluding the line terminator. It matches `NativeLab`.
pub const DEFAULT_MAX_LINE_BYTES: usize = 4 * 1024 * 1024;

/// Default cap on one event: the bytes of all its non-comment lines. It matches `NativeLab`.
pub const DEFAULT_MAX_EVENT_BYTES: usize = 4 * 1024 * 1024;

/// The `data` payload the server sends to close the stream on purpose.
pub const DONE_SENTINEL: &str = "[DONE]";

const BOM: [u8; 3] = [0xEF, 0xBB, 0xBF];

/// Size caps that protect the client from an unbounded line or event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SseLimits {
    /// Maximum bytes in one line, excluding its terminator.
    pub max_line_bytes: usize,
    /// Maximum bytes across the field lines of one event, excluding terminators and comments.
    pub max_event_bytes: usize,
}

impl Default for SseLimits {
    fn default() -> Self {
        Self {
            max_line_bytes: DEFAULT_MAX_LINE_BYTES,
            max_event_bytes: DEFAULT_MAX_EVENT_BYTES,
        }
    }
}

/// One dispatched server-sent event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SseEvent {
    /// The `event:` field, or `None` when it was absent or empty.
    pub event: Option<String>,
    /// The `data:` lines joined with `\n`.
    pub data: String,
    /// The last `id:` value seen on this stream, if any. The Omnigent server sends none.
    pub id: Option<String>,
}

impl SseEvent {
    /// Whether this is the server's intentional-close sentinel, `data: [DONE]`. Surrounding
    /// whitespace is ignored and so is the `event` field, the same as in `web/src/lib/sse.ts`.
    #[must_use]
    pub fn is_done(&self) -> bool {
        self.data.trim() == DONE_SENTINEL
    }
}

/// Why the byte stream cannot be parsed further.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SseError {
    /// A line grew past [`SseLimits::max_line_bytes`] before its terminator arrived.
    #[error("server-sent event line {line} exceeds {limit} bytes")]
    LineTooLong {
        /// The 1-based line number.
        line: u64,
        /// The configured cap.
        limit: usize,
    },
    /// An event's field lines grew past [`SseLimits::max_event_bytes`] before it dispatched.
    #[error("server-sent event ending at line {line} exceeds {limit} bytes")]
    EventTooLarge {
        /// The 1-based line number of the line that crossed the cap.
        line: u64,
        /// The configured cap.
        limit: usize,
    },
    /// A complete line was not valid UTF-8.
    #[error("server-sent event line {line} is not valid UTF-8 (valid up to byte {valid_up_to})")]
    InvalidUtf8 {
        /// The 1-based line number.
        line: u64,
        /// Bytes of the line that were valid before the bad sequence.
        valid_up_to: usize,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BomState {
    /// At stream start; this many BOM bytes have matched so far.
    Matching(usize),
    Done,
}

/// Incremental parser from SSE body bytes to [`SseEvent`]s. Create one per connection.
#[derive(Debug, Clone)]
pub struct SseParser {
    limits: SseLimits,
    bom: BomState,
    line: Vec<u8>,
    after_cr: bool,
    line_number: u64,
    event_type: Option<String>,
    data: String,
    event_bytes: usize,
    last_event_id: Option<String>,
    failed: Option<SseError>,
}

impl Default for SseParser {
    fn default() -> Self {
        Self::new()
    }
}

impl SseParser {
    /// A parser with the [`SseLimits::default`] caps.
    #[must_use]
    pub fn new() -> Self {
        Self::with_limits(SseLimits::default())
    }

    /// A parser with explicit caps.
    #[must_use]
    pub const fn with_limits(limits: SseLimits) -> Self {
        Self {
            limits,
            bom: BomState::Matching(0),
            line: Vec::new(),
            after_cr: false,
            line_number: 0,
            event_type: None,
            data: String::new(),
            event_bytes: 0,
            last_event_id: None,
            failed: None,
        }
    }

    /// Feeds the next body chunk and appends every event it completes to `out`, in order.
    ///
    /// # Errors
    ///
    /// Returns an [`SseError`] when a cap is exceeded or a line is not UTF-8. Events completed
    /// earlier in the same chunk are already in `out`. The parser then stays failed, and every
    /// later call returns the same error without reading its input.
    pub fn push(&mut self, chunk: &[u8], out: &mut Vec<SseEvent>) -> Result<(), SseError> {
        if let Some(error) = &self.failed {
            return Err(error.clone());
        }
        let result = self.feed(chunk, out);
        if let Err(error) = &result {
            self.failed = Some(error.clone());
        }
        result
    }

    /// Whether bytes of an incomplete line or an undispatched event are buffered. At EOF this
    /// means the stream was cut mid-event; the spec discards such an event.
    #[must_use]
    pub const fn has_partial_event(&self) -> bool {
        !self.line.is_empty()
            || !self.data.is_empty()
            || self.event_type.is_some()
            || matches!(self.bom, BomState::Matching(matched) if matched > 0)
    }

    fn feed(&mut self, chunk: &[u8], out: &mut Vec<SseEvent>) -> Result<(), SseError> {
        let mut bytes = self.skip_bom(chunk)?;
        while let Some((&first, rest)) = bytes.split_first() {
            if self.after_cr {
                self.after_cr = false;
                if first == b'\n' {
                    bytes = rest;
                    continue;
                }
            }
            let Some(end) = bytes.iter().position(|&b| b == b'\n' || b == b'\r') else {
                self.append(bytes)?;
                break;
            };
            let Some((content, terminated)) = bytes.split_at_checked(end) else {
                break;
            };
            self.append(content)?;
            let Some((&terminator, rest)) = terminated.split_first() else {
                break;
            };
            self.after_cr = terminator == b'\r';
            bytes = rest;
            self.end_line(out)?;
        }
        Ok(())
    }

    /// Consumes a leading BOM, which may be split across chunks. Bytes that turn out not to be a
    /// BOM are fed back as ordinary line content.
    fn skip_bom<'a>(&mut self, chunk: &'a [u8]) -> Result<&'a [u8], SseError> {
        let mut bytes = chunk;
        while let BomState::Matching(matched) = self.bom {
            let Some((&byte, rest)) = bytes.split_first() else {
                break;
            };
            if BOM.get(matched) == Some(&byte) {
                bytes = rest;
                self.bom = if matched + 1 == BOM.len() {
                    BomState::Done
                } else {
                    BomState::Matching(matched + 1)
                };
            } else {
                self.bom = BomState::Done;
                if let Some(prefix) = BOM.get(..matched) {
                    self.append(prefix)?;
                }
            }
        }
        Ok(bytes)
    }

    fn append(&mut self, content: &[u8]) -> Result<(), SseError> {
        if self.line.len().saturating_add(content.len()) > self.limits.max_line_bytes {
            return Err(SseError::LineTooLong {
                line: self.line_number + 1,
                limit: self.limits.max_line_bytes,
            });
        }
        self.line.extend_from_slice(content);
        Ok(())
    }

    fn end_line(&mut self, out: &mut Vec<SseEvent>) -> Result<(), SseError> {
        self.line_number += 1;
        let bytes = std::mem::take(&mut self.line);
        let line = String::from_utf8(bytes).map_err(|error| SseError::InvalidUtf8 {
            line: self.line_number,
            valid_up_to: error.utf8_error().valid_up_to(),
        })?;
        if line.is_empty() {
            self.dispatch(out);
            return Ok(());
        }
        if line.starts_with(':') {
            return Ok(());
        }
        self.event_bytes = self.event_bytes.saturating_add(line.len());
        if self.event_bytes > self.limits.max_event_bytes {
            return Err(SseError::EventTooLarge {
                line: self.line_number,
                limit: self.limits.max_event_bytes,
            });
        }
        let (field, value) = match line.split_once(':') {
            Some((field, value)) => (field, value.strip_prefix(' ').unwrap_or(value)),
            None => (line.as_str(), ""),
        };
        match field {
            "event" => self.event_type = Some(value.to_owned()),
            "data" => {
                self.data.push_str(value);
                self.data.push('\n');
            }
            // The spec ignores an id containing NUL rather than failing the stream.
            "id" if !value.contains('\0') => self.last_event_id = Some(value.to_owned()),
            _ => {}
        }
        Ok(())
    }

    fn dispatch(&mut self, out: &mut Vec<SseEvent>) {
        let event_type = self.event_type.take();
        self.event_bytes = 0;
        if self.data.is_empty() {
            return;
        }
        let mut data = std::mem::take(&mut self.data);
        data.pop();
        out.push(SseEvent {
            event: event_type.filter(|name| !name.is_empty()),
            data,
            id: self.last_event_id.clone(),
        });
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;
    use crate::realtime::test_support::recorded_sse_stream;

    fn parse_chunks<'a>(
        parser: &mut SseParser,
        chunks: impl IntoIterator<Item = &'a [u8]>,
    ) -> (Vec<SseEvent>, Option<SseError>) {
        let mut events = Vec::new();
        for chunk in chunks {
            if let Err(error) = parser.push(chunk, &mut events) {
                return (events, Some(error));
            }
        }
        (events, None)
    }

    fn parse_all(bytes: &[u8]) -> (Vec<SseEvent>, Option<SseError>) {
        parse_chunks(&mut SseParser::new(), [bytes])
    }

    fn parse_bytewise(bytes: &[u8]) -> (Vec<SseEvent>, Option<SseError>) {
        parse_chunks(&mut SseParser::new(), bytes.chunks(1))
    }

    fn event(name: Option<&str>, data: &str) -> SseEvent {
        SseEvent {
            event: name.map(str::to_owned),
            data: data.to_owned(),
            id: None,
        }
    }

    /// Splits `bytes` at the given cut points (taken modulo the length, sorted, deduped).
    fn split_at_cuts(bytes: &[u8], cuts: &[usize]) -> Vec<Vec<u8>> {
        let mut points: Vec<usize> = cuts.iter().map(|cut| cut % (bytes.len() + 1)).collect();
        points.push(0);
        points.push(bytes.len());
        points.sort_unstable();
        points.dedup();
        points
            .windows(2)
            .map(|pair| bytes[pair[0]..pair[1]].to_vec())
            .collect()
    }

    // Port of LiveConversationReducerTests.swift::testByteFramingRetainsEmptyLinesCRLFAndUTF8.
    #[test]
    fn a_default_parser_is_a_new_parser_and_a_partial_bom_at_the_start_is_reported_as_bad_text() {
        let mut parser = SseParser::default();
        let mut events = Vec::new();
        parser.push(b"data: a\n\n", &mut events).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "a");

        let mut parser = SseParser::new();
        let mut events = Vec::new();
        assert_eq!(
            parser.push(b"\xEFdata: b\n\n", &mut events),
            Err(SseError::InvalidUtf8 {
                line: 1,
                valid_up_to: 0
            })
        );
    }

    #[test]
    fn byte_framing_retains_empty_lines_crlf_and_utf8() {
        let stream = "\u{FEFF}event: test\r\ndata: héllo 🌎\r\n\r\ndata: second\r\rdata: third\n\n";
        let (events, error) = parse_bytewise(stream.as_bytes());
        assert_eq!(error, None);
        assert_eq!(
            events.iter().map(|e| e.data.as_str()).collect::<Vec<_>>(),
            ["héllo 🌎", "second", "third"]
        );
        assert_eq!(events[0].event.as_deref(), Some("test"));
        assert_eq!(events[1].event, None);
        assert_eq!(parse_all(stream.as_bytes()), (events, None));
    }

    // Port of LiveConversationReducerTests.swift::testSSEParserHandlesCommentsMultilineAndBoundaries.
    #[test]
    fn sse_parser_handles_comments_multiline_and_boundaries() {
        let mut parser = SseParser::new();
        let mut out = Vec::new();
        let mut line = |text: &str, out: &mut Vec<SseEvent>| {
            parser.push(text.as_bytes(), out).unwrap();
            parser.push(b"\n", out).unwrap();
        };
        line(": keepalive", &mut out);
        line("event: response.output_text.delta", &mut out);
        line("data: {\"delta\":", &mut out);
        line("data: \"hello\"}", &mut out);
        assert_eq!(out, []);
        line("", &mut out);
        assert_eq!(
            out,
            [event(
                Some("response.output_text.delta"),
                "{\"delta\":\n\"hello\"}"
            )]
        );
        line("", &mut out);
        assert_eq!(
            out.len(),
            1,
            "a blank line with nothing pending dispatches nothing"
        );
        line("data: [DONE]", &mut out);
        assert_eq!(out.len(), 1);
        line("", &mut out);
        assert_eq!(out.len(), 2);
        assert_eq!(out[1].data, "[DONE]");
        assert!(out[1].is_done());
        assert!(!out[0].is_done());
    }

    #[test]
    fn crlf_split_across_chunks_is_one_line_break() {
        let mut parser = SseParser::new();
        let (events, error) = parse_chunks(
            &mut parser,
            [&b"data: a\r"[..], b"\n", b"\r", b"\ndata: b\r", b"\r"],
        );
        assert_eq!(error, None);
        assert_eq!(events, [event(None, "a"), event(None, "b")]);
        assert!(!parser.has_partial_event());
    }

    #[test]
    fn field_parsing_follows_the_spec() {
        let stream = b"data\ndata:x\ndata:  two\nevent:\nretry: 10\nfoo: bar\nid: 7\n\n\
                       event: e\ndata\n\n";
        let (events, error) = parse_all(stream);
        assert_eq!(error, None);
        assert_eq!(
            events,
            [
                SseEvent {
                    event: None,
                    data: "\nx\n two".into(),
                    id: Some("7".into()),
                },
                SseEvent {
                    event: Some("e".into()),
                    data: String::new(),
                    id: Some("7".into()),
                },
            ]
        );
    }

    #[test]
    fn event_without_data_is_not_dispatched_and_does_not_leak_its_type() {
        let (events, error) = parse_all(b"event: lonely\n\ndata: x\n\n");
        assert_eq!(error, None);
        assert_eq!(events, [event(None, "x")]);
    }

    #[test]
    fn id_with_nul_is_ignored_and_ids_persist_across_events() {
        let (events, _) = parse_all(b"id: 1\ndata: a\n\nid: bad\0\ndata: b\n\n");
        assert_eq!(events[0].id.as_deref(), Some("1"));
        assert_eq!(events[1].id.as_deref(), Some("1"));
    }

    #[test]
    fn bom_is_skipped_only_at_stream_start_even_when_split() {
        let mut parser = SseParser::new();
        let (events, error) = parse_chunks(
            &mut parser,
            [&[0xEF][..], &[0xBB], &[0xBF, b'd'], b"ata: x\n\n"],
        );
        assert_eq!(error, None);
        assert_eq!(events, [event(None, "x")]);

        // A BOM later in the stream is content: here it turns `data` into an unknown field.
        let (events, error) = parse_all("data: a\n\n\u{FEFF}data: b\n\n".as_bytes());
        assert_eq!(error, None);
        assert_eq!(events, [event(None, "a")]);
    }

    #[test]
    fn partial_bom_prefix_is_kept_as_line_content() {
        // 0xEF 0xBB followed by a non-BOM byte is not a BOM; the bytes stay in the line, which
        // is then invalid UTF-8 and reported as such, not silently dropped.
        let (events, error) = parse_all(&[0xEF, 0xBB, b'x', b'\n']);
        assert_eq!(events, []);
        assert_eq!(
            error,
            Some(SseError::InvalidUtf8 {
                line: 1,
                valid_up_to: 0
            })
        );
    }

    #[test]
    fn utf8_split_across_chunks_decodes() {
        let bytes = "data: 🌎\n\n".as_bytes();
        let (events, error) = parse_bytewise(bytes);
        assert_eq!(error, None);
        assert_eq!(events, [event(None, "🌎")]);
    }

    #[test]
    fn invalid_utf8_is_a_typed_error_and_poisons_the_parser() {
        let mut parser = SseParser::new();
        let mut out = Vec::new();
        parser
            .push(b"data: ok\n\ndata: \xFF\xFE\n", &mut out)
            .unwrap_err();
        assert_eq!(
            out,
            [event(None, "ok")],
            "events before the error are delivered"
        );
        let expected = SseError::InvalidUtf8 {
            line: 3,
            valid_up_to: 6,
        };
        assert_eq!(parser.push(b"data: later\n\n", &mut out), Err(expected));
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn line_limit_is_enforced_before_the_terminator_arrives() {
        let mut parser = SseParser::with_limits(SseLimits {
            max_line_bytes: 8,
            max_event_bytes: 100,
        });
        let mut out = Vec::new();
        parser.push(b"data: 12", &mut out).unwrap();
        assert_eq!(
            parser.push(b"3", &mut out),
            Err(SseError::LineTooLong { line: 1, limit: 8 })
        );
        assert_eq!(out, []);
    }

    #[test]
    fn event_limit_counts_all_field_lines_but_not_comments() {
        let limits = SseLimits {
            max_line_bytes: 100,
            max_event_bytes: 12,
        };
        let mut parser = SseParser::with_limits(limits);
        let mut out = Vec::new();
        parser
            .push(b": a very long comment line\ndata: 12345\n\n", &mut out)
            .unwrap();
        assert_eq!(out, [event(None, "12345")]);
        assert_eq!(
            parser.push(b"data: 12345\ndata: 6\n", &mut out),
            Err(SseError::EventTooLarge { line: 5, limit: 12 })
        );
    }

    #[test]
    fn partial_event_is_reported() {
        let mut parser = SseParser::new();
        let mut out = Vec::new();
        assert!(!parser.has_partial_event());
        parser.push(b"data: x", &mut out).unwrap();
        assert!(parser.has_partial_event());
        parser.push(b"\n", &mut out).unwrap();
        assert!(parser.has_partial_event());
        parser.push(b"\n", &mut out).unwrap();
        assert!(!parser.has_partial_event());
        parser.push(&[0xEF], &mut out).unwrap();
        assert!(parser.has_partial_event());
    }

    #[test]
    fn done_sentinel_tolerates_whitespace_and_event_names() {
        assert!(event(Some("done"), " [DONE] ").is_done());
        assert!(!event(None, "[DONE]x").is_done());
    }

    #[test]
    fn recorded_stream_parses_to_its_frames() {
        let recorded = recorded_sse_stream("recorded-turn-text-tool-completion.jsonl");
        let (events, error) = parse_all(&recorded.bytes);
        assert_eq!(error, None);
        assert_eq!(events.len(), 19);
        for (event, frame) in events.iter().zip(&recorded.frames) {
            assert_eq!(event.event.as_deref(), Some(frame.event.as_str()));
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&event.data).unwrap(),
                frame.data
            );
            assert_eq!(event.id, None, "the server sends no id: lines");
            assert!(!event.is_done());
        }
    }

    fn with_line_endings(bytes: &[u8], ending: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(bytes.len() * 2);
        for &byte in bytes {
            if byte == b'\n' {
                out.extend_from_slice(ending);
            } else {
                out.push(byte);
            }
        }
        out
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(256))]

        /// Any split of a recorded stream, with any line-ending style and an optional BOM,
        /// yields exactly the events of the unsplit LF stream.
        #[test]
        fn any_split_of_recorded_streams_yields_the_same_events(
            fixture in prop::sample::select(vec![
                "recorded-turn-text-tool-completion.jsonl",
                "recorded-reconnect-last-event-id-turn2.jsonl",
            ]),
            ending in prop::sample::select(vec![&b"\n"[..], b"\r\n", b"\r"]),
            bom in any::<bool>(),
            cuts in prop::collection::vec(any::<usize>(), 0..64),
        ) {
            let recorded = recorded_sse_stream(fixture);
            let (expected, error) = parse_all(&recorded.bytes);
            prop_assert_eq!(error, None);
            prop_assert_eq!(expected.len(), recorded.frames.len());

            let mut bytes = if bom { BOM.to_vec() } else { Vec::new() };
            bytes.extend(with_line_endings(&recorded.bytes, ending));
            let chunks = split_at_cuts(&bytes, &cuts);
            let (events, error) =
                parse_chunks(&mut SseParser::new(), chunks.iter().map(Vec::as_slice));
            prop_assert_eq!(error, None);
            prop_assert_eq!(events, expected);
        }

        /// For arbitrary bytes (including invalid UTF-8 and over-limit lines), chunking never
        /// changes the events delivered or the error raised.
        #[test]
        fn chunking_never_changes_events_or_errors(
            bytes in prop::collection::vec(
                prop::sample::select(vec![
                    b'd', b'a', b't', b'e', b':', b' ', b'\n', b'\r', b'x', 0xEF, 0xBB, 0xBF, 0xFF,
                ]),
                0..256,
            ),
            cuts in prop::collection::vec(any::<usize>(), 0..32),
        ) {
            let limits = SseLimits { max_line_bytes: 24, max_event_bytes: 40 };
            let whole = parse_chunks(&mut SseParser::with_limits(limits), [bytes.as_slice()]);
            let chunks = split_at_cuts(&bytes, &cuts);
            let split = parse_chunks(
                &mut SseParser::with_limits(limits),
                chunks.iter().map(Vec::as_slice),
            );
            prop_assert_eq!(split, whole);
        }
    }
}
