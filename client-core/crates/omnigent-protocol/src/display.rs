//! Bounded, sanitised display of unknown JSON values.
//!
//! Provider and future payloads are shown for inspection only. Before anything reaches a view this
//! module removes credentials, private reasoning, hidden context and embedded bytes, and bounds the
//! result by characters, depth and entry count. Ported from `NativeLab`'s `JSONValue.safeDisplayText`.

use serde_json::{Map, Value};

/// Maximum characters of a whole display text, before the truncation marker.
pub const MAX_DISPLAY_CHARS: usize = 16_000;
/// Maximum characters of one string inside a payload.
pub const MAX_STRING_CHARS: usize = 8_000;
/// Nesting depth after which content is replaced by [`OMITTED_DETAILS`].
pub const MAX_DEPTH: usize = 7;
/// Maximum values inspected in one payload.
pub const MAX_NODES: usize = 200;
/// Maximum entries shown from one array or object.
pub const MAX_ENTRIES: usize = 40;
/// A string that looks like JSON and is larger than this is not parsed.
pub const MAX_NESTED_JSON_BYTES: usize = 262_144;

/// Appended to text cut at a bound.
pub const TRUNCATED_MARKER: &str = "\n[Truncated]";
/// Replaces content beyond the depth or node budget.
pub const OMITTED_DETAILS: &str = "[Additional details omitted]";
/// Replaces a JSON-looking string too large to parse.
pub const OMITTED_LARGE_PAYLOAD: &str = "[Large structured payload omitted]";
/// Replaces a string that starts like JSON but does not parse (it may be a cut-off secret).
pub const INCOMPLETE_PAYLOAD: &str = "[Structured payload is incomplete]";
/// Replaces data URLs and base64-looking blobs.
pub const OMITTED_EMBEDDED_DATA: &str = "[Embedded data omitted]";
/// Appended to an array whose entries were cut or removed.
pub const OMITTED_ENTRIES: &str = "[Additional or private content omitted]";
/// Value of the `…` key added to an object with too many fields.
pub const OMITTED_FIELDS: &str = "Additional fields omitted";

/// Content block types that carry private model reasoning. They are never shown, except for an
/// explicit public `summary`.
pub const PRIVATE_CONTENT_TYPES: &[&str] = &[
    "reasoning",
    "reasoning_text",
    "thinking",
    "redacted_thinking",
    "encrypted_reasoning",
    "hidden_reasoning",
    "chain_of_thought",
    "analysis",
    "analysis_text",
    "redacted_reasoning",
];

const PRIVATE_KEYS: &[&str] = &[
    "authorization",
    "proxyauthorization",
    "cookie",
    "setcookie",
    "credentials",
    "credential",
    "apikey",
    "xapikey",
    "accesskey",
    "privatekey",
    "token",
    "accesstoken",
    "refreshtoken",
    "idtoken",
    "sessiontoken",
    "authtoken",
    "bearer",
    "accesskeyid",
    "reasoning",
    "thinking",
    "reasoningcontent",
    "reasoningtext",
    "rawreasoning",
    "hiddenreasoning",
    "thinkingtext",
    "thinkingcontent",
    "hiddenthoughts",
    "analysis",
    "chainofthought",
    "hiddencontent",
    "filedata",
    "imagedata",
    "audiodata",
    "b64json",
    "signature",
    "compactedmessages",
];

const PRIVATE_KEY_FRAGMENTS: &[&str] = &["password", "secret", "encrypted", "base64"];

const TEXT_BLOCK_TYPES: &[&str] = &["text", "input_text", "output_text", "summary_text"];

/// True for a content block `type` that carries private reasoning (case-insensitive).
#[must_use]
pub fn is_private_content_type(content_type: &str) -> bool {
    let lowered = content_type.to_lowercase();
    PRIVATE_CONTENT_TYPES.contains(&lowered.as_str())
}

/// True for an object key whose value must never be displayed: credentials, private reasoning,
/// embedded bytes, signatures. Case, punctuation and separators are ignored.
#[must_use]
pub fn is_private_key(key: &str) -> bool {
    let normalized: String = key
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    PRIVATE_KEYS.contains(&normalized.as_str())
        || PRIVATE_KEY_FRAGMENTS
            .iter()
            .any(|fragment| normalized.contains(fragment))
}

/// True for an object flagged as hidden context (`is_meta`, `hidden` or `is_hidden` set to true).
#[must_use]
pub fn is_hidden_object(fields: &Map<String, Value>) -> bool {
    ["is_meta", "hidden", "is_hidden"]
        .iter()
        .any(|key| fields.get(*key) == Some(&Value::Bool(true)))
}

/// Cuts `text` to `limit` characters, appending [`TRUNCATED_MARKER`] when anything was removed.
#[must_use]
pub fn bounded(text: &str, limit: usize) -> String {
    if text.chars().nth(limit).is_none() {
        return text.to_owned();
    }
    let mut out: String = text.chars().take(limit).collect();
    out.push_str(TRUNCATED_MARKER);
    out
}

/// The sanitised, bounded display text of a JSON value. At most [`MAX_DISPLAY_CHARS`] characters
/// plus the truncation marker.
#[must_use]
pub fn safe_display_text(value: &Value) -> String {
    let mut budget = MAX_NODES;
    let cleaned = clean(value, 0, &mut budget);
    let text = cleaned.as_ref().map(plain_text).unwrap_or_default();
    bounded(&text, MAX_DISPLAY_CHARS)
}

/// [`safe_display_text`] for a string, which may itself hold JSON (tool arguments and output).
#[must_use]
pub fn safe_display_str(text: &str) -> String {
    safe_display_text(&Value::String(text.to_owned()))
}

/// The sanitised value tree that [`safe_display_text`] renders, or `None` when the whole value is
/// private or hidden.
#[must_use]
pub fn sanitized(value: &Value) -> Option<Value> {
    let mut budget = MAX_NODES;
    clean(value, 0, &mut budget)
}

fn clean(value: &Value, depth: usize, budget: &mut usize) -> Option<Value> {
    if *budget == 0 || depth >= MAX_DEPTH {
        return Some(Value::String(OMITTED_DETAILS.to_owned()));
    }
    *budget -= 1;
    match value {
        Value::String(text) => clean_string(text, depth, budget),
        Value::Array(values) => Some(clean_array(values, depth, budget)),
        Value::Object(fields) => clean_object(fields, depth, budget),
        Value::Null | Value::Bool(_) | Value::Number(_) => Some(value.clone()),
    }
}

fn clean_string(text: &str, depth: usize, budget: &mut usize) -> Option<Value> {
    let trimmed = text.trim();
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        if text.len() > MAX_NESTED_JSON_BYTES {
            return Some(Value::String(OMITTED_LARGE_PAYLOAD.to_owned()));
        }
        if let Ok(decoded) = serde_json::from_str::<Value>(text) {
            return clean(&decoded, depth + 1, budget);
        }
        if trimmed.starts_with('{') || trimmed.starts_with("[\"") || trimmed.starts_with("[{") {
            return Some(Value::String(INCOMPLETE_PAYLOAD.to_owned()));
        }
    }
    if trimmed.to_lowercase().starts_with("data:") || looks_like_binary(trimmed) {
        return Some(Value::String(OMITTED_EMBEDDED_DATA.to_owned()));
    }
    Some(Value::String(bounded(text, MAX_STRING_CHARS)))
}

fn clean_array(values: &[Value], depth: usize, budget: &mut usize) -> Value {
    let mut result = Vec::new();
    for value in values.iter().take(MAX_ENTRIES) {
        if *budget == 0 {
            break;
        }
        if let Some(cleaned) = clean(value, depth + 1, budget) {
            result.push(cleaned);
        }
    }
    if values.len() > result.len() {
        result.push(Value::String(OMITTED_ENTRIES.to_owned()));
    }
    Value::Array(result)
}

fn clean_object(fields: &Map<String, Value>, depth: usize, budget: &mut usize) -> Option<Value> {
    if is_hidden_object(fields) {
        return None;
    }
    if let Some(Value::String(content_type)) = fields.get("type")
        && is_private_content_type(content_type)
    {
        return fields
            .get("summary")
            .and_then(|summary| clean(summary, depth + 1, budget));
    }
    let mut keys: Vec<&String> = fields.keys().collect();
    keys.sort();
    let mut result = Map::new();
    for key in keys.into_iter().take(MAX_ENTRIES) {
        if *budget == 0 {
            break;
        }
        if is_private_key(key) {
            continue;
        }
        if let Some(value) = fields.get(key)
            && let Some(cleaned) = clean(value, depth + 1, budget)
        {
            result.insert(bounded(key, 100), cleaned);
        }
    }
    if fields.len() > MAX_ENTRIES {
        result.insert("…".to_owned(), Value::String(OMITTED_FIELDS.to_owned()));
    }
    Some(Value::Object(result))
}

fn looks_like_binary(text: &str) -> bool {
    text.len() > 256
        && text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"+/=\n\r".contains(&byte))
}

fn plain_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Array(values) => values.iter().map(plain_text).collect::<Vec<_>>().join("\n"),
        Value::Object(fields) => {
            if let Some(Value::String(text)) = fields.get("text") {
                let block_type = fields.get("type").and_then(Value::as_str).unwrap_or("");
                if fields.len() == 1 || TEXT_BLOCK_TYPES.contains(&block_type) {
                    return text.clone();
                }
            }
            let mut keys: Vec<&String> = fields.keys().collect();
            keys.sort();
            keys.into_iter()
                .map(|key| {
                    let text = fields.get(key).map(plain_text).unwrap_or_default();
                    format!("{key}: {text}")
                })
                .collect::<Vec<_>>()
                .join("\n")
        }
        Value::Number(number) => number_text(number),
        Value::Bool(flag) => flag.to_string(),
        Value::Null => String::new(),
    }
}

fn number_text(number: &serde_json::Number) -> String {
    if number.is_f64()
        && let Some(float) = number.as_f64()
        && float.is_finite()
        && float.fract() == 0.0
    {
        return format!("{float:.0}");
    }
    number.to_string()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn huge_or_wide_values_stop_at_their_budgets() {
        assert_eq!(sanitized(&json!({"a": 1})), Some(json!({"a": 1})));
        let large = format!("[{}]", "1,".repeat(MAX_NESTED_JSON_BYTES));
        assert_eq!(
            sanitized(&Value::String(large)),
            Some(Value::String(OMITTED_LARGE_PAYLOAD.to_owned()))
        );
        // Each row spends budget, so the outer list stops before reaching the end.
        let row: Vec<Value> = (0..MAX_ENTRIES).map(|index| json!(index)).collect();
        let wide: Vec<Value> = (0..MAX_ENTRIES)
            .map(|_| Value::Array(row.clone()))
            .collect();
        let cleaned = sanitized(&Value::Array(wide)).unwrap();
        assert!(cleaned.as_array().unwrap().len() < MAX_ENTRIES);
        let object: Map<String, Value> = (0..MAX_ENTRIES)
            .map(|index| (format!("k{index:02}"), Value::Array(row.clone())))
            .collect();
        let cleaned = sanitized(&Value::Object(object)).unwrap();
        assert!(cleaned.as_object().unwrap().len() < MAX_ENTRIES);
    }

    #[test]
    fn a_text_field_beside_other_fields_is_shown_with_its_key() {
        let text = safe_display_text(&json!({"text": "body", "kind": "note"}));
        assert!(text.contains("body") && text.contains("kind"), "{text}");
    }

    #[test]
    fn credentials_private_reasoning_and_hidden_context_are_removed() {
        let value = json!({
            "result": "Kept result",
            "headers": {"Authorization": "PRIVATE_AUTH", "X-Api-Key": "PRIVATE_KEY"},
            "nested": {
                "password": "PRIVATE_PASSWORD",
                "encrypted_content": "PRIVATE_ENCRYPTED",
                "content": [
                    {"type": "reasoning_text", "text": "PRIVATE_THOUGHTS"},
                    {"type": "output_text", "text": "Public output"},
                    {"is_meta": true, "text": "PRIVATE_META"}
                ]
            },
            "image_data": "PRIVATE_IMAGE",
            "session_token": "PRIVATE_TOKEN"
        });
        let text = safe_display_text(&value);
        assert!(text.contains("Kept result"), "{text}");
        assert!(text.contains("Public output"), "{text}");
        assert!(text.contains(OMITTED_ENTRIES), "{text}");
        assert!(!text.contains("PRIVATE_"), "{text}");
    }

    #[test]
    fn private_block_keeps_only_an_explicit_summary() {
        let value = json!([{"type": "thinking", "summary": "Public gist", "thinking": "PRIVATE"}]);
        assert_eq!(safe_display_text(&value), "Public gist");
    }

    #[test]
    fn embedded_data_and_binary_blobs_are_omitted() {
        assert_eq!(
            safe_display_str("data:image/png;base64,AAAA"),
            OMITTED_EMBEDDED_DATA
        );
        assert_eq!(safe_display_str(&"QUJD".repeat(100)), OMITTED_EMBEDDED_DATA);
        assert_eq!(safe_display_str("short plain text"), "short plain text");
    }

    #[test]
    fn json_strings_are_parsed_and_sanitized() {
        let text = safe_display_str(r#"{"query":"weather","api_key":"PRIVATE_KEY"}"#);
        assert_eq!(text, "query: weather");
        assert_eq!(
            safe_display_str(r#"{"encrypted_content":"PRIVATE_PARTIAL"#),
            INCOMPLETE_PAYLOAD
        );
        assert_eq!(
            safe_display_str("[Tool output unavailable]"),
            "[Tool output unavailable]"
        );
    }

    #[test]
    fn numbers_render_like_the_swift_oracle() {
        assert_eq!(safe_display_text(&json!(120)), "120");
        assert_eq!(safe_display_text(&json!(2.0)), "2");
        assert_eq!(safe_display_text(&json!(0.5)), "0.5");
        assert_eq!(safe_display_text(&json!(true)), "true");
        assert_eq!(safe_display_text(&Value::Null), "");
    }

    #[test]
    fn bounded_counts_characters_not_bytes() {
        assert_eq!(bounded("ééé", 3), "ééé");
        assert_eq!(bounded("éééé", 3), format!("ééé{TRUNCATED_MARKER}"));
    }

    #[test]
    fn wide_objects_and_long_arrays_are_cut() {
        let wide: Map<String, Value> = (0..50)
            .map(|index| (format!("k{index:02}"), json!(index)))
            .collect();
        let text = safe_display_text(&Value::Object(wide));
        assert!(text.contains(OMITTED_FIELDS), "{text}");
        assert!(!text.contains("k45"), "{text}");
        let long = Value::Array((0..100).map(|index| json!(format!("e{index}"))).collect());
        let text = safe_display_text(&long);
        assert!(text.contains("e39") && !text.contains("e40"), "{text}");
    }
}
