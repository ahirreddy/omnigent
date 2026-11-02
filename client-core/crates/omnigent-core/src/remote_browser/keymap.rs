//! Physical key tables: macOS virtual key codes (`kVK_*`) and USB HID keyboard usages
//! (`UIKeyboardHIDUsage`) to DOM `KeyboardEvent.code`, plus the DOM `key` of non-printing keys.
//!
//! The values follow Chromium's `ui/events/keycodes/dom/dom_code_data.inc` (mac and USB columns)
//! and the W3C UI Events `code` and `key` specifications.

/// `(kVK_* code, DOM code)`.
const MAC: &[(u16, &str)] = &[
    (0x00, "KeyA"),
    (0x01, "KeyS"),
    (0x02, "KeyD"),
    (0x03, "KeyF"),
    (0x04, "KeyH"),
    (0x05, "KeyG"),
    (0x06, "KeyZ"),
    (0x07, "KeyX"),
    (0x08, "KeyC"),
    (0x09, "KeyV"),
    (0x0A, "IntlBackslash"),
    (0x0B, "KeyB"),
    (0x0C, "KeyQ"),
    (0x0D, "KeyW"),
    (0x0E, "KeyE"),
    (0x0F, "KeyR"),
    (0x10, "KeyY"),
    (0x11, "KeyT"),
    (0x12, "Digit1"),
    (0x13, "Digit2"),
    (0x14, "Digit3"),
    (0x15, "Digit4"),
    (0x16, "Digit6"),
    (0x17, "Digit5"),
    (0x18, "Equal"),
    (0x19, "Digit9"),
    (0x1A, "Digit7"),
    (0x1B, "Minus"),
    (0x1C, "Digit8"),
    (0x1D, "Digit0"),
    (0x1E, "BracketRight"),
    (0x1F, "KeyO"),
    (0x20, "KeyU"),
    (0x21, "BracketLeft"),
    (0x22, "KeyI"),
    (0x23, "KeyP"),
    (0x24, "Enter"),
    (0x25, "KeyL"),
    (0x26, "KeyJ"),
    (0x27, "Quote"),
    (0x28, "KeyK"),
    (0x29, "Semicolon"),
    (0x2A, "Backslash"),
    (0x2B, "Comma"),
    (0x2C, "Slash"),
    (0x2D, "KeyN"),
    (0x2E, "KeyM"),
    (0x2F, "Period"),
    (0x30, "Tab"),
    (0x31, "Space"),
    (0x32, "Backquote"),
    (0x33, "Backspace"),
    (0x35, "Escape"),
    (0x36, "MetaRight"),
    (0x37, "MetaLeft"),
    (0x38, "ShiftLeft"),
    (0x39, "CapsLock"),
    (0x3A, "AltLeft"),
    (0x3B, "ControlLeft"),
    (0x3C, "ShiftRight"),
    (0x3D, "AltRight"),
    (0x3E, "ControlRight"),
    (0x3F, "Fn"),
    (0x40, "F17"),
    (0x41, "NumpadDecimal"),
    (0x43, "NumpadMultiply"),
    (0x45, "NumpadAdd"),
    (0x47, "NumLock"),
    (0x48, "AudioVolumeUp"),
    (0x49, "AudioVolumeDown"),
    (0x4A, "AudioVolumeMute"),
    (0x4B, "NumpadDivide"),
    (0x4C, "NumpadEnter"),
    (0x4E, "NumpadSubtract"),
    (0x4F, "F18"),
    (0x50, "F19"),
    (0x51, "NumpadEqual"),
    (0x52, "Numpad0"),
    (0x53, "Numpad1"),
    (0x54, "Numpad2"),
    (0x55, "Numpad3"),
    (0x56, "Numpad4"),
    (0x57, "Numpad5"),
    (0x58, "Numpad6"),
    (0x59, "Numpad7"),
    (0x5A, "F20"),
    (0x5B, "Numpad8"),
    (0x5C, "Numpad9"),
    (0x5D, "IntlYen"),
    (0x5E, "IntlRo"),
    (0x5F, "NumpadComma"),
    (0x60, "F5"),
    (0x61, "F6"),
    (0x62, "F7"),
    (0x63, "F3"),
    (0x64, "F8"),
    (0x65, "F9"),
    (0x66, "Lang2"),
    (0x67, "F11"),
    (0x68, "Lang1"),
    (0x69, "F13"),
    (0x6A, "F16"),
    (0x6B, "F14"),
    (0x6D, "F10"),
    (0x6E, "ContextMenu"),
    (0x6F, "F12"),
    (0x71, "F15"),
    (0x72, "Insert"),
    (0x73, "Home"),
    (0x74, "PageUp"),
    (0x75, "Delete"),
    (0x76, "F4"),
    (0x77, "End"),
    (0x78, "F2"),
    (0x79, "PageDown"),
    (0x7A, "F1"),
    (0x7B, "ArrowLeft"),
    (0x7C, "ArrowRight"),
    (0x7D, "ArrowDown"),
    (0x7E, "ArrowUp"),
];

/// `(HID keyboard usage id, DOM code)` for usage page 7.
const HID: &[(u16, &str)] = &[
    (0x04, "KeyA"),
    (0x05, "KeyB"),
    (0x06, "KeyC"),
    (0x07, "KeyD"),
    (0x08, "KeyE"),
    (0x09, "KeyF"),
    (0x0A, "KeyG"),
    (0x0B, "KeyH"),
    (0x0C, "KeyI"),
    (0x0D, "KeyJ"),
    (0x0E, "KeyK"),
    (0x0F, "KeyL"),
    (0x10, "KeyM"),
    (0x11, "KeyN"),
    (0x12, "KeyO"),
    (0x13, "KeyP"),
    (0x14, "KeyQ"),
    (0x15, "KeyR"),
    (0x16, "KeyS"),
    (0x17, "KeyT"),
    (0x18, "KeyU"),
    (0x19, "KeyV"),
    (0x1A, "KeyW"),
    (0x1B, "KeyX"),
    (0x1C, "KeyY"),
    (0x1D, "KeyZ"),
    (0x1E, "Digit1"),
    (0x1F, "Digit2"),
    (0x20, "Digit3"),
    (0x21, "Digit4"),
    (0x22, "Digit5"),
    (0x23, "Digit6"),
    (0x24, "Digit7"),
    (0x25, "Digit8"),
    (0x26, "Digit9"),
    (0x27, "Digit0"),
    (0x28, "Enter"),
    (0x29, "Escape"),
    (0x2A, "Backspace"),
    (0x2B, "Tab"),
    (0x2C, "Space"),
    (0x2D, "Minus"),
    (0x2E, "Equal"),
    (0x2F, "BracketLeft"),
    (0x30, "BracketRight"),
    (0x31, "Backslash"),
    (0x32, "Backslash"),
    (0x33, "Semicolon"),
    (0x34, "Quote"),
    (0x35, "Backquote"),
    (0x36, "Comma"),
    (0x37, "Period"),
    (0x38, "Slash"),
    (0x39, "CapsLock"),
    (0x3A, "F1"),
    (0x3B, "F2"),
    (0x3C, "F3"),
    (0x3D, "F4"),
    (0x3E, "F5"),
    (0x3F, "F6"),
    (0x40, "F7"),
    (0x41, "F8"),
    (0x42, "F9"),
    (0x43, "F10"),
    (0x44, "F11"),
    (0x45, "F12"),
    (0x46, "PrintScreen"),
    (0x47, "ScrollLock"),
    (0x48, "Pause"),
    (0x49, "Insert"),
    (0x4A, "Home"),
    (0x4B, "PageUp"),
    (0x4C, "Delete"),
    (0x4D, "End"),
    (0x4E, "PageDown"),
    (0x4F, "ArrowRight"),
    (0x50, "ArrowLeft"),
    (0x51, "ArrowDown"),
    (0x52, "ArrowUp"),
    (0x53, "NumLock"),
    (0x54, "NumpadDivide"),
    (0x55, "NumpadMultiply"),
    (0x56, "NumpadSubtract"),
    (0x57, "NumpadAdd"),
    (0x58, "NumpadEnter"),
    (0x59, "Numpad1"),
    (0x5A, "Numpad2"),
    (0x5B, "Numpad3"),
    (0x5C, "Numpad4"),
    (0x5D, "Numpad5"),
    (0x5E, "Numpad6"),
    (0x5F, "Numpad7"),
    (0x60, "Numpad8"),
    (0x61, "Numpad9"),
    (0x62, "Numpad0"),
    (0x63, "NumpadDecimal"),
    (0x64, "IntlBackslash"),
    (0x65, "ContextMenu"),
    (0x66, "Power"),
    (0x67, "NumpadEqual"),
    (0x68, "F13"),
    (0x69, "F14"),
    (0x6A, "F15"),
    (0x6B, "F16"),
    (0x6C, "F17"),
    (0x6D, "F18"),
    (0x6E, "F19"),
    (0x6F, "F20"),
    (0x70, "F21"),
    (0x71, "F22"),
    (0x72, "F23"),
    (0x73, "F24"),
    (0x75, "Help"),
    (0x77, "Select"),
    (0x79, "Again"),
    (0x7A, "Undo"),
    (0x7B, "Cut"),
    (0x7C, "Copy"),
    (0x7D, "Paste"),
    (0x7E, "Find"),
    (0x7F, "AudioVolumeMute"),
    (0x80, "AudioVolumeUp"),
    (0x81, "AudioVolumeDown"),
    (0x85, "NumpadComma"),
    (0x87, "IntlRo"),
    (0x88, "KanaMode"),
    (0x89, "IntlYen"),
    (0x8A, "Convert"),
    (0x8B, "NonConvert"),
    (0x90, "Lang1"),
    (0x91, "Lang2"),
    (0x92, "Lang3"),
    (0x93, "Lang4"),
    (0x94, "Lang5"),
    (0xE0, "ControlLeft"),
    (0xE1, "ShiftLeft"),
    (0xE2, "AltLeft"),
    (0xE3, "MetaLeft"),
    (0xE4, "ControlRight"),
    (0xE5, "ShiftRight"),
    (0xE6, "AltRight"),
    (0xE7, "MetaRight"),
];

/// The code DOM uses when a key's physical position is unknown.
pub const UNIDENTIFIED: &str = "Unidentified";

/// The DOM `code` of a macOS virtual key code (`NSEvent.keyCode`).
#[must_use]
pub fn dom_code_for_mac(key_code: u16) -> Option<&'static str> {
    MAC.iter()
        .find(|(code, _)| *code == key_code)
        .map(|(_, name)| *name)
}

/// The DOM `code` of a USB HID keyboard usage: a bare usage id (`UIKeyboardHIDUsage`) or a full
/// `0x0007_xxxx` page-and-usage value.
#[must_use]
pub fn dom_code_for_hid(usage: u32) -> Option<&'static str> {
    let id = match usage >> 16 {
        0 | 7 => u16::try_from(usage & 0xFFFF).ok()?,
        _ => return None,
    };
    HID.iter()
        .find(|(code, _)| *code == id)
        .map(|(_, name)| *name)
}

/// The DOM `key` of a non-printing physical key, or `None` for keys whose `key` is the
/// character they type.
#[must_use]
pub fn named_key_for_code(code: &str) -> Option<&'static str> {
    Some(match code {
        "Enter" | "NumpadEnter" => "Enter",
        "Tab" => "Tab",
        "Backspace" => "Backspace",
        "Escape" => "Escape",
        "Delete" => "Delete",
        "Insert" => "Insert",
        "Home" => "Home",
        "End" => "End",
        "PageUp" => "PageUp",
        "PageDown" => "PageDown",
        "ArrowLeft" => "ArrowLeft",
        "ArrowRight" => "ArrowRight",
        "ArrowUp" => "ArrowUp",
        "ArrowDown" => "ArrowDown",
        "ShiftLeft" | "ShiftRight" => "Shift",
        "ControlLeft" | "ControlRight" => "Control",
        "AltLeft" | "AltRight" => "Alt",
        "MetaLeft" | "MetaRight" => "Meta",
        "CapsLock" => "CapsLock",
        "NumLock" => "NumLock",
        "ScrollLock" => "ScrollLock",
        "Fn" => "Fn",
        "ContextMenu" => "ContextMenu",
        "PrintScreen" => "PrintScreen",
        "Pause" => "Pause",
        "Help" => "Help",
        "AudioVolumeUp" => "AudioVolumeUp",
        "AudioVolumeDown" => "AudioVolumeDown",
        "AudioVolumeMute" => "AudioVolumeMute",
        "F1" => "F1",
        "F2" => "F2",
        "F3" => "F3",
        "F4" => "F4",
        "F5" => "F5",
        "F6" => "F6",
        "F7" => "F7",
        "F8" => "F8",
        "F9" => "F9",
        "F10" => "F10",
        "F11" => "F11",
        "F12" => "F12",
        "F13" => "F13",
        "F14" => "F14",
        "F15" => "F15",
        "F16" => "F16",
        "F17" => "F17",
        "F18" => "F18",
        "F19" => "F19",
        "F20" => "F20",
        "F21" => "F21",
        "F22" => "F22",
        "F23" => "F23",
        "F24" => "F24",
        _ => return None,
    })
}

/// Whether a platform-supplied `key` string is unusable as a DOM `key`: empty, a control
/// character, or an `NSEvent` function-key character from the private-use area (U+F700–U+F8FF).
#[must_use]
pub fn is_unusable_key(key: &str) -> bool {
    key.is_empty()
        || key.chars().any(|character| {
            character.is_control() || ('\u{F700}'..='\u{F8FF}').contains(&character)
        })
}

/// The DOM `code` and `key` for a key event: an explicit `code` wins, then the mac key code,
/// then the HID usage. A named key's DOM `key` replaces an unusable platform `key`.
#[must_use]
pub fn resolve(
    code: Option<&str>,
    mac_key_code: Option<u16>,
    hid_usage: Option<u32>,
    key: &str,
) -> (String, String) {
    let code = code
        .filter(|code| !code.is_empty())
        .map(str::to_owned)
        .or_else(|| mac_key_code.and_then(dom_code_for_mac).map(str::to_owned))
        .or_else(|| hid_usage.and_then(dom_code_for_hid).map(str::to_owned))
        .unwrap_or_else(|| UNIDENTIFIED.to_owned());
    let key = match named_key_for_code(&code) {
        Some(named) if is_unusable_key(key) => named.to_owned(),
        _ if is_unusable_key(key) => "Unidentified".to_owned(),
        _ => key.to_owned(),
    };
    (code, key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tables_have_no_duplicate_keys() {
        for table in [MAC, HID] {
            let mut codes: Vec<u16> = table.iter().map(|(code, _)| *code).collect();
            codes.sort_unstable();
            codes.dedup();
            assert_eq!(codes.len(), table.len());
        }
    }

    #[test]
    fn mac_and_hid_agree_on_every_shared_code() {
        assert_eq!(dom_code_for_mac(0x00), Some("KeyA"));
        assert_eq!(dom_code_for_mac(0x7E), Some("ArrowUp"));
        assert_eq!(dom_code_for_mac(0x34), None);
        assert_eq!(dom_code_for_hid(0x04), Some("KeyA"));
        assert_eq!(dom_code_for_hid(0x0007_0004), Some("KeyA"));
        assert_eq!(dom_code_for_hid(0x000C_00E9), None);
        let mac: std::collections::BTreeSet<&str> = MAC.iter().map(|(_, name)| *name).collect();
        let hid: std::collections::BTreeSet<&str> = HID.iter().map(|(_, name)| *name).collect();
        // Every mac key except Fn (no HID usage on page 7) has a HID counterpart.
        let missing: Vec<&&str> = mac.difference(&hid).collect();
        assert_eq!(missing, [&"Fn"]);
    }

    #[test]
    fn resolve_prefers_explicit_codes_and_names_function_keys() {
        assert_eq!(
            resolve(None, Some(0x7E), None, "\u{F700}"),
            ("ArrowUp".to_owned(), "ArrowUp".to_owned())
        );
        assert_eq!(
            resolve(None, Some(0x24), None, "\r"),
            ("Enter".to_owned(), "Enter".to_owned())
        );
        assert_eq!(
            resolve(None, Some(0x00), None, "A"),
            ("KeyA".to_owned(), "A".to_owned())
        );
        assert_eq!(
            resolve(Some("KeyQ"), Some(0x00), Some(0x04), "q"),
            ("KeyQ".to_owned(), "q".to_owned())
        );
        assert_eq!(
            resolve(None, None, Some(0x2A), ""),
            ("Backspace".to_owned(), "Backspace".to_owned())
        );
        assert_eq!(
            resolve(None, None, None, ""),
            ("Unidentified".to_owned(), "Unidentified".to_owned())
        );
        assert_eq!(
            resolve(None, Some(0x7A), None, "\u{F704}"),
            ("F1".to_owned(), "F1".to_owned())
        );
    }
}
