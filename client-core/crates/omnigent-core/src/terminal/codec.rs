//! The attach WebSocket wire format.
//!
//! Ground truth: `omnigent/server/routes/terminal_attach.py` and
//! `omnigent/terminals/control_bridge.py`.
//!
//! - **Client → server**
//!   - binary frames: raw input bytes (keystrokes, paste, mouse reports), forwarded to tmux
//!     byte-exact with `send-keys -H`. Dropped by the server on a read-only attach.
//!   - text frames: JSON control messages. Only `{"type":"resize","cols":N,"rows":M}` exists.
//!     The server ignores unknown shapes, so there is no client keepalive frame.
//! - **Server → client**
//!   - binary frames: raw pane output. The first one after attach is the `capture-pane -e -p`
//!     seed of the current screen; later ones are live `%output`, coalesced to at most 64 KiB
//!     (2 KiB just after input).
//!   - text frames: JSON control messages:
//!     - `{"type":"tmux-replies","queries":[...]}`, sent first, listing the terminal queries tmux
//!       answers itself (`omnigent/terminals/query_replies.py` identifiers such as `da1`, `dsr:6`,
//!       `decrqm:?*`);
//!     - `{"type":"clipboard-write","encoding":"base64","data":"..."}` after a tmux copy-mode
//!       selection.
//!   - Any other text frame decodes to [`ServerFrame::Unknown`] and is surfaced, never dropped.
//!
//! The server sends no heartbeat on this socket. Liveness is the transport's job (TCP and the
//! platform WebSocket's own ping), and a silent terminal is normal.

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Value};

use crate::realtime::SocketMessage;

/// Largest clipboard payload accepted, in decoded bytes. Mirrors
/// `TERMINAL_CLIPBOARD_MAX_BYTES` in `web/src/components/blocks/TerminalSession.ts`.
pub const MAX_CLIPBOARD_BYTES: usize = 1024 * 1024;

/// Largest grid dimension sent in a resize. tmux accepts up to 10,000, but nothing real is
/// wider than this and a bogus layout value should not reach the server.
pub const MAX_GRID_DIMENSION: u16 = 2_000;

/// A grid size in character cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct GridSize {
    /// Columns.
    pub cols: u16,
    /// Rows.
    pub rows: u16,
}

impl GridSize {
    /// A grid size, if both dimensions are in `1..=MAX_GRID_DIMENSION`.
    #[must_use]
    pub const fn new(cols: u16, rows: u16) -> Option<Self> {
        if cols == 0 || rows == 0 || cols > MAX_GRID_DIMENSION || rows > MAX_GRID_DIMENSION {
            None
        } else {
            Some(Self { cols, rows })
        }
    }
}

/// One client → server frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientFrame {
    /// Raw input bytes.
    Input(Vec<u8>),
    /// A grid resize.
    Resize(GridSize),
}

impl ClientFrame {
    /// The WebSocket message for this frame.
    #[must_use]
    pub fn encode(&self) -> SocketMessage {
        match self {
            Self::Input(bytes) => SocketMessage::Binary(bytes.clone()),
            Self::Resize(size) => SocketMessage::Text(format!(
                "{{\"type\":\"resize\",\"cols\":{},\"rows\":{}}}",
                size.cols, size.rows
            )),
        }
    }
}

/// Why a server text frame could not be decoded.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FrameError {
    /// Not JSON.
    #[error("terminal control frame is not JSON: {message}")]
    NotJson {
        /// The decoder's message.
        message: String,
    },
    /// Not an object with a string `type`.
    #[error("terminal control frame is not an object with a string type")]
    MissingType,
    /// A known frame with a bad payload.
    #[error("{frame_type} frame is invalid: {message}")]
    Invalid {
        /// The frame type.
        frame_type: &'static str,
        /// What is wrong.
        message: String,
    },
}

/// One decoded server → client frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerFrame {
    /// Pane output bytes, not necessarily valid UTF-8 or split on character boundaries.
    Output(Vec<u8>),
    /// The queries tmux answers itself. A renderer that also answers them would reply twice.
    TmuxReplies {
        /// Query identifiers, for example `da1` or `dsr:6`.
        queries: Vec<String>,
    },
    /// tmux copied a selection: write these bytes (UTF-8 text) to the local clipboard, subject
    /// to the user's consent and recent input on this attach.
    ClipboardWrite {
        /// The decoded clipboard bytes.
        data: Vec<u8>,
    },
    /// A control frame this client does not know.
    Unknown {
        /// Its `type`.
        frame_type: String,
        /// The whole frame.
        raw: Map<String, Value>,
    },
}

impl ServerFrame {
    /// Decodes one WebSocket message.
    ///
    /// # Errors
    ///
    /// [`FrameError`] for a text frame that is not a JSON object with a string `type`, or a known
    /// control frame with an invalid payload. Binary frames always decode.
    pub fn decode(message: SocketMessage) -> Result<Self, FrameError> {
        match message {
            SocketMessage::Binary(bytes) => Ok(Self::Output(bytes)),
            SocketMessage::Text(text) => Self::decode_text(&text),
        }
    }

    fn decode_text(text: &str) -> Result<Self, FrameError> {
        let value: Value = serde_json::from_str(text).map_err(|error| FrameError::NotJson {
            message: error.to_string(),
        })?;
        let Value::Object(raw) = value else {
            return Err(FrameError::MissingType);
        };
        let Some(Value::String(frame_type)) = raw.get("type") else {
            return Err(FrameError::MissingType);
        };
        match frame_type.as_str() {
            "tmux-replies" => decode_replies(&raw),
            "clipboard-write" => decode_clipboard(&raw),
            other => Ok(Self::Unknown {
                frame_type: other.to_owned(),
                raw: raw.clone(),
            }),
        }
    }
}

fn decode_replies(raw: &Map<String, Value>) -> Result<ServerFrame, FrameError> {
    let invalid = |message: &str| FrameError::Invalid {
        frame_type: "tmux-replies",
        message: message.to_owned(),
    };
    let Some(Value::Array(values)) = raw.get("queries") else {
        return Err(invalid("queries is not an array"));
    };
    let queries = values
        .iter()
        .map(|value| value.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| invalid("a query is not a string"))?;
    Ok(ServerFrame::TmuxReplies { queries })
}

fn decode_clipboard(raw: &Map<String, Value>) -> Result<ServerFrame, FrameError> {
    let invalid = |message: String| FrameError::Invalid {
        frame_type: "clipboard-write",
        message,
    };
    match raw.get("encoding") {
        Some(Value::String(encoding)) if encoding == "base64" => {}
        other => return Err(invalid(format!("encoding is {other:?}, not base64"))),
    }
    let Some(Value::String(encoded)) = raw.get("data") else {
        return Err(invalid("data is not a string".to_owned()));
    };
    let limit = MAX_CLIPBOARD_BYTES.div_ceil(3) * 4;
    if encoded.is_empty() || encoded.len() > limit {
        return Err(invalid(format!(
            "data is {} base64 characters, outside 1..={limit}",
            encoded.len()
        )));
    }
    let data = STANDARD
        .decode(encoded)
        .map_err(|error| invalid(format!("data is not canonical base64: {error}")))?;
    if data.is_empty() || data.len() > MAX_CLIPBOARD_BYTES {
        return Err(invalid(format!("decoded {} bytes", data.len())));
    }
    if std::str::from_utf8(&data).is_err() {
        return Err(invalid("data is not UTF-8 text".to_owned()));
    }
    Ok(ServerFrame::ClipboardWrite { data })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn text(value: &Value) -> SocketMessage {
        SocketMessage::Text(value.to_string())
    }

    #[test]
    fn client_frames_match_the_bridge() {
        assert_eq!(
            ClientFrame::Input(b"ls\r".to_vec()).encode(),
            SocketMessage::Binary(b"ls\r".to_vec())
        );
        let SocketMessage::Text(resize) =
            ClientFrame::Resize(GridSize::new(120, 40).unwrap()).encode()
        else {
            panic!("resize is a text frame");
        };
        let parsed: Value = serde_json::from_str(&resize).unwrap();
        assert_eq!(parsed, json!({"type": "resize", "cols": 120, "rows": 40}));
    }

    #[test]
    fn grid_sizes_are_bounded() {
        assert!(GridSize::new(0, 24).is_none());
        assert!(GridSize::new(80, 0).is_none());
        assert!(GridSize::new(MAX_GRID_DIMENSION + 1, 24).is_none());
        assert!(GridSize::new(MAX_GRID_DIMENSION, MAX_GRID_DIMENSION).is_some());
    }

    #[test]
    fn decodes_output_and_control_frames() {
        assert_eq!(
            ServerFrame::decode(SocketMessage::Binary(vec![0x1b, b'[', b'H', 0xff])),
            Ok(ServerFrame::Output(vec![0x1b, b'[', b'H', 0xff]))
        );
        assert_eq!(
            ServerFrame::decode(text(
                &json!({"type": "tmux-replies", "queries": ["da1", "dsr:6"]})
            )),
            Ok(ServerFrame::TmuxReplies {
                queries: vec!["da1".into(), "dsr:6".into()]
            })
        );
        assert_eq!(
            ServerFrame::decode(text(
                &json!({"type": "clipboard-write", "encoding": "base64", "data": "aGVsbG8="})
            )),
            Ok(ServerFrame::ClipboardWrite {
                data: b"hello".to_vec()
            })
        );
        let unknown = ServerFrame::decode(text(&json!({"type": "future-thing", "x": 1}))).unwrap();
        assert!(
            matches!(unknown, ServerFrame::Unknown { ref frame_type, .. } if frame_type == "future-thing")
        );
    }

    #[test]
    fn rejects_malformed_control_frames() {
        for value in [
            json!({"type": "tmux-replies"}),
            json!({"type": "tmux-replies", "queries": [1]}),
            json!({"type": "clipboard-write", "encoding": "hex", "data": "00"}),
            json!({"type": "clipboard-write", "encoding": "base64", "data": ""}),
            json!({"type": "clipboard-write", "encoding": "base64", "data": "!!!!"}),
            json!({"type": "clipboard-write", "encoding": "base64", "data": "/w=="}),
            json!({"no": "type"}),
            json!([1, 2]),
        ] {
            assert!(ServerFrame::decode(text(&value)).is_err(), "{value}");
        }
        assert!(matches!(
            ServerFrame::decode(SocketMessage::Text("not json".into())),
            Err(FrameError::NotJson { .. })
        ));
        let oversized = "A".repeat(MAX_CLIPBOARD_BYTES.div_ceil(3) * 4 + 4);
        assert!(
            ServerFrame::decode(text(
                &json!({"type": "clipboard-write", "encoding": "base64", "data": oversized})
            ))
            .is_err()
        );
    }
}
