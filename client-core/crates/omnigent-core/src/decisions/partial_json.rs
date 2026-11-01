//! A JSON reader for previews the server cut off at a fixed length.
//!
//! `content_preview` is capped (1024 characters for native permission hooks, 300 for SDK
//! harnesses), so the JSON in it often ends mid-value. [`parse`] reads what is there:
//! - Every value that ends before the cut is kept exactly.
//! - A string, number or literal the cut runs through is dropped, with its key, so a cut path or
//!   text never reads as complete.
//! - A container the cut runs through keeps its complete members and is marked
//!   [`Json::is_cut`], and so is every container around it.
//!
//! Input that is not a JSON prefix (rather than a cut one) is an error.

/// A parsed JSON value. Containers record whether the cut ran through them.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Json {
    /// `null`.
    Null,
    /// `true` or `false`.
    Bool(bool),
    /// A number, as written.
    Number(String),
    /// A string.
    String(String),
    /// An array and whether it was cut.
    Array(Vec<Self>, bool),
    /// An object, members in document order, and whether it was cut.
    Object(Vec<(String, Self)>, bool),
}

impl Json {
    /// The member `key` of an object (the last one, as JSON parsers do).
    pub(super) fn get(&self, key: &str) -> Option<&Self> {
        match self {
            Self::Object(members, _) => members
                .iter()
                .rev()
                .find(|(name, _)| name == key)
                .map(|(_, value)| value),
            _ => None,
        }
    }

    /// The first of `keys` present as a string.
    pub(super) fn text(&self, keys: &[&str]) -> Option<&str> {
        keys.iter()
            .find_map(|key| self.get(key))
            .and_then(Self::as_str)
    }

    /// The string, if this is one.
    pub(super) const fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(text) => Some(text.as_str()),
            _ => None,
        }
    }

    /// Whether the cut ran through this container.
    pub(super) const fn is_cut(&self) -> bool {
        matches!(self, Self::Array(_, true) | Self::Object(_, true))
    }
}

/// Why a preview is not a JSON prefix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct NotJson;

/// Parses the JSON value at the start of `text`. Whitespace may follow a complete value; anything
/// else is [`NotJson`].
pub(super) fn parse(text: &str) -> Result<Json, NotJson> {
    let mut reader = Reader {
        bytes: text.as_bytes(),
        text,
        at: 0,
    };
    let value = reader.value()?.ok_or(NotJson)?;
    reader.whitespace();
    if !value.is_cut() && reader.at < reader.bytes.len() {
        return Err(NotJson);
    }
    Ok(value)
}

struct Reader<'a> {
    bytes: &'a [u8],
    text: &'a str,
    at: usize,
}

/// `Ok(None)`: the cut ran through a scalar, which is dropped.
type Step = Result<Option<Json>, NotJson>;

impl Reader<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    /// The unread text. Positions only ever stop on character boundaries.
    fn rest(&self) -> Result<&str, NotJson> {
        self.text.get(self.at..).ok_or(NotJson)
    }

    /// The text from `start` to the position.
    fn since(&self, start: usize) -> Result<&str, NotJson> {
        self.text.get(start..self.at).ok_or(NotJson)
    }

    fn whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.at += 1;
        }
    }

    fn value(&mut self) -> Step {
        self.whitespace();
        match self.peek() {
            None => Ok(None),
            Some(b'{') => self.object().map(Some),
            Some(b'[') => self.array().map(Some),
            Some(b'"') => Ok(self.string()?.map(Json::String)),
            Some(b't') => self.literal("true", Json::Bool(true)),
            Some(b'f') => self.literal("false", Json::Bool(false)),
            Some(b'n') => self.literal("null", Json::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(NotJson),
        }
    }

    fn literal(&mut self, word: &str, value: Json) -> Step {
        let rest = self.rest()?;
        if rest.starts_with(word) {
            self.at += word.len();
            Ok(Some(value))
        } else if word.starts_with(rest) {
            self.at = self.bytes.len();
            Ok(None)
        } else {
            Err(NotJson)
        }
    }

    fn number(&mut self) -> Step {
        let start = self.at;
        while matches!(
            self.peek(),
            Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
        ) {
            self.at += 1;
        }
        // A number that runs to the cut may have lost digits.
        if self.at == self.bytes.len() {
            return Ok(None);
        }
        let raw = self.since(start)?;
        if raw.parse::<f64>().is_err() {
            return Err(NotJson);
        }
        Ok(Some(Json::Number(raw.to_owned())))
    }

    /// A string at `"`; `None` when the cut runs through it.
    fn string(&mut self) -> Result<Option<String>, NotJson> {
        self.at += 1;
        let mut out = String::new();
        loop {
            let Some(byte) = self.peek() else {
                return Ok(None);
            };
            match byte {
                b'"' => {
                    self.at += 1;
                    return Ok(Some(out));
                }
                b'\\' => {
                    self.at += 1;
                    let Some(escape) = self.peek() else {
                        return Ok(None);
                    };
                    self.at += 1;
                    let decoded = match escape {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => match self.unicode()? {
                            Some(character) => character,
                            None => return Ok(None),
                        },
                        _ => return Err(NotJson),
                    };
                    out.push(decoded);
                }
                0..=0x1f => return Err(NotJson),
                _ => {
                    let start = self.at;
                    while matches!(self.peek(), Some(byte) if byte != b'"' && byte != b'\\' && byte >= 0x20)
                    {
                        self.at += 1;
                    }
                    out.push_str(self.since(start)?);
                }
            }
        }
    }

    /// Four hex digits, joined with a following low surrogate; `None` when cut.
    fn unicode(&mut self) -> Result<Option<char>, NotJson> {
        let Some(high) = self.hex4()? else {
            return Ok(None);
        };
        if !(0xD800..0xDC00).contains(&high) {
            return char::from_u32(high).map(Some).ok_or(NotJson);
        }
        let rest = self.rest()?;
        if rest.len() < 2 && "\\u".starts_with(rest) {
            return Ok(None);
        }
        if !rest.starts_with("\\u") {
            return Err(NotJson);
        }
        self.at += 2;
        let Some(low) = self.hex4()? else {
            return Ok(None);
        };
        if !(0xDC00..0xE000).contains(&low) {
            return Err(NotJson);
        }
        char::from_u32(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
            .map(Some)
            .ok_or(NotJson)
    }

    fn hex4(&mut self) -> Result<Option<u32>, NotJson> {
        let rest = self.rest()?;
        let digits: String = rest.chars().take(4).collect();
        if !digits.chars().all(|digit| digit.is_ascii_hexdigit()) {
            return Err(NotJson);
        }
        if digits.len() < 4 {
            self.at = self.bytes.len();
            return Ok(None);
        }
        self.at += 4;
        u32::from_str_radix(&digits, 16)
            .map(Some)
            .map_err(|_| NotJson)
    }

    fn array(&mut self) -> Result<Json, NotJson> {
        self.at += 1;
        let mut items = Vec::new();
        self.whitespace();
        if self.peek() == Some(b']') {
            self.at += 1;
            return Ok(Json::Array(items, false));
        }
        loop {
            match self.value()? {
                Some(item) if item.is_cut() => {
                    items.push(item);
                    return Ok(Json::Array(items, true));
                }
                Some(item) => items.push(item),
                None => return Ok(Json::Array(items, true)),
            }
            self.whitespace();
            match self.peek() {
                None => return Ok(Json::Array(items, true)),
                Some(b',') => self.at += 1,
                Some(b']') => {
                    self.at += 1;
                    return Ok(Json::Array(items, false));
                }
                Some(_) => return Err(NotJson),
            }
        }
    }

    fn object(&mut self) -> Result<Json, NotJson> {
        self.at += 1;
        let mut members = Vec::new();
        self.whitespace();
        if self.peek() == Some(b'}') {
            self.at += 1;
            return Ok(Json::Object(members, false));
        }
        loop {
            self.whitespace();
            match self.peek() {
                None => return Ok(Json::Object(members, true)),
                Some(b'"') => {}
                Some(_) => return Err(NotJson),
            }
            let Some(key) = self.string()? else {
                return Ok(Json::Object(members, true));
            };
            self.whitespace();
            match self.peek() {
                None => return Ok(Json::Object(members, true)),
                Some(b':') => self.at += 1,
                Some(_) => return Err(NotJson),
            }
            match self.value()? {
                Some(value) if value.is_cut() => {
                    members.push((key, value));
                    return Ok(Json::Object(members, true));
                }
                Some(value) => members.push((key, value)),
                None => return Ok(Json::Object(members, true)),
            }
            self.whitespace();
            match self.peek() {
                None => return Ok(Json::Object(members, true)),
                Some(b',') => self.at += 1,
                Some(b'}') => {
                    self.at += 1;
                    return Ok(Json::Object(members, false));
                }
                Some(_) => return Err(NotJson),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(value: &str) -> Json {
        Json::String(value.to_owned())
    }

    #[test]
    fn complete_json_reads_exactly() {
        assert_eq!(
            parse(r#"{"a": "x\né😀", "b": [1, true, null], "c": {}}"#),
            Ok(Json::Object(
                vec![
                    ("a".into(), text("x\n\u{e9}\u{1f600}")),
                    (
                        "b".into(),
                        Json::Array(
                            vec![Json::Number("1".into()), Json::Bool(true), Json::Null],
                            false
                        )
                    ),
                    ("c".into(), Json::Object(Vec::new(), false)),
                ],
                false
            ))
        );
        assert_eq!(parse("[] x"), Err(NotJson));
        assert_eq!(parse("Edit({})"), Err(NotJson));
        assert_eq!(parse(""), Err(NotJson));
    }

    #[test]
    fn a_cut_drops_the_partial_scalar_and_marks_every_open_container() {
        let cut =
            parse(r#"{"file_path": "/repo/a.rs", "edits": [{"old_string": "a", "new_st"#).unwrap();
        assert!(cut.is_cut());
        assert_eq!(cut.text(&["file_path"]), Some("/repo/a.rs"));
        let Some(Json::Array(edits, true)) = cut.get("edits") else {
            panic!("{cut:?}");
        };
        assert_eq!(
            edits,
            &vec![Json::Object(vec![("old_string".into(), text("a"))], true)]
        );
        // A cut path is never read as a shorter path.
        assert_eq!(
            parse(r#"{"file_path": "/repo/sr"#),
            Ok(Json::Object(Vec::new(), true))
        );
        for prefix in [
            r#"{"a": tr"#,
            r#"{"a": 12"#,
            r#"{"a": "\u00"#,
            r#"{"a": "\"#,
            r#"{"a" "#,
            r#"{"a": "#,
        ] {
            let parsed = parse(prefix).unwrap();
            assert!(parsed.is_cut(), "{prefix}");
            assert_eq!(parsed.get("a"), None, "{prefix}");
        }
        // Members that ended before the cut are kept.
        let kept = parse(r#"{"a": "b", "#).unwrap();
        assert!(kept.is_cut());
        assert_eq!(kept.text(&["a"]), Some("b"));
    }

    #[test]
    fn malformed_input_is_not_a_cut() {
        for bad in [
            r#"{"a" 1}"#,
            r#"{"a": tru}"#,
            r#"["a" "b"]"#,
            "{a: 1}",
            r#""\q""#,
        ] {
            assert_eq!(parse(bad), Err(NotJson), "{bad}");
        }
    }
}
