//! The string formats an MCP form field can require (`format`): `email`, `uri`, `date` and
//! `date-time`, the four MCP's `StringSchema` allows.
//!
//! Each check is at least as strict as common JSON Schema validators, so an answer the native
//! form accepts is one the asking server accepts. Valid but unusual spellings (a quoted email
//! local part, a leap second, a lowercase `t`) are refused rather than risked.

use std::fmt;

/// A format a text answer must match.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TextFormat {
    /// `email`: an address such as `name@example.com`.
    Email,
    /// `uri`: an absolute URI such as `https://example.com/path`.
    Uri,
    /// `date`: an RFC 3339 full date, `YYYY-MM-DD`.
    Date,
    /// `date-time`: an RFC 3339 date and time with its offset, `YYYY-MM-DDTHH:MM:SSZ`.
    DateTime,
}

impl TextFormat {
    /// The format named by a schema's `format` value, if the native form can check it.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "email" => Some(Self::Email),
            "uri" => Some(Self::Uri),
            "date" => Some(Self::Date),
            "date-time" => Some(Self::DateTime),
            _ => None,
        }
    }

    /// The wire value.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Email => "email",
            Self::Uri => "uri",
            Self::Date => "date",
            Self::DateTime => "date-time",
        }
    }

    /// What an answer must be, for messages: "an email address".
    #[must_use]
    pub const fn expected(self) -> &'static str {
        match self {
            Self::Email => "an email address",
            Self::Uri => "a full URL",
            Self::Date => "a date as YYYY-MM-DD",
            Self::DateTime => "a date and time as YYYY-MM-DDTHH:MM:SSZ",
        }
    }

    /// Whether `text` is in this format.
    #[must_use]
    pub fn matches(self, text: &str) -> bool {
        text.is_ascii()
            && match self {
                Self::Email => is_email(text),
                Self::Uri => is_uri(text),
                Self::Date => is_full_date(text),
                Self::DateTime => is_date_time(text),
            }
    }
}

impl fmt::Display for TextFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

const MAX_EMAIL_LENGTH: usize = 254;
const MAX_LOCAL_PART_LENGTH: usize = 64;
const MAX_DOMAIN_LENGTH: usize = 253;
const MAX_LABEL_LENGTH: usize = 63;

/// `local@domain`: a dot-atom local part and a hostname with at least two labels.
fn is_email(text: &str) -> bool {
    let Some((local, domain)) = text.rsplit_once('@') else {
        return false;
    };
    text.len() <= MAX_EMAIL_LENGTH
        && local.len() <= MAX_LOCAL_PART_LENGTH
        && is_dot_atom(local)
        && domain.contains('.')
        && is_hostname(domain)
}

/// RFC 5322 `atext`.
fn is_atext(character: char) -> bool {
    character.is_ascii_alphanumeric() || "!#$%&'*+/=?^_`{|}~-".contains(character)
}

fn is_dot_atom(text: &str) -> bool {
    text.split('.')
        .all(|atom| !atom.is_empty() && atom.chars().all(is_atext))
}

fn is_hostname(domain: &str) -> bool {
    domain.len() <= MAX_DOMAIN_LENGTH
        && domain.split('.').all(|label| {
            (1..=MAX_LABEL_LENGTH).contains(&label.len())
                && label
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || character == '-')
                && !label.starts_with('-')
                && !label.ends_with('-')
        })
}

/// An RFC 3986 absolute URI: a scheme, only URI characters with well-formed percent escapes, and
/// one the WHATWG parser also accepts.
fn is_uri(text: &str) -> bool {
    let Some((scheme, _)) = text.split_once(':') else {
        return false;
    };
    let mut scheme_characters = scheme.chars();
    scheme_characters
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic())
        && scheme_characters.all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '+' | '-' | '.')
        })
        && has_only_uri_characters(text)
        && url::Url::parse(text).is_ok()
}

fn has_only_uri_characters(text: &str) -> bool {
    let bytes = text.as_bytes();
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        if byte == b'%' {
            let escaped = bytes
                .get(index + 1..index + 3)
                .is_some_and(|hex| hex.iter().all(u8::is_ascii_hexdigit));
            if !escaped {
                return false;
            }
            index += 3;
            continue;
        }
        if !(byte.is_ascii_alphanumeric() || b"-._~:/?#[]@!$&'()*+,;=".contains(&byte)) {
            return false;
        }
        index += 1;
    }
    true
}

/// The ASCII digit at `index`, as a number.
fn digit(bytes: &[u8], index: usize) -> Option<u32> {
    bytes
        .get(index)
        .filter(|byte| byte.is_ascii_digit())
        .map(|byte| u32::from(*byte - b'0'))
}

/// Two ASCII digits at `start`, as a number.
fn two_digits(bytes: &[u8], start: usize) -> Option<u32> {
    Some(digit(bytes, start)? * 10 + digit(bytes, start + 1)?)
}

const fn is_leap_year(year: u32) -> bool {
    year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400))
}

const fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        2 if is_leap_year(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// `YYYY-MM-DD`, a real calendar day.
fn is_full_date(text: &str) -> bool {
    let bytes = text.as_bytes();
    if bytes.len() != 10 || bytes.get(4) != Some(&b'-') || bytes.get(7) != Some(&b'-') {
        return false;
    }
    let (Some(century), Some(year_of_century), Some(month), Some(day)) = (
        two_digits(bytes, 0),
        two_digits(bytes, 2),
        two_digits(bytes, 5),
        two_digits(bytes, 8),
    ) else {
        return false;
    };
    let year = century * 100 + year_of_century;
    (1..=12).contains(&month) && (1..=days_in_month(year, month)).contains(&day)
}

/// `HH:MM`, with hours below 24 and minutes below 60, at `start`.
fn is_hours_minutes(bytes: &[u8], start: usize) -> bool {
    matches!(
        (two_digits(bytes, start), bytes.get(start + 2), two_digits(bytes, start + 3)),
        (Some(hours), Some(b':'), Some(minutes)) if hours < 24 && minutes < 60
    )
}

/// `full-date "T" HH:MM:SS [.fraction] ("Z" / ("+" / "-") HH:MM)`.
fn is_date_time(text: &str) -> bool {
    let Some((date, time)) = text.split_once('T') else {
        return false;
    };
    let bytes = time.as_bytes();
    let has_seconds =
        bytes.get(5) == Some(&b':') && two_digits(bytes, 6).is_some_and(|seconds| seconds < 60);
    let Some(mut offset) = bytes.get(8..) else {
        return false;
    };
    if !is_full_date(date) || !is_hours_minutes(bytes, 0) || !has_seconds {
        return false;
    }
    if let Some(fraction) = offset.strip_prefix(b".") {
        let digits = fraction
            .iter()
            .take_while(|byte| byte.is_ascii_digit())
            .count();
        if digits == 0 {
            return false;
        }
        offset = fraction.get(digits..).unwrap_or_default();
    }
    match offset {
        b"Z" => true,
        [b'+' | b'-', ..] => offset.len() == 6 && is_hours_minutes(offset, 1),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_format_names_itself_and_only_the_four_mcp_formats_parse() {
        for format in [
            TextFormat::Email,
            TextFormat::Uri,
            TextFormat::Date,
            TextFormat::DateTime,
        ] {
            assert_eq!(TextFormat::parse(format.as_str()), Some(format));
            assert_eq!(format.to_string(), format.as_str());
            assert_ne!(format.expected(), "");
        }
        for other in ["time", "uuid", "hostname", "ipv4", "Email", ""] {
            assert_eq!(TextFormat::parse(other), None, "{other}");
        }
    }

    #[test]
    fn email_addresses_need_a_dot_atom_and_a_dotted_hostname() {
        for valid in [
            "name@example.com",
            "first.last+tag@mail.example.org",
            "o'brien@example.co",
            "a@b-c.example",
        ] {
            assert!(TextFormat::Email.matches(valid), "{valid}");
        }
        let long_local = format!("{}@example.com", "a".repeat(65));
        let long_label = format!("a@{}.com", "b".repeat(64));
        for invalid in [
            "",
            "name",
            "name@",
            "@example.com",
            "name@localhost",
            "name@@example.com",
            ".name@example.com",
            "name.@example.com",
            "na..me@example.com",
            "na me@example.com",
            "name@-example.com",
            "name@example-.com",
            "name@example..com",
            "\"quoted\"@example.com",
            "name@[192.0.2.1]",
            "näme@example.com",
            long_local.as_str(),
            long_label.as_str(),
        ] {
            assert!(!TextFormat::Email.matches(invalid), "{invalid}");
        }
    }

    #[test]
    fn uris_need_a_scheme_and_only_uri_characters() {
        for valid in [
            "https://example.com",
            "https://example.com/a/b?c=d&e=%20f#top",
            "mailto:name@example.com",
            "urn:isbn:0451450523",
            "http://[2001:db8::1]:8080/",
        ] {
            assert!(TextFormat::Uri.matches(valid), "{valid}");
        }
        for invalid in [
            "",
            "example.com",
            "/relative/path",
            "1http://example.com",
            "ht tp://example.com",
            "https://example.com/a b",
            "https://example.com/%zz",
            "https://example.com/%2",
            "https://example.com/\"quoted\"",
            "https://exämple.com",
            "https://example.com/<tag>",
            "http:",
        ] {
            assert!(!TextFormat::Uri.matches(invalid), "{invalid}");
        }
    }

    #[test]
    fn dates_are_real_calendar_days() {
        for valid in ["2026-11-17", "2024-02-29", "2000-02-29", "1999-12-31"] {
            assert!(TextFormat::Date.matches(valid), "{valid}");
        }
        for invalid in [
            "",
            "2026-1-17",
            "2026/11/17",
            "2026-13-01",
            "2026-00-10",
            "2026-11-00",
            "2026-11-31",
            "2025-02-29",
            "1900-02-29",
            "2026-11-17T00:00:00Z",
            "２０２６-11-17",
        ] {
            assert!(!TextFormat::Date.matches(invalid), "{invalid}");
        }
    }

    #[test]
    fn date_times_need_seconds_and_an_offset() {
        for valid in [
            "2026-11-17T13:05:00Z",
            "2026-11-17T13:05:00-08:00",
            "2026-11-17T23:59:59.123456+05:30",
            "2024-02-29T00:00:00+00:00",
        ] {
            assert!(TextFormat::DateTime.matches(valid), "{valid}");
        }
        for invalid in [
            "",
            "2026-11-17",
            "2026-11-17T13:05Z",
            "2026-11-17T13:05:00",
            "2026-11-17 13:05:00Z",
            "2026-11-17t13:05:00z",
            "2026-11-17T24:00:00Z",
            "2026-11-17T13:60:00Z",
            "2026-11-17T13:05:60Z",
            "2026-11-17T13:05:00.Z",
            "2026-11-17T13:05:00+0800",
            "2026-11-17T13:05:00+24:00",
            "2026-11-17T13:05:00+08:60",
            "2026-11-31T13:05:00Z",
            "2026-11-17T13:05:00ZZ",
        ] {
            assert!(!TextFormat::DateTime.matches(invalid), "{invalid}");
        }
    }
}
