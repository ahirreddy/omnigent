//! Pin order: the keys a drag writes (ported from the web's `pinOrderWrites` tests in
//! `web/src/shell/sidebarNav.test.ts`), the list order they give, and the requests a move sends.

use futures::executor::block_on;
use serde_json::json;

use super::super::sessions::SessionSummary;
use super::super::test_support::{Reply, RouteTransport, connected};
use super::{PinOrderWrite, PinStamp, compare, pin_order_writes};
use crate::session_query::{self, SessionFilter};

fn pins(values: &[Option<f64>]) -> Vec<SessionSummary> {
    values
        .iter()
        .enumerate()
        .map(|(index, value)| SessionSummary {
            is_pinned: true,
            pin_stamp: value.map(|value| value.to_string()),
            ..SessionSummary::new(format!("conv_{index}"), "", "")
        })
        .collect()
}

fn write(id: &str, key: f64) -> PinOrderWrite {
    PinOrderWrite {
        session_id: id.to_owned(),
        key,
    }
}

const NOW: u64 = 1_791_337_307_018;

#[test]
fn rewrites_only_the_moved_pin_between_its_new_neighbours() {
    let rows = pins(&[Some(1000.0), Some(2000.0), Some(3000.0)]);
    assert_eq!(
        pin_order_writes(&rows, "conv_2", "conv_1", NOW),
        [write("conv_2", 1500.0)]
    );
    assert_eq!(
        pin_order_writes(&rows, "conv_0", "conv_1", NOW),
        [write("conv_0", 2500.0)]
    );
    // To the top or bottom: just past the end key.
    assert_eq!(
        pin_order_writes(&rows, "conv_2", "conv_0", NOW),
        [write("conv_2", 999.0)]
    );
    assert_eq!(
        pin_order_writes(&rows, "conv_0", "conv_2", NOW),
        [write("conv_0", 3001.0)]
    );
}

#[test]
fn renumbers_every_pin_when_there_is_no_room() {
    let equal = pins(&[Some(1000.0), Some(1000.0), Some(1000.0)]);
    assert_eq!(
        pin_order_writes(&equal, "conv_2", "conv_1", NOW),
        [write("conv_2", 1001.0), write("conv_1", 1002.0)]
    );
    let missing = pins(&[Some(1000.0), None, None]);
    assert_eq!(
        pin_order_writes(&missing, "conv_0", "conv_1", NOW),
        [
            write("conv_1", 1000.0),
            write("conv_0", 1001.0),
            write("conv_2", 1002.0)
        ]
    );
    // Keys too large to count up from renumber just below now.
    let huge = pins(&[Some(1e20), Some(1e20), Some(1e20)]);
    let now = 1_791_337_307_018.0;
    assert_eq!(
        pin_order_writes(&huge, "conv_2", "conv_1", NOW),
        [
            write("conv_0", now - 3.0),
            write("conv_2", now - 2.0),
            write("conv_1", now - 1.0)
        ]
    );
    // Adjacent doubles at epoch scale leave no representable midpoint.
    let low = 1_791_337_307_018.0;
    let high = low + 2f64.powi(-12);
    let crowded = pins(&[Some(low), Some(high), Some(5_000_000_000_000.0)]);
    assert_eq!(
        pin_order_writes(&crowded, "conv_2", "conv_1", NOW),
        [write("conv_2", low + 1.0), write("conv_1", low + 2.0)]
    );
}

#[test]
fn inserts_an_unpinned_session_and_ignores_no_ops() {
    let rows = pins(&[Some(1000.0), Some(2000.0)]);
    assert_eq!(
        pin_order_writes(&rows, "new", "conv_1", NOW),
        [write("new", 1500.0)]
    );
    assert_eq!(
        pin_order_writes(&rows, "new", "conv_0", NOW),
        [write("new", 999.0)]
    );
    assert_eq!(pin_order_writes(&rows, "conv_0", "conv_0", NOW), []);
    assert_eq!(pin_order_writes(&rows, "conv_0", "missing", NOW), []);
}

#[test]
fn the_list_orders_pins_by_key_then_the_rest_by_recency() {
    let mut rows = pins(&[Some(1000.0), Some(2000.0), Some(3000.0), Some(4000.0)]);
    for write in pin_order_writes(&rows, "conv_3", "conv_1", NOW) {
        let row = rows
            .iter_mut()
            .find(|row| row.id == write.session_id)
            .unwrap();
        row.pin_stamp = PinStamp::new(write.key).map(|stamp| stamp.label().to_owned());
    }
    // A recent update does not move a pin; an unreadable key sinks to the bottom of Pinned.
    rows[2].updated_at = 99;
    rows.push(SessionSummary {
        is_pinned: true,
        pin_stamp: Some("soon".into()),
        ..SessionSummary::new("odd", "", "")
    });
    rows.push(SessionSummary {
        updated_at: 100,
        ..SessionSummary::new("loose", "", "")
    });
    let ids: Vec<String> = session_query::matching(&rows, "", SessionFilter::All)
        .into_iter()
        .map(|row| row.id)
        .collect();
    assert_eq!(
        ids,
        ["conv_0", "conv_3", "conv_1", "conv_2", "odd", "loose"]
    );
    assert!(compare(&rows[0], &rows[4]).is_lt());
    assert_eq!(PinStamp::new(f64::NAN), None);
    assert_eq!(PinStamp::new(1500.5).unwrap().label(), "1500.5");
    assert_eq!(PinStamp::new(1000.0).unwrap().label(), "1000");
}

#[test]
fn moving_a_pin_writes_its_new_key_and_pins_an_unpinned_session_first() {
    let transport = RouteTransport::local();
    for (id, labels) in [
        ("p0", r#"{"omnigent.pinned":"1000"}"#),
        ("p1", r#"{"omnigent.pinned":"2000"}"#),
        ("loose", "{}"),
    ] {
        let row = format!(
            r#"{{"id":"{id}","status":"idle","created_at":1,"permission_level":4,"labels":{labels}}}"#
        );
        transport.respond(
            Some("GET"),
            &format!("/v1/sessions/{id}"),
            None,
            Reply::json(200, row.clone()),
        );
        transport.respond(
            Some("PATCH"),
            &format!("/v1/sessions/{id}"),
            None,
            Reply::json(200, row),
        );
    }
    let core = connected(transport);
    for id in ["p0", "p1", "loose"] {
        block_on(core.editable_session(id)).unwrap();
    }
    block_on(core.move_pin("p1", "p0", NOW)).unwrap();
    block_on(core.move_pin("loose", "p1", NOW)).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        vec![
            json!({"labels": {"omnigent.pinned": "999"}}),
            json!({"labels": {"omnigent.pinned": "1500"}}),
        ]
    );
}

#[test]
fn every_write_is_finite_whatever_keys_the_server_sent() {
    let hostile = [
        Some(f64::INFINITY),
        Some(f64::NEG_INFINITY),
        Some(f64::NAN),
        Some(f64::MAX),
        Some(f64::MIN),
        Some(-1e308),
        Some(0.0),
        None,
    ];
    for first in hostile {
        for second in hostile {
            for third in hostile {
                let rows = pins(&[first, second, third]);
                for (from, to) in [
                    ("conv_0", "conv_1"),
                    ("conv_0", "conv_2"),
                    ("conv_2", "conv_0"),
                    ("conv_2", "conv_1"),
                    ("loose", "conv_0"),
                    ("loose", "conv_2"),
                ] {
                    for write in pin_order_writes(&rows, from, to, u64::MAX) {
                        assert!(
                            PinStamp::new(write.key).is_some(),
                            "{from} to {to} over {first:?} {second:?} {third:?}: {write:?}"
                        );
                    }
                }
            }
        }
    }
}
