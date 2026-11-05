//! Schedules, ported from `web/src/lib/scheduleBuilder.test.ts` and `scheduleText.test.ts`.

use super::*;

fn model(preset: SchedulePreset) -> ScheduleModel {
    ScheduleModel {
        preset,
        hour: 8,
        minute: 30,
        ..ScheduleModel::default()
    }
}

#[test]
fn presets_build_the_web_rules() {
    assert_eq!(
        build_rrule(&model(SchedulePreset::Hourly)),
        "FREQ=HOURLY;BYMINUTE=30"
    );
    assert_eq!(
        build_rrule(&model(SchedulePreset::Daily)),
        "FREQ=DAILY;BYHOUR=8;BYMINUTE=30"
    );
    assert_eq!(
        build_rrule(&model(SchedulePreset::Weekdays)),
        "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=30"
    );
    let weekly = ScheduleModel {
        weekdays: vec![Weekday::Friday, Weekday::Monday, Weekday::Friday],
        ..model(SchedulePreset::Weekly)
    };
    assert_eq!(
        build_rrule(&weekly),
        "FREQ=WEEKLY;BYDAY=MO,FR;BYHOUR=8;BYMINUTE=30"
    );
    let no_days = ScheduleModel {
        weekdays: Vec::new(),
        ..model(SchedulePreset::Weekly)
    };
    assert_eq!(
        build_rrule(&no_days),
        "FREQ=WEEKLY;BYDAY=MO;BYHOUR=8;BYMINUTE=30"
    );
}

#[test]
fn custom_rules_carry_interval_and_days() {
    let custom = |frequency| ScheduleModel {
        frequency,
        interval: 3,
        month_days: vec![15, 1],
        month: 3,
        ..model(SchedulePreset::Custom)
    };
    assert_eq!(
        build_rrule(&custom(ScheduleFrequency::Hourly)),
        "FREQ=HOURLY;INTERVAL=3;BYMINUTE=30"
    );
    assert_eq!(
        build_rrule(&custom(ScheduleFrequency::Monthly)),
        "FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1,15;BYHOUR=8;BYMINUTE=30"
    );
    assert_eq!(
        build_rrule(&custom(ScheduleFrequency::Yearly)),
        "FREQ=YEARLY;INTERVAL=3;BYMONTH=3;BYMONTHDAY=1,15;BYHOUR=8;BYMINUTE=30"
    );
}

#[test]
fn parsing_round_trips_and_names_the_preset() {
    for preset in [
        SchedulePreset::Hourly,
        SchedulePreset::Daily,
        SchedulePreset::Weekdays,
    ] {
        let parsed = parse_rrule(&build_rrule(&model(preset))).unwrap();
        assert_eq!(parsed.preset, preset);
        assert_eq!(parsed.minute, 30);
    }
    let weekly = parse_rrule("RRULE:FREQ=WEEKLY;BYDAY=FR,MO;BYHOUR=8;BYMINUTE=0").unwrap();
    assert_eq!(weekly.preset, SchedulePreset::Weekly);
    assert_eq!(weekly.weekdays, vec![Weekday::Monday, Weekday::Friday]);
    let every_two = parse_rrule("FREQ=DAILY;INTERVAL=2;BYHOUR=6;BYMINUTE=5").unwrap();
    assert_eq!(every_two.preset, SchedulePreset::Custom);
    assert_eq!(every_two.interval, 2);
    assert_eq!(
        build_rrule(&every_two),
        "FREQ=DAILY;INTERVAL=2;BYHOUR=6;BYMINUTE=5"
    );
}

#[test]
fn rules_the_editor_cannot_make_are_left_alone() {
    for rule in [
        "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;COUNT=1",
        "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;COUNT=3;UNTIL=20261231T235959Z",
        "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;UNTIL=20260230T000000Z",
        "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;UNTIL=2026-12-31",
        "FREQ=DAILY;BYHOUR=8",
        "FREQ=SECONDLY;BYMINUTE=0",
        "FREQ=WEEKLY;BYDAY=XX;BYHOUR=8;BYMINUTE=0",
        "FREQ=DAILY;BYHOUR=25;BYMINUTE=0",
        "garbage",
        "",
    ] {
        assert_eq!(parse_rrule(rule), None, "{rule}");
    }
}

#[test]
fn describes_like_the_web() {
    let cases = [
        (
            "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=0",
            "Weekdays at 8:00 AM",
        ),
        ("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", "Every day at 9:00 AM"),
        (
            "FREQ=WEEKLY;BYDAY=MO,FR;BYHOUR=14;BYMINUTE=30",
            "Weekly on Monday and Friday at 2:30 PM",
        ),
        (
            "FREQ=WEEKLY;BYDAY=SA,SU;BYHOUR=0;BYMINUTE=0",
            "Weekends at 12:00 AM",
        ),
        ("FREQ=HOURLY;INTERVAL=2;BYMINUTE=15", "Every 2 hours at :15"),
        ("FREQ=HOURLY;BYMINUTE=0", "Hourly"),
        ("FREQ=HOURLY;BYMINUTE=30", "Hourly at :30"),
        (
            "FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1,15;BYHOUR=6;BYMINUTE=0",
            "Every 3 months on the 1st and 15th at 6:00 AM",
        ),
        (
            "FREQ=YEARLY;INTERVAL=2;BYMONTH=3;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0",
            "Every 2 years in March on the 1st at 9:00 AM",
        ),
        (
            "FREQ=MONTHLY;BYMONTHDAY=1,2,23;BYHOUR=12;BYMINUTE=5",
            "Monthly on the 1st, 2nd, and 23rd at 12:05 PM",
        ),
        ("not a rule", "not a rule"),
    ];
    for (rule, text) in cases {
        assert_eq!(describe_schedule(rule), text, "{rule}");
    }
}

#[test]
fn next_run_rounds_and_promotes() {
    let now = 1_000_000;
    assert_eq!(format_next_run(now - 5, now), "soon");
    assert_eq!(format_next_run(now + 30, now), "soon");
    assert_eq!(format_next_run(now + 60, now), "in 1 min");
    assert_eq!(format_next_run(now + 8 * 60, now), "in 8 mins");
    assert_eq!(format_next_run(now + 59 * 60 + 40, now), "in 1 hour");
    assert_eq!(format_next_run(now + 109 * 60, now), "in 2 hours");
    assert_eq!(format_next_run(now + 23 * 3600 + 40 * 60, now), "in 1 day");
    assert_eq!(format_next_run(now + 3 * 86_400, now), "in 3 days");
}

#[test]
fn iso_timestamps_with_zones() {
    assert_eq!(parse_iso8601("1970-01-01T00:00:00+00:00"), Some(0));
    assert_eq!(parse_iso8601("2026-11-05T08:00:00Z"), Some(1_793_865_600));
    assert_eq!(
        parse_iso8601("2026-11-05T03:00:00.250-05:00"),
        Some(1_793_865_600)
    );
    assert_eq!(
        parse_iso8601("2000-02-29T12:00:00+05:30"),
        Some(951_805_800)
    );
    assert_eq!(parse_iso8601("2026-11-05T08:00:00"), None);
    assert_eq!(parse_iso8601("tomorrow"), None);
}

#[test]
fn end_conditions_round_trip() {
    let count = parse_rrule("FREQ=DAILY;BYHOUR=8;BYMINUTE=0;COUNT=3").unwrap();
    assert_eq!(count.end, ScheduleEnd::Count(3));
    assert_eq!(
        build_rrule(&count),
        "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;COUNT=3"
    );
    let until = parse_rrule("FREQ=HOURLY;BYMINUTE=15;UNTIL=20261231T235959Z").unwrap();
    assert_eq!(until.end, ScheduleEnd::Until(1_798_761_599));
    assert_eq!(
        build_rrule(&until),
        "FREQ=HOURLY;BYMINUTE=15;UNTIL=20261231T235959Z"
    );
    assert_eq!(format_until(0), "19700101T000000Z");
    assert_eq!(parse_until("20000229T120000Z"), Some(951_825_600));
}

#[test]
fn validation_matches_the_web() {
    let now = 1_793_865_600;
    let mut daily = model(SchedulePreset::Daily);
    assert_eq!(validate_schedule(&daily, now, false), None);
    daily.end = ScheduleEnd::Count(1);
    assert!(
        validate_schedule(&daily, now, false)
            .unwrap()
            .contains("at least 2")
    );
    daily.end = ScheduleEnd::Until(now - 1);
    assert_eq!(
        validate_schedule(&daily, now, false).as_deref(),
        Some("Choose an end date in the future.")
    );
    assert_eq!(validate_schedule(&daily, now, true), None);
    let weekly = ScheduleModel {
        weekdays: Vec::new(),
        ..model(SchedulePreset::Weekly)
    };
    assert!(validate_schedule(&weekly, now, false).is_some());
    assert!(!needs_anchored_scheduling(&daily));
    daily.end = ScheduleEnd::Count(4);
    assert!(needs_anchored_scheduling(&daily));
    assert!(needs_anchored_scheduling(&model(SchedulePreset::Custom)));
}
