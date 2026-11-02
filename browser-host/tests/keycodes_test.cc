#include "core/keycodes.h"
#include "core/protocol.h"
#include "test.h"

TEST(KeyCodesMapLettersArrowsAndModifiers) {
  rb::KeyMapping mapping;
  CHECK(rb::LookupKeyCode("KeyA", &mapping));
  CHECK_EQ(mapping.windows_key_code, 0x41);
  CHECK_EQ(mapping.xkb_keycode, 38);  // evdev 30 + 8
  CHECK_EQ(mapping.mac_keycode, 0x00);
  CHECK(rb::LookupKeyCode("ArrowLeft", &mapping));
  CHECK_EQ(mapping.windows_key_code, 0x25);
  CHECK_EQ(mapping.xkb_keycode, 113);
  CHECK_EQ(mapping.mac_keycode, 0x7B);
  CHECK(rb::LookupKeyCode("Enter", &mapping));
  CHECK_EQ(mapping.windows_key_code, 0x0D);
  CHECK(rb::LookupKeyCode("ShiftRight", &mapping));
  CHECK(mapping.right);
  CHECK(!rb::LookupKeyCode("Unidentified", &mapping));
  CHECK(!rb::LookupKeyCode("NotAKey", &mapping));
}

TEST(ModifiersMapToCefFlags) {
  using namespace rb::protocol;  // NOLINT(google-build-using-namespace)
  CHECK_EQ(rb::CefFlagsFromModifiers(kModifierShift | kModifierMeta),
           rb::kCefShiftDown | rb::kCefCommandDown);
  CHECK_EQ(rb::CefFlagsFromModifiers(kModifierLeftButton), rb::kCefLeftMouseButton);
  CHECK_EQ(rb::CefFlagsFromModifiers(1u << 20), 0u);
}
