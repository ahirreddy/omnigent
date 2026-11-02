//! The 24-byte little-endian `RB` media header that starts every binary frame (design doc
//! section 5.2).

/// `magic`: the bytes `52 42` ("RB") read as a little-endian `u16`.
pub const MAGIC: u16 = 0x4252;
/// The binary header version of protocol v1.
pub const HEADER_VERSION: u8 = 1;
/// Header length in v1. Receivers accept longer headers and skip the extra bytes.
pub const HEADER_LEN: usize = 24;
/// Largest binary frame, header included. Larger frames close the connection with 1009.
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

const FLAG_KEYFRAME: u16 = 1;
const FLAG_NEW_STREAM: u16 = 1 << 1;

/// What a binary frame carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MediaKind {
    /// One H.264 access unit, Annex-B.
    H264,
    /// A full-viewport JPEG.
    JpegStill,
    /// A JPEG thumbnail, at most 320 px wide.
    JpegThumbnail,
    /// A kind newer than this client. Ack it, then ignore it.
    Unknown(u8),
}

impl MediaKind {
    /// The wire value.
    #[must_use]
    pub const fn to_wire(self) -> u8 {
        match self {
            Self::H264 => 1,
            Self::JpegStill => 2,
            Self::JpegThumbnail => 3,
            Self::Unknown(value) => value,
        }
    }

    /// Maps a wire value.
    #[must_use]
    pub const fn from_wire(value: u8) -> Self {
        match value {
            1 => Self::H264,
            2 => Self::JpegStill,
            3 => Self::JpegThumbnail,
            other => Self::Unknown(other),
        }
    }
}

/// A decoded media header.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MediaHeader {
    /// What the payload is.
    pub kind: MediaKind,
    /// The access unit is an IDR.
    pub keyframe: bool,
    /// The first frame of `stream_id`.
    pub new_stream: bool,
    /// Per-connection sequence number, from 1. Acked by the client.
    pub seq: u32,
    /// The H.264 stream (0 for JPEG).
    pub stream_id: u32,
    /// Host monotonic capture time, µs.
    pub pts_us: u64,
}

/// Why a binary frame could not be decoded.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HeaderError {
    /// Fewer bytes than a header.
    #[error("binary frame of {len} bytes is shorter than the 24-byte media header")]
    Truncated {
        /// The frame length.
        len: usize,
    },
    /// The first two bytes are not `RB`.
    #[error("binary frame magic is {found:#06x}, not 0x4252")]
    BadMagic {
        /// The value read.
        found: u16,
    },
    /// A header version this client does not speak.
    #[error("binary frame header version {version} is not supported")]
    UnsupportedVersion {
        /// The version read.
        version: u8,
        /// The sequence number, so the frame can still be acked.
        seq: u32,
    },
    /// `header_len` is below 24 or past the end of the frame.
    #[error("binary frame header length {header_len} does not fit a {frame_len}-byte frame")]
    BadHeaderLen {
        /// The value read.
        header_len: u16,
        /// The frame length.
        frame_len: usize,
        /// The sequence number, so the frame can still be acked.
        seq: u32,
    },
    /// The frame is over [`MAX_FRAME_BYTES`].
    #[error("binary frame of {len} bytes exceeds the 16 MiB limit")]
    TooLarge {
        /// The frame length.
        len: usize,
    },
}

impl HeaderError {
    /// The sequence number of a frame whose header could be read far enough, for acking.
    #[must_use]
    pub const fn seq(&self) -> Option<u32> {
        match self {
            Self::UnsupportedVersion { seq, .. } | Self::BadHeaderLen { seq, .. } => Some(*seq),
            Self::Truncated { .. } | Self::BadMagic { .. } | Self::TooLarge { .. } => None,
        }
    }
}

/// One decoded binary frame, borrowing its payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MediaFrame<'a> {
    /// The header.
    pub header: MediaHeader,
    /// The bytes after the header (and any extension bytes).
    pub payload: &'a [u8],
}

fn u16_at(bytes: &[u8], offset: usize) -> Option<u16> {
    let pair = bytes.get(offset..offset.checked_add(2)?)?;
    Some(u16::from_le_bytes(pair.try_into().ok()?))
}

fn u32_at(bytes: &[u8], offset: usize) -> Option<u32> {
    let quad = bytes.get(offset..offset.checked_add(4)?)?;
    Some(u32::from_le_bytes(quad.try_into().ok()?))
}

fn u64_at(bytes: &[u8], offset: usize) -> Option<u64> {
    let octet = bytes.get(offset..offset.checked_add(8)?)?;
    Some(u64::from_le_bytes(octet.try_into().ok()?))
}

impl MediaHeader {
    /// The 24 header bytes.
    #[must_use]
    pub fn encode(&self) -> [u8; HEADER_LEN] {
        let mut flags = 0;
        if self.keyframe {
            flags |= FLAG_KEYFRAME;
        }
        if self.new_stream {
            flags |= FLAG_NEW_STREAM;
        }
        let mut out = [0_u8; HEADER_LEN];
        let fields: [(usize, &[u8]); 8] = [
            (0, &MAGIC.to_le_bytes()),
            (2, &[HEADER_VERSION]),
            (3, &[self.kind.to_wire()]),
            (4, &flags.to_le_bytes()),
            (6, &24_u16.to_le_bytes()),
            (8, &self.seq.to_le_bytes()),
            (12, &self.stream_id.to_le_bytes()),
            (16, &self.pts_us.to_le_bytes()),
        ];
        for (offset, bytes) in fields {
            if let Some(slot) = out.get_mut(offset..offset + bytes.len()) {
                slot.copy_from_slice(bytes);
            }
        }
        out
    }

    /// A complete frame: this header, then `payload`.
    #[must_use]
    pub fn encode_frame(&self, payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
        out.extend_from_slice(&self.encode());
        out.extend_from_slice(payload);
        out
    }
}

/// Decodes one binary frame.
///
/// # Errors
///
/// [`HeaderError`] for a short, oversized or malformed frame.
pub fn decode_frame(bytes: &[u8]) -> Result<MediaFrame<'_>, HeaderError> {
    let len = bytes.len();
    if len > MAX_FRAME_BYTES {
        return Err(HeaderError::TooLarge { len });
    }
    let truncated = HeaderError::Truncated { len };
    if len < HEADER_LEN {
        return Err(truncated);
    }
    let magic = u16_at(bytes, 0).ok_or_else(|| truncated.clone())?;
    if magic != MAGIC {
        return Err(HeaderError::BadMagic { found: magic });
    }
    let version = bytes.get(2).copied().ok_or_else(|| truncated.clone())?;
    let seq = u32_at(bytes, 8).ok_or_else(|| truncated.clone())?;
    if version != HEADER_VERSION {
        return Err(HeaderError::UnsupportedVersion { version, seq });
    }
    let kind = MediaKind::from_wire(bytes.get(3).copied().ok_or_else(|| truncated.clone())?);
    let flags = u16_at(bytes, 4).ok_or_else(|| truncated.clone())?;
    let header_len = u16_at(bytes, 6).ok_or_else(|| truncated.clone())?;
    let stream_id = u32_at(bytes, 12).ok_or_else(|| truncated.clone())?;
    let pts_us = u64_at(bytes, 16).ok_or(truncated)?;
    let payload = usize::from(header_len)
        .checked_sub(HEADER_LEN)
        .and_then(|_| bytes.get(usize::from(header_len)..))
        .ok_or(HeaderError::BadHeaderLen {
            header_len,
            frame_len: len,
            seq,
        })?;
    Ok(MediaFrame {
        header: MediaHeader {
            kind,
            keyframe: flags & FLAG_KEYFRAME != 0,
            new_stream: flags & FLAG_NEW_STREAM != 0,
            seq,
            stream_id,
            pts_us,
        },
        payload,
    })
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    fn header() -> MediaHeader {
        MediaHeader {
            kind: MediaKind::H264,
            keyframe: true,
            new_stream: true,
            seq: 1,
            stream_id: 7,
            pts_us: 1_000_000,
        }
    }

    #[test]
    fn layout_is_little_endian_with_rb_magic() {
        let bytes = header().encode();
        assert_eq!(&bytes[..4], &[0x52, 0x42, 1, 1]);
        assert_eq!(&bytes[4..8], &[3, 0, 24, 0]);
        assert_eq!(&bytes[8..12], &[1, 0, 0, 0]);
        assert_eq!(&bytes[12..16], &[7, 0, 0, 0]);
        assert_eq!(&bytes[16..24], &1_000_000_u64.to_le_bytes());
    }

    #[test]
    fn rejects_short_bad_and_oversized_frames() {
        assert_eq!(
            decode_frame(&[0x52, 0x42]),
            Err(HeaderError::Truncated { len: 2 })
        );
        let mut swapped = header().encode();
        swapped[0] = 0x42;
        swapped[1] = 0x52;
        assert_eq!(
            decode_frame(&swapped),
            Err(HeaderError::BadMagic { found: 0x5242 })
        );
        let mut short_len = header().encode();
        short_len[6] = 16;
        let error = decode_frame(&short_len).unwrap_err();
        assert_eq!(error.seq(), Some(1));
        let mut long_len = header().encode();
        long_len[6] = 40;
        assert!(matches!(
            decode_frame(&long_len),
            Err(HeaderError::BadHeaderLen { header_len: 40, .. })
        ));
        let huge = vec![0_u8; MAX_FRAME_BYTES + 1];
        assert!(matches!(
            decode_frame(&huge),
            Err(HeaderError::TooLarge { .. })
        ));
    }

    #[test]
    fn longer_headers_skip_their_extension_and_unknown_flag_bits_are_ignored() {
        let mut bytes = header().encode().to_vec();
        bytes[4] = 0xFF;
        bytes[6] = 28;
        bytes.extend_from_slice(&[9, 9, 9, 9, 0xAA]);
        let frame = decode_frame(&bytes).unwrap();
        assert_eq!(frame.payload, &[0xAA]);
        assert!(frame.header.keyframe && frame.header.new_stream);
    }

    proptest! {
        #[test]
        fn header_round_trips(
            kind in any::<u8>(),
            keyframe in any::<bool>(),
            new_stream in any::<bool>(),
            seq in any::<u32>(),
            stream_id in any::<u32>(),
            pts_us in any::<u64>(),
            payload in proptest::collection::vec(any::<u8>(), 0..256),
        ) {
            let header = MediaHeader {
                kind: MediaKind::from_wire(kind),
                keyframe,
                new_stream,
                seq,
                stream_id,
                pts_us,
            };
            let bytes = header.encode_frame(&payload);
            let frame = decode_frame(&bytes).unwrap();
            prop_assert_eq!(frame.header, header);
            prop_assert_eq!(frame.payload, payload.as_slice());
            prop_assert_eq!(MediaKind::from_wire(kind).to_wire(), kind);
        }

        #[test]
        fn arbitrary_bytes_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..64)) {
            if let Ok(frame) = decode_frame(&bytes) {
                prop_assert!(frame.payload.len() + HEADER_LEN <= bytes.len());
            }
        }
    }
}
