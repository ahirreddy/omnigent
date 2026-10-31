# Native mobile core validation

Date: 2026-10-16. Local branch: feature/mobile-native-core.
Toolchain: Xcode 27.1 (27A9275), Swift 6.4, Apple Silicon.
Simulator: iPhone Duo / iOS 27.1,
6042F80F-0BDD-4B26-AE05-4C01B95DD9D4.

## Automated coverage

| Acceptance check | Evidence |
| --- | --- |
| AC1: query/filter/group/order | MobileCoreTests query, filter and stable-order tests; native organization/search journey |
| AC2: rename/pin/archive/restore | MobileCoreTests mutation/read-only/round-trip tests; native organization/relaunch journey |
| AC3: exact per-session drafts | Native expanded-composer navigation/relaunch/send journey; new-session dismissal journey; exact Unicode core round-trip |
| AC4: responsive native editing | Native largest-text and landscape journey; TextEditor supplies native selection/paste; manual device input checks remain |
| AC5: decision and permission gates | Existing approval, Attention, read-only and creation journeys; client send/stop/decision constraint tests |
| AC6: interrupted recovery and IDs | Core recovery, restart ID uniqueness and persistence tests |
| AC7: glass and fallback | iOS 26 availability guard plus Reduce Transparency branch; simulator visual inspection; older-OS runtime check remains |
| AC8: reproducible checks and boundaries | NativeLab README and bin/check.sh; source comparison explicitly separates preview from live release |

## Results

- Core: **22 tests passed**, 0 failures, after the final core formatting pass.
- Swift formatting lint: passed for App, Sources, Tests and UITests.
- Native UI: **8 journeys passed**, 0 failures, 0 skips. Xcode exited successfully.
- Result bundle: /private/tmp/omni-mobile-final-ui.xcresult. The xcresult summary
  reports Passed, totalTestCount 8, passedTests 8 and failedTests 0.
- Shell syntax and Xcode project plist validation: passed.

The first UI pass found a keyboard-obscured creation action; it was moved into
the native toolbar and passed the following run. Expanded tests found duplicate
inline/modal action identifiers and a largest-text onboarding action below the
viewport. Modal controls now have distinct identifiers, the underlying composer
is hidden from accessibility while expanded, and the welcome action is pinned
in a safe-area inset. Filter menu actions now expose their own identifiers.

Xcode's second run completed test execution but stalled collecting diagnostics.
Its process was interrupted; its unfinished result bundle is not a clean test
result. The rerun disables extra diagnostic collection while retaining explicit
test screenshot attachments.

The first screenshot export captured the Duo's inactive primary panel (black).
Direct capture of display 3 confirmed the app was visible on the other panel.
The screenshot helper now captures all active XCUIScreens. Both focused visual
journeys passed in /private/tmp/omni-mobile-visual-ui.xcresult. The active-panel
captures were inspected: session rows, native editor and glass composer render
correctly. A final large-text review found oversized accessory icons; those now
use fixed symbol sizes inside 44-point hit targets, without capping text scaling.
The post-fix focused large-text/landscape journey passed with 0 failures and
0 skips in /private/tmp/omni-mobile-large-type-ui.xcresult. Both active-panel
captures were inspected: the editor and controls remain visible, and accessory
icons no longer overlap the draft notice. Both captures show the Duo's wide
panel; this does not establish narrow-phone or a distinct portrait layout coverage.

Screenshots: [sessions](screenshots/sessions.png),
[expanded composer](screenshots/expanded-composer.png),
[conversation](screenshots/conversation.png),
[large-text composer](screenshots/large-text-composer.png).
These are real simulator captures, resized only for documentation.

## Remaining device matrix

The original iOS 27.1 runtime rejected creation of an iPhone 17 Pro simulator
because it supports only Duo. A subsequent pass installed the standard iOS 26.0
runtime and tested iPhone 17 Pro and SE. See
[regular-phone-validation.md](regular-phone-validation.md) for the results and
the expanded-editor visual issues found on those devices. The earlier Duo-only
results above do not clear those issues. iPad has not been run separately.

Before release, resolve and retest the regular-phone findings, then run on iPad, iOS 18's material
fallback, Reduce Transparency, VoiceOver, and a physical device's keyboard,
paste, selection, dictation and background/foreground transitions. A simulator
build is not evidence for those device-specific behaviors.

No live-server login, transport, notification or sync claim follows from these
tests. The production web shell and original Downloads prototype are unchanged.
