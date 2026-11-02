// Maps DOM KeyboardEvent.code values to the Windows virtual key code and native scan codes CEF
// expects, and protocol modifier bits to CEF EVENTFLAG_* bits. US layout for virtual keys.
#pragma once

#include <cstdint>
#include <string_view>

namespace rb {

struct KeyMapping {
  int windows_key_code = 0;
  /// XKB keycode (evdev + 8), the native code CEF uses on Linux.
  int xkb_keycode = 0;
  /// macOS virtual key (kVK_*); 0xFFFF when the key has none.
  int mac_keycode = 0xFFFF;
  /// Character a macOS NSEvent carries for a non-text key (function keys, arrows); 0 for none.
  char16_t mac_function_character = 0;
  bool keypad = false;
  bool left = false;
  bool right = false;
};

/// Looks up `code`. False for unknown codes (including "Unidentified").
bool LookupKeyCode(std::string_view code, KeyMapping* mapping);

// CEF cef_event_flags_t values, duplicated so this file does not depend on CEF headers.
inline constexpr uint32_t kCefCapsLockOn = 1u << 0;
inline constexpr uint32_t kCefShiftDown = 1u << 1;
inline constexpr uint32_t kCefControlDown = 1u << 2;
inline constexpr uint32_t kCefAltDown = 1u << 3;
inline constexpr uint32_t kCefLeftMouseButton = 1u << 4;
inline constexpr uint32_t kCefMiddleMouseButton = 1u << 5;
inline constexpr uint32_t kCefRightMouseButton = 1u << 6;
inline constexpr uint32_t kCefCommandDown = 1u << 7;
inline constexpr uint32_t kCefNumLockOn = 1u << 8;
inline constexpr uint32_t kCefIsKeyPad = 1u << 9;
inline constexpr uint32_t kCefIsLeft = 1u << 10;
inline constexpr uint32_t kCefIsRight = 1u << 11;

/// Converts protocol modifier bits (section 5.4) to CEF event flags. Unknown bits are ignored.
uint32_t CefFlagsFromModifiers(uint32_t modifiers);

}  // namespace rb
