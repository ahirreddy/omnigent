//! Test helpers for the SSE parser and the realtime machines: fixture loaders and a fixed
//! jitter source.

use serde_json::Value;

use super::backoff::JitterSource;

/// Always returns the same sample: 0 gives the low end of the jitter window.
#[derive(Debug, Clone, Copy)]
pub(crate) struct FixedJitter(pub(crate) u32);

impl JitterSource for FixedJitter {
    fn next_u32(&mut self) -> u32 {
        self.0
    }
}

/// Reads `client-core/fixtures/<relative>`.
pub(crate) fn fixture_text(relative: &str) -> String {
    let path = format!("{}/../../fixtures/{relative}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("reading {path}: {error}"))
}

/// Parses each non-empty line of a `.jsonl` fixture.
pub(crate) fn fixture_lines(relative: &str) -> Vec<Value> {
    fixture_text(relative)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line).unwrap_or_else(|error| panic!("{relative}: {error}"))
        })
        .collect()
}

/// One recorded SSE frame: its `event:` name and parsed `data:` payload.
#[derive(Debug, Clone)]
pub(crate) struct RecordedFrame {
    pub(crate) event: String,
    pub(crate) data: Value,
}

/// A recorded SSE capture rebuilt into the exact bytes the server sent.
#[derive(Debug, Clone)]
pub(crate) struct RecordedStream {
    pub(crate) bytes: Vec<u8>,
    pub(crate) frames: Vec<RecordedFrame>,
}

/// Loads `fixtures/sse/<name>`. Each line's `raw` frame text is joined with the blank-line
/// terminator the server writes after every frame.
pub(crate) fn recorded_sse_stream(name: &str) -> RecordedStream {
    let mut bytes = Vec::new();
    let mut frames = Vec::new();
    for line in fixture_lines(&format!("sse/{name}")) {
        let raw = line["raw"]
            .as_str()
            .expect("recorded frames carry raw text");
        bytes.extend_from_slice(raw.as_bytes());
        bytes.extend_from_slice(b"\n\n");
        frames.push(RecordedFrame {
            event: line["event"].as_str().expect("event name").to_owned(),
            data: line["data"].clone(),
        });
    }
    RecordedStream { bytes, frames }
}

/// A WebSocket fixture line: `{direction: "send"|"recv", message}`.
#[derive(Debug, Clone)]
pub(crate) enum WsLine {
    Send(Value),
    Recv(Value),
}

/// Loads a `fixtures/sessions/<name>` WebSocket transcript.
pub(crate) fn ws_transcript(name: &str) -> Vec<WsLine> {
    fixture_lines(&format!("sessions/{name}"))
        .into_iter()
        .map(|line| {
            let message = line["message"].clone();
            match line["direction"].as_str() {
                Some("send") => WsLine::Send(message),
                Some("recv") => WsLine::Recv(message),
                other => panic!("{name}: unexpected direction {other:?}"),
            }
        })
        .collect()
}
