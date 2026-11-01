//! Typed reads from JSON objects for the hand-written decoders in this package.
//!
//! The core has no `serde` derive of its own, so the session client, creation catalog,
//! configuration codec and workspace store decode with these helpers. Each one distinguishes a
//! missing key or `null` (`Ok(None)`) from a value of the wrong type (`Err`), so a malformed
//! payload is never mistaken for an absent field.

#![allow(
    clippy::redundant_pub_crate,
    reason = "crate-internal helpers of a private module; `pub` would trip rustc's unreachable_pub"
)]

use serde_json::{Map, Value};

/// `object[key]` as a string.
pub(crate) fn opt_str(object: &Map<String, Value>, key: &str) -> Result<Option<String>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(other) => Err(format!("`{key}` is not a string: {}", kind(other))),
    }
}

/// `object[key]` as a required string (it may be empty).
pub(crate) fn req_str(object: &Map<String, Value>, key: &str) -> Result<String, String> {
    opt_str(object, key)?.ok_or_else(|| format!("`{key}` is missing"))
}

/// `object[key]` as a boolean.
pub(crate) fn opt_bool(object: &Map<String, Value>, key: &str) -> Result<Option<bool>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(other) => Err(format!("`{key}` is not a boolean: {}", kind(other))),
    }
}

/// `object[key]` as an unsigned integer.
pub(crate) fn opt_u64(object: &Map<String, Value>, key: &str) -> Result<Option<u64>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| format!("`{key}` is not an unsigned integer: {}", kind(value))),
    }
}

/// `object[key]` as an array.
pub(crate) fn opt_array<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<Option<&'a Vec<Value>>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(values)) => Ok(Some(values)),
        Some(other) => Err(format!("`{key}` is not an array: {}", kind(other))),
    }
}

/// `object[key]` as an object.
pub(crate) fn opt_object<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<Option<&'a Map<String, Value>>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Object(value)) => Ok(Some(value)),
        Some(other) => Err(format!("`{key}` is not an object: {}", kind(other))),
    }
}

/// `value` as an object.
pub(crate) fn as_object<'a>(
    value: &'a Value,
    context: &str,
) -> Result<&'a Map<String, Value>, String> {
    value
        .as_object()
        .ok_or_else(|| format!("{context} is not an object: {}", kind(value)))
}

/// Inserts `value` under `key` when it is `Some`.
pub(crate) fn put_opt(object: &mut Map<String, Value>, key: &str, value: Option<Value>) {
    if let Some(value) = value {
        object.insert(key.to_owned(), value);
    }
}

/// A short name for the JSON type of `value`, for error messages that must not echo content.
pub(crate) const fn kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn missing_and_null_are_absent_but_wrong_types_are_errors() {
        let value = json!({"s": "x", "n": null, "b": true, "i": -3, "u": 4, "a": [], "o": {}});
        let object = value.as_object().unwrap();
        assert_eq!(opt_str(object, "s"), Ok(Some("x".into())));
        assert_eq!(opt_str(object, "n"), Ok(None));
        assert_eq!(opt_str(object, "missing"), Ok(None));
        assert!(opt_str(object, "b").is_err());
        assert_eq!(opt_bool(object, "b"), Ok(Some(true)));
        assert!(opt_bool(object, "s").is_err());
        assert!(opt_u64(object, "i").is_err());
        assert_eq!(opt_u64(object, "u"), Ok(Some(4)));
        assert!(opt_array(object, "a").unwrap().is_some());
        assert!(opt_object(object, "o").unwrap().is_some());
        assert!(opt_object(object, "a").is_err());
        assert!(req_str(object, "n").is_err());
    }
}
