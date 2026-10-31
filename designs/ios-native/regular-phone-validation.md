# Regular iPhone validation

Date: 2026-10-16. Branch: `feature/mobile-native-core`.

## Setup

Installed Apple's iOS 26.0 (23A343), arm64 simulator runtime through
`xcodebuild -downloadPlatform iOS -buildVersion 26.0 -architectureVariant arm64`.
The download was approximately 8 GB. The previously installed iOS 27.1 runtime
supports only the Duo; it cannot create conventional iPhones.

| Simulator | UUID | Runtime |
| --- | --- | --- |
| Omni iPhone 17 Pro | FB1F71AC-0B76-4F2B-B251-6EE3E1955B14 | iOS 26.0 |
| Omni iPhone SE (3rd generation, 4.7-inch) | 3FE85398-4342-4F05-BC55-C2DFBD5B6CB2 | iOS 26.0 |

The app and UI runner build for these simulators. An unsigned generic physical
iPhone build also succeeded; this is **not** a signed install or a physical-device
test. Xcode reports an existing all-orientations warning for the iPad-capable
target. No physical iPhone was connected during setup.

## Test evidence

All 22 Foundation core tests passed again.

The initial eight-journey pass ran on both phones:
`/private/tmp/omni-regular-phones-ui.xcresult`.

- iPhone 17 Pro: five passed, three failed. One approval confirmation assertion
  failed; the other two failures were a SpringBoard launch error and an
  accessibility-service error. All three passed on an unchanged-app focused
  rerun: `/private/tmp/omni-iphone17-recheck-ui.xcresult` (three passed, zero
  failed/skipped). The original pass remains failed; the approval failure was
  not reproduced and its precise cause is not established.
- iPhone SE: five passed, three failed. The existing tests assumed session rows
  and approval controls were already on screen. On the smaller phone, large
  text and multiline drafts require scrolling. Test helpers now use bounded
  swipes inside the list or conversation before tapping these controls.
- Added a minimum visible editor-bounds check to the large-text journey. The
  focused iPhone 17 Pro run passed:
  `/private/tmp/omni-iphone17-editor-layout-ui.xcresult`. This geometry check
  does **not** establish that the editor is visually unobscured.

The scrolling-aware full SE rerun passed **all eight journeys**, with zero
failures/skips, in `/private/tmp/omni-iphone-se-scroll-ui.xcresult`; xcodebuild
exited successfully. This includes approval/chat, Attention, creation, exact
draft recovery, large text/landscape, new-session drafts, read-only access and
rename/pin/archive/restore/search. Swift formatting and whitespace checks pass.
No production app behavior was changed during this testing pass. The visual
findings below remain open even though these interaction tests pass.

## Visual findings requiring follow-up

1. **Expanded-editor background:** on iOS 26 phones, conversation text and the
   underlying navigation title show through the expanded editor, overlapping
   the draft and modal title. This occurs even at normal text size on the SE.
   See [SE editor capture](screenshots/iphone-se-editor-overlap.png).
2. **Maximum text size:** the expanded editor's status/footer consumes much of
   the available space, particularly with the software keyboard or in landscape.
   Draft text is obscured or cramped despite the original interaction assertions
   passing. See [iPhone 17 Pro capture](screenshots/iphone-17-pro-large-text-issue.png)
   and [SE landscape after the passing rerun](screenshots/iphone-se-landscape-issue.png).

These screenshots are actual test captures, resized only for documentation.
They are issue evidence, not approved visual baselines. The
[normal conversation screen](screenshots/iphone-17-pro-conversation.png) renders
without the modal overlap.

## Reproduce locally

Open `web/ios/NativeLab/NativeLab.xcodeproj`, select **NativeLab**, choose
**Omni iPhone 17 Pro** or **Omni iPhone SE**, and press **Cmd-R**.
Tap **Open sample workspace > Native mobile design**, expand the composer and
type a multiline draft. Look for conversation text behind the editor.
Repeat at the largest accessibility text size, with the software keyboard
visible, then rotate to landscape. Check actual readability, not only whether
Done can be tapped.

From the repository root, run core checks plus the full UI suite on either phone:

```sh
bash web/ios/NativeLab/bin/check.sh FB1F71AC-0B76-4F2B-B251-6EE3E1955B14
bash web/ios/NativeLab/bin/check.sh 3FE85398-4342-4F05-BC55-C2DFBD5B6CB2
```

**Cmd-U** runs the UI journeys on the selected Xcode destination.
Tests use separate sample storage and do not reset normal preview data.

## Still unverified

Physical-device keyboard/dictation, selection/paste, VoiceOver, Reduce
Transparency, dark appearance, iPad and iOS 18's material fallback remain manual
checks. The app is still an offline preview; none of these results validates
authentication, Arca connectivity, real agents or server sync.
