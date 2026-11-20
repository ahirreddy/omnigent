//! Automation schedules and their text.
//!
//! The RFC 5545 rules the scheduled-task API stores, the editor model the web's schedule builder
//! produces (`web/src/lib/scheduleBuilder.ts`), the human summary (`describeSchedule`) and the
//! next-run label (`formatNextRunAt`).
//!
//! The next fire instant is always the server's (`next_run_at`); only its distance from now is
//! formatted here.

use std::collections::{BTreeMap, BTreeSet};
use std::ops::RangeInclusive;

/// A day of the week, Monday first as RFC 5545 counts them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Weekday {
    /// Monday.
    Monday,
    /// Tuesday.
    Tuesday,
    /// Wednesday.
    Wednesday,
    /// Thursday.
    Thursday,
    /// Friday.
    Friday,
    /// Saturday.
    Saturday,
    /// Sunday.
    Sunday,
}

impl Weekday {
    /// Every day, Monday first.
    pub const ALL: [Self; 7] = [
        Self::Monday,
        Self::Tuesday,
        Self::Wednesday,
        Self::Thursday,
        Self::Friday,
        Self::Saturday,
        Self::Sunday,
    ];

    const fn code(self) -> &'static str {
        match self {
            Self::Monday => "MO",
            Self::Tuesday => "TU",
            Self::Wednesday => "WE",
            Self::Thursday => "TH",
            Self::Friday => "FR",
            Self::Saturday => "SA",
            Self::Sunday => "SU",
        }
    }

    /// The English name.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Monday => "Monday",
            Self::Tuesday => "Tuesday",
            Self::Wednesday => "Wednesday",
            Self::Thursday => "Thursday",
            Self::Friday => "Friday",
            Self::Saturday => "Saturday",
            Self::Sunday => "Sunday",
        }
    }

    fn from_code(code: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|day| day.code() == code)
    }
}

/// The schedule picker's choice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SchedulePreset {
    /// Every hour at a minute.
    Hourly,
    /// Every day at a time.
    Daily,
    /// Monday to Friday at a time.
    Weekdays,
    /// Chosen weekdays at a time.
    Weekly,
    /// Any frequency with an interval.
    Custom,
}

/// A custom schedule's unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScheduleFrequency {
    /// Minutes: the web's Interval schedules and trigger polling.
    Minutely,
    /// Hours.
    Hourly,
    /// Days.
    Daily,
    /// Weeks.
    Weekly,
    /// Months.
    Monthly,
    /// Years.
    Yearly,
    /// RRULE text the visual controls can't show ([`ScheduleModel::rule`]).
    Rule,
}

impl ScheduleFrequency {
    fn from_code(code: &str) -> Option<Self> {
        match code {
            "MINUTELY" => Some(Self::Minutely),
            "HOURLY" => Some(Self::Hourly),
            "DAILY" => Some(Self::Daily),
            "WEEKLY" => Some(Self::Weekly),
            "MONTHLY" => Some(Self::Monthly),
            "YEARLY" => Some(Self::Yearly),
            _ => None,
        }
    }
}

/// When a schedule stops firing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ScheduleEnd {
    /// It never ends.
    #[default]
    Never,
    /// After this many runs, 2 or more (`COUNT`).
    Count(u32),
    /// At this instant, Unix seconds (`UNTIL`, written in UTC).
    Until(i64),
}

/// What the schedule editor holds. [`build_rrule`] and [`parse_rrule`] convert it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ScheduleModel {
    /// The picker's choice.
    pub preset: SchedulePreset,
    /// Hour of day, 0-23 (unused hourly).
    pub hour: u8,
    /// Minute, 0-59.
    pub minute: u8,
    /// Weekly days.
    pub weekdays: Vec<Weekday>,
    /// A custom schedule's unit.
    pub frequency: ScheduleFrequency,
    /// A custom schedule's interval, 1 or more.
    pub interval: u16,
    /// Monthly and yearly days of the month, 1-31.
    pub month_days: Vec<u8>,
    /// The yearly month, 1-12.
    pub month: u8,
    /// A [`ScheduleFrequency::Rule`] schedule's RRULE text, without `COUNT` or `UNTIL`, which
    /// `end` holds.
    pub rule: String,
    /// When it stops.
    pub end: ScheduleEnd,
}

impl Default for ScheduleModel {
    /// The web's default: every day at 9:00 AM.
    fn default() -> Self {
        Self {
            preset: SchedulePreset::Daily,
            hour: 9,
            minute: 0,
            weekdays: vec![Weekday::Monday],
            frequency: ScheduleFrequency::Daily,
            interval: 1,
            month_days: vec![1],
            month: 1,
            rule: String::new(),
            end: ScheduleEnd::Never,
        }
    }
}

const WEEKDAYS: [Weekday; 5] = [
    Weekday::Monday,
    Weekday::Tuesday,
    Weekday::Wednesday,
    Weekday::Thursday,
    Weekday::Friday,
];

fn sorted_days(days: &[Weekday]) -> Vec<Weekday> {
    let mut days = days.to_vec();
    days.sort_unstable();
    days.dedup();
    days
}

fn sorted_month_days(days: &[u8]) -> Vec<u8> {
    let mut days: Vec<u8> = days
        .iter()
        .copied()
        .filter(|day| (1..=31).contains(day))
        .collect();
    days.sort_unstable();
    days.dedup();
    days
}

fn join_codes(days: &[Weekday]) -> String {
    let codes: Vec<&str> = sorted_days(days).into_iter().map(Weekday::code).collect();
    if codes.is_empty() {
        "MO".to_owned()
    } else {
        codes.join(",")
    }
}

fn join_month_days(days: &[u8]) -> String {
    let days = sorted_month_days(days);
    if days.is_empty() {
        "1".to_owned()
    } else {
        days.iter().map(u8::to_string).collect::<Vec<_>>().join(",")
    }
}

/// The rule body (no `RRULE:` prefix) for `model`, as the web builds it.
#[must_use]
pub fn build_rrule(model: &ScheduleModel) -> String {
    let rule = build_recurrence(model);
    match model.end {
        ScheduleEnd::Never => rule,
        ScheduleEnd::Count(count) => format!("{rule};COUNT={}", count.max(MIN_COUNT)),
        ScheduleEnd::Until(until) => format!("{rule};UNTIL={}", format_until(until)),
    }
}

/// The fewest runs an end condition can name, as the web's form.
const MIN_COUNT: u32 = 2;

/// The most runs an end condition can name: the server's 32-bit limit.
const MAX_COUNT: u32 = 2_147_483_647;

/// The longest minute interval: 366 days.
pub const MAX_MINUTE_INTERVAL: u16 = 366 * 60;

/// The shortest minute interval where the server runs schedules under an hour.
pub const MIN_SUBHOUR_MINUTE_INTERVAL: u16 = 10;

/// The shortest minute interval elsewhere: an hour.
pub const MIN_HOURLY_MINUTE_INTERVAL: u16 = 60;

/// What decides how short a minute schedule may be (the web's `minimumScheduleInterval`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ScheduleLimits {
    /// The server runs schedules under an hour (`scheduled_task_subhour`).
    pub subhour_supported: bool,
    /// Every run continues one session.
    pub continues_session: bool,
    /// Runs go to a connected host rather than a new sandbox.
    pub on_connected_host: bool,
}

impl ScheduleLimits {
    /// Limits that allow every interval a server could run, for reading saved rules.
    pub const SAVED: Self = Self {
        subhour_supported: true,
        continues_session: true,
        on_connected_host: true,
    };
}

/// The smallest interval `frequency` allows under `limits`: 1, or 10 or 60 minutes.
#[must_use]
pub const fn minimum_schedule_interval(
    frequency: ScheduleFrequency,
    limits: ScheduleLimits,
) -> u16 {
    if !matches!(frequency, ScheduleFrequency::Minutely) {
        return 1;
    }
    if limits.subhour_supported && (limits.continues_session || limits.on_connected_host) {
        MIN_SUBHOUR_MINUTE_INTERVAL
    } else {
        MIN_HOURLY_MINUTE_INTERVAL
    }
}

/// The largest interval `frequency` allows.
#[must_use]
pub const fn maximum_schedule_interval(frequency: ScheduleFrequency) -> u16 {
    if matches!(frequency, ScheduleFrequency::Minutely) {
        MAX_MINUTE_INTERVAL
    } else {
        366
    }
}

/// `UNTIL`'s form of Unix second `seconds`: `20261231T235959Z`.
#[must_use]
pub fn format_until(seconds: i64) -> String {
    let day = crate::client::usage::utc_day(seconds).replace('-', "");
    let time = seconds.rem_euclid(86_400);
    format!(
        "{day}T{:02}{:02}{:02}Z",
        time / 3600,
        time % 3600 / 60,
        time % 60
    )
}

/// Unix seconds of an `UNTIL` value in the form [`format_until`] writes, or `None`.
#[must_use]
pub fn parse_until(value: &str) -> Option<i64> {
    let (date, time) = value.strip_suffix('Z')?.split_once('T')?;
    let digits = |part: &str, len: usize| {
        part.len() == len && part.bytes().all(|byte| byte.is_ascii_digit())
    };
    if !digits(date, 8) || !digits(time, 6) {
        return None;
    }
    // Every byte is an ASCII digit, so these splits fall on character boundaries.
    let (year, month_day) = date.split_at_checked(4)?;
    let (month, day) = month_day.split_at_checked(2)?;
    let (hour, minute_second) = time.split_at_checked(2)?;
    let (minute, second) = minute_second.split_at_checked(2)?;
    let iso = format!("{year}-{month}-{day}T{hour}:{minute}:{second}Z");
    // A date like February 30 parses but does not round-trip.
    parse_iso8601(&iso).filter(|&seconds| format_until(seconds) == value)
}

/// Why the editor cannot save `model`, in the web's words, or `None`. `now` is Unix seconds; an
/// unchanged schedule may keep an end in the past (`allow_past_end`); `limits` bound minute
/// intervals.
#[must_use]
pub fn validate_schedule(
    model: &ScheduleModel,
    now: i64,
    allow_past_end: bool,
    limits: ScheduleLimits,
) -> Option<String> {
    let custom = |frequency| model.preset == SchedulePreset::Custom && model.frequency == frequency;
    if custom(ScheduleFrequency::Rule) {
        return validate_rule_text(&model.rule).or_else(|| end_problem(model, now, allow_past_end));
    }
    if model.preset == SchedulePreset::Weekly && model.weekdays.is_empty() {
        return Some("Pick at least one day of the week.".to_owned());
    }
    if model.preset == SchedulePreset::Custom
        && let Some(problem) = interval_problem(model.frequency, model.interval, limits)
    {
        return Some(problem);
    }
    if custom(ScheduleFrequency::Weekly) && model.weekdays.is_empty() {
        return Some("Pick at least one day of the week.".to_owned());
    }
    if (custom(ScheduleFrequency::Monthly) || custom(ScheduleFrequency::Yearly))
        && sorted_month_days(&model.month_days).is_empty()
    {
        return Some("Pick at least one day of the month.".to_owned());
    }
    end_problem(model, now, allow_past_end)
}

/// Why `model`'s ending can't be saved, or `None`.
fn end_problem(model: &ScheduleModel, now: i64, allow_past_end: bool) -> Option<String> {
    match model.end {
        ScheduleEnd::Count(count) if !(MIN_COUNT..=MAX_COUNT).contains(&count) => {
            Some("Enter at least 2 occurrences (at most 2,147,483,647).".to_owned())
        }
        ScheduleEnd::Until(until) if !allow_past_end && until <= now => {
            Some("Choose an end date in the future.".to_owned())
        }
        ScheduleEnd::Never | ScheduleEnd::Count(_) | ScheduleEnd::Until(_) => None,
    }
}

const RULE_PREFIX: &str = "RRULE:";

/// RRULE editor text as the server reads it: no `RRULE:` prefix, upper case.
#[must_use]
pub fn normalize_rule_text(rule: &str) -> String {
    let text = rule.trim();
    let body = text
        .get(..RULE_PREFIX.len())
        .filter(|prefix| prefix.eq_ignore_ascii_case(RULE_PREFIX))
        .and_then(|_| text.get(RULE_PREFIX.len()..))
        .unwrap_or(text);
    body.to_uppercase()
}

/// The frequencies the server's parser accepts.
const RULE_FREQUENCIES: [&str; 7] = [
    "SECONDLY", "MINUTELY", "HOURLY", "DAILY", "WEEKLY", "MONTHLY", "YEARLY",
];

/// The fields the server's parser accepts; `COUNT` and `UNTIL` belong to the ending.
const RULE_FIELDS: [&str; 13] = [
    "FREQ",
    "INTERVAL",
    "WKST",
    "BYSECOND",
    "BYMINUTE",
    "BYHOUR",
    "BYDAY",
    "BYMONTHDAY",
    "BYYEARDAY",
    "BYWEEKNO",
    "BYMONTH",
    "BYSETPOS",
    "BYEASTER",
];

/// What is wrong with the shape of RRULE editor text, in the web's words, or `None`. Whether
/// the rule runs, how often, and its values' ranges are the server's to judge on save.
#[must_use]
pub fn validate_rule_text(rule: &str) -> Option<String> {
    let text = normalize_rule_text(rule);
    if text.is_empty() {
        return Some("Enter a recurrence rule, such as FREQ=DAILY;BYHOUR=9;BYMINUTE=0.".to_owned());
    }
    if text.contains(['\r', '\n']) {
        return Some(
            "Enter one RRULE line. Choose the timezone below instead of DTSTART;TZID.".to_owned(),
        );
    }
    let Some(parts) = rule_segments(&text, false) else {
        return Some(
            "Write the rule as NAME=VALUE pairs separated by semicolons, using each name once."
                .to_owned(),
        );
    };
    if parts
        .iter()
        .any(|(key, _)| key == "COUNT" || key == "UNTIL")
    {
        return Some(
            "Set when the schedule ends under Ends instead of with COUNT or UNTIL.".to_owned(),
        );
    }
    if let Some((unknown, _)) = parts
        .iter()
        .find(|(key, _)| !RULE_FIELDS.contains(&key.as_str()))
    {
        return Some(format!("{unknown} isn't a supported rule field."));
    }
    let frequency = parts.iter().find(|(key, _)| key == "FREQ");
    if !frequency.is_some_and(|(_, value)| RULE_FREQUENCIES.contains(&value.as_str())) {
        return Some(
            "Include a FREQ such as MINUTELY, HOURLY, DAILY, WEEKLY, MONTHLY or YEARLY.".to_owned(),
        );
    }
    None
}

/// The rule without its `COUNT` or `UNTIL`, as the RRULE editor starts from it.
#[must_use]
pub fn recurring_rule(model: &ScheduleModel) -> String {
    build_recurrence(model)
}

/// Why a custom `interval` of `frequency` is out of range under `limits`, in the web's words.
fn interval_problem(
    frequency: ScheduleFrequency,
    interval: u16,
    limits: ScheduleLimits,
) -> Option<String> {
    let minimum = minimum_schedule_interval(frequency, limits);
    let maximum = maximum_schedule_interval(frequency);
    if (minimum..=maximum).contains(&interval) {
        return None;
    }
    if frequency == ScheduleFrequency::Minutely && interval < MIN_HOURLY_MINUTE_INTERVAL {
        if !limits.subhour_supported {
            return Some("This server requires schedules of at least 60 minutes.".to_owned());
        }
        if !limits.continues_session && !limits.on_connected_host {
            return Some(
                "New sandbox sessions require schedules of at least 60 minutes. Continue in the same session or use a connected host for shorter intervals."
                    .to_owned(),
            );
        }
    }
    Some(format!(
        "Interval must be a whole number of at least {minimum} and at most {maximum}."
    ))
}

/// Whether `model` needs a server with anchored scheduling (`automations_v2`): custom schedules
/// and run-count endings.
#[must_use]
pub fn needs_anchored_scheduling(model: &ScheduleModel) -> bool {
    model.preset == SchedulePreset::Custom || matches!(model.end, ScheduleEnd::Count(_))
}

fn build_recurrence(model: &ScheduleModel) -> String {
    let (hour, minute) = (model.hour.min(23), model.minute.min(59));
    let time = format!("BYHOUR={hour};BYMINUTE={minute}");
    match model.preset {
        SchedulePreset::Hourly => format!("FREQ=HOURLY;BYMINUTE={minute}"),
        SchedulePreset::Daily => format!("FREQ=DAILY;{time}"),
        SchedulePreset::Weekdays => format!("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;{time}"),
        SchedulePreset::Weekly => {
            format!("FREQ=WEEKLY;BYDAY={};{time}", join_codes(&model.weekdays))
        }
        SchedulePreset::Custom => {
            let interval = model
                .interval
                .clamp(1, maximum_schedule_interval(model.frequency));
            match model.frequency {
                ScheduleFrequency::Minutely => format!("FREQ=MINUTELY;INTERVAL={interval}"),
                ScheduleFrequency::Hourly => {
                    format!("FREQ=HOURLY;INTERVAL={interval};BYMINUTE={minute}")
                }
                ScheduleFrequency::Daily => format!("FREQ=DAILY;INTERVAL={interval};{time}"),
                ScheduleFrequency::Weekly => format!(
                    "FREQ=WEEKLY;INTERVAL={interval};BYDAY={};{time}",
                    join_codes(&model.weekdays)
                ),
                ScheduleFrequency::Monthly => format!(
                    "FREQ=MONTHLY;INTERVAL={interval};BYMONTHDAY={};{time}",
                    join_month_days(&model.month_days)
                ),
                ScheduleFrequency::Yearly => format!(
                    "FREQ=YEARLY;INTERVAL={interval};BYMONTH={};BYMONTHDAY={};{time}",
                    model.month.clamp(1, 12),
                    join_month_days(&model.month_days)
                ),
                ScheduleFrequency::Rule => normalize_rule_text(&model.rule),
            }
        }
    }
}

/// The rule's `KEY=VALUE` parts, or `None` when it is not one well-formed rule.
fn rule_parts(rrule: &str) -> Option<BTreeMap<String, String>> {
    let body = rrule.trim();
    let body = body.strip_prefix(RULE_PREFIX).unwrap_or(body);
    let parts: BTreeMap<String, String> = rule_segments(body, true)?.into_iter().collect();
    parts.contains_key("FREQ").then_some(parts)
}

/// `body`'s `KEY=VALUE` parts in order, upper case, or `None` when a part is malformed or a key
/// repeats. Empty parts (a trailing `;`) are skipped where `skip_empty`, else malformed.
fn rule_segments(body: &str, skip_empty: bool) -> Option<Vec<(String, String)>> {
    let mut parts: Vec<(String, String)> = Vec::new();
    let mut seen = BTreeSet::new();
    for segment in body.split(';') {
        if skip_empty && segment.is_empty() {
            continue;
        }
        let (key, value) = segment.split_once('=')?;
        if key.is_empty() || value.is_empty() || value.contains('=') {
            return None;
        }
        let key = key.to_ascii_uppercase();
        if !seen.insert(key.clone()) {
            return None;
        }
        parts.push((key, value.to_ascii_uppercase()));
    }
    Some(parts)
}

pub(crate) fn number<T: std::str::FromStr + PartialOrd>(
    value: &str,
    range: &RangeInclusive<T>,
) -> Option<T> {
    value
        .parse::<T>()
        .ok()
        .filter(|number| range.contains(number))
}

fn weekdays_part(value: &str) -> Option<Vec<Weekday>> {
    let days = value
        .split(',')
        .map(Weekday::from_code)
        .collect::<Option<Vec<_>>>()?;
    Some(sorted_days(&days))
}

fn month_days_part(value: &str) -> Option<Vec<u8>> {
    let days = value
        .split(',')
        .map(|day| number(day, &(1_u8..=31)))
        .collect::<Option<Vec<_>>>()?;
    Some(sorted_month_days(&days))
}

/// The editor model for a stored rule, as the web reads one.
///
/// The visual controls when they show it exactly, else its RRULE text. `None` when the ending
/// can't show the rule's `COUNT` or `UNTIL` (a one-time `COUNT=1`, both, or a malformed value)
/// or the rule is malformed; the editor then keeps the rule as it is.
#[must_use]
pub fn parse_rrule(rrule: &str) -> Option<ScheduleModel> {
    // The server accepts any case, a lower-case prefix and surrounding spaces.
    let parts = rule_segments(&normalize_rule_text(rrule), true)?;
    if parts.is_empty() {
        return None;
    }
    let lookup: BTreeMap<String, String> = parts.iter().cloned().collect();
    let end = match (lookup.get("COUNT"), lookup.get("UNTIL")) {
        (None, None) => ScheduleEnd::Never,
        (Some(count), None) => ScheduleEnd::Count(number(count, &(MIN_COUNT..=MAX_COUNT))?),
        (None, Some(until)) => ScheduleEnd::Until(parse_until(until)?),
        (Some(_), Some(_)) => return None,
    };
    let recurring: Vec<(String, String)> = parts
        .into_iter()
        .filter(|(key, _)| key != "COUNT" && key != "UNTIL")
        .collect();
    let model = parse_visual_rule(&recurring.iter().cloned().collect()).unwrap_or_else(|| {
        let text = recurring
            .iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect::<Vec<_>>()
            .join(";");
        ScheduleModel {
            preset: SchedulePreset::Custom,
            frequency: ScheduleFrequency::Rule,
            rule: text,
            ..ScheduleModel::default()
        }
    });
    Some(ScheduleModel { end, ..model })
}

/// The visual controls for a rule without `COUNT` or `UNTIL`, or `None` when they can't show it.
fn parse_visual_rule(parts: &BTreeMap<String, String>) -> Option<ScheduleModel> {
    let frequency = ScheduleFrequency::from_code(parts.get("FREQ")?)?;
    let mut allowed = vec!["FREQ", "INTERVAL"];
    if frequency != ScheduleFrequency::Minutely {
        allowed.push("BYMINUTE");
    }
    match frequency {
        ScheduleFrequency::Minutely | ScheduleFrequency::Hourly => {}
        ScheduleFrequency::Daily => allowed.push("BYHOUR"),
        ScheduleFrequency::Weekly => allowed.extend(["BYHOUR", "BYDAY"]),
        ScheduleFrequency::Monthly => allowed.extend(["BYHOUR", "BYMONTHDAY"]),
        ScheduleFrequency::Yearly => allowed.extend(["BYHOUR", "BYMONTHDAY", "BYMONTH"]),
        ScheduleFrequency::Rule => return None,
    }
    if parts.keys().any(|key| !allowed.contains(&key.as_str())) {
        return None;
    }
    let defaults = ScheduleModel::default();
    let interval = number(
        parts.get("INTERVAL").map_or("1", String::as_str),
        &(1_u16..=maximum_schedule_interval(frequency)),
    )?;
    // As the web, only a minute rule some server could save reopens in the editor.
    if interval < minimum_schedule_interval(frequency, ScheduleLimits::SAVED) {
        return None;
    }
    let minute = if frequency == ScheduleFrequency::Minutely {
        defaults.minute
    } else {
        number(parts.get("BYMINUTE")?, &(0_u8..=59))?
    };
    let hour = if matches!(
        frequency,
        ScheduleFrequency::Minutely | ScheduleFrequency::Hourly
    ) {
        defaults.hour
    } else {
        number(parts.get("BYHOUR")?, &(0_u8..=23))?
    };
    let mut model = ScheduleModel {
        preset: SchedulePreset::Custom,
        hour,
        minute,
        frequency,
        interval,
        ..defaults
    };
    if frequency == ScheduleFrequency::Weekly {
        model.weekdays = weekdays_part(parts.get("BYDAY")?)?;
    }
    if matches!(
        frequency,
        ScheduleFrequency::Monthly | ScheduleFrequency::Yearly
    ) {
        model.month_days = month_days_part(parts.get("BYMONTHDAY")?)?;
    }
    if frequency == ScheduleFrequency::Yearly {
        model.month = number(parts.get("BYMONTH")?, &(1_u8..=12))?;
    }
    if interval == 1 {
        model.preset = match frequency {
            ScheduleFrequency::Hourly => SchedulePreset::Hourly,
            ScheduleFrequency::Daily => SchedulePreset::Daily,
            ScheduleFrequency::Weekly if model.weekdays == WEEKDAYS => SchedulePreset::Weekdays,
            ScheduleFrequency::Weekly => SchedulePreset::Weekly,
            ScheduleFrequency::Minutely
            | ScheduleFrequency::Monthly
            | ScheduleFrequency::Yearly
            | ScheduleFrequency::Rule => SchedulePreset::Custom,
        };
    }
    Some(model)
}

/// `8:00 AM`, `12:30 PM`.
#[must_use]
pub fn clock_time(hour: u8, minute: u8) -> String {
    let period = if hour < 12 { "AM" } else { "PM" };
    let twelve = if hour.is_multiple_of(12) {
        12
    } else {
        hour % 12
    };
    format!("{twelve}:{minute:02} {period}")
}

fn join_list(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [only] => only.clone(),
        [first, second] => format!("{first} and {second}"),
        [head @ .., last] => format!("{}, and {last}", head.join(", ")),
    }
}

fn ordinal(day: u8) -> String {
    let suffix = match (day % 10, day % 100) {
        (_, 11..=13) => "th",
        (1, _) => "st",
        (2, _) => "nd",
        (3, _) => "rd",
        _ => "th",
    };
    format!("{day}{suffix}")
}

fn day_names(days: &[Weekday]) -> String {
    join_list(
        &days
            .iter()
            .map(|day| day.name().to_owned())
            .collect::<Vec<_>>(),
    )
}

const MONTH_NAMES: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];

/// A readable summary of `rrule`: "Weekdays at 8:00 AM", "Every 2 hours at :15", "Monthly on the
/// 1st and 15th at 6:00 AM". A rule this cannot read is returned as it is.
#[must_use]
pub fn describe_schedule(rrule: &str) -> String {
    describe_schedule_in(rrule, None)
}

/// [`describe_schedule`] for a rule kept in `timezone`, which a one-time rule names.
///
/// As the web's: "Once on November 12 at 11:00 PM (Asia/Tokyo)", "Once on November 12 at
/// 11:00 PM UTC"; a one-time rule of another shape reads "Once: Every day at 9:00 AM".
#[must_use]
pub fn describe_schedule_in(rrule: &str, timezone: Option<&str>) -> String {
    describe_once(rrule, timezone)
        .or_else(|| describe(rrule))
        .unwrap_or_else(|| rrule.to_owned())
}

/// A one-time rule (`COUNT=1`): a literal date for the reminder shape (yearly, one month, one
/// positive day, at most one time), else the rule without its count after "Once: ".
fn describe_once(rrule: &str, timezone: Option<&str>) -> Option<String> {
    let parts = rule_parts(rrule)?;
    if parts.get("COUNT").map(String::as_str) != Some("1") {
        return None;
    }
    let single = |key: &str| parts.get(key).is_none_or(|value| !value.contains(','));
    let month = parts
        .get("BYMONTH")
        .filter(|value| !value.contains(','))
        .and_then(|value| number(value, &(1_usize..=12)))
        .and_then(|month| MONTH_NAMES.get(month - 1));
    let day = parts
        .get("BYMONTHDAY")
        .filter(|value| !value.contains(','))
        .and_then(|value| number(value, &(1_u8..=31)));
    if let (Some("YEARLY"), Some(month), Some(day), true, true) = (
        parts.get("FREQ").map(String::as_str),
        month,
        day,
        single("BYHOUR"),
        single("BYMINUTE"),
    ) {
        let hour = first_number(parts.get("BYHOUR"), 23_u8)?;
        let minute = first_number(parts.get("BYMINUTE"), 59_u8)?;
        let zone = match timezone.filter(|zone| !zone.is_empty()) {
            None => String::new(),
            Some("UTC") => " UTC".to_owned(),
            Some(zone) => format!(" ({zone})"),
        };
        return Some(format!(
            "Once on {month} {day} at {}{zone}",
            clock_time(hour, minute)
        ));
    }
    let body = rrule.trim();
    let body = body.strip_prefix("RRULE:").unwrap_or(body);
    let recurring: Vec<&str> = body
        .split(';')
        .filter(|part| {
            !part
                .split_once('=')
                .is_some_and(|(key, _)| key.trim().eq_ignore_ascii_case("COUNT"))
        })
        .collect();
    Some(format!("Once: {}", describe_schedule(&recurring.join(";"))))
}

/// The first of a comma-separated list of numbers up to `high`, or 0 when the part is absent.
fn first_number(value: Option<&String>, high: u8) -> Option<u8> {
    match value {
        None => Some(0),
        Some(value) => number(value.split(',').next()?, &(0..=high)),
    }
}

fn describe(rrule: &str) -> Option<String> {
    let parts = rule_parts(rrule)?;
    // A summary that skipped a field would describe a different schedule.
    if !phrases_state_every_field(&parts) {
        return None;
    }
    let frequency = ScheduleFrequency::from_code(parts.get("FREQ")?)?;
    if frequency == ScheduleFrequency::Minutely {
        return describe_minutely(&parts);
    }
    let hour = first_number(parts.get("BYHOUR"), 23_u8)?;
    let minute = first_number(parts.get("BYMINUTE"), 59_u8)?;
    let at = format!(" at {}", clock_time(hour, minute));
    let interval = match parts.get("INTERVAL") {
        None => 1,
        Some(value) => number(value, &(1_u16..=u16::MAX))?,
    };
    let days = match parts.get("BYDAY") {
        None => Vec::new(),
        Some(value) => weekdays_part(value)?,
    };
    let on_days = match parts.get("BYMONTHDAY") {
        None => String::new(),
        Some(value) => {
            let ordinals: Vec<String> = month_days_part(value)?.into_iter().map(ordinal).collect();
            format!(" on the {}", join_list(&ordinals))
        }
    };
    Some(match frequency {
        ScheduleFrequency::Minutely | ScheduleFrequency::Rule => return None,
        ScheduleFrequency::Hourly => describe_hourly(interval, minute),
        ScheduleFrequency::Daily if interval > 1 => format!("Every {interval} days{at}"),
        ScheduleFrequency::Daily => format!("Every day{at}"),
        ScheduleFrequency::Weekly => describe_weekly(interval, &days) + &at,
        ScheduleFrequency::Monthly if interval > 1 => {
            format!("Every {interval} months{on_days}{at}")
        }
        ScheduleFrequency::Monthly => format!("Monthly{on_days}{at}"),
        ScheduleFrequency::Yearly => {
            let months = match parts.get("BYMONTH") {
                None => String::new(),
                Some(value) => format!(" in {}", month_names(value)?),
            };
            if interval > 1 {
                format!("Every {interval} years{months}{on_days}{at}")
            } else {
                format!("Yearly{months}{on_days}{at}")
            }
        }
    })
}

/// A part's comma-separated values; none when the rule lacks it.
fn rule_values<'a>(parts: &'a BTreeMap<String, String>, key: &str) -> Vec<&'a str> {
    parts
        .get(key)
        .map_or_else(Vec::new, |value| value.split(',').collect())
}

/// Whether the summaries state every field of a rule: the shapes the visual controls make. A
/// rule with, say, `BYSETPOS` or several hours shows as written, as the web's.
fn phrases_state_every_field(parts: &BTreeMap<String, String>) -> bool {
    if ["BYSETPOS", "BYYEARDAY", "BYWEEKNO", "BYEASTER"]
        .iter()
        .any(|key| parts.contains_key(*key))
    {
        return false;
    }
    let list = |key: &str| rule_values(parts, key);
    let within = |values: &[&str], range: RangeInclusive<i64>| {
        values.iter().all(|value| number(value, &range).is_some())
    };
    if !within(&list("BYSECOND"), 0..=0) {
        return false;
    }
    let (hours, minutes) = (list("BYHOUR"), list("BYMINUTE"));
    let (months, month_days, weekdays) = (list("BYMONTH"), list("BYMONTHDAY"), list("BYDAY"));
    // A numbered weekday such as 1MO (the first Monday) has no phrase.
    if weekdays.iter().any(|day| Weekday::from_code(day).is_none()) {
        return false;
    }
    if hours.len() > 1 || minutes.len() > 1 {
        return false;
    }
    if !within(&hours, 0..=23) || !within(&minutes, 0..=59) {
        return false;
    }
    if !within(&months, 1..=12) || !within(&month_days, 1..=31) {
        return false;
    }
    let interval = parts
        .get("INTERVAL")
        .and_then(|value| number(value, &(1_i64..=i64::MAX)))
        .unwrap_or(1);
    let day_filters = weekdays.len() + months.len() + month_days.len();
    match parts.get("FREQ").map(String::as_str) {
        // Minute rules show any filter as written.
        Some("MINUTELY") => true,
        Some("SECONDLY") => day_filters + hours.len() + minutes.len() == 0,
        Some("HOURLY") => hours.is_empty() && day_filters == 0,
        Some("DAILY") => day_filters == 0,
        // WKST changes which weeks a multi-week interval groups together.
        Some("WEEKLY") => {
            months.len() + month_days.len() == 0
                && !(interval > 1 && parts.get("WKST").is_some_and(|start| start != "MO"))
        }
        Some("MONTHLY") => weekdays.len() + months.len() == 0,
        // Without BYMONTH, BYMONTHDAY runs in every month.
        Some("YEARLY") => weekdays.is_empty() && (month_days.is_empty() || !months.is_empty()),
        _ => false,
    }
}

/// "Every minute", "Every 10 minutes"; a minute rule with `BY` filters stays raw, as the web.
fn describe_minutely(parts: &BTreeMap<String, String>) -> Option<String> {
    if parts.keys().any(|key| key.starts_with("BY")) {
        return None;
    }
    let interval = match parts.get("INTERVAL") {
        None => 1,
        Some(value) => number(value, &(1_u32..=u32::MAX))?,
    };
    Some(if interval == 1 {
        "Every minute".to_owned()
    } else {
        format!("Every {interval} minutes")
    })
}

fn describe_hourly(interval: u16, minute: u8) -> String {
    if interval > 1 {
        format!("Every {interval} hours at :{minute:02}")
    } else if minute == 0 {
        "Hourly".to_owned()
    } else {
        format!("Hourly at :{minute:02}")
    }
}

/// The weekly text before its time: shorthands for weekdays, every day and weekends.
fn describe_weekly(interval: u16, days: &[Weekday]) -> String {
    if interval > 1 {
        if days.is_empty() {
            return format!("Every {interval} weeks");
        }
        return format!("Every {interval} weeks on {}", day_names(days));
    }
    if days.is_empty() {
        "Weekly".to_owned()
    } else if days == WEEKDAYS {
        "Weekdays".to_owned()
    } else if days == Weekday::ALL {
        "Every day".to_owned()
    } else if days == [Weekday::Saturday, Weekday::Sunday] {
        "Weekends".to_owned()
    } else {
        format!("Weekly on {}", day_names(days))
    }
}

fn month_names(value: &str) -> Option<String> {
    let names = value
        .split(',')
        .map(|month| number(month, &(1_usize..=12)).and_then(|month| MONTH_NAMES.get(month - 1)))
        .collect::<Option<Vec<_>>>()?;
    Some(names.into_iter().copied().collect::<Vec<_>>().join(", "))
}

fn plural(count: i64, noun: &str) -> String {
    if count == 1 {
        format!("{count} {noun}")
    } else {
        format!("{count} {noun}s")
    }
}

/// How far the server's next fire is from `now`, both Unix seconds: `soon`, `in 8 mins`,
/// `in 3 hours`, `in 2 days`. Each unit rounds to nearest and promotes when it rounds up.
#[must_use]
pub fn format_next_run(next_run_at: i64, now: i64) -> String {
    const MINUTE: i64 = 60;
    const HOUR: i64 = 60 * MINUTE;
    const DAY: i64 = 24 * HOUR;
    let delta = next_run_at.saturating_sub(now);
    if delta < MINUTE {
        return "soon".to_owned();
    }
    let rounded = |unit: i64| delta.saturating_add(unit / 2) / unit;
    let minutes = rounded(MINUTE);
    if minutes < 60 {
        return format!("in {}", plural(minutes, "min"));
    }
    let hours = rounded(HOUR);
    if hours < 24 {
        return format!("in {}", plural(hours, "hour"));
    }
    format!("in {}", plural(rounded(DAY), "day"))
}

/// The latest year a server date may name; beyond it the day arithmetic could overflow an `i64`.
pub(crate) const MAX_DATE_YEAR: i64 = 1_000_000;

/// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
pub(crate) const fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_index = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// Unix seconds of an ISO 8601 date-time with a zone (`2026-11-05T08:00:00+00:00`, `...Z`,
/// fractional seconds allowed), or `None`.
#[must_use]
pub fn parse_iso8601(value: &str) -> Option<i64> {
    let value = value.trim();
    let (date, rest) = value.split_once(['T', ' '])?;
    let mut date = date.splitn(3, '-');
    let year = number(date.next()?, &(0_i64..=MAX_DATE_YEAR))?;
    let month = number(date.next()?, &(1_i64..=12))?;
    let day = number(date.next()?, &(1_i64..=31))?;
    let (time, offset_seconds) = if let Some(time) = rest.strip_suffix(['Z', 'z']) {
        (time, 0)
    } else {
        let split = rest.rfind(['+', '-'])?;
        let (time, zone) = rest.split_at(split);
        let sign = if zone.starts_with('-') { -1 } else { 1 };
        let zone = zone.get(1..)?;
        let (zone_hours, zone_minutes) = zone.split_once(':').unwrap_or((zone, "0"));
        let zone_hours = number(zone_hours, &(0_i64..=23))?;
        let zone_minutes = number(zone_minutes, &(0_i64..=59))?;
        (time, sign * (zone_hours * 3600 + zone_minutes * 60))
    };
    let mut time = time.splitn(3, ':');
    let hour = number(time.next()?, &(0_i64..=23))?;
    let minute = number(time.next()?, &(0_i64..=59))?;
    let second = match time.next() {
        None => 0,
        Some(second) => number(second.split('.').next()?, &(0_i64..=60))?,
    };
    let days = days_from_civil(year, month, day);
    Some(days * 86_400 + hour * 3600 + minute * 60 + second - offset_seconds)
}

#[cfg(test)]
#[path = "schedule_tests.rs"]
mod tests;
