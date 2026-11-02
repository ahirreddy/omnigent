#include "core/keycodes.h"

#include <algorithm>
#include <array>
#include <iterator>

#include "core/protocol.h"

namespace rb {

namespace {

struct Entry {
  std::string_view code;
  KeyMapping mapping;
};

// Sorted by code. Native codes follow Chromium's keycode_converter table (evdev + 8 for XKB,
// kVK_* for macOS); virtual keys follow the Windows US layout.
constexpr Entry kKeys[] = {
    {"AltLeft", {0x12, 64, 0x3A, 0x0000, false, true, false}},
    {"AltRight", {0x12, 108, 0x3D, 0x0000, false, false, true}},
    {"ArrowDown", {0x28, 116, 0x7D, 0xF701, false, false, false}},
    {"ArrowLeft", {0x25, 113, 0x7B, 0xF702, false, false, false}},
    {"ArrowRight", {0x27, 114, 0x7C, 0xF703, false, false, false}},
    {"ArrowUp", {0x26, 111, 0x7E, 0xF700, false, false, false}},
    {"Backquote", {0xC0, 49, 0x32, 0x0000, false, false, false}},
    {"Backslash", {0xDC, 51, 0x2A, 0x0000, false, false, false}},
    {"Backspace", {0x08, 22, 0x33, 0x007F, false, false, false}},
    {"BracketLeft", {0xDB, 34, 0x21, 0x0000, false, false, false}},
    {"BracketRight", {0xDD, 35, 0x1E, 0x0000, false, false, false}},
    {"CapsLock", {0x14, 66, 0x39, 0x0000, false, false, false}},
    {"Comma", {0xBC, 59, 0x2B, 0x0000, false, false, false}},
    {"ContextMenu", {0x5D, 135, 0x6E, 0x0000, false, false, false}},
    {"ControlLeft", {0x11, 37, 0x3B, 0x0000, false, true, false}},
    {"ControlRight", {0x11, 105, 0x3E, 0x0000, false, false, true}},
    {"Delete", {0x2E, 119, 0x75, 0xF728, false, false, false}},
    {"Digit0", {0x30, 19, 0x1D, 0x0000, false, false, false}},
    {"Digit1", {0x31, 10, 0x12, 0x0000, false, false, false}},
    {"Digit2", {0x32, 11, 0x13, 0x0000, false, false, false}},
    {"Digit3", {0x33, 12, 0x14, 0x0000, false, false, false}},
    {"Digit4", {0x34, 13, 0x15, 0x0000, false, false, false}},
    {"Digit5", {0x35, 14, 0x17, 0x0000, false, false, false}},
    {"Digit6", {0x36, 15, 0x16, 0x0000, false, false, false}},
    {"Digit7", {0x37, 16, 0x1A, 0x0000, false, false, false}},
    {"Digit8", {0x38, 17, 0x1C, 0x0000, false, false, false}},
    {"Digit9", {0x39, 18, 0x19, 0x0000, false, false, false}},
    {"End", {0x23, 115, 0x77, 0xF72B, false, false, false}},
    {"Enter", {0x0D, 36, 0x24, 0x000D, false, false, false}},
    {"Equal", {0xBB, 21, 0x18, 0x0000, false, false, false}},
    {"Escape", {0x1B, 9, 0x35, 0x001B, false, false, false}},
    {"F1", {0x70, 67, 0x7A, 0xF704, false, false, false}},
    {"F10", {0x79, 76, 0x6D, 0xF70D, false, false, false}},
    {"F11", {0x7A, 95, 0x67, 0xF70E, false, false, false}},
    {"F12", {0x7B, 96, 0x6F, 0xF70F, false, false, false}},
    {"F13", {0x7C, 191, 0x69, 0xF710, false, false, false}},
    {"F14", {0x7D, 192, 0x6B, 0xF711, false, false, false}},
    {"F15", {0x7E, 193, 0x71, 0xF712, false, false, false}},
    {"F16", {0x7F, 194, 0x6A, 0xF713, false, false, false}},
    {"F17", {0x80, 195, 0x40, 0xF714, false, false, false}},
    {"F18", {0x81, 196, 0x4F, 0xF715, false, false, false}},
    {"F19", {0x82, 197, 0x50, 0xF716, false, false, false}},
    {"F2", {0x71, 68, 0x78, 0xF705, false, false, false}},
    {"F20", {0x83, 198, 0x5A, 0xF717, false, false, false}},
    {"F21", {0x84, 199, 0xFFFF, 0xF718, false, false, false}},
    {"F22", {0x85, 200, 0xFFFF, 0xF719, false, false, false}},
    {"F23", {0x86, 201, 0xFFFF, 0xF71A, false, false, false}},
    {"F24", {0x87, 202, 0xFFFF, 0xF71B, false, false, false}},
    {"F3", {0x72, 69, 0x63, 0xF706, false, false, false}},
    {"F4", {0x73, 70, 0x76, 0xF707, false, false, false}},
    {"F5", {0x74, 71, 0x60, 0xF708, false, false, false}},
    {"F6", {0x75, 72, 0x61, 0xF709, false, false, false}},
    {"F7", {0x76, 73, 0x62, 0xF70A, false, false, false}},
    {"F8", {0x77, 74, 0x64, 0xF70B, false, false, false}},
    {"F9", {0x78, 75, 0x65, 0xF70C, false, false, false}},
    {"Home", {0x24, 110, 0x73, 0xF729, false, false, false}},
    {"Insert", {0x2D, 118, 0x72, 0xF727, false, false, false}},
    {"IntlBackslash", {0xE2, 94, 0x0A, 0x0000, false, false, false}},
    {"KeyA", {0x41, 38, 0x00, 0x0000, false, false, false}},
    {"KeyB", {0x42, 56, 0x0B, 0x0000, false, false, false}},
    {"KeyC", {0x43, 54, 0x08, 0x0000, false, false, false}},
    {"KeyD", {0x44, 40, 0x02, 0x0000, false, false, false}},
    {"KeyE", {0x45, 26, 0x0E, 0x0000, false, false, false}},
    {"KeyF", {0x46, 41, 0x03, 0x0000, false, false, false}},
    {"KeyG", {0x47, 42, 0x05, 0x0000, false, false, false}},
    {"KeyH", {0x48, 43, 0x04, 0x0000, false, false, false}},
    {"KeyI", {0x49, 31, 0x22, 0x0000, false, false, false}},
    {"KeyJ", {0x4A, 44, 0x26, 0x0000, false, false, false}},
    {"KeyK", {0x4B, 45, 0x28, 0x0000, false, false, false}},
    {"KeyL", {0x4C, 46, 0x25, 0x0000, false, false, false}},
    {"KeyM", {0x4D, 58, 0x2E, 0x0000, false, false, false}},
    {"KeyN", {0x4E, 57, 0x2D, 0x0000, false, false, false}},
    {"KeyO", {0x4F, 32, 0x1F, 0x0000, false, false, false}},
    {"KeyP", {0x50, 33, 0x23, 0x0000, false, false, false}},
    {"KeyQ", {0x51, 24, 0x0C, 0x0000, false, false, false}},
    {"KeyR", {0x52, 27, 0x0F, 0x0000, false, false, false}},
    {"KeyS", {0x53, 39, 0x01, 0x0000, false, false, false}},
    {"KeyT", {0x54, 28, 0x11, 0x0000, false, false, false}},
    {"KeyU", {0x55, 30, 0x20, 0x0000, false, false, false}},
    {"KeyV", {0x56, 55, 0x09, 0x0000, false, false, false}},
    {"KeyW", {0x57, 25, 0x0D, 0x0000, false, false, false}},
    {"KeyX", {0x58, 53, 0x07, 0x0000, false, false, false}},
    {"KeyY", {0x59, 29, 0x10, 0x0000, false, false, false}},
    {"KeyZ", {0x5A, 52, 0x06, 0x0000, false, false, false}},
    {"MetaLeft", {0x5B, 133, 0x37, 0x0000, false, true, false}},
    {"MetaRight", {0x5C, 134, 0x36, 0x0000, false, false, true}},
    {"Minus", {0xBD, 20, 0x1B, 0x0000, false, false, false}},
    {"NumLock", {0x90, 77, 0x47, 0xF739, true, false, false}},
    {"Numpad0", {0x60, 90, 0x52, 0x0000, true, false, false}},
    {"Numpad1", {0x61, 87, 0x53, 0x0000, true, false, false}},
    {"Numpad2", {0x62, 88, 0x54, 0x0000, true, false, false}},
    {"Numpad3", {0x63, 89, 0x55, 0x0000, true, false, false}},
    {"Numpad4", {0x64, 83, 0x56, 0x0000, true, false, false}},
    {"Numpad5", {0x65, 84, 0x57, 0x0000, true, false, false}},
    {"Numpad6", {0x66, 85, 0x58, 0x0000, true, false, false}},
    {"Numpad7", {0x67, 79, 0x59, 0x0000, true, false, false}},
    {"Numpad8", {0x68, 80, 0x5B, 0x0000, true, false, false}},
    {"Numpad9", {0x69, 81, 0x5C, 0x0000, true, false, false}},
    {"NumpadAdd", {0x6B, 86, 0x45, 0x0000, true, false, false}},
    {"NumpadDecimal", {0x6E, 91, 0x41, 0x0000, true, false, false}},
    {"NumpadDivide", {0x6F, 106, 0x4B, 0x0000, true, false, false}},
    {"NumpadEnter", {0x0D, 104, 0x4C, 0x0003, true, false, false}},
    {"NumpadEqual", {0xBB, 125, 0x51, 0x0000, true, false, false}},
    {"NumpadMultiply", {0x6A, 63, 0x43, 0x0000, true, false, false}},
    {"NumpadSubtract", {0x6D, 82, 0x4E, 0x0000, true, false, false}},
    {"PageDown", {0x22, 117, 0x79, 0xF72D, false, false, false}},
    {"PageUp", {0x21, 112, 0x74, 0xF72C, false, false, false}},
    {"Pause", {0x13, 127, 0xFFFF, 0xF730, false, false, false}},
    {"Period", {0xBE, 60, 0x2F, 0x0000, false, false, false}},
    {"PrintScreen", {0x2C, 107, 0xFFFF, 0xF72E, false, false, false}},
    {"Quote", {0xDE, 48, 0x27, 0x0000, false, false, false}},
    {"ScrollLock", {0x91, 78, 0xFFFF, 0xF72F, false, false, false}},
    {"Semicolon", {0xBA, 47, 0x29, 0x0000, false, false, false}},
    {"ShiftLeft", {0x10, 50, 0x38, 0x0000, false, true, false}},
    {"ShiftRight", {0x10, 62, 0x3C, 0x0000, false, false, true}},
    {"Slash", {0xBF, 61, 0x2C, 0x0000, false, false, false}},
    {"Space", {0x20, 65, 0x31, 0x0000, false, false, false}},
    {"Tab", {0x09, 23, 0x30, 0x0009, false, false, false}},
};

}  // namespace

bool LookupKeyCode(std::string_view code, KeyMapping* mapping) {
  const auto* found = std::lower_bound(
      std::begin(kKeys), std::end(kKeys), code,
      [](const Entry& entry, std::string_view value) { return entry.code < value; });
  if (found == std::end(kKeys) || found->code != code) {
    return false;
  }
  *mapping = found->mapping;
  return true;
}

uint32_t CefFlagsFromModifiers(uint32_t modifiers) {
  using namespace protocol;  // NOLINT(google-build-using-namespace)
  uint32_t flags = 0;
  if ((modifiers & kModifierShift) != 0) flags |= kCefShiftDown;
  if ((modifiers & kModifierCtrl) != 0) flags |= kCefControlDown;
  if ((modifiers & kModifierAlt) != 0) flags |= kCefAltDown;
  if ((modifiers & kModifierMeta) != 0) flags |= kCefCommandDown;
  if ((modifiers & kModifierCapsLock) != 0) flags |= kCefCapsLockOn;
  if ((modifiers & kModifierNumLock) != 0) flags |= kCefNumLockOn;
  if ((modifiers & kModifierLeftButton) != 0) flags |= kCefLeftMouseButton;
  if ((modifiers & kModifierMiddleButton) != 0) flags |= kCefMiddleMouseButton;
  if ((modifiers & kModifierRightButton) != 0) flags |= kCefRightMouseButton;
  return flags;
}

}  // namespace rb
