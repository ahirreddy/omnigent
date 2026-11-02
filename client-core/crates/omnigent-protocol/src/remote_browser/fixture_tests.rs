//! Round trips over `client-core/fixtures/remote_browser/`.

use serde_json::Value;

use super::*;
use crate::test_support::{fixture, fixture_text};

const ROOT: &str = "remote_browser";

fn bytes(path: &str) -> Vec<u8> {
    let full = format!(
        "{}/../../fixtures/{ROOT}/{path}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read(&full).unwrap_or_else(|error| panic!("reading {full}: {error}"))
}

fn json(path: &str) -> Value {
    fixture(&format!("{ROOT}/{path}"))
}

fn names(directory: &str) -> Vec<String> {
    let full = format!(
        "{}/../../fixtures/{ROOT}/{directory}",
        env!("CARGO_MANIFEST_DIR")
    );
    let mut names: Vec<String> = std::fs::read_dir(&full)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter_map(|name| {
            let path = std::path::Path::new(&name);
            let is_json = path
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("json"));
            is_json.then(|| path.file_stem().unwrap().to_string_lossy().into_owned())
        })
        .collect();
    names.sort();
    names
}

fn without_nulls(value: Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .filter(|(_, value)| !value.is_null())
                .map(|(key, value)| (key, without_nulls(value)))
                .collect(),
        ),
        Value::Array(values) => Value::Array(values.into_iter().map(without_nulls).collect()),
        other => other,
    }
}

fn numbers_as_f64(value: Value) -> Value {
    match value {
        Value::Number(number) => number.as_f64().map_or(Value::Number(number), Value::from),
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(key, value)| (key, numbers_as_f64(value)))
                .collect(),
        ),
        Value::Array(values) => Value::Array(values.into_iter().map(numbers_as_f64).collect()),
        other => other,
    }
}

fn same(left: &str, right: &Value) -> bool {
    let left: Value = serde_json::from_str(left).unwrap();
    numbers_as_f64(without_nulls(left)) == numbers_as_f64(without_nulls(right.clone()))
}

/// Fixtures that carry fields a v1 receiver drops, so they do not re-encode byte for byte.
const WITH_EXTRAS: [&str; 1] = ["hello_view_handoff"];

#[test]
fn every_host_message_decodes_and_re_encodes() {
    let names = names("messages/host_to_client");
    assert!(names.len() >= 25, "{names:?}");
    for name in names {
        let value = json(&format!("messages/host_to_client/{name}.json"));
        let message = HostMessage::decode(&value.to_string())
            .unwrap_or_else(|error| panic!("{name}: {error}"));
        let wire_type = value["type"].as_str().unwrap();
        let expected_unknown = name == "unknown_type";
        assert_eq!(
            matches!(message, HostMessage::Unknown { .. }),
            expected_unknown,
            "{name}"
        );
        let encoded = message.encode().unwrap();
        assert_eq!(HostMessage::decode(&encoded).unwrap(), message, "{name}");
        assert!(
            encoded.contains(&format!("\"type\":\"{wire_type}\"")),
            "{name}"
        );
        if !WITH_EXTRAS.contains(&name.as_str()) {
            assert!(same(&encoded, &value), "{name}: {encoded} vs {value}");
        }
    }
}

#[test]
fn every_client_message_decodes_and_re_encodes() {
    let names = names("messages/client_to_host");
    assert!(names.len() >= 25, "{names:?}");
    for name in names {
        let value = json(&format!("messages/client_to_host/{name}.json"));
        let message = ClientMessage::decode(&value.to_string())
            .unwrap_or_else(|error| panic!("{name}: {error}"));
        assert!(!matches!(message, ClientMessage::Unknown { .. }), "{name}");
        let encoded = message.encode().unwrap();
        assert_eq!(ClientMessage::decode(&encoded).unwrap(), message, "{name}");
        assert!(same(&encoded, &value), "{name}: {encoded} vs {value}");
    }
}

#[test]
fn decoded_values_match_the_spec() {
    let hello =
        HostMessage::decode(&json("messages/host_to_client/hello_view_handoff.json").to_string())
            .unwrap();
    let HostMessage::Hello(hello) = hello else {
        panic!("{hello:?}");
    };
    assert_eq!(hello.mode, AttachMode::View);
    assert_eq!(hello.window.max_frames, 2);
    assert_eq!(hello.control.handoff.unwrap().id, "elicit_42");
    let cursor =
        HostMessage::decode(&json("messages/host_to_client/cursor_unknown.json").to_string())
            .unwrap();
    assert!(
        matches!(cursor, HostMessage::Cursor(CursorUpdate { ref cursor, .. }) if cursor == "-webkit-future-cursor")
    );
    let down = ClientMessage::decode(&json("messages/client_to_host/mouse_down.json").to_string())
        .unwrap();
    let ClientMessage::Mouse(down) = down else {
        panic!("{down:?}");
    };
    assert_eq!(down.modifiers, modifiers::LEFT_BUTTON);
    assert_eq!(down.button, Some(MouseButton::Left));
    let control =
        HostMessage::decode(&json("messages/host_to_client/control_grace.json").to_string())
            .unwrap();
    let HostMessage::Control(control) = control else {
        panic!("{control:?}");
    };
    assert_eq!(control.state.holder, None);
    assert_eq!(control.reason, Some(ControlReason::HolderLeft));
}

#[test]
fn malformed_messages_are_errors_not_unknowns() {
    assert!(matches!(
        HostMessage::decode("not json"),
        Err(MessageError::Syntax { .. })
    ));
    assert_eq!(HostMessage::decode("[1]"), Err(MessageError::NoType));
    assert_eq!(
        HostMessage::decode(r#"{"type":3}"#),
        Err(MessageError::NoType)
    );
    assert!(matches!(
        HostMessage::decode(r#"{"type":"nav","url":"x"}"#),
        Err(MessageError::Invalid { .. })
    ));
    assert!(matches!(
        ClientMessage::decode(r#"{"type":"ack","seq":-1}"#),
        Err(MessageError::Invalid { .. })
    ));
}

#[test]
fn runner_host_fixtures_decode() {
    for name in names("runner_host") {
        let value = json(&format!("runner_host/{name}.json"));
        if name.starts_with("attach") || name == "control_preamble" {
            let preamble: Preamble = serde_json::from_value(value.clone()).unwrap();
            assert_eq!(serde_json::to_value(&preamble).unwrap(), value, "{name}");
        } else if name.starts_with("request_") {
            let request: ControlRequest = serde_json::from_value(value.clone()).unwrap();
            assert_eq!(request.message_type, "request");
        } else if name.starts_with("response_") {
            let response: ControlResponse = serde_json::from_value(value.clone()).unwrap();
            assert_eq!(response.message_type, "response");
            assert_eq!(response.ok, response.error.is_none(), "{name}");
            let result = response.result.unwrap_or(Value::Null);
            let tabs = result
                .get("tabs")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            for tab in tabs {
                serde_json::from_value::<TabRecord>(tab).unwrap();
            }
            if name.contains("tabs_create") || name.contains("tabs_navigate") {
                serde_json::from_value::<TabRecord>(result).unwrap();
            }
        } else if name == "host_json" {
            let info: HostInfo = serde_json::from_value(value.clone()).unwrap();
            assert_eq!(serde_json::to_value(&info).unwrap(), value);
        } else {
            panic!("unclassified runner_host fixture {name}");
        }
    }
}

/// The bytes a `payload` source in `binary_frames/index.json` names.
fn payload_of(source: &Value) -> Vec<u8> {
    if let Some(text) = source.get("inline_utf8").and_then(Value::as_str) {
        return text.as_bytes().to_vec();
    }
    let file = source["file"].as_str().unwrap();
    let data = bytes(file);
    let Some(index) = source.get("frame_index").and_then(Value::as_u64) else {
        return data;
    };
    let frames = json(&file.replace(".annexb", ".frames.json"));
    let frame = &frames["frames"][usize::try_from(index).unwrap()];
    let offset = usize::try_from(frame["offset"].as_u64().unwrap()).unwrap();
    let length = usize::try_from(frame["length"].as_u64().unwrap()).unwrap();
    data[offset..offset + length].to_vec()
}

#[test]
fn binary_frames_match_their_index() {
    let index = json("binary_frames/index.json");
    let frames = index["frames"].as_array().unwrap();
    assert!(frames.len() >= 11);
    for entry in frames {
        let file = entry["file"].as_str().unwrap();
        let data = bytes(&format!("binary_frames/{file}"));
        if entry["valid"] == Value::Bool(false) {
            let error = decode_frame(&data).unwrap_err();
            let expected = entry["error"].as_str().unwrap();
            let matches = match expected {
                "bad_magic" => matches!(error, HeaderError::BadMagic { .. }),
                "truncated" => matches!(error, HeaderError::Truncated { .. }),
                "bad_header_len" => matches!(error, HeaderError::BadHeaderLen { seq: 9, .. }),
                "unsupported_version" => {
                    matches!(
                        error,
                        HeaderError::UnsupportedVersion {
                            version: 2,
                            seq: 10
                        }
                    )
                }
                other => panic!("unknown expected error {other}"),
            };
            assert!(matches, "{file}: {error:?}");
            continue;
        }
        let frame = decode_frame(&data).unwrap_or_else(|error| panic!("{file}: {error}"));
        let header = &entry["header"];
        let expected = MediaHeader {
            kind: MediaKind::from_wire(u8::try_from(header["kind"].as_u64().unwrap()).unwrap()),
            keyframe: header["keyframe"].as_bool().unwrap(),
            new_stream: header["new_stream"].as_bool().unwrap(),
            seq: u32::try_from(header["seq"].as_u64().unwrap()).unwrap(),
            stream_id: u32::try_from(header["stream_id"].as_u64().unwrap()).unwrap(),
            pts_us: header["pts_us"].as_u64().unwrap(),
        };
        assert_eq!(frame.header, expected, "{file}");
        let payload = payload_of(&entry["payload"]);
        assert_eq!(frame.payload, payload.as_slice(), "{file}");
        let header_len = usize::try_from(header["header_len"].as_u64().unwrap()).unwrap();
        let mut rebuilt = expected.encode().to_vec();
        rebuilt[6..8].copy_from_slice(&u16::try_from(header_len).unwrap().to_le_bytes());
        rebuilt.resize(header_len, 0);
        rebuilt.extend_from_slice(&payload);
        assert_eq!(rebuilt, data, "{file}");
    }
}

#[test]
fn unix_socket_frames_match_their_index() {
    let index = json("unix_socket/index.json");
    let entries = index["frames"].as_array().unwrap();
    let mut stream = Vec::new();
    let mut expected = Vec::new();
    for entry in entries {
        let file = entry["file"].as_str().unwrap();
        let data = bytes(&format!("unix_socket/{file}"));
        stream.extend_from_slice(&data);
        let mut decoder = UnixFrameDecoder::new();
        let frames = decoder.push(&data).unwrap();
        assert_eq!(frames.len(), 1, "{file}");
        let frame = frames.into_iter().next().unwrap();
        assert_eq!(frame.encode().unwrap(), data, "{file}");
        match (&frame, file) {
            (UnixFrame::Text(text), "text_attach.bin") => {
                let preamble: Preamble = serde_json::from_str(text).unwrap();
                assert_eq!(
                    serde_json::to_value(preamble).unwrap(),
                    json("runner_host/attach.json")
                );
            }
            (UnixFrame::Binary(binary), "binary_delta.bin") => {
                assert_eq!(binary, &bytes("binary_frames/h264_delta.bin"));
            }
            (UnixFrame::Close { code, reason }, "close_4404.bin") => {
                assert_eq!((*code, reason.as_str()), (4404, "tab closed"));
            }
            (UnixFrame::Close { code, reason }, "close_no_reason.bin") => {
                assert_eq!((*code, reason.as_str()), (1000, ""));
            }
            other => panic!("unexpected {other:?}"),
        }
        expected.push(frame);
    }
    let mut decoder = UnixFrameDecoder::new();
    let mut reassembled = Vec::new();
    for chunk in stream.chunks(7) {
        reassembled.extend(decoder.push(chunk).unwrap());
    }
    assert_eq!(reassembled, expected);
}

#[test]
fn h264_frame_tables_cover_their_streams() {
    for name in ["testsrc_1280x800", "testsrc_640x400"] {
        let table = json(&format!("h264/{name}.frames.json"));
        let data = bytes(&format!("h264/{name}.annexb"));
        let frames = table["frames"].as_array().unwrap();
        let mut offset = 0;
        for (index, frame) in frames.iter().enumerate() {
            assert_eq!(
                frame["offset"].as_u64().unwrap(),
                u64::try_from(offset).unwrap()
            );
            offset += usize::try_from(frame["length"].as_u64().unwrap()).unwrap();
            assert_eq!(
                frame["keyframe"].as_bool().unwrap(),
                index == 0,
                "{name} {index}"
            );
        }
        assert_eq!(offset, data.len(), "{name}");
    }
    assert!(fixture_text(&format!("{ROOT}/README.md")).contains("libx264"));
}
