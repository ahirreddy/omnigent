use omnigent_protocol::remote_browser::{MediaHeader, MediaKind};
use proptest::prelude::*;

use super::*;
use crate::remote_browser::test_support::{access_units, fixture_bytes, fixture_json, hex};

fn types(units: &[&[u8]]) -> Vec<u8> {
    units.iter().map(|unit| type_of(unit).unwrap()).collect()
}

fn header(keyframe: bool, stream_id: u32, pts_us: u64) -> MediaHeader {
    MediaHeader {
        kind: MediaKind::H264,
        keyframe,
        new_stream: keyframe,
        seq: 1,
        stream_id,
        pts_us,
    }
}

#[test]
fn splits_the_fixture_idr_into_its_nal_units() {
    let units = access_units("testsrc_1280x800");
    let first = split_nal_units(&units[0]);
    assert_eq!(
        types(&first),
        [9, 7, 8, 6, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5]
    );
    assert!(first.iter().all(|unit| unit.last() != Some(&0)));
    assert_eq!(types(&split_nal_units(&units[1]))[..2], [9, 1]);
    assert_eq!(split_nal_units(&[1, 2, 3]).len(), 0);
    assert_eq!(
        split_nal_units(&[0, 0, 1, 0x65, 0xAA, 0, 0, 0, 1, 0x41, 0xBB, 0]),
        vec![&[0x65_u8, 0xAA][..], &[0x41, 0xBB][..]]
    );
}

#[test]
fn converts_the_fixture_idr_to_avcc_with_its_parameter_sets() {
    let table = fixture_json("h264/testsrc_1280x800.frames.json");
    let units = access_units("testsrc_1280x800");
    let unit = annex_b_to_avcc(&units[0]).unwrap();
    assert!(unit.keyframe);
    let params = unit.params.unwrap();
    assert_eq!(params.sps, hex(table["sps_hex"].as_str().unwrap()));
    assert_eq!(params.pps, hex(table["pps_hex"].as_str().unwrap()));
    // Profile 66 (Baseline) with constraint_set1 (Constrained Baseline).
    assert_eq!(params.sps[1], 66);
    assert_ne!(params.sps[2] & 0x40, 0);
    let mut rest = unit.avcc.as_slice();
    let mut slices = 0;
    while !rest.is_empty() {
        let len = usize::try_from(u32::from_be_bytes(rest[..4].try_into().unwrap())).unwrap();
        assert_eq!(type_of(&rest[4..]), Some(nal_type::IDR));
        rest = &rest[4 + len..];
        slices += 1;
    }
    assert_eq!(slices, 12);
    let delta = annex_b_to_avcc(&units[1]).unwrap();
    assert!(!delta.keyframe);
    assert_eq!(delta.params, None);
}

#[test]
fn rejects_payloads_that_are_not_access_units() {
    assert_eq!(annex_b_to_avcc(b"nope"), Err(CodecError::NotAnnexB));
    assert_eq!(
        annex_b_to_avcc(&[0, 0, 1, 0x09, 0x10, 0, 0, 1, 0x67, 0x42]),
        Err(CodecError::NoSlice)
    );
}

#[test]
fn track_detects_format_changes_and_waits_for_keyframes() {
    let big = access_units("testsrc_1280x800");
    let small = access_units("testsrc_640x400");
    let mut track = VideoTrack::new();
    let VideoOutcome::Dropped { request, .. } = track.accept(&header(false, 1, 0), &big[1]) else {
        panic!("a delta before any keyframe must drop");
    };
    assert_eq!(request, Some(KeyframeReason::Gap));
    let VideoOutcome::Dropped { request, .. } = track.accept(&header(false, 1, 0), &big[2]) else {
        panic!("still waiting");
    };
    assert_eq!(request, None, "one request per wait");
    let VideoOutcome::Frame(first) = track.accept(&header(true, 7, 10), &big[0]) else {
        panic!("keyframe");
    };
    assert!(first.keyframe && first.format_changed && first.params.is_some());
    let VideoOutcome::Frame(delta) = track.accept(&header(false, 7, 20), &big[1]) else {
        panic!("delta");
    };
    assert!(!delta.keyframe && delta.params.is_none() && !delta.format_changed);
    let VideoOutcome::Frame(same) = track.accept(&header(true, 8, 30), &big[0]) else {
        panic!("keyframe");
    };
    assert!(!same.format_changed, "same SPS/PPS is not a format change");
    let VideoOutcome::Frame(changed) = track.accept(&header(true, 9, 40), &small[0]) else {
        panic!("keyframe");
    };
    assert!(changed.format_changed);
    let stale = track.accept(&header(false, 8, 50), &big[3]);
    assert!(matches!(
        stale,
        VideoOutcome::Dropped {
            reason: VideoDrop::AwaitingKeyframe { stream_id: 8 },
            request: Some(KeyframeReason::Gap)
        }
    ));
    let mismatch = track.accept(&header(true, 10, 60), &small[1]);
    assert!(matches!(
        mismatch,
        VideoOutcome::Dropped {
            reason: VideoDrop::Malformed(CodecError::KeyframeMismatch { .. }),
            ..
        }
    ));
    track.reset();
    let VideoOutcome::Frame(again) = track.accept(&header(true, 11, 70), &small[0]) else {
        panic!("keyframe");
    };
    assert!(
        !again.format_changed,
        "a reconnect keeps the last parameter sets"
    );
}

fn frame(keyframe: bool, format_changed: bool) -> VideoFrame {
    VideoFrame {
        stream_id: 1,
        keyframe,
        pts_us: 0,
        params: None,
        format_changed,
        avcc: Vec::new(),
    }
}

#[test]
fn queue_keeps_the_newest_keyframe_and_skips_after_overflow() {
    let mut queue = VideoQueue::new(2);
    assert_eq!(queue.push(frame(true, true)), QueuePush::Queued);
    assert_eq!(queue.push(frame(false, false)), QueuePush::Queued);
    assert_eq!(
        queue.push(frame(false, false)),
        QueuePush::Overflowed { dropped: 3 }
    );
    assert_eq!(queue.len(), 0);
    assert_eq!(queue.push(frame(false, false)), QueuePush::Skipped);
    assert_eq!(queue.push(frame(true, false)), QueuePush::Queued);
    let resumed = queue.pop().unwrap();
    assert!(
        resumed.keyframe && resumed.format_changed,
        "carries the lost change"
    );
    queue.push(frame(false, false));
    queue.push(frame(false, false));
    assert_eq!(
        queue.push(frame(true, false)),
        QueuePush::Replaced { dropped: 2 }
    );
    assert_eq!(queue.len(), 1);
    queue.clear();
    assert!(queue.pop().is_none());
}

fn chunked(data: &[u8], cuts: &[usize]) -> Vec<Vec<u8>> {
    let mut points: Vec<usize> = cuts.iter().map(|cut| cut % (data.len() + 1)).collect();
    points.push(data.len());
    points.sort_unstable();
    let mut chunks = Vec::new();
    let mut last = 0;
    for point in points {
        chunks.push(data[last..point].to_vec());
        last = point;
    }
    chunks
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    #[test]
    fn streamed_splitting_matches_whole_buffer_splitting(
        cuts in proptest::collection::vec(any::<usize>(), 0..40),
    ) {
        let data = fixture_bytes("h264/testsrc_640x400.annexb");
        let whole: Vec<Vec<u8>> = split_nal_units(&data).into_iter().map(<[u8]>::to_vec).collect();
        let mut splitter = NalSplitter::new();
        let mut streamed = Vec::new();
        for chunk in chunked(&data, &cuts) {
            streamed.extend(splitter.push(&chunk));
        }
        streamed.extend(splitter.finish());
        prop_assert_eq!(streamed, whole);
    }

    #[test]
    fn assembled_access_units_match_the_fixture_table(
        cuts in proptest::collection::vec(any::<usize>(), 0..40),
        byte_at_a_time in any::<bool>(),
    ) {
        let data = fixture_bytes("h264/testsrc_640x400.annexb");
        let expected = access_units("testsrc_640x400");
        let chunks = if byte_at_a_time {
            data.iter().map(|byte| vec![*byte]).collect()
        } else {
            chunked(&data, &cuts)
        };
        let mut splitter = NalSplitter::new();
        let mut assembler = AccessUnitAssembler::new();
        let mut units = Vec::new();
        for chunk in chunks {
            for nal in splitter.push(&chunk) {
                units.extend(assembler.push(nal));
            }
        }
        if let Some(nal) = splitter.finish() {
            units.extend(assembler.push(nal));
        }
        units.extend(assembler.finish());
        prop_assert_eq!(units.len(), expected.len());
        for (unit, original) in units.iter().zip(&expected) {
            prop_assert_eq!(split_nal_units(unit), split_nal_units(original));
        }
    }

    #[test]
    fn arbitrary_payloads_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..128)) {
        if let Ok(unit) = annex_b_to_avcc(&bytes) {
            prop_assert!(unit.avcc.len() <= bytes.len() + 4 * bytes.len());
        }
        let mut splitter = NalSplitter::new();
        let streamed: usize = splitter.push(&bytes).iter().map(Vec::len).sum();
        prop_assert!(streamed <= bytes.len());
    }
}
