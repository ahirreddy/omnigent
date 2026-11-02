//! Fixture loading for the remote browser tests (`client-core/fixtures/remote_browser`).

use serde_json::Value;

/// The bytes of `client-core/fixtures/remote_browser/<path>`.
pub(crate) fn fixture_bytes(path: &str) -> Vec<u8> {
    let full = format!(
        "{}/../../fixtures/remote_browser/{path}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read(&full).unwrap_or_else(|error| panic!("reading {full}: {error}"))
}

/// A JSON fixture.
pub(crate) fn fixture_json(path: &str) -> Value {
    serde_json::from_slice(&fixture_bytes(path)).unwrap_or_else(|error| panic!("{path}: {error}"))
}

/// The access units of an `h264/<name>.annexb` fixture, split by its `frames.json`.
pub(crate) fn access_units(name: &str) -> Vec<Vec<u8>> {
    let data = fixture_bytes(&format!("h264/{name}.annexb"));
    let table = fixture_json(&format!("h264/{name}.frames.json"));
    table["frames"]
        .as_array()
        .unwrap()
        .iter()
        .map(|frame| {
            let offset = usize::try_from(frame["offset"].as_u64().unwrap()).unwrap();
            let length = usize::try_from(frame["length"].as_u64().unwrap()).unwrap();
            data[offset..offset + length].to_vec()
        })
        .collect()
}

/// A text message fixture, as the wire text.
pub(crate) fn message_text(path: &str) -> String {
    fixture_json(&format!("messages/{path}.json")).to_string()
}

/// Hex decoding for the `sps_hex` / `pps_hex` fixture fields.
pub(crate) fn hex(text: &str) -> Vec<u8> {
    text.as_bytes()
        .chunks(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
        .collect()
}
