# Native UI polish review

The web's organization and journeys remain the foundation. The visual target is
the calm reading experience of ChatGPT on Mac, with native controls, Omnigent
palettes and restrained brand accents. Reviewed against the supplied captures,
the shared SwiftUI components and the October 31 decisions in `web-ui-spec.md`.

| Priority / impact | Problem | Fix |
| --- | --- | --- |
| 1 / High | Prose stretches too far, line spacing is tight, and short user messages fill a large bubble. Transcript and composer edges differ. | Share a 720pt column with consistent gutters; use scaled prose type and leading, content-sized right-aligned bubbles, and a clearer paragraph/turn rhythm. |
| 2 / High | Composer controls have uneven targets and compete with the text; long model names crowd compact layouts. Focus is hard to see. | Use a rounded floating material card, a clear focus border, consistent chips and send/stop targets, with a wrapping control row at narrow widths. Keep Return, modified Return, Escape and approval-mode shortcuts. |
| 3 / High | Approvals repeat large accent outlines and equally heavy secondary actions; a tall dock can dominate a phone. | Use neutral surfaces, a small state accent and one primary action. Wrap secondary choices, bound the dock, and retain paging, inline cards, shared drafts and permission-change confirmations. |
| 4 / High | Faint secondary text, thin outlines and hover-only actions do not adequately account for accessibility settings. | Increase boundary contrast, use opaque surfaces with Reduce Transparency, preserve scaled text and touch targets, reveal message actions for keyboard/VoiceOver focus, and disable decorative motion with Reduce Motion. |
| 5 / Medium | Spacing, radii and text treatments are repeated as local numbers. | Extend the existing DesignSystem with a named spacing, typography, control-size and surface scale; reuse it across conversation, navigation, inspector and settings surfaces. |
| 6 / Medium | Code resembles a flat gray box; copying is an unlabeled glyph and long lines need scrolling. | Give fenced code a dark theme-derived surface, language header, visible Copy feedback and a wrap toggle; keep SF Mono, selection and bounded scrolling for tool output. |
| 7 / Medium | Worked folds and nested tool cards produce too much chrome. Streaming text and interrupted output need a clearer finish. | Use muted disclosure lines with a hover target and a hairline guide; remove nested tool-card outlines, preserve error indicators, and show a small labeled streaming/interrupted state. |
| 8 / Medium | Sidebar section spacing, row heights and badges are uneven; selection is too saturated. Long server names compete with the wordmark. | Preserve the native source list and keyboard selection, normalize row height and section type, soften selection, add quiet hover feedback, and constrain the server label. Keep all navigation sections and quick filters. |
| 9 / Medium | The session toolbar is crowded at small widths and title/subtitle hierarchy varies. | Keep system toolbar placement and the native title/subtitle, use compact Share labeling when needed, and standardize secondary header type. Keep Info, Chat/Terminal and inspector actions. |
| 10 / Medium | The new-session greeting is oversized relative to the composer, uses fixed pointer coordinates and can crowd small heights. Empty states vary in tone. | Use a smaller Otto, a balanced greeting and shared column, scroll on short windows, and position pointer tracking relative to the actual greeting. Keep the composer prominent and empty-state guidance concise. |
| 11 / Medium | Inbox rows span the entire window, with timestamps far from their content. Inspector navigation and headers feel detached. | Bound Inbox content, give rows a consistent vertical rhythm, adapt filters to narrow widths, and group inspector tabs/title on a quiet native surface. Preserve all six tabs and system settings forms. |
| 12 / Medium | Error panels use broad tinted fills and can squeeze action labels on a phone. | Reuse calm semantic surfaces, wrap error content and actions, and retain all error text, copy, retry and dismissal paths. |
| 13 / Low | Rich syntax highlighting and custom mascot choreography could add polish but also add complexity. | Retain selectable SF Mono and restrained existing Otto movement; consider syntax highlighting separately after validating language coverage and performance. |

## Native conventions and validation

Use SF Pro/SF Mono, native menus, segmented controls, source-list selection,
context menus, Settings forms and toolbar placement. Hover supplements keyboard,
touch and VoiceOver access. Status must retain a label or symbol, not color alone.
Theme-derived surfaces must work with Omnigent, Dracula, GitHub, Catppuccin,
Gruvbox, Solarized, Nord and Custom in both appearances.

Reuse the existing component and gallery-render suites. Extend their render
matrix for theme/accessibility and compact layout checks rather than creating a
new application harness. Manually inspect Streaming Turn, Pending Approvals,
New Session, Inbox, Errors, Compact Width and all inspector tabs in the playground;
check long drafts, long model names, keyboard navigation and accessibility settings.
The implementation keeps view-state contracts and existing accessibility
identifiers unchanged. Code uses the selected theme's dark palette even in light
appearance, with native selectable text and a visible copy confirmation.

## Verification results

- `swift build --product OmnigentPlayground`: passed with the package's Swift 6,
  strict-concurrency and warnings-as-errors settings, using the sandbox flags below.
- `swift test`: 40 tests in 7 suites passed, including 14 gallery surfaces in light
  and dark at regular and compact widths. Added coverage for long wrapping labels,
  short user bubbles, aligned reading/composer columns, all eight palettes with a
  large Dynamic Type environment and high-contrast AppKit appearance, opaque
  surfaces, and WCAG 4.5:1 send-label contrast across palette accents.
- `OmnigentUIComponents` compiled for `arm64-apple-ios26.0-simulator` using the
  installed iOS 27.2 SDK. This verifies compilation for the iOS 26 deployment target;
  it does not replace an iPhone/iPad interaction check.
- `swift-format lint --strict` and `git diff --check`: passed. SwiftLint is not
  installed in this environment.
- Inspected rendered conversation, markdown/code, composer states, approvals,
  landing and Inbox images. Captures are outside the tracked tree at
  `/private/tmp/omnigent-ui-polish/`; they are review evidence, not test baselines.
- Live interaction verification was blocked: Computer Use rejected access to the
  playground with “Computer Use was not approved to use Omnigent UI Review.”
  Keyboard navigation, VoiceOver, device text sizing and OS accessibility toggles
  still need the manual checks below. No real-server streaming claim is made.

The default build cannot write the user module cache or run SwiftPM's nested
sandbox here, and network access cannot reach GitHub. The existing dependency
checkouts allowed both requested commands to run with temporary caches:

```sh
cd apps/apple/Packages/OmnigentUI
export CLANG_MODULE_CACHE_PATH=/private/tmp/omnigent-ui-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/omnigent-ui-module-cache
swift build --disable-sandbox --cache-path /private/tmp/omnigent-ui-swiftpm-cache \
  --skip-update --force-resolved-versions --product OmnigentPlayground
OMNIGENT_UI_RENDER_DIR=/private/tmp/omnigent-ui-polish \
  swift test --disable-sandbox --cache-path /private/tmp/omnigent-ui-swiftpm-cache \
  --skip-update --force-resolved-versions
```

`--disable-sandbox` disables SwiftPM's nested manifest sandbox only; the workspace
sandbox remains in effect. No dependencies or package settings were changed.

## Manual acceptance

1. Run `swift run OmnigentPlayground` in the package. In **Streaming Turn**, expand
   Worked and tool rows; confirm the guide, readable prose, interrupted label and
   streaming status. Copy a code block and toggle wrapping.
2. In **New Session**, type a task, add several lines with Shift-Return, and check
   editor growth and focus. Start the session. In a running session, Escape should
   interrupt; a typed follow-up should retain the existing queue/send behavior.
3. In **Pending Approvals**, page the dock, answer a question and inspect a long
   approval. Confirm that permission-widening choices still open a confirmation
   and the inline and dock form drafts stay shared.
4. Visit **Inbox**, **Empty**, **Errors**, settings and every right-panel tab.
   Check sidebar selection with arrow keys, disclosure controls, Copy feedback,
   composer chips, Share, and keyboard focus visibility.
5. Repeat at **Compact Width**, an iPad-sized window and on iPhone/iPad with large
   text. Try every theme in both appearances. Enable Reduce Motion, Increase
   Contrast and Reduce Transparency; check static indicators, distinct boundaries,
   opaque surfaces, readable labels and VoiceOver access to message actions.

Rich syntax highlighting remains a low-priority follow-up. Device and assistive
technology acceptance is the next verification step.
