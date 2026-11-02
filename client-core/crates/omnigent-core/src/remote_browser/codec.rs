//! H.264 Annex-B handling for the remote browser stream.
//!
//! NAL splitting (whole buffers and streamed chunks), access-unit assembly, Annex-B to AVCC
//! conversion with SPS/PPS extraction, and the per-connection video track that detects format
//! changes and missing keyframes.
//!
//! AVCC here means what `CMSampleBuffer` wants: each NAL unit prefixed by its length as a 4-byte
//! big-endian integer, without start codes. Parameter sets go to the format description, so they
//! and the NAL types the decoder does not need (AUD, SEI, filler) are left out.

use omnigent_protocol::remote_browser::{KeyframeReason, MediaHeader};

/// NAL unit types this module cares about.
pub mod nal_type {
    /// Coded slice of a non-IDR picture.
    pub const SLICE: u8 = 1;
    /// Coded slice of an IDR picture.
    pub const IDR: u8 = 5;
    /// Supplemental enhancement information.
    pub const SEI: u8 = 6;
    /// Sequence parameter set.
    pub const SPS: u8 = 7;
    /// Picture parameter set.
    pub const PPS: u8 = 8;
    /// Access unit delimiter.
    pub const AUD: u8 = 9;
    /// Filler data.
    pub const FILLER: u8 = 12;
}

/// The `nal_unit_type` of a NAL unit (without start code).
#[must_use]
pub fn type_of(nal: &[u8]) -> Option<u8> {
    nal.first().map(|header| header & 0x1F)
}

const fn is_vcl(nal_type: u8) -> bool {
    matches!(nal_type, 1..=5)
}

/// Finds the next start code (`00 00 01`) at or after `from`. Returns the index of its `01`.
fn next_start_code(data: &[u8], from: usize) -> Option<usize> {
    let mut index = from;
    while let Some(window) = data.get(index..index + 3) {
        if window == [0, 0, 1] {
            return Some(index + 2);
        }
        // Skip ahead: a start code cannot begin inside a window whose third byte is > 1.
        index += if window.get(2).is_some_and(|byte| *byte > 1) {
            3
        } else {
            1
        };
    }
    None
}

/// Trailing zero bytes are `trailing_zero_8bits` or the first byte of a 4-byte start code; a NAL
/// unit never ends in zero.
fn trim_trailing_zeros(nal: &[u8]) -> &[u8] {
    let end = nal
        .iter()
        .rposition(|byte| *byte != 0)
        .map_or(0, |last| last + 1);
    nal.get(..end).unwrap_or_default()
}

/// The NAL units of a complete Annex-B buffer, without start codes. Bytes before the first start
/// code are ignored (there are none in a conforming stream).
#[must_use]
pub fn split_nal_units(data: &[u8]) -> Vec<&[u8]> {
    let mut units = Vec::new();
    let Some(mut start) = next_start_code(data, 0).map(|one| one + 1) else {
        return units;
    };
    loop {
        let next = next_start_code(data, start);
        let end = next.map_or(data.len(), |one| one - 2);
        let unit = trim_trailing_zeros(data.get(start..end).unwrap_or_default());
        if !unit.is_empty() {
            units.push(unit);
        }
        match next {
            Some(one) => start = one + 1,
            None => return units,
        }
    }
}

/// Splits an Annex-B byte stream that arrives in arbitrary chunks (a pipe from an encoder) into
/// NAL units.
#[derive(Debug, Default, Clone)]
pub struct NalSplitter {
    buffer: Vec<u8>,
    /// Index in `buffer` where the current NAL unit's payload starts, once a start code was seen.
    current: Option<usize>,
    /// Where to resume scanning for the next start code.
    scan_from: usize,
}

impl NalSplitter {
    /// An empty splitter.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            buffer: Vec::new(),
            current: None,
            scan_from: 0,
        }
    }

    /// Appends `chunk` and returns every NAL unit it completes.
    pub fn push(&mut self, chunk: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(chunk);
        let mut units = Vec::new();
        while let Some(one) = next_start_code(&self.buffer, self.scan_from) {
            if let Some(start) = self.current {
                let end = one.saturating_sub(2);
                let unit = trim_trailing_zeros(self.buffer.get(start..end).unwrap_or_default());
                if !unit.is_empty() {
                    units.push(unit.to_vec());
                }
            }
            self.current = Some(one + 1);
            self.scan_from = one + 1;
        }
        // Keep two bytes of look-behind so a start code split across chunks is found.
        self.scan_from = self
            .buffer
            .len()
            .saturating_sub(2)
            .max(self.current.unwrap_or(0));
        let keep_from = self.current.unwrap_or(self.scan_from);
        if keep_from > 0 {
            self.buffer.drain(..keep_from);
            self.scan_from -= keep_from;
            self.current = self.current.map(|start| start - keep_from);
        }
        units
    }

    /// The end of the stream: the last NAL unit, if any.
    pub fn finish(&mut self) -> Option<Vec<u8>> {
        let start = self.current.take()?;
        let unit = trim_trailing_zeros(self.buffer.get(start..).unwrap_or_default()).to_vec();
        self.buffer.clear();
        self.scan_from = 0;
        (!unit.is_empty()).then_some(unit)
    }
}

/// Groups NAL units into access units (ITU-T H.264 7.4.1.2.3): a new one starts at an AUD, at
/// an SPS, PPS or SEI after a slice, or at a slice with `first_mb_in_slice == 0` after a slice.
#[derive(Debug, Default, Clone)]
pub struct AccessUnitAssembler {
    current: Vec<Vec<u8>>,
    seen_vcl: bool,
}

impl AccessUnitAssembler {
    /// An empty assembler.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            current: Vec::new(),
            seen_vcl: false,
        }
    }

    /// Adds one NAL unit; returns the previous access unit (as Annex-B) when this one starts a
    /// new access unit.
    pub fn push(&mut self, nal: Vec<u8>) -> Option<Vec<u8>> {
        let nal_kind = type_of(&nal)?;
        let first_slice = is_vcl(nal_kind) && nal.get(1).is_some_and(|byte| byte & 0x80 != 0);
        let starts_new = self.seen_vcl
            && (nal_kind == nal_type::AUD
                || matches!(nal_kind, nal_type::SPS | nal_type::PPS | nal_type::SEI)
                || first_slice);
        let finished = if starts_new { self.take() } else { None };
        if is_vcl(nal_kind) {
            self.seen_vcl = true;
        }
        self.current.push(nal);
        finished
    }

    /// The end of the stream: the last access unit, if any.
    pub fn finish(&mut self) -> Option<Vec<u8>> {
        self.take()
    }

    fn take(&mut self) -> Option<Vec<u8>> {
        if self.current.is_empty() {
            return None;
        }
        self.seen_vcl = false;
        Some(annex_b(&std::mem::take(&mut self.current)))
    }
}

/// NAL units joined with 4-byte start codes.
#[must_use]
pub fn annex_b(units: &[Vec<u8>]) -> Vec<u8> {
    let mut out = Vec::with_capacity(units.iter().map(|unit| unit.len() + 4).sum());
    for unit in units {
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(unit);
    }
    out
}

/// One SPS and one PPS, without start codes or emulation-prevention changes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ParameterSets {
    /// The sequence parameter set NAL unit.
    pub sps: Vec<u8>,
    /// The picture parameter set NAL unit.
    pub pps: Vec<u8>,
}

/// An access unit converted for a hardware decoder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AvccUnit {
    /// The access unit holds an IDR slice.
    pub keyframe: bool,
    /// The SPS and PPS it carried, when it carried both.
    pub params: Option<ParameterSets>,
    /// Slice NAL units with 4-byte big-endian length prefixes.
    pub avcc: Vec<u8>,
}

/// Why an access unit could not be converted.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CodecError {
    /// No start code: the payload is not Annex-B.
    #[error("the access unit has no Annex-B start code")]
    NotAnnexB,
    /// No slice NAL unit.
    #[error("the access unit has no coded slice")]
    NoSlice,
    /// The header says keyframe but the access unit has no IDR slice, or the reverse.
    #[error("the keyframe flag ({flag}) does not match the access unit (IDR slice: {idr})")]
    KeyframeMismatch {
        /// The header's flag.
        flag: bool,
        /// Whether an IDR slice is present.
        idr: bool,
    },
    /// A keyframe without its SPS and PPS.
    #[error("the keyframe does not carry its SPS and PPS")]
    MissingParameterSets,
    /// A NAL unit longer than a 4-byte length prefix can express.
    #[error("a NAL unit of {len} bytes is too large")]
    NalTooLarge {
        /// Its length.
        len: usize,
    },
}

/// Converts one Annex-B access unit to AVCC and pulls out its SPS and PPS.
///
/// # Errors
///
/// [`CodecError`] for a payload that is not a usable access unit.
pub fn annex_b_to_avcc(access_unit: &[u8]) -> Result<AvccUnit, CodecError> {
    let units = split_nal_units(access_unit);
    if units.is_empty() {
        return Err(CodecError::NotAnnexB);
    }
    let mut sps = None;
    let mut pps = None;
    let mut keyframe = false;
    let mut slices = false;
    let mut avcc = Vec::with_capacity(access_unit.len());
    for unit in units {
        match type_of(unit) {
            Some(nal_type::SPS) => sps = Some(unit.to_vec()),
            Some(nal_type::PPS) => pps = Some(unit.to_vec()),
            Some(nal_type::AUD | nal_type::SEI | nal_type::FILLER) | None => {}
            Some(kind) => {
                if is_vcl(kind) {
                    slices = true;
                    keyframe |= kind == nal_type::IDR;
                }
                let len = u32::try_from(unit.len())
                    .map_err(|_| CodecError::NalTooLarge { len: unit.len() })?;
                avcc.extend_from_slice(&len.to_be_bytes());
                avcc.extend_from_slice(unit);
            }
        }
    }
    if !slices {
        return Err(CodecError::NoSlice);
    }
    let params = match (sps, pps) {
        (Some(sps), Some(pps)) => Some(ParameterSets { sps, pps }),
        _ => None,
    };
    Ok(AvccUnit {
        keyframe,
        params,
        avcc,
    })
}

/// A frame ready for the platform decoder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VideoFrame {
    /// The H.264 stream.
    pub stream_id: u32,
    /// An IDR: the decoder can start here.
    pub keyframe: bool,
    /// Host capture time, µs.
    pub pts_us: u64,
    /// The stream's SPS and PPS, on every keyframe.
    pub params: Option<ParameterSets>,
    /// The parameter sets differ from the previous stream's (or this is the first stream):
    /// rebuild the format description before decoding.
    pub format_changed: bool,
    /// Slice NAL units, AVCC.
    pub avcc: Vec<u8>,
}

/// Why a video frame was not delivered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VideoDrop {
    /// A delta before the first keyframe of its stream, or after a gap.
    AwaitingKeyframe {
        /// The delta's stream.
        stream_id: u32,
    },
    /// The payload could not be converted.
    Malformed(CodecError),
}

/// What a video frame became.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VideoOutcome {
    /// Deliver it.
    Frame(VideoFrame),
    /// Dropped; ask for a keyframe when `request` is set.
    Dropped {
        /// Why.
        reason: VideoDrop,
        /// Send `keyframe_request` with this reason (at most once per stream).
        request: Option<KeyframeReason>,
    },
}

/// The video state of one connection.
#[derive(Debug, Default, Clone)]
pub struct VideoTrack {
    stream_id: Option<u32>,
    params: Option<ParameterSets>,
    keyframe_requested: bool,
}

impl VideoTrack {
    /// A track waiting for its first keyframe.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            stream_id: None,
            params: None,
            keyframe_requested: false,
        }
    }

    /// A new connection: wait for a keyframe again. The last parameter sets are kept, so a
    /// keyframe with the same SPS and PPS is not a format change.
    pub const fn reset(&mut self) {
        self.stream_id = None;
        self.keyframe_requested = false;
    }

    /// The stream being decoded.
    #[must_use]
    pub const fn stream_id(&self) -> Option<u32> {
        self.stream_id
    }

    /// Converts one H.264 frame.
    pub fn accept(&mut self, header: &MediaHeader, payload: &[u8]) -> VideoOutcome {
        let unit = match annex_b_to_avcc(payload).and_then(|unit| {
            if unit.keyframe == header.keyframe {
                Ok(unit)
            } else {
                Err(CodecError::KeyframeMismatch {
                    flag: header.keyframe,
                    idr: unit.keyframe,
                })
            }
        }) {
            Ok(unit) => unit,
            Err(error) => {
                self.stream_id = None;
                return self.drop_with(VideoDrop::Malformed(error), KeyframeReason::Gap);
            }
        };
        if unit.keyframe {
            let Some(params) = unit.params else {
                self.stream_id = None;
                return self.drop_with(
                    VideoDrop::Malformed(CodecError::MissingParameterSets),
                    KeyframeReason::Gap,
                );
            };
            let format_changed = self.params.as_ref() != Some(&params);
            self.params = Some(params.clone());
            self.stream_id = Some(header.stream_id);
            self.keyframe_requested = false;
            return VideoOutcome::Frame(VideoFrame {
                stream_id: header.stream_id,
                keyframe: true,
                pts_us: header.pts_us,
                params: Some(params),
                format_changed,
                avcc: unit.avcc,
            });
        }
        if self.stream_id != Some(header.stream_id) {
            self.stream_id = None;
            return self.drop_with(
                VideoDrop::AwaitingKeyframe {
                    stream_id: header.stream_id,
                },
                KeyframeReason::Gap,
            );
        }
        VideoOutcome::Frame(VideoFrame {
            stream_id: header.stream_id,
            keyframe: false,
            pts_us: header.pts_us,
            params: None,
            format_changed: false,
            avcc: unit.avcc,
        })
    }

    /// A frame was lost or unreadable: wait for a keyframe. Returns the request to send, once
    /// per wait.
    pub fn gap(&mut self) -> Option<KeyframeReason> {
        self.stream_id?;
        self.stream_id = None;
        (!std::mem::replace(&mut self.keyframe_requested, true)).then_some(KeyframeReason::Gap)
    }

    /// Drops a frame, asking for a keyframe once until the next one arrives.
    fn drop_with(&mut self, reason: VideoDrop, request: KeyframeReason) -> VideoOutcome {
        let request = (!std::mem::replace(&mut self.keyframe_requested, true)).then_some(request);
        VideoOutcome::Dropped { reason, request }
    }
}

/// A bounded, latest-wins queue between the attach loop and a slow renderer.
///
/// When it is full, a keyframe replaces everything queued; a delta clears the queue and starts
/// skipping until the next keyframe, and the caller asks the host for one. A format change on a
/// discarded keyframe carries over to the next keyframe, so the renderer never misses one.
#[derive(Debug, Clone)]
pub struct VideoQueue {
    capacity: usize,
    frames: std::collections::VecDeque<VideoFrame>,
    skipping: bool,
    format_change_pending: bool,
}

/// What [`VideoQueue::push`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueuePush {
    /// Queued.
    Queued,
    /// A keyframe replaced the frames queued before it.
    Replaced {
        /// Frames discarded.
        dropped: usize,
    },
    /// The queue overflowed on a delta and now skips to the next keyframe: send
    /// `keyframe_request` (`flush`).
    Overflowed {
        /// Frames discarded, the new delta included.
        dropped: usize,
    },
    /// Discarded while skipping to a keyframe.
    Skipped,
}

impl VideoQueue {
    /// A queue holding at most `capacity` frames (at least 1).
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            frames: std::collections::VecDeque::new(),
            skipping: false,
            format_change_pending: false,
        }
    }

    fn discard_all(&mut self) -> usize {
        let dropped = self.frames.len();
        self.format_change_pending |= self.frames.iter().any(|frame| frame.format_changed);
        self.frames.clear();
        dropped
    }

    /// Adds a frame.
    pub fn push(&mut self, mut frame: VideoFrame) -> QueuePush {
        if frame.keyframe {
            self.skipping = false;
            let dropped = if self.frames.len() >= self.capacity {
                self.discard_all()
            } else {
                0
            };
            frame.format_changed |= std::mem::take(&mut self.format_change_pending);
            self.frames.push_back(frame);
            return if dropped == 0 {
                QueuePush::Queued
            } else {
                QueuePush::Replaced { dropped }
            };
        }
        if self.skipping {
            return QueuePush::Skipped;
        }
        if self.frames.len() >= self.capacity {
            let dropped = self.discard_all() + 1;
            self.skipping = true;
            return QueuePush::Overflowed { dropped };
        }
        self.frames.push_back(frame);
        QueuePush::Queued
    }

    /// The oldest frame.
    pub fn pop(&mut self) -> Option<VideoFrame> {
        self.frames.pop_front()
    }

    /// Frames waiting.
    #[must_use]
    pub fn len(&self) -> usize {
        self.frames.len()
    }

    /// Nothing waiting.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }

    /// Forgets everything (a new connection). A pending format change is kept.
    pub fn clear(&mut self) {
        self.discard_all();
        self.skipping = false;
    }
}

#[cfg(test)]
#[path = "codec_tests.rs"]
mod tests;
