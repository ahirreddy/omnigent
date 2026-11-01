//! Shared fixture loading for this crate's tests (`client-core/fixtures`).

use serde_json::Value;

/// The text of `client-core/fixtures/<path>`.
pub(crate) fn fixture_text(path: &str) -> String {
    let full = format!("{}/../../fixtures/{path}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&full).unwrap_or_else(|error| panic!("reading {full}: {error}"))
}

/// A `.json` fixture.
pub(crate) fn fixture(path: &str) -> Value {
    serde_json::from_str(&fixture_text(path)).unwrap_or_else(|error| panic!("{path}: {error}"))
}

/// The values of a `.jsonl` fixture, one per non-empty line.
pub(crate) fn fixture_lines(path: &str) -> Vec<Value> {
    fixture_text(path)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).unwrap_or_else(|error| panic!("{path}: {error}")))
        .collect()
}

/// The `response` body of an HTTP-envelope fixture value.
pub(crate) fn response(envelope: &Value) -> Value {
    envelope
        .get("response")
        .cloned()
        .unwrap_or_else(|| panic!("no response in {envelope}"))
}

/// Every fixture file under `client-core/fixtures`, as `(relative path, values)`.
pub(crate) fn all_fixtures() -> Vec<(String, Vec<Value>)> {
    let root = format!("{}/../../fixtures", env!("CARGO_MANIFEST_DIR"));
    let mut out = Vec::new();
    let mut directories = vec![std::path::PathBuf::from(&root)];
    while let Some(directory) = directories.pop() {
        for entry in std::fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                directories.push(path);
                continue;
            }
            let relative = path
                .strip_prefix(&root)
                .unwrap()
                .to_string_lossy()
                .into_owned();
            match path.extension().and_then(|extension| extension.to_str()) {
                Some("jsonl") => out.push((relative.clone(), fixture_lines(&relative))),
                Some("json") => out.push((relative.clone(), vec![fixture(&relative)])),
                _ => {}
            }
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}
