//! The execution logs' live view keeps each session's stream events, bounded.

use serde_json::{Value, json};

use super::{MAX_BYTES, MAX_EVENTS};
use crate::client::test_support::{RouteTransport, connected};

#[test]
fn events_are_kept_per_session_in_order_until_the_stream_opens_anew() {
    let core = connected(RouteTransport::local());
    assert_eq!(core.stream_log("conv_a", None).len(), 0);
    core.record_stream_log("conv_a", &json!({"type":"response.created"}), 1_000);
    core.record_stream_log(
        "conv_a",
        &json!({"type":"response.output_text.delta","delta":"hi"}),
        1_250,
    );
    core.record_stream_log("conv_b", &json!({"type":"session.status"}), 1_300);
    let log = core.stream_log("conv_a", None);
    assert_eq!(log.len(), 2);
    assert_eq!((log[0].index, log[0].received_at_ms), (0, 1_000));
    let compact: Value = serde_json::from_str(&log[1].compact).expect("compact JSON");
    assert_eq!(
        compact,
        json!({"type":"response.output_text.delta","delta":"hi"})
    );
    assert!(!log[1].compact.contains('\n'));
    assert!(log[1].pretty.contains("\n  \"delta\": \"hi\""));
    assert_eq!(core.stream_log("conv_b", None).len(), 1);
    let newer = core.stream_log("conv_a", Some(0));
    assert_eq!(
        newer.iter().map(|entry| entry.index).collect::<Vec<_>>(),
        [1]
    );
    assert_eq!(core.stream_log("conv_a", Some(1)).len(), 0);
    core.clear_stream_log("conv_a");
    assert_eq!(core.stream_log("conv_a", None).len(), 0);
    assert_eq!(core.stream_log("conv_b", None).len(), 1);
}

#[test]
fn the_oldest_events_go_past_the_count_and_size_limits() {
    let core = connected(RouteTransport::local());
    for index in 0..MAX_EVENTS + 3 {
        core.record_stream_log("conv_a", &json!({ "n": index }), 0);
    }
    let log = core.stream_log("conv_a", None);
    assert_eq!(log.len(), MAX_EVENTS);
    assert_eq!(
        log[0].index, 3,
        "numbering keeps counting as old events drop"
    );
    let large = "x".repeat(MAX_BYTES / 2);
    for _ in 0..3 {
        core.record_stream_log("conv_b", &json!({ "output": large }), 0);
    }
    let log = core.stream_log("conv_b", None);
    assert_eq!(log.len(), 1);
    assert_eq!(log[0].index, 2);
    let huge = "y".repeat(MAX_BYTES + 1);
    core.record_stream_log("conv_c", &json!({ "output": huge }), 0);
    assert_eq!(
        core.stream_log("conv_c", None).len(),
        1,
        "one event over the limit still shows"
    );
}
