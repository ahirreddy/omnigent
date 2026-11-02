//! The runner ⇄ host Unix socket framing (design doc sections 5.2 and 5.7): a `u32`
//! little-endian payload length, a `u8` kind, then the payload.

use super::header::MAX_FRAME_BYTES;

/// Bytes before every payload.
pub const PREFIX_LEN: usize = 5;
/// Longest close reason, in bytes (the WebSocket limit).
pub const MAX_CLOSE_REASON: usize = 123;

const KIND_TEXT: u8 = 1;
const KIND_BINARY: u8 = 2;
const KIND_CLOSE: u8 = 3;

/// One socket frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnixFrame {
    /// One JSON text message.
    Text(String),
    /// One media frame, `RB` header included.
    Binary(Vec<u8>),
    /// The last frame in its direction.
    Close {
        /// The close code.
        code: u16,
        /// The reason.
        reason: String,
    },
}

/// Why socket bytes could not be framed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UnixFrameError {
    /// The length prefix is over the 16 MiB limit (close with 1009).
    #[error("socket frame of {len} bytes exceeds the 16 MiB limit")]
    TooLarge {
        /// The declared length.
        len: usize,
    },
    /// An unknown kind byte.
    #[error("socket frame kind {kind} is not 1, 2 or 3")]
    UnknownKind {
        /// The kind read.
        kind: u8,
    },
    /// A text frame or close reason that is not UTF-8.
    #[error("socket frame text is not UTF-8")]
    NotUtf8,
    /// A close payload without a code, or with an over-long reason.
    #[error("socket close payload of {len} bytes is malformed")]
    BadClose {
        /// The payload length.
        len: usize,
    },
}

impl UnixFrame {
    /// The frame's bytes.
    ///
    /// # Errors
    ///
    /// [`UnixFrameError::TooLarge`] or [`UnixFrameError::BadClose`] for a frame the peer would
    /// reject.
    pub fn encode(&self) -> Result<Vec<u8>, UnixFrameError> {
        let (kind, payload): (u8, Vec<u8>) = match self {
            Self::Text(text) => (KIND_TEXT, text.as_bytes().to_vec()),
            Self::Binary(bytes) => (KIND_BINARY, bytes.clone()),
            Self::Close { code, reason } => {
                if reason.len() > MAX_CLOSE_REASON {
                    return Err(UnixFrameError::BadClose {
                        len: 2 + reason.len(),
                    });
                }
                let mut payload = code.to_le_bytes().to_vec();
                payload.extend_from_slice(reason.as_bytes());
                (KIND_CLOSE, payload)
            }
        };
        if payload.len() > MAX_FRAME_BYTES {
            return Err(UnixFrameError::TooLarge { len: payload.len() });
        }
        let len = u32::try_from(payload.len())
            .map_err(|_| UnixFrameError::TooLarge { len: payload.len() })?;
        let mut out = Vec::with_capacity(PREFIX_LEN + payload.len());
        out.extend_from_slice(&len.to_le_bytes());
        out.push(kind);
        out.extend_from_slice(&payload);
        Ok(out)
    }

    fn from_parts(kind: u8, payload: Vec<u8>) -> Result<Self, UnixFrameError> {
        match kind {
            KIND_TEXT => String::from_utf8(payload)
                .map(Self::Text)
                .map_err(|_| UnixFrameError::NotUtf8),
            KIND_BINARY => Ok(Self::Binary(payload)),
            KIND_CLOSE => {
                let len = payload.len();
                let (Some(code), Some(reason)) = (payload.get(..2), payload.get(2..)) else {
                    return Err(UnixFrameError::BadClose { len });
                };
                if reason.len() > MAX_CLOSE_REASON {
                    return Err(UnixFrameError::BadClose { len });
                }
                let code = u16::from_le_bytes(
                    code.try_into()
                        .map_err(|_| UnixFrameError::BadClose { len })?,
                );
                let reason =
                    String::from_utf8(reason.to_vec()).map_err(|_| UnixFrameError::NotUtf8)?;
                Ok(Self::Close { code, reason })
            }
            kind => Err(UnixFrameError::UnknownKind { kind }),
        }
    }
}

/// Reassembles frames from socket reads of any size.
#[derive(Debug, Default, Clone)]
pub struct UnixFrameDecoder {
    buffer: Vec<u8>,
}

impl UnixFrameDecoder {
    /// An empty decoder.
    #[must_use]
    pub const fn new() -> Self {
        Self { buffer: Vec::new() }
    }

    /// Appends `bytes` and returns every frame they complete, in order.
    ///
    /// # Errors
    ///
    /// [`UnixFrameError`] for a frame the protocol forbids; the connection must then close.
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<UnixFrame>, UnixFrameError> {
        self.buffer.extend_from_slice(bytes);
        let mut frames = Vec::new();
        let mut start = 0;
        while let Some(prefix) = self.buffer.get(start..start + PREFIX_LEN) {
            let mut len_bytes = [0_u8; 4];
            len_bytes.copy_from_slice(prefix.get(..4).unwrap_or(&[0; 4]));
            let len = usize::try_from(u32::from_le_bytes(len_bytes))
                .map_err(|_| UnixFrameError::TooLarge { len: usize::MAX })?;
            if len > MAX_FRAME_BYTES {
                return Err(UnixFrameError::TooLarge { len });
            }
            let kind = prefix.get(4).copied().unwrap_or_default();
            let body_start = start + PREFIX_LEN;
            let Some(payload) = self.buffer.get(body_start..body_start + len) else {
                break;
            };
            frames.push(UnixFrame::from_parts(kind, payload.to_vec())?);
            start = body_start + len;
        }
        self.buffer.drain(..start);
        Ok(frames)
    }

    /// Bytes buffered toward an incomplete frame. Non-zero at EOF means the peer died mid-frame.
    #[must_use]
    pub const fn pending(&self) -> usize {
        self.buffer.len()
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    fn frames() -> Vec<UnixFrame> {
        vec![
            UnixFrame::Text(r#"{"type":"attach"}"#.to_owned()),
            UnixFrame::Binary(vec![1, 2, 3, 4, 5]),
            UnixFrame::Binary(Vec::new()),
            UnixFrame::Close {
                code: 4404,
                reason: "tab closed".to_owned(),
            },
        ]
    }

    #[test]
    fn rejects_forbidden_frames() {
        let mut decoder = UnixFrameDecoder::new();
        assert_eq!(
            decoder.push(&[0, 0, 0, 0, 9]),
            Err(UnixFrameError::UnknownKind { kind: 9 })
        );
        let mut decoder = UnixFrameDecoder::new();
        assert_eq!(
            decoder.push(&[0xFF, 0xFF, 0xFF, 0x7F, 1]),
            Err(UnixFrameError::TooLarge { len: 0x7FFF_FFFF })
        );
        let mut decoder = UnixFrameDecoder::new();
        assert_eq!(
            decoder.push(&[1, 0, 0, 0, 3, 0]),
            Err(UnixFrameError::BadClose { len: 1 })
        );
        let mut decoder = UnixFrameDecoder::new();
        assert_eq!(
            decoder.push(&[1, 0, 0, 0, 1, 0xFF]),
            Err(UnixFrameError::NotUtf8)
        );
        assert!(
            UnixFrame::Close {
                code: 1000,
                reason: "x".repeat(124)
            }
            .encode()
            .is_err()
        );
    }

    proptest! {
        #[test]
        fn any_chunking_yields_the_same_frames(cuts in proptest::collection::vec(0_usize..64, 0..12)) {
            let expected = frames();
            let mut stream = Vec::new();
            for frame in &expected {
                stream.extend(frame.encode().unwrap());
            }
            let mut points: Vec<usize> = cuts.into_iter().map(|cut| cut % (stream.len() + 1)).collect();
            points.push(stream.len());
            points.sort_unstable();
            let mut decoder = UnixFrameDecoder::new();
            let mut decoded = Vec::new();
            let mut last = 0;
            for point in points {
                decoded.extend(decoder.push(&stream[last..point]).unwrap());
                last = point;
            }
            prop_assert_eq!(decoded, expected);
            prop_assert_eq!(decoder.pending(), 0);
        }
    }
}
