Validation baseline for the mostly native iOS discovery, recorded 2026-10-16
against commit `76281b94`. This separates executed checks from source findings
and outstanding device work. The application source and dependency lockfiles
were unchanged during discovery.

**Executed checks**

| Check | Outcome | What it establishes |
| --- | --- | --- |
| Environment inspection | Linux x86_64; Node 24.14.0, npm 11.9.0, uv 0.11.21, Python 3.13.5. Swift, Xcode, Ruby and Bundler unavailable. | Web checks are runnable; native compilation, simulator tests and Fastlane are not available here. |
| Locked web dependency installation | `npm ci --legacy-peer-deps --no-audit --no-fund` succeeded using the environment's configured registry. | Installed the existing lockfile without source/lock changes. An initial public-registry attempt failed DNS; offline cache alone was incomplete. |
| Focused Vitest baseline | **527 passed, 0 failed, 0 skipped across 10 files.** | Existing mocked web state/protocol/bridge behavior has a passing reference suite. It does not validate Swift, WebKit, real SSO, live backend behavior, or iOS suspension. |
| Production web build | `npm --prefix web run build` passed, including TypeScript compilation; server static `web-ui/index.html` produced. Vite reported a bundle-size advisory. | The current web app builds for the shell/screenshot workflow. It establishes no native performance baseline. |
| Plist and scheme parsing | Both Info plists and privacy manifest parsed with Python `plistlib`; shared scheme parsed as XML and includes both test targets. | Basic configuration syntax and target declarations are valid; this is not Xcode project/build validation. |
| Git working-tree inspection | Discovery documents only; no tracked source or lockfile changes. | Runtime code was not changed to obtain passing results. Ignored dependencies and web build output were generated locally. |

The test breakdown is:

| File under `web/src/` | Passing tests |
| --- | ---: |
| `store/chatStore.test.ts` | 290 |
| `lib/blockStream.test.ts` | 58 |
| `lib/sessionsApi.test.ts` | 49 |
| `lib/nativeBridge.test.ts` | 38 |
| `components/blocks/TerminalSession.test.ts` | 25 |
| `lib/itemsToBlocks.test.ts` | 24 |
| `lib/identity.test.ts` | 15 |
| `lib/sse.test.ts` | 14 |
| `hooks/SessionUpdatesProvider.test.tsx` | 12 |
| `lib/sessionUpdatesSocket.test.ts` | 2 |

Local execution artifacts are `/tmp/omnigent-ios-discovery-tests.json`,
`/tmp/omnigent-ios-discovery-tests.log`, and
`/tmp/omnigent-ios-discovery-build.log`. These are temporary evidence from this
session; this document records the durable result.

**Native build and test readiness — source findings**

The shared scheme contains one app target plus unit and UI test targets. Project
settings specify iPhone, iOS 18 minimum, Swift language mode 5, Debug/Release,
and automatic signing. No Swift package references or CocoaPods integration
were found in the iOS project. Sources are explicitly listed in the project,
so new source files must be added to the appropriate targets.

Sources: [project settings](../../web/ios/Omnigent.xcodeproj/project.pbxproj#L485),
[source membership](../../web/ios/Omnigent.xcodeproj/project.pbxproj#L311), and
[shared scheme](../../web/ios/Omnigent.xcodeproj/xcshareddata/xcschemes/Omnigent.xcscheme#L25).

The README/release guide says Xcode 16+, while the project includes an Icon
Composer asset and the Fastlane test lane pins iPhone 17 Pro Max/iOS 26.5.
Confirm a working Xcode/runtime combination on a Mac before relying on the
documented minimum toolchain. The app's minimum deployment OS is a separate
setting from the simulator used for tests.

There are **32 unit-test methods** in four source files: 19 deep-link parsing,
5 server-URL/privacy, 4 settings, and 4 workspace-expansion tests. The UI target
has **7 test methods**: one setup/connected screenshot test and six deep-link
consent/parsing tests. These counts describe source coverage, not execution.
The deep-link UI tests use a Debug launch argument, so actual OS delivery still
needs a separate test. The screenshot test proves a WebView appeared and captures
two screens; it does not exercise chat, decisions, or terminal behavior.

Sources: [unit suites](../../web/ios/OmnigentTests/),
[UI tests](../../web/ios/OmnigentUITests/OmnigentUITests.swift#L9),
[unit lane](../../web/ios/fastlane/Fastfile#L112), and
[screenshot configuration](../../web/ios/fastlane/Snapfile#L1).

The Debug plist's HTTP exception is `NSAllowsArbitraryLoadsInWebContent`.
Moving traffic to `URLSession` needs an explicit local-development networking
policy and device validation; this web-content setting is not a native-client
HTTP exception. Release uses ATS defaults. See the connection-policy details in
[native-shell.md](native-shell.md) and [server-contracts.md](server-contracts.md).

**Automation and release readiness — source findings**

- No iOS compile/XCTest/simulator workflow was found in `.github/workflows/`.
  External Mac automation and existing App Store build results are unknown.
- Swift formatting hooks intentionally return success without running when
  Swift or `swift format` is unavailable. Passing Linux pre-commit therefore
  does not prove Swift formatting or compilation.
- Web CI runs Vitest on Ubuntu. Mobile Playwright tests use a Chromium
  390×844 viewport; these verify responsive web behavior, not WKWebView or
  native controls. The server fixture supports deterministic mocked responses
  and disposable state that can inform a future native integration fixture.
- The current E2E-required gate inspects `web/**` and looks for coverage under
  `tests/e2e_ui/**`. Because the iOS target lives under `web/ios`, native UI
  work needs a deliberate gate policy recognizing meaningful XCUITest evidence.
  A browser test cannot establish native UI behavior.
- Fastlane has public and internal distributions built from the same target,
  with bundle ID/display-name overrides and separate build counters. Both
  identities and existing app state need to be considered during migration.
  Release lanes archive/upload but do not call the test lane first. Credentials,
  signing, provisioning, upload, or production services were not exercised.

Sources: [Swift hook wrapper](../../web/ios/bin/swift-format.sh#L1),
[web CI](../../.github/workflows/web-tests.yml#L33),
[mobile web tests](../../tests/e2e_ui/mobile/test_mobile_workflow.py#L1),
[mock fixture](../../tests/e2e_ui/conftest.py#L1),
[E2E gate](../../.github/scripts/e2e-ui-required/check.sh#L58),
[release flavors](../../web/ios/fastlane/Fastfile#L100), and
[release helpers](../../web/ios/fastlane/Fastfile#L269).

**Required evidence before shipping native workflows**

| Evidence gap | Next check / owner |
| --- | --- |
| Native compile, 32 unit tests, six deep-link UI tests | Run on a Mac with a named Xcode and simulator; coordinator/iOS implementation owner. |
| Current mobile visual baseline | Capture setup, sessions, chat, decisions, and representative optional surfaces on a named simulator/device. Record server mode, capabilities and version. |
| Deployment authentication and transports | Validate actual login, REST, SSE, WebSocket, expiry and reconnect against each supported deployment; connection implementation owner plus workspace integration owner. |
| Native state machine | Add Swift reducer/client tests for snapshot/history/live merging, pending sends, switching, stale decisions, unknown events and reconnect during implementation. Reuse web fixtures/semantics where useful. |
| Native user journeys | Deterministic XCUITest coverage for connect → list → conversation → send → decision; failures/reconnect and cold/warm routing. Integrate with a Mac CI lane and the repository's coverage policy. |
| Device behavior | Check keyboard, paste/selection, VoiceOver, Dynamic Type, orientation, appearance, background/resume and notification taps on the retained workflows. |
| Performance | Measure cold start, first session open, long-history scrolling, streaming responsiveness and memory with named device/data. No numeric runtime baseline was measured here. |
| Upgrade and distribution | Verify saved-server/preferences migration, explicit reauthentication when needed, unsupported-link handoff, each bundle flavor, and older-server compatibility before release. |

**Reproduce the executed web checks**

From the repository root, use the configured package registry available in your
environment. The fixed local Vite target and unset auth override keep these unit
tests/builds independent of a workspace account:

```sh
npm --prefix web ci --legacy-peer-deps --no-audit --no-fund
env -u OMNIGENT_AUTH_TOKEN OMNIGENT_URL=http://127.0.0.1:6767 \
  npm --prefix web test -- src/lib/nativeBridge.test.ts \
  src/store/chatStore.test.ts src/lib/sse.test.ts \
  src/components/blocks/TerminalSession.test.ts \
  src/hooks/SessionUpdatesProvider.test.tsx src/lib/sessionsApi.test.ts \
  src/lib/identity.test.ts src/lib/blockStream.test.ts \
  src/lib/itemsToBlocks.test.ts src/lib/sessionUpdatesSocket.test.ts \
  --maxWorkers=2
env -u OMNIGENT_AUTH_TOKEN OMNIGENT_URL=http://127.0.0.1:6767 \
  npm --prefix web run build
```

**Run the outstanding native baseline on a Mac**

Use the first command to choose an installed simulator, then substitute its UUID.
The first test invocation covers units and deep links without the screenshot
test's live-server prerequisite:

```sh
xcodebuild -project web/ios/Omnigent.xcodeproj -scheme Omnigent -showdestinations
xcodebuild -project web/ios/Omnigent.xcodeproj -scheme Omnigent \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -skip-testing:OmnigentUITests/OmnigentUITests/testLocalServerSnapshot test
```

For setup screenshots, follow [RELEASE.md](../../web/ios/RELEASE.md) prerequisites,
prepare the repository Python environment, and use `bundle exec fastlane
screenshots` from `web/ios`. That lane rebuilds the SPA, launches its own local
server, and targets the configured simulator. It does not exercise a scripted
conversation. For full manual journeys and actual custom-scheme URL delivery,
follow [native-shell.md](native-shell.md)'s reproducible checks. Record any
pre-existing test failure separately from rewrite regressions.
