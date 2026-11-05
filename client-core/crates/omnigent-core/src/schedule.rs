//! Automation schedules and their text.
//!
//! The RFC 5545 rules the scheduled-task API stores, the editor model the web's schedule builder
//! produces (`web/src/lib/scheduleBuilder.ts`), the human summary (`describeSchedule`) and the
//! next-run label (`formatNextRunAt`).
//!
//! The next fire instant is always the server's (`next_run_at`); only its distance from now is
//! formatted here.

use std::collections::BTreeMap;
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
}

impl ScheduleFrequency {
    fn from_code(code: &str) -> Option<Self> {
        match code {
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
/// unchanged schedule may keep an end in the past (`allow_past_end`).
#[must_use]
pub fn validate_schedule(model: &ScheduleModel, now: i64, allow_past_end: bool) -> Option<String> {
    let custom = |frequency| model.preset == SchedulePreset::Custom && model.frequency == frequency;
    if (model.preset == SchedulePreset::Weekly || custom(ScheduleFrequency::Weekly))
        && model.weekdays.is_empty()
    {
        return Some("Pick at least one day of the week.".to_owned());
    }
    if (custom(ScheduleFrequency::Monthly) || custom(ScheduleFrequency::Yearly))
        && sorted_month_days(&model.month_days).is_empty()
    {
        return Some("Pick at least one day of the month.".to_owned());
    }
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
            let interval = model.interval.clamp(1, 366);
            match model.frequency {
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
            }
        }
    }
}

/// The rule's `KEY=VALUE` parts, or `None` when it is not one well-formed rule.
fn rule_parts(rrule: &str) -> Option<BTreeMap<String, String>> {
    let body = rrule.trim();
    let body = body.strip_prefix("RRULE:").unwrap_or(body);
    let mut parts = BTreeMap::new();
    for segment in body.split(';').filter(|segment| !segment.is_empty()) {
        let (key, value) = segment.split_once('=')?;
        if key.is_empty() || value.is_empty() || value.contains('=') {
            return None;
        }
        if parts
            .insert(key.to_ascii_uppercase(), value.to_ascii_uppercase())
            .is_some()
        {
            return None;
        }
    }
    parts.contains_key("FREQ").then_some(parts)
}

fn number<T: std::str::FromStr + PartialOrd>(value: &str, range: &RangeInclusive<T>) -> Option<T> {
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

/// The editor model for a rule the editor can produce, or `None` (other parts or malformed
/// rules), in which case the editor keeps the rule as it is.
#[must_use]
pub fn parse_rrule(rrule: &str) -> Option<ScheduleModel> {
    let parts = rule_parts(rrule)?;
    let frequency = ScheduleFrequency::from_code(parts.get("FREQ")?)?;
    let mut allowed = vec!["FREQ", "INTERVAL", "BYMINUTE", "COUNT", "UNTIL"];
    match frequency {
        ScheduleFrequency::Hourly => {}
        ScheduleFrequency::Daily => allowed.push("BYHOUR"),
        ScheduleFrequency::Weekly => allowed.extend(["BYHOUR", "BYDAY"]),
        ScheduleFrequency::Monthly => allowed.extend(["BYHOUR", "BYMONTHDAY"]),
        ScheduleFrequency::Yearly => allowed.extend(["BYHOUR", "BYMONTHDAY", "BYMONTH"]),
    }
    if parts.keys().any(|key| !allowed.contains(&key.as_str())) {
        return None;
    }
    let defaults = ScheduleModel::default();
    let interval = number(
        parts.get("INTERVAL").map_or("1", String::as_str),
        &(1_u16..=366),
    )?;
    let minute = number(parts.get("BYMINUTE")?, &(0_u8..=59))?;
    let hour = if frequency == ScheduleFrequency::Hourly {
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
    model.end = match (parts.get("COUNT"), parts.get("UNTIL")) {
        (None, None) => ScheduleEnd::Never,
        (Some(count), None) => ScheduleEnd::Count(number(count, &(MIN_COUNT..=MAX_COUNT))?),
        (None, Some(until)) => ScheduleEnd::Until(parse_until(until)?),
        (Some(_), Some(_)) => return None,
    };
    if interval == 1 {
        model.preset = match frequency {
            ScheduleFrequency::Hourly => SchedulePreset::Hourly,
            ScheduleFrequency::Daily => SchedulePreset::Daily,
            ScheduleFrequency::Weekly if model.weekdays == WEEKDAYS => SchedulePreset::Weekdays,
            ScheduleFrequency::Weekly => SchedulePreset::Weekly,
            ScheduleFrequency::Monthly | ScheduleFrequency::Yearly => SchedulePreset::Custom,
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
    describe(rrule).unwrap_or_else(|| rrule.to_owned())
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
    let frequency = ScheduleFrequency::from_code(parts.get("FREQ")?)?;
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
    let rounded = |unit: i64| (delta + unit / 2) / unit;
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
    let year: i64 = date.next()?.parse().ok()?;
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
