//! Usage: decoding, the date windows and the breakdowns.

use futures::executor::block_on;

use super::super::SessionError;
use super::super::test_support::{RouteTransport, connected};
use super::{format_cost_usd, usage_window, utc_day, window_start};

const REPORT: &str = r#"{"object":"usage_report","cost_today":1.0,"daily_costs":[{"day":"2026-10-01","cost_usd":2.0},{"day":"2026-11-03","cost_usd":0.5},{"day":"2026-11-04","cost_usd":1.0}],"sessions":[{"id":"s1","created_at":1793700000,"updated_at":1793750000,"title":"Fix","cost_usd":1.25,"models":{"opus":0.25,"sonnet":1.0},"harness":"claude-code"},{"id":"s2","created_at":1790000000,"updated_at":1790000000,"title":"","cost_usd":2.0,"models":{},"harness":null}]}"#;

fn close(left: f64, right: f64) -> bool {
    (left - right).abs() < 1e-9
}

#[test]
fn days_and_windows_are_utc_calendar_days() {
    assert_eq!(utc_day(0), "1970-01-01");
    assert_eq!(utc_day(1_793_865_600), "2026-11-05");
    assert_eq!(utc_day(951_825_600), "2000-02-29");
    assert_eq!(utc_day(-1), "1969-12-31");
    assert_eq!(window_start(7, 1_793_865_600), "2026-10-30");
    assert_eq!(window_start(1, 1_793_865_600), "2026-11-05");
}

#[test]
fn decodes_and_narrows_the_report() {
    let transport = RouteTransport::local();
    transport.ok("/v1/usage", REPORT);
    let report = block_on(connected(transport).usage_report()).unwrap();
    assert_eq!(report.sessions[0].models[0], ("sonnet".to_owned(), 1.0));
    assert_eq!(report.sessions[1].title, None);

    let all = usage_window(&report, None, None);
    assert!(close(all.total_cost_usd, 3.5));
    assert_eq!(all.sessions.len(), 2);
    assert_eq!(all.by_harness[0].name, "Unknown");
    assert_eq!(all.by_model[0].name, "sonnet");

    let recent = usage_window(&report, Some("2026-11-03"), Some("2026-11-04"));
    assert_eq!(recent.daily_costs.len(), 2);
    assert!(close(recent.total_cost_usd, 1.5));
    assert_eq!(recent.sessions.len(), 1);

    // No daily spend recorded in the window: the sessions' total stands in.
    let quiet = usage_window(&report, Some("2026-09-21"), Some("2026-09-21"));
    assert!(close(quiet.total_cost_usd, 2.0));
}

#[test]
fn a_malformed_report_is_an_error() {
    let transport = RouteTransport::local();
    transport.ok("/v1/usage", r#"{"sessions":[{"id":1}]}"#);
    assert!(matches!(
        block_on(connected(transport).usage_report()),
        Err(SessionError::MalformedResponse { .. })
    ));
}

#[test]
fn costs_format_like_the_web() {
    assert_eq!(format_cost_usd(0.0), "$0.00");
    assert_eq!(format_cost_usd(0.004), "<$0.01");
    assert_eq!(format_cost_usd(12.345), "$12.35");
}
