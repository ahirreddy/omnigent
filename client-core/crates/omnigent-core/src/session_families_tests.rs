use serde_json::{Value, json};

use super::*;

fn info(value: &Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

fn family(representative: Option<&str>, pinned: bool) -> SessionFamily {
    SessionFamily {
        id: "lead".to_owned(),
        representative_id: representative.map(str::to_owned),
        representative_title: Some("Coordinator".to_owned()),
        pinned,
        pinned_at: pinned.then(|| "100".to_owned()),
    }
}

fn row(id: &str, family: Option<SessionFamily>, pinned: bool) -> SessionSummary {
    SessionSummary {
        is_pinned: pinned,
        pin_stamp: pinned.then(|| "100".to_owned()),
        family,
        ..SessionSummary::new(id, id, "")
    }
}

#[test]
fn destinations_default_to_any_host_and_unknown_values_to_the_current_host() {
    for (body, expected) in [
        (json!({}), SiblingDestinations::AnyHost),
        (
            json!({"sibling_session_destinations": null}),
            SiblingDestinations::AnyHost,
        ),
        (
            json!({"sibling_session_destinations": "any_host"}),
            SiblingDestinations::AnyHost,
        ),
        (
            json!({"sibling_session_destinations": "current_host_or_new_sandbox"}),
            SiblingDestinations::CurrentHostOrNewSandbox,
        ),
        (
            json!({"sibling_session_destinations": "current_host"}),
            SiblingDestinations::CurrentHost,
        ),
        (
            json!({"sibling_session_destinations": "galaxy_wide"}),
            SiblingDestinations::CurrentHost,
        ),
        (
            json!({"sibling_session_destinations": 7}),
            SiblingDestinations::CurrentHost,
        ),
    ] {
        assert_eq!(
            SiblingDestinations::from_info(&info(&body)),
            expected,
            "{body}"
        );
    }
    assert_eq!(SiblingDestinations::default(), SiblingDestinations::AnyHost);
}

#[test]
fn only_true_turns_nested_agents_on() {
    assert!(sibling_sessions_enabled(&info(
        &json!({"sibling_sessions": true})
    )));
    for body in [
        json!({}),
        json!({"sibling_sessions": false}),
        json!({"sibling_sessions": null}),
        json!({"sibling_sessions": "true"}),
        json!({"features": {"sibling_sessions": true}}),
    ] {
        assert!(!sibling_sessions_enabled(&info(&body)), "{body}");
    }
}

#[test]
fn a_nested_member_shows_its_representatives_pin_and_ignores_its_own() {
    let lead_pinned = row("lead", Some(family(Some("lead"), true)), true);
    let lead_unpinned = row("lead", Some(family(Some("lead"), true)), false);
    // A stale personal pin on the member does not count.
    let member = row("peer", Some(family(Some("lead"), false)), true);
    assert!(member.is_nested_member());
    assert!(shows_pinned(&member, Some(&lead_pinned)));
    assert!(!shows_pinned(&member, Some(&lead_unpinned)));
    // Without the representative loaded, the family's own pin decides.
    assert!(!shows_pinned(&member, None));
    let pinned_member = row("peer", Some(family(Some("lead"), true)), false);
    assert!(shows_pinned(&pinned_member, None));
    // A row that is not the representative is not consulted.
    let stranger = row("other", None, false);
    assert!(shows_pinned(&pinned_member, Some(&stranger)));
    // The representative and standalone rows show their own pin.
    assert!(!lead_pinned.is_nested_member());
    assert!(shows_pinned(&lead_pinned, None));
    assert!(!shows_pinned(&lead_unpinned, Some(&lead_pinned)));
    assert!(shows_pinned(&row("solo", None, true), None));
    let headless = row("peer", Some(family(None, true)), false);
    assert!(!headless.is_nested_member());
    assert!(!shows_pinned(&headless, None));
}

#[test]
fn only_standalone_sessions_and_representatives_take_pin_slots() {
    let solo = row("solo", None, true);
    let lead = row("lead", Some(family(Some("lead"), true)), true);
    let member = row("peer", Some(family(Some("lead"), true)), true);
    let headless = row("orphan", Some(family(None, true)), true);
    assert!(is_pin_unit(&solo) && is_pin_unit(&lead));
    assert!(!is_pin_unit(&member) && !is_pin_unit(&headless));
    let archived = SessionSummary {
        is_archived: true,
        ..row("old", None, true)
    };
    let unpinned = row("idle", None, false);
    let rows = [solo, lead, member, headless, archived, unpinned];
    let ids: Vec<&str> = pinned_units(&rows)
        .into_iter()
        .map(|session| session.id.as_str())
        .collect();
    assert_eq!(ids, ["solo", "lead"]);
}
