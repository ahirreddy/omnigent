# Native Omnigent UI spec: parity with the web UI

The native Mac, iPad and iPhone apps follow the web UI's layout, information
architecture, user journeys and brand identity: the pink accent, the Otto
mascot, the dark purple-black or light character, and the same named color
themes. They are built from native components and system conventions. They do
not copy the web pixel for pixel. Web fonts, spacing scales, radii and shadows
are replaced by system typography (SF Pro and SF Mono with Dynamic Type),
standard spacing, system materials, SF Symbols, and native menus, sheets and
popovers.

Where the native design differs from the web in structure or flow, and native
is arguably better, the item is listed in "Questions for the user" at the end.
Everything else is "match the web".

## Sources

- Web code at `web/src` (cited as `web/src/...:line`). It is the source of truth
  for tokens, strings and flows.
- Journeys: `feature-map/sessions.md`, `composer.md`, `terminals.md`,
  `preferences.md`, and `designs/ios-native/mobile-scope.md` (the earlier
  native scoping).
- Deployed web, dark theme, Databricks workspace:
  `/private/tmp/claude-502/web-capture/01-home` to `05-rightpanel`. The `06` and
  `07` captures were meant to show the model and mode menus but show the
  maximized right panel, so the menu facts come from code only. The Databricks
  bar at the top of every capture belongs to the workspace host, not Omnigent.
- Native today: `apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/`
  (cited as `UC/...`), `apps/apple/Packages/OmnigentAuthUI`, the app targets
  under `apps/apple/Apps/`, and the playground captures
  `/private/tmp/claude-502/playground*.png` and `ui-*.png`.

One important fact about "native today" in this doc: it was written when the
app targets mounted only a placeholder root (a server list, a connect form and
a placeholder detail), and the conversation, list, composer, new-session,
decision and inspector views rendered in the playground, gallery and previews
only. The apps now mount them through `OmnigentAppUI`'s `ServerRootView`. In
this doc, "native has X" means the component exists. It does not mean the
component ships.

---

## 1. Tokens: brand layer only

### 1.1 What the theme owns, and what stays system

| Surface | Native source | Per-theme? |
|---|---|---|
| Text tiers (primary, secondary, tertiary, placeholder) | `.primary`, `.secondary`, `.tertiary`, `.quaternary` | No: system |
| Separators, borders | `Divider`, `.separator` | No: system |
| Control chrome: buttons, toggles, pickers, segmented controls, text fields | System styles | Tint only (accent) |
| Menus, popovers, sheets, alerts, tooltips | System materials | No: system |
| Settings forms, grouped lists | `Form`, `.formStyle(.grouped)` | No: system |
| Code and inline-code fills, cards, the user bubble | `.fill.tertiary`, `.background.secondary` | No: system (see 1.4) |
| Accent: prominent buttons, selection, focus rings, the send button, Share | `.tint(theme.accent)` | Yes |
| Brand accent: unread dot, "Needs response" badge, Inbox count, skill pills | `theme.brandAccent` | Yes |
| Links in markdown | `theme.link` | Yes |
| Detail canvas (behind transcript and composer) | `theme.canvas` | Yes |
| Sidebar tint over the system sidebar material | `theme.sidebarTint` | Yes |
| Text selection highlight | `theme.selection` | Yes |
| Status: success, warning, info, destructive, session-active, gray | Asset catalog, constant across themes | Mode only |
| Harness brand marks | Asset catalog | Mode only |

The web's status colors are defined outside the palette, in `web/src/index.css`.
They do not change with the color theme (`PALETTE_TOKEN_CSS_NAMES`,
`web/src/lib/themePalette.ts:104-143`, has no status keys). Native does the same.

### 1.2 Default theme (Omnigent): accent and status

The web supports light, dark and system. Mode is set by next-themes
(`web/src/components/theme/ThemeProvider.tsx:36-44`, `defaultTheme="system"`).

| Role | Light | Dark | Web source | Native name (asset catalog / Swift) |
|---|---|---|---|---|
| Accent (`--primary`) | `#DF3C85` | `#DF3C85` | `themePalettes.generated.css:12,53` | `AccentColor` / `theme.accent` |
| Accent foreground | `#FFFFFF` | `#11171C` | `:14,55` | system (prominent button label) |
| Brand accent (`--brand-accent`) | `#DF3C85` | `#DF3C85` | `:29,70` | `BrandAccent` / `theme.brandAccent` |
| Link (`--link`) | `#1967B5` | `#72B7F5` | `:13,54` | `Link` / `theme.link` |
| Selection (`--selection-background`) | `rgba(223,60,133,0.10)` | `rgba(223,60,133,0.15)` | `:15,56` | `theme.selection` |
| Canvas (`--background`) | `#FFFFFF` | `#0E0B19` | `:4,45` | `Canvas` / `theme.canvas` |
| Sidebar (`--sidebar`, `--sidebar-background`) | `#FDFAFA`, gradient `90deg #FFFEFE to #FCF6FA` | `#0E0B19`, gradients at `:81-83` | `:30,40,71,81` | `theme.sidebarTint` |
| Sidebar selection (`--sidebar-active`) | accent at 12%, accent text | same | `:38-39,79-80` | native `List` selection with `.tint(accent)` |
| Success (`--success`, `--status-green`) | `#2EA65C` | `#2EA65C` | `index.css:247,311` | `StatusSuccess` |
| Warning (`--warning`, `--status-yellow`) | `#D4972A` | `#D4972A` | `index.css:248,312` | `StatusWarning` |
| Info (`--info`, `--status-blue`) | `#3B8FF5` | `#3B8FF5` | `index.css:249,313` | `StatusInfo` |
| Destructive (`--destructive`) | `#C8324C` | `#E65B77` | `index.css:243,307` | `StatusDestructive` / `theme.failure` |
| Status red (`--status-red`) | `#F04858` | `#F04858` | `index.css:263,324` | `StatusRed` |
| Status gray (`--status-gray`) | `#8E99A4` | `#8E99A4` | `index.css:264,325` | `StatusGray` |
| Session active (`--session-active`) | `#2F7FD4` | `#5CA4F5` | `index.css:253,317` | `SessionActive` |
| Diff added (`text-green-600` / `dark:text-green-400`) | `#16A34A` | `#4ADE80` | `components/blocks/ToolCodePanel.tsx:17-20` | `DiffAdded` |
| Diff removed (`text-red-600` / `dark:text-red-400`) | `#DC2626` | `#F87171` | same | `DiffRemoved` |
| Plan done (`text-green-500`), in progress (`text-blue-500`) | `#22C55E`, `#3B82F6` | same | `shell/TodoPanel.tsx:15-76` | `StatusSuccess`, `StatusInfo` |
| Approval card icon (`text-yellow-600` / `400`) | `#CA8A04` | `#FACC15` | `components/blocks/ApprovalCard.tsx:864-989` | `StatusWarning` |
| PR open / ready (`green-700` / `400`) | `#15803D` | `#4ADE80` | `lib/pullRequestStatus.ts:31-88` | `PRGreen` |
| PR conflicts, failing, closed (`red-700` / `400`) | `#B91C1C` | `#F87171` | same | `PRRed` |
| PR checks running (`amber-700` / `400`) | `#B45309` | `#FBBF24` | same | `PRAmber` |
| PR merged (`purple-700` / `400`) | `#7E22CE` | `#C084FC` | same | `PRPurple` |
| PR draft, unavailable | muted | muted | same | `.secondary` |

The web references the Tailwind palette (green-600 and similar) by class name,
not by token. The hexes above are the classic Tailwind sRGB values. Tailwind v4
defines these colors in OKLCH, so the rendered web colors can differ slightly.
Sample the running web app if an exact match matters.

Web elements that map onto these roles:

- Unread dot: `bg-brand-accent size-1.5` (`components/SessionStateBadge.tsx:83-89`).
- "Needs response" badge: `bg-brand-accent/15 text-brand-accent` (`:20-35`).
  Native today uses orange for this. Change it to `brandAccent`.
- Running: a muted spinning `Loader2` (`components/RunningDot.tsx:9-19`). It is
  not green. Native today uses a green pulsing dot.
- Error: `CircleAlert` in destructive (`SessionStateBadge.tsx:50-56`).
- Disconnected: a hollow muted ring (`:58-69`).
- Running tool spinner: `text-info`. Shell `exit 0`: `text-success`. Non-zero
  exit: destructive (`components/blocks/ToolCard.tsx:759-826`).
- The Share button uses a pink gradient (`.share-button-glassy`,
  `index.css:1262-1280`; light `#FA3D99 to #F22286 to #D51D74`, dark
  `#FF4DA6 to #F22286 to #B8185F`). Natively this is a `.borderedProminent`
  button tinted with the accent. The gradient is web styling and is dropped.

### 1.3 Harness brand colors and marks

Both web mappers are used: `shell/NewChatDialog.tsx:1037-1092` and
`components/ComposerAgentIcon.tsx:7-29`.

| Harness | Web mark | Color | Native today (`UC/DesignSystem/HarnessAppearance.swift:48-56`) | Change |
|---|---|---|---|---|
| Claude Code, Claude SDK | `web/src/assets/claude-code-logo.svg` | `#D97757` | `#D97757` monogram | Use the logo glyph (template image filled `#D97757`) |
| Codex, OpenAI Agents | Inline SVG, vertical gradient `#B1A7FF`, `#7A9DFF`, `#3941FF` | gradient | `#0FA380` green monogram | Use the gradient glyph. Drop the green. |
| Polly, Debby | 16x16 path | `#FF3621` | none | Add |
| Otto | `components/icons/OttoIcon.tsx` | `#F53B9D`, `#4DC5A0`, `#26A079` | none | Add (mascot asset) |
| Cursor, OpenCode, Pi, Antigravity, Devin, Kiro, Goose, Kimi, Hermes | `components/icons/*.tsx` (lobehub Mono or custom), `currentColor`, `dark:invert` | monochrome | Kiro `#9046FF`, Antigravity `#4285F5`, others `.secondary` | Monochrome template glyphs in `.primary`. Drop the Kiro and Antigravity tints. |
| Gemini, Copilot, unknown | lucide `Bot` | monochrome | monogram | SF Symbol `cpu` or a custom bot glyph |
| Smart Routing | lucide `WandSparkles` | monochrome | none | SF Symbol `wand.and.sparkles` |

Asset catalog names: `Harness/Claude`, `Harness/Codex` (vector PDF with the
gradient), `Harness/Cursor`, and so on, as template images except Claude,
Codex, Polly and Otto, which keep their colors.

### 1.4 Surfaces the web tints that native leaves to the system

The following are web styling. Native uses system equivalents and keeps the
web's role:

- User bubble: the web uses `bg-muted` with a 1px `ring-border/60`, which is
  neutral gray, not accent (`components/ai-elements/message.tsx:65-81`). Native
  today uses accent at 12%. Change `ThemePalette.userBubble` to default to
  `.fill.secondary`.
- Code blocks and inline code: `--code-bg`. Native uses `.fill.tertiary`.
- Composer card, menus, popovers, cards: system materials.
- Fonts: the web uses the system stack for UI (`index.css:34-36`), the same SF
  Pro that native uses. Its mono font is Geist Mono, then JetBrains Mono
  (`index.css:37`). Native uses SF Mono. The web's 13px UI size and its font
  size and code font settings are replaced by Dynamic Type.

### 1.5 Mascot, logo and assets

| Asset | Path | Use | Notes |
|---|---|---|---|
| Otto mascot (vector) | `web/src/components/icons/OttoIcon.tsx` (1024 viewBox; pink `#F53B9D` starfish, green `#4DC5A0` / `#26A079` companion) | Default brand mark | Export to a PDF or SVG asset `Brand/Otto` |
| Otto with tracking eyes | `web/src/components/OttoEyes.tsx` (eye centers (619.1, 520.6) and (413.8, 520.6), white r 71.3, pupil r 55.9, max offset 9.3; respects reduced motion at :214) | New-session hero, 56pt tall (`shell/NewChatDialog.tsx:6408-6420`) | Native: a SwiftUI `Canvas` with pupils following the insertion point or pointer; static under Reduce Motion |
| Otto working glyph | `BrandLogo` icon, `otto-working` bob 1.6s and blink 3.4s (`index.css:1927-1936`) | Working indicator in the transcript | Native: `.symbolEffect`-style bob, static under Reduce Motion |
| Starfish raster | `web/src/assets/omnigent-starfish-icon.png` (880x843 RGBA) | Onboarding and auth cards (`pages/onboarding/AuthCardShell.tsx:8`) | Use in `OmnigentAuthUI` cards in place of the generic SF Symbol |
| Otto, no padding | `web/src/assets/otto-no-padding.svg` (39x41) | Compact mark | |
| Wordmark | `web/src/assets/omnigent-wordmark.svg` | Sidebar header, 15px tall (`shell/Sidebar.tsx:118,1143`) | Native: sidebar header on Mac and iPad, navigation title on iPhone |
| Dark canvas glow | `web/src/assets/omnigent-center-glow.svg` (white radial gradient, center 50% / 46%, r 56%, 26% to 0% opacity) | Dark-mode background of the content area for every palette (`index.css:664-672`) | Native: a `RadialGradient` overlay on `theme.canvas` in dark mode |
| App icon | `web/platform-assets/AppIcon.icon` (Icon Composer source of truth, per `web/platform-assets/README.md`) | App icon | Reference it directly from the Apple targets |
| Setup logos | `web/platform-assets/logos/omnigents-logo.svg`, `omnigents-logo-reverse.svg` | Setup screen | Already symlinked by the old iOS shell |
| Claude logo | `web/src/assets/claude-code-logo.svg` (the starburst `claude.svg` is unused) | Harness mark | |
| Server branding | `useLogoUrl` / `useAppName` (`lib/branding.ts:10,32`) | A server can replace the logo, app name and heading | Native must honor the same branding fields from `/v1/info` |

Licensing and usage: the repository is Apache-2.0, copyright Databricks
(`LICENSE`, `NOTICE`). Apache-2.0 section 6 grants no trademark rights, so the
Omnigent name, Otto and the wordmark are product branding to use only inside
Omnigent apps and must not be altered or recolored. The Claude, OpenAI/Codex,
Cursor and other harness marks are third-party trademarks, used only to
identify the harness. The web gets most monochrome marks from `@lobehub/icons`.
Its license was not verified here because `node_modules` is not installed in
this worktree. Verify it before bundling those paths.

### 1.6 Native theme model

Extend the existing `OmnigentTheme` and `ThemePalette`
(`UC/DesignSystem/OmnigentTheme.swift:5-42,45-91`). Other agents are
refactoring this file now, so treat the names below as the target.

```swift
struct ThemePalette {          // one per color scheme
  var accent: Color            // --primary
  var brandAccent: Color       // --brand-accent (unread, Needs response, Inbox count)
  var link: Color              // --link
  var selection: Color         // --selection-background
  var canvas: Color            // --background (detail column backing)
  var canvasGlow: Bool         // dark mode: draw omnigent-center-glow (true for every palette)
  var sidebarTint: Color?      // --sidebar over the system sidebar material; nil = untinted
  var running: Color           // .secondary (web running spinner is muted)
  var attention: Color         // = brandAccent
  var failure: Color           // StatusDestructive
  var unread: Color            // = brandAccent
  var userBubble: Color        // .fill.secondary (neutral, like the web)
}
struct OmnigentTheme { id: String /* web palette id */; name: String; light; dark }
```

Rules that keep it native:

- `.tint(accent)` at the root. Every system control picks up the theme from
  that one modifier.
- Detail column: `.scrollContentBackground(.hidden)` with `theme.canvas` behind
  it. In dark mode, add the glow.
- Sidebar: keep `.listStyle(.sidebar)` and its material. When
  "Translucent sidebars" is off, which is the web default, lay `sidebarTint`
  over the material. When it is on, show the material untinted. This maps the
  web flag `translucentSidebar` (`lib/customTheme.ts:15-33`).
- Never theme text colors, separators, menus, popovers or sheets. Palettes with
  low-contrast foregrounds (Solarized light `#657B83`) are not copied. System
  label colors stay, which keeps contrast within Apple's guidance.
- iOS and iPadOS: set `.preferredColorScheme` from the mode preference. On
  macOS, set `NSApp.appearance` so the window chrome follows too.

---

## 2. Theme inventory and mapping

### 2.1 Axes and preferences in the web

| Axis | Values | Storage (device-local `localStorage`) | Source |
|---|---|---|---|
| Mode | `system` (default), `light`, `dark` | `web-theme` | `components/theme/ThemeProvider.tsx:36-44`, `themeMode.ts:1` |
| Color theme (palette) | `omni` (default, label "Omnigent"), `dracula`, `github`, `catppuccin`, `gruvbox`, `solarized`, `nord`, `custom` | `omnigent:ui-theme-palette`, JSON string; removed when `omni` | `lib/themePalette.ts:27-47,691-718` |
| Custom theme | `{basePalette, accent, darkAccent, tint, darkTint, contrast 0-100, translucentSidebar}`; default `omni`, `#df3c85`, `#df3c85`, `#ffffff`, `#0e0b19`, `50`, `false` | `omnigent:custom-theme` | `lib/customTheme.ts:12-33` |
| Terminal theme | `auto` ("Match app"), `light`, `dark` | `omnigent:terminal-theme` | `lib/terminalThemePreferences.ts:7`, `pages/SettingsPage.tsx:414-418` |
| Embedded host | When the app runs inside Databricks, Mode's System option becomes "Use Databricks setting", with a link "Databricks appearance settings" | host config `themeSettingsUrl` | `pages/SettingsPage.tsx:479-528`, `lib/host.ts:164-168` |

Settings UI (`pages/SettingsPage.tsx`):

- Settings, Appearance, Theme group:
  - "Mode": a System / Light / Dark segmented control (`:408-412`, `:479-528`).
  - "Terminal theme" (`:531-556`).
  - "Color theme": a "Theme palette" select with swatches, then "Accent",
    "Background tint" (each edits the variant for the current mode), a
    "Contrast" slider and a "Translucent sidebars" switch. Editing any control
    on a preset turns it into Custom, based on that preset (`:741-905`).
- Palette blurbs (`themePalette.ts`): Omnigent "The signature pink brand look."
  (:219); Dracula "Moody purple with a pink pop." (:299); GitHub "Clean
  neutrals with a signal blue." (:358); Catppuccin "Soft pastels — Latte &
  Mocha." (:416); Gruvbox "Warm retro earth tones." (:477); Solarized
  "Precision colors in Solarized Light & Dark." (:534); Nord "Arctic frost blues
  over polar-night neutrals." (:607).

Sync: none of these is stored server-side. All four keys are device-local.
The shared preferences API (`docs/shared-preferences-api.md:67-73`) only
supports `model`, `harness`, `harness_args` and `plugin` keys. The only
cross-device path is Settings data export and import: the JSON
`{version: 1, settings: {key: string}}` includes `web-theme`,
`omnigent:ui-theme-palette`, `omnigent:custom-theme` and
`omnigent:terminal-theme` (`lib/settingsPortability.ts:27-48`). The web also
tells a native shell its mode through `setThemeSource`
(`lib/nativeBridge.ts:871`), which matters for the Mac app's embedded browser
window.

Native preference, to stay compatible:

- Store the same keys with the same values in `UserDefaults`: `web-theme`,
  `omnigent:ui-theme-palette` (same JSON-string encoding),
  `omnigent:custom-theme` (same JSON object) and `omnigent:terminal-theme`.
- Accept a web Settings export file in Settings. Write the same shape on export.
- Change the native theme ids to the web ids. `standard` becomes `omni`.
- Whether to sync to the server is a question for the user (Q9).

### 2.2 Full palette token sets

Generated from `PALETTES` (`web/src/lib/themePalette.ts:215-665`) into
`web/src/themePalettes.generated.css` by `web/scripts/generate-theme-palettes.mjs`.
Each block lists the tokens in the order below, one per line. The value of row
N is at `block start + N`. One exception: in the dark `omni` block,
`sidebar-background` spans lines 81-83, so `shell-background` is at line 84.
Two rows are the same in every block and are omitted from the tables:
`sidebar-active` = `color-mix(in srgb, var(--primary) 12%, transparent)` and
`sidebar-active-foreground` = `var(--primary)`.

Tokens the native theme consumes: `primary` (accent), `brand-accent`, `link`,
`selection-background`, `background` and `shell-background` (canvas),
`sidebar` and `sidebar-background` (sidebar tint). The other rows are listed
for completeness. Native replaces them with system colors.

Light blocks start at: omni line 3, dracula 87, github 169, catppuccin 251,
gruvbox 333, solarized 415, nord 497.

| Token | omni | dracula | github | catppuccin | gruvbox | solarized | nord |
|---|---|---|---|---|---|---|---|
| `background` | `#ffffff` | `#f7f5fd` | `#f6f8fa` | `#eff1f5` | `#fbf1c7` | `#fdf6e3` | `#eceff4` |
| `foreground` | `#27272a` | `#1e1a2b` | `#1f2328` | `#4c4f69` | `#3c3836` | `#657b83` | `#2e3440` |
| `card` | `#ffffff` | `#ffffff` | `#ffffff` | `#ffffff` | `#fffdf2` | `#eee8d5` | `#e5e9f0` |
| `card-solid` | `#ffffff` | `#ffffff` | `#ffffff` | `#ffffff` | `#fffdf2` | `#eee8d5` | `#e5e9f0` |
| `card-foreground` | `#27272a` | `#1e1a2b` | `#1f2328` | `#4c4f69` | `#3c3836` | `#657b83` | `#2e3440` |
| `tray` | `#ffffff` | `#ffffff` | `#ffffff` | `#ffffff` | `#fffdf2` | `#eee8d5` | `#e5e9f0` |
| `popover` | `#ffffff` | `#ffffff` | `#ffffff` | `#ffffff` | `#fffdf2` | `#eee8d5` | `#e5e9f0` |
| `popover-foreground` | `#11171c` | `#1e1a2b` | `#1f2328` | `#4c4f69` | `#3c3836` | `#657b83` | `#2e3440` |
| `primary` | `#df3c85` | `#7c3aed` | `#0969da` | `#8839ef` | `#d65d0e` | `#268bd2` | `#5e81ac` |
| `link` | `#1967b5` | `#7c3aed` | `#0968d9` | `#8739ec` | `#9d360a` | `#026287` | `#355e86` |
| `primary-foreground` | `#ffffff` | `#ffffff` | `#ffffff` | `#ffffff` | `#ffffff` | `#fdf6e3` | `#eceff4` |
| `selection-background` | `rgba(223,60,133,0.1)` | `rgba(124,58,237,0.15)` | `rgba(9,105,218,0.15)` | `rgba(136,57,239,0.15)` | `rgba(214,93,14,0.18)` | `rgba(38,139,210,0.15)` | `rgba(94,129,172,0.25)` |
| `selection-foreground` | `#651249` | `#1e1a2b` | `#1f2328` | `#4c4f69` | `#3c3836` | `#073642` | `#2e3440` |
| `secondary` | `#eceef1` | `#efeaf9` | `#eaeef2` | `#e6e9ef` | `#ebdbb2` | `#eee8d5` | `#d8dee9` |
| `secondary-foreground` | `#27272a` | `#1e1a2b` | `#1f2328` | `#4c4f69` | `#3c3836` | `#657b83` | `#2e3440` |
| `muted` | `#0000000f` | `#efeaf9` | `#eaeef2` | `#e6e9ef` | `#ebdbb2` | `#d6d4c6` | `#d8dee9` |
| `muted-foreground` | `#71717a` | `#6b6786` | `#59636e` | `#6c6f85` | `#7c6f64` | `#586e75` | `#4c566a` |
| `code-bg` | `#0000000f` | `#efeaf9` | `#eff1f3` | `#e6e9ef` | `#ebdbb2` | `#eee8d5` | `#d8dee9` |
| `accent` | `#d7edfe` | `#f3e8ff` | `#ddf4ff` | `#ccd0da` | `#f2e5bc` | `#eee8d5` | `#e5e9f0` |
| `accent-foreground` | `#04355d` | `#6b21a8` | `#0550ae` | `#8839ef` | `#af3a03` | `#268bd2` | `#5e81ac` |
| `border` | `#e4e4e7` | `#e6e0f2` | `#d1d9e0` | `#ccd0da` | `#e6d5a8` | `#c1c5bb` | `#d8dee9` |
| `border-strong` | `#a1a1aa` | `#b6abd6` | `#afb8c1` | `#acb0be` | `#bdae93` | `#aeb6af` | `#81a1c1` |
| `button-border` | `#d6d6d6` | `#e6e0f2` | `#d1d9e0` | `#ccd0da` | `#e6d5a8` | `#c1c5bb` | `#d8dee9` |
| `input` | `#e4e4e7` | `#e6e0f2` | `#d1d9e0` | `#ccd0da` | `#e6d5a8` | `#c1c5bb` | `#d8dee9` |
| `ring` | `#11171c` | `#7c3aed` | `#0969da` | `#8839ef` | `#d65d0e` | `#268bd2` | `#5e81ac` |
| `brand-accent` | `#df3c85` | `#d6409f` | `#0969da` | `#ea76cb` | `#d65d0e` | `#6c71c4` | `#5e81ac` |
| `sidebar` | `#fdfafa` | `#f3f0fa` | `#f6f8fa` | `#e6e9ef` | `#f4e8bc` | `#eee8d5` | `#e5e9f0` |
| `sidebar-foreground` | `#27272a` | `#1e1a2b` | `#1f2328` | `#4c4f69` | `#3c3836` | `#657b83` | `#2e3440` |
| `sidebar-primary` | `#2272b4` | `#7c3aed` | `#0969da` | `#8839ef` | `#d65d0e` | `#268bd2` | `#5e81ac` |
| `sidebar-primary-foreground` | `#ffffff` | `#ffffff` | `#ffffff` | `#ffffff` | `#ffffff` | `#fdf6e3` | `#eceff4` |
| `sidebar-accent` | `#d7edfe` | `#f3e8ff` | `#ddf4ff` | `#ccd0da` | `#f2e5bc` | `#eee8d5` | `#d8dee9` |
| `sidebar-accent-foreground` | `#04355d` | `#6b21a8` | `#0550ae` | `#8839ef` | `#af3a03` | `#268bd2` | `#5e81ac` |
| `sidebar-border` | `#e4e4e7` | `#e6e0f2` | `#d1d9e0` | `#ccd0da` | `#e6d5a8` | `#c1c5bb` | `#d8dee9` |
| `sidebar-ring` | `#2272b4` | `#7c3aed` | `#0969da` | `#8839ef` | `#d65d0e` | `#268bd2` | `#5e81ac` |
| `sidebar-background` | `linear-gradient(90deg, #fffefe, #fcf6fa)` | `var(--sidebar)` | `var(--sidebar)` | `var(--sidebar)` | `var(--sidebar)` | `var(--sidebar)` | `var(--sidebar)` |
| `shell-background` | `var(--background)` | `linear-gradient(160deg, #faf8ff 0%, #f5f1fd 50%, #f3eefb 100%)` | `linear-gradient(180deg, #fbfcfd 0%, #f6f8fa 100%)` | `linear-gradient(160deg, #f2f3f7 0%, #eff1f5 60%, #e9ecf2 100%)` | `linear-gradient(160deg, #fbf3cd 0%, #fbf1c7 55%, #f7ecbb 100%)` | `#fdf6e3` | `linear-gradient(160deg, #eceff4 0%, #e5e9f0 55%, #d8dee9 100%)` |

Dark blocks start at: omni line 44, dracula 128, github 210, catppuccin 292,
gruvbox 374, solarized 456, nord 538.

| Token | omni | dracula | github | catppuccin | gruvbox | solarized | nord |
|---|---|---|---|---|---|---|---|
| `background` | `#0e0b19` | `#282a36` | `#0d1117` | `#1e1e2e` | `#282828` | `#002b36` | `#2e3440` |
| `foreground` | `#f5f5f4` | `#f8f8f2` | `#e6edf3` | `#cdd6f4` | `#ebdbb2` | `#839496` | `#eceff4` |
| `card` | `rgba(31,39,45,0.6)` | `rgba(68,71,90,0.5)` | `rgba(22,27,34,0.72)` | `rgba(49,50,68,0.6)` | `rgba(60,56,54,0.6)` | `#073642` | `rgba(59,66,82,0.6)` |
| `card-solid` | `#181f25` | `#343746` | `#161b22` | `#282938` | `#32302f` | `#073642` | `#3b4252` |
| `card-foreground` | `#f5f5f4` | `#f8f8f2` | `#e6edf3` | `#cdd6f4` | `#ebdbb2` | `#839496` | `#eceff4` |
| `tray` | `rgba(31,39,45,0.6)` | `rgba(68,71,90,0.5)` | `rgba(22,27,34,0.72)` | `rgba(49,50,68,0.6)` | `rgba(60,56,54,0.6)` | `#073642` | `rgba(59,66,82,0.6)` |
| `popover` | `rgba(26,33,41,0.8)` | `rgba(33,34,44,0.92)` | `rgba(22,27,34,0.9)` | `rgba(24,24,37,0.92)` | `rgba(29,32,33,0.92)` | `#073642` | `rgba(46,52,64,0.92)` |
| `popover-foreground` | `#f5f5f4` | `#f8f8f2` | `#e6edf3` | `#cdd6f4` | `#ebdbb2` | `#839496` | `#eceff4` |
| `primary` | `#df3c85` | `#bd93f9` | `#58a6ff` | `#cba6f7` | `#fe8019` | `#268bd2` | `#88c0d0` |
| `link` | `#72b7f5` | `#be95f9` | `#58a6ff` | `#cba6f7` | `#fe8019` | `#6ab8d0` | `#8fc4d3` |
| `primary-foreground` | `#11171c` | `#282a36` | `#0d1117` | `#1e1e2e` | `#282828` | `#fdf6e3` | `#2e3440` |
| `selection-background` | `rgba(223,60,133,0.15)` | `rgba(189,147,249,0.33)` | `rgba(88,166,255,0.39)` | `rgba(203,166,247,0.26)` | `rgba(254,128,25,0.34)` | `rgba(38,139,210,0.42)` | `rgba(136,192,208,0.25)` |
| `selection-foreground` | `#f9a8d4` | `#f8f8f2` | `#e6edf3` | `#f5e0dc` | `#ebdbb2` | `#eee8d5` | `#eceff4` |
| `secondary` | `#1f272d` | `#343746` | `#21262d` | `#313244` | `#3c3836` | `#073642` | `#3b4252` |
| `secondary-foreground` | `#e8ecf0` | `#f8f8f2` | `#e6edf3` | `#cdd6f4` | `#ebdbb2` | `#839496` | `#eceff4` |
| `muted` | `rgb(255 255 255 / 12%)` | `#3b3d4d` | `#21262d` | `#313244` | `#3c3836` | `#1d474f` | `#434c5e` |
| `muted-foreground` | `rgb(245 245 244 / 56%)` | `#b3b8d4` | `#8b949e` | `#a6adc8` | `#a89984` | `#93a1a1` | `#d8dee9` |
| `code-bg` | `oklch(0.38 0.005 240)` | `#21222c` | `#1c2128` | `#181825` | `#1d2021` | `#073642` | `#3b4252` |
| `accent` | `#04355d` | `#3b304f` | `#121d2f` | `#45475a` | `#504945` | `#073642` | `#434c5e` |
| `accent-foreground` | `#4299e0` | `#ff79c6` | `#58a6ff` | `#cba6f7` | `#fe8019` | `#2aa198` | `#88c0d0` |
| `border` | `oklch(0.28 0.005 240)` | `#44475a` | `#30363d` | `#45475a` | `#504945` | `#304f5c` | `#4c566a` |
| `border-strong` | `#a1a1aa` | `#5a5d75` | `#444c56` | `#585b70` | `#665c54` | `#3f5f69` | `#81a1c1` |
| `button-border` | `#d6d6d6` | `#44475a` | `#30363d` | `#45475a` | `#504945` | `#304f5c` | `#4c566a` |
| `input` | `rgb(255 255 255 / 15%)` | `#44475a` | `#30363d` | `#45475a` | `#504945` | `#304f5c` | `#4c566a` |
| `ring` | `#e8ecf0` | `#bd93f9` | `#58a6ff` | `#cba6f7` | `#fe8019` | `#268bd2` | `#88c0d0` |
| `brand-accent` | `#df3c85` | `#ff79c6` | `#58a6ff` | `#cba6f7` | `#fe8019` | `#6c71c4` | `#88c0d0` |
| `sidebar` | `#0e0b19` | `rgba(33,34,44,0.8)` | `rgba(13,17,23,0.75)` | `rgba(24,24,37,0.8)` | `rgba(29,32,33,0.8)` | `#073642` | `rgba(46,52,64,0.8)` |
| `sidebar-foreground` | `#f5f5f4` | `#f8f8f2` | `#e6edf3` | `#cdd6f4` | `#ebdbb2` | `#839496` | `#eceff4` |
| `sidebar-primary` | `oklch(0.64 0.22 254)` | `#bd93f9` | `#58a6ff` | `#cba6f7` | `#fe8019` | `#268bd2` | `#88c0d0` |
| `sidebar-primary-foreground` | `oklch(0.12 0.004 240)` | `#282a36` | `#0d1117` | `#1e1e2e` | `#282828` | `#fdf6e3` | `#2e3440` |
| `sidebar-accent` | `oklch(0.245 0.005 240)` | `#3b304f` | `#121d2f` | `#45475a` | `#504945` | `#073642` | `#434c5e` |
| `sidebar-accent-foreground` | `oklch(0.965 0.003 240)` | `#ff79c6` | `#58a6ff` | `#cba6f7` | `#fe8019` | `#2aa198` | `#88c0d0` |
| `sidebar-border` | `oklch(0.28 0.005 240)` | `#44475a` | `#30363d` | `#45475a` | `#504945` | `#304f5c` | `#4c566a` |
| `sidebar-ring` | `oklch(0.92 0.003 240 / 0.4)` | `#bd93f9` | `#58a6ff` | `#cba6f7` | `#fe8019` | `#268bd2` | `#88c0d0` |
| `sidebar-background` | `linear-gradient(transparent 35%, rgba(92,48,108,0.2)), linear-gradient(135deg, rgba(255,255,255,0.04), transparent 60%)` | `var(--sidebar)` | `var(--sidebar)` | `var(--sidebar)` | `var(--sidebar)` | `var(--sidebar)` | `var(--sidebar)` |
| `shell-background` | `var(--background)` | `var(--background)` | `var(--background)` | `var(--background)` | `var(--background)` | `var(--background)` | `var(--background)` |

Mode-specific additions that apply to every palette (`web/src/index.css`):

- Dark mode: the content area gets the center glow (`:664-672`). The sidebar
  gets a 1px edge border, foreground at 4% (`:694-697`), plus
  `--sidebar-surface-image` (`:282-284`).
- Light mode: the sidebar gets an inset shadow instead of a border
  (`:690-693`).

The Custom theme (`data-theme="custom"`, generated CSS lines 579-659) is derived
at runtime by `deriveCustomTheme` (`lib/customTheme.ts:467-491`):

- Light background = `mix(tint, #fffdff, 0.79 - 0.15c)`. Dark background =
  `darkTint`. Here c is contrast / 100.
- Card, border, muted and sidebar are mixes of background and foreground
  (`:278-310`).
- Primary = `accent` / `darkAccent`.
- Muted foreground is pushed to at least 4.5:1 contrast (`:162-178`).

Native port: port `generateCustomTheme` to Swift, or better to the Rust core
since it is pure logic. Consume only the accent, canvas and sidebar outputs.

### 2.3 Native mapping per theme

| Web id (label) | `accent` light / dark | `brandAccent` light / dark | `link` light / dark | `canvas` light / dark | `sidebarTint` light / dark |
|---|---|---|---|---|---|
| `omni` (Omnigent) | `#DF3C85` / `#DF3C85` | `#DF3C85` / `#DF3C85` | `#1967B5` / `#72B7F5` | system background (`#FFF`) / `#0E0B19` plus glow | none (`#FDFAFA` is near white) / `#0E0B19` plus purple bottom wash `rgba(92,48,108,0.2)` |
| `dracula` (Dracula) | `#7C3AED` / `#BD93F9` | `#D6409F` / `#FF79C6` | `#7C3AED` / `#BE95F9` | `#F7F5FD` / `#282A36` | `#F3F0FA` / `#21222C` at 80% |
| `github` (GitHub) | `#0969DA` / `#58A6FF` | `#0969DA` / `#58A6FF` | `#0968D9` / `#58A6FF` | `#F6F8FA` / `#0D1117` | `#F6F8FA` / `#0D1117` at 75% |
| `catppuccin` (Catppuccin) | `#8839EF` / `#CBA6F7` | `#EA76CB` / `#CBA6F7` | `#8739EC` / `#CBA6F7` | `#EFF1F5` / `#1E1E2E` | `#E6E9EF` / `#181825` at 80% |
| `gruvbox` (Gruvbox) | `#D65D0E` / `#FE8019` | `#D65D0E` / `#FE8019` | `#9D360A` / `#FE8019` | `#FBF1C7` / `#282828` | `#F4E8BC` / `#1D2021` at 80% |
| `solarized` (Solarized) | `#268BD2` / `#268BD2` | `#6C71C4` / `#6C71C4` | `#026287` / `#6AB8D0` | `#FDF6E3` / `#002B36` | `#EEE8D5` / `#073642` |
| `nord` (Nord) | `#5E81AC` / `#88C0D0` | `#5E81AC` / `#88C0D0` | `#355E86` / `#8FC4D3` | `#ECEFF4` / `#2E3440` | `#E5E9F0` / `#2E3440` at 80% |
| `custom` (Custom) | `accent` / `darkAccent` | = accent | base palette link | derived background | derived sidebar, or none when `translucentSidebar` |

`selection` per theme is the `selection-background` row above. The light-mode
gradient backgrounds (`shell-background`) are reduced to their middle stop. A
gradient is web styling.

---

## 3. Layout

### 3.1 Web window structure

Sources: `shell/AppShell.tsx`, `shell/Sidebar.tsx`, `shell/ChatHeader.tsx`,
`shell/WorkspacePanel.tsx`.

- Row: sidebar | content (header over the transcript and composer) | right
  panel.
- Sidebar: 320px default, 220px minimum, at most 50% of the viewport. It can be
  resized and collapsed (`hooks/useResizableSidebar.ts:19-28`). Below 768px it
  becomes a full-screen drawer.
- Sidebar header: the wordmark, then Search (⌘K), Settings (⌘⌥,) and the
  collapse toggle (⌘⌥[) (`shell/SidebarHeaderActions.tsx:64-98`).
- Primary navigation (`Sidebar.tsx:1183-1310`):
  - New session (`MessageCirclePlus`, highlighted with the accent at 12% and
    accent text while on `/`)
  - Automations (`Clock`, `/tasks`)
  - Inbox (`Inbox`, count badge)
  - Canvas (`LayoutDashboard`)
  - extension items
  - Usage (`Wallet`)
  - Automations, Canvas and Usage are feature-gated. The deployed capture shows
    New session, Inbox and Canvas.
- Sections, in order: Pinned (`:2891`), Projects (`:2912`, folders show 5 rows
  then "Show more"), Shared (`:3028`), Sessions (`:3086`). The filter and
  display menu sits on the section header. It has:
  - Show: All, My, Shared or Archived sessions (`:446-449`).
  - Group by: Default, Status, Harness, Created, Updated.
  - Sort by: Updated, Created.
  - Row details: Updated, Environment, Repo, Branch (`:3450-3463`).
- Header, 48px (`ChatHeader.tsx:539-830`):
  - Left: the project tag and title breadcrumb, and a title kebab menu.
  - Right: presence avatars, Info, the Chat/Terminal toggle (terminal-first
    sessions only), Share (accent), and the right-panel toggle (⌘⌥]).
- Transcript column: `--chat-column-width` is 48rem (768px). It grows to 56rem
  at 1921px and up, and to clamp(64rem, 40vw, 100rem) at 2561px and up
  (`pages/chatLayout.ts:1-2`). Prose is capped at 80ch, or 120ch when the
  column is at least 64rem (`index.css:1619-1631`). The composer has the same
  width.
- Right panel ("Workspace"): default width clamp(36% of the window, 420, 600),
  minimum 240 (`hooks/useResizableInlinePanel.ts:19-31`). Collapsed by default
  (`lib/workspacePanelPreferences.ts:18`).
  - Icon tabs: Content search (gated), Files, Changes (with count), Pull
    Requests, Agents (N or N/M working) (`WorkspacePanel.tsx:1322-1401`).
  - Soft tabs: Browser (desktop), side chats, shells, open files.
  - Execution logs is a debug-only card (`?debug=1`, `AppShell.tsx:2716-2722`).
    It appears in the deployed page text but is not a normal tab.
- Mobile web: the right panel becomes a header "Session actions" menu (Files,
  Changes, Pull Requests, Agents, Side chats, Shells, Fork). Each item opens a
  full-screen drawer (`ChatHeader.tsx:386-711`).

### 3.2 Native structure

| Web | Mac | iPad | iPhone |
|---|---|---|---|
| Window | `NavigationSplitView` with 2 columns (sidebar, detail) plus `.inspector` on the detail | Same | `NavigationSplitView` collapses to a stack: sidebar list is the root, a session pushes |
| Sidebar | `List` with `.listStyle(.sidebar)`. Nav rows, then `Section`s Pinned, Projects (a `DisclosureGroup` per project), Shared, Sessions. Width min 220, ideal 320. | Same | Root list. "New session" is the toolbar `square.and.pencil` button. |
| Sidebar header actions | Search via `.searchable(placement: .sidebar)` plus ⌘K command palette; Settings via the Settings scene (⌘,); collapse via the system sidebar toggle | Toolbar search; Settings via a gear in the sidebar toolbar | Same as iPad |
| Filter and display menu | `Menu` in the Sessions section header with `Picker`s (Show, Group by, Sort by) and toggles (row details) | Same | Same, in the toolbar |
| New-session landing | Detail column content when "New session" is selected | Same | Pushed screen |
| Inbox, Canvas, Automations, Usage | Detail content for the selected nav row | Same | Pushed screens |
| Header title, project tag, kebab menu | `navigationTitle` with `toolbarTitleMenu` holding the header menu; `navigationSubtitle` shows the project. Rename edits the title in place (⌘⌥R). | `toolbarTitleMenu` | Title menu in the navigation bar |
| Presence avatars | Toolbar item (custom avatar stack) | Same | Inside the title menu |
| Info | Toolbar button `info.circle` opening a `.popover` with the agent's tools and policies | Same | Item in the title menu, opens a sheet |
| Chat/Terminal toggle | Segmented `Picker` in the toolbar (`.principal` on Mac), only for terminal-first sessions, ⌘⌥\ | Same | Segmented control under the navigation bar |
| Share | Toolbar `Button("Share", systemImage: "person.badge.plus")` with `.borderedProminent` and the accent tint. Opens the Share sheet (see 4.10). | Same | Toolbar button |
| Right-panel toggle | System inspector toggle (`sidebar.trailing`), ⌘⌥] | Same | Toolbar `Menu` "Session actions" with Files, Changes, Pull Requests, Agents; each opens a sheet with that tab |
| Right panel | `.inspector`, `inspectorColumnWidth(min: 240, ideal: 420, max: 600)`. Top: a segmented `Picker` with icons (`folder`, `plus.forwardslash.minus`, `arrow.triangle.pull`, `cpu`) and the counts as badges. Collapsed by default. | Same | Sheet with `.presentationDetents([.medium, .large])` |
| Transcript column | `ScrollView` with content `.frame(maxWidth: 768)`, centered. Widen to 896 on windows of 1920pt or more. | Same | Full width, standard margins |
| Composer | Pinned to the bottom of the detail with `safeAreaInset(edge: .bottom)`, same max width | Same | Same |

Native today:

- The playground uses a 3-column split: servers and status filters | session
  list | detail (`UC/Gallery/PlaygroundView.swift:279-301`, `playground.png`).
  The inspector is a grouped `Form` of session facts, not tabs
  (`UC/Inspector/SessionInspectorView.swift:27-227`).
- When this was written, the apps used a 3-column server, connect,
  placeholder split, one window per server on Mac (`ServerWindowRoot.swift`).

Changes needed:

- Move to the 2-column structure above (G1). Whether to keep a servers section
  is Q1.
- Make the inspector the web's tabs (G20). Whether to keep native's session
  facts is Q2.

---

## 4. Components

Each row names the web element, the native control that replaces it, and the
states and interactions to keep. "Today" says what native has.

### 4.1 Sidebar rows

| Element | Web | Native control | Today |
|---|---|---|---|
| Nav row | Icon and label. Active: accent text on accent 12% (`shell/sidebarStyles.ts:3-14`). | `Label` in a sidebar `List` row; selection gets the system highlight with the accent tint | Absent: no New session, Inbox, Canvas or Automations rows |
| Inbox badge | Count, `aria` "N inbox items waiting" (`Sidebar.tsx:1267-1300`) | `.badge(count)` | Absent |
| Session row | Line 1: title, truncated. Line 2 (optional): environment, repo, branch. Right: state indicator, else "Draft" pencil, else relative time (`now`, `5m`, `3h`, `2d`, `1w`, `2mo`, `1y`; `lib/relativeTime.ts`), plus a shared marker (`Sidebar.tsx:4768-5450`). Hover tooltip: title, time, harness, location. | Row view: `Text(title).lineLimit(1)`, optional secondary line, trailing state or time. Tooltip via `.help`. | `UC/SessionList/SessionRow.swift:38-146` shows title, preview, agent and workspace on 3 lines, plus a date. Needs to become 1-2 lines with web time formatting. |
| State indicator | awaiting "Needs response" badge (brand accent) > running spinner > disconnected ring > error icon > unseen dot (`hooks/useSessionState.ts:27-38`) | Brand-accent capsule `Text("Needs response")`; `ProgressView().controlSize(.mini)`; `circle` outline; `exclamationmark.circle` in destructive; brand-accent dot | Present but different: orange `hand.raised` pill, green live dot, blue unread dot. Recolor and reorder by the web precedence. |
| Hover quick pin | Pin button on hover, desktop only (`:5511-5530`) | `.onHover` reveals a `pin` button on Mac | Absent |
| Row menu | Kebab or right click. Items in order: Open in grid (gated), Pin/Unpin, Share, Fork, Rename, Mark as unread/read, Add to project/Move session, Stop session, Archive/Unarchive, Delete, Leave session (`Sidebar.tsx:4067-4440`). Disabled items keep their place and show a tooltip with the reason. | `.contextMenu` plus a hover `Menu` (`ellipsis`). Same items and order. Delete and Leave confirm with `.confirmationDialog`. | Context menu has Open in New Window, Copy Link, Copy Session ID, Pin, Mark as Read/Unread, Rename…, Archive/Restore (`SessionListView.swift:167-209`). Missing: Share, Fork, Add to project, Stop, Delete, Leave. |
| Swipe actions (iOS) | none | Keep native: leading Read/Unread and Pin, trailing Archive | Present (`SessionListView.swift:211-239`) |
| Pin limit | 30 pins; "Unpin a session first" (`appConfig.ts:31`) | Disabled menu item with the reason | Absent |
| Pinned reorder | Drag within Pinned; dropping an unpinned row on a pinned row pins it into that slot | `.onMove` in the Pinned section | Absent |
| Unpin, archive | Unpin: toast "Unpinned session" with "Undo" (5s). Archive: toast "Archived N session(s)" with "Undo" and "View archived" (3s) (`shell/unpinUndoToast.tsx`, `archiveUndoToast.tsx`). | Undo via `UndoManager` (Edit > Undo, ⌘Z), plus a transient bottom banner with Undo | Absent |
| Delete key | none | Mac: Delete archives the selected row (native convention, keep) | Present (`SessionListView.swift:68-75`) |
| Empty | "No sessions"; "No archived sessions"; in a project "No sessions. Start a [new session]" (`Sidebar.tsx:452-456,1688-1696`) | `ContentUnavailableView` in the section | Different strings (`SessionListView.swift:126-142`) |
| Loading | "Loading sessions…" | `ProgressView("Loading sessions…")` | "Loading sessions" |

### 4.2 Transcript messages

| Element | Web | Native control | Today |
|---|---|---|---|
| User message | Right-aligned bubble at most 640px wide, neutral muted fill with a hairline ring, rounded 2xl (`chatBubbleParts.tsx:790-792`, `message.tsx:65-81`). Text is markdown with single newlines kept as breaks. Prompts over 12,000 characters collapse with "Show full prompt (N chars)" / "Collapse prompt" (`:907-937`). | `Text` (markdown) in a rounded rectangle with `.fill.secondary`, trailing alignment, maximum width 640 | Accent-tinted bubble, radius 16, with an author label (`MessageViews.swift:39-69`). Change the fill to neutral; drop the author label except in shared sessions. |
| Author avatar | Only in shared sessions, when the author is not the viewer: initials and a hashed color (`lib/userBadge.ts:11-60`) | Small initials circle beside the bubble | Author name shown on every speaker change |
| Pending user message | "The agent will read this after its current step" with a clock icon (`:943-951`) | `.caption` `.secondary` with `clock` | Absent |
| User actions | Revealed on hover (always shown at 40% on touch): Copy, Copy link (`?message=<id>`), then the timestamp (`:953-983`; `lib/messageDeepLink.ts`) | Hover toolbar on Mac. `.contextMenu` everywhere: Copy, Copy Link, and a timestamp line. | Context menu: Copy Text, Share, Copy Message ID (`MessageViews.swift:118-129`). Add Copy Link and the timestamp. |
| Timestamp | Same day `h:mm AM`; otherwise `Mon D, h:mm`; other years add `, YYYY` (`chatBubbleParts.tsx:562-579`) | `Date.FormatStyle` with the same rules | Absent in the transcript |
| Assistant message | No bubble, prose at most 80ch. No agent name. | Plain markdown view | Agent name above each run (`MessageViews.swift:71-104`). Drop the name. |
| Assistant actions | Copy, "Fork from here" (`arrow.triangle.branch`, hidden while streaming), Copy link, timestamp. Always visible on the last message when the session is idle (`chatBubbleParts.tsx:1160-1221`, `Transcript.tsx:630`). | Hover toolbar plus context menu: Copy, Fork from Here…, Copy Link | Copy Text, Share, Copy Message ID. No fork. |
| Interrupted | `xmark` and "Interrupted" (`:1150-1158`) | `Label("Interrupted", systemImage: "xmark")` `.caption` `.secondary` | "Stopped" (`MessageViews.swift:111`). Rename it. |
| Working indicator | Otto glyph bobbing, shimmering mono label that rotates every 5s ("Working…", "Cooking…", "Crunching…"), blocked-state text such as "Waiting for your approval in the agent's terminal." (`chatBubbleParts.tsx:373-499`) | Otto image with a gentle bob; label with `.contentTransition(.opacity)` | "Working" with three dots (`TranscriptView.swift:56-63`) |
| Text selection popup | "Reply ↵" and "Ask in side chat" above a selection (`components/chat/SelectionPopup.tsx`) | Mac: items in the selection context menu. iOS: `UIEditMenuInteraction` items. | Absent |

### 4.3 "Worked" folds and tool rows

| Element | Web | Native control | Today |
|---|---|---|---|
| Turn fold | One `Worked for 2m` row per assistant turn, or "Worked" when there is no single duration (`BlockRenderer.tsx:633-785`). Formats: `8s`, `1m 46s`, `1m`, `1h 2m`. Closed in settled history. Never folds the last bubble while running. Appears after a 500ms debounce. Expanded content has a 1px vertical guide line. | `DisclosureGroup` with a muted label and a small chevron; content indented with a leading hairline | Absent. Native groups only consecutive tools ("Used N tools", `ToolViews.swift:86-143`). |
| Tool run summary | A settled run of tools folds to one line, e.g. "Ran 3 shell commands", "Ran 1 shell command, read 2 files". Phrase order: shell, list, read, edit, search, then "called N other tools"; "Called N tools" when none are known (`lib/toolTitle.ts:405-605`). While live, the last 3 tools stay visible (`STREAMING_TAIL`). | Nested `DisclosureGroup` with the same string builder. Put the builder in the Rust core so web and native share it. | "Working with N tools" / "Used N tools", plus tool names. Replace with the web strings. |
| Tool row | Collapsed one-liner: status or category icon, bold verb, truncated body, +N/−N for edits, MCP server badge, duration (`ToolCard.tsx:469-541`). Titles such as "Read <path>", "Edit <path>", "Edit N files", "Web search: \"q\"". Bash uses the model's description. | `DisclosureGroup` row. Map icons: Terminal to `terminal`, Globe to `globe`, ListTodo to `checklist`, FileText to `doc.text`, Search to `magnifyingglass`, Plug to `powerplug`, Bot to `cpu`, Wrench to `wrench.and.screwdriver`. Running: `ProgressView` in info blue. Error: `xmark.circle` in destructive. Cancelled: `circle.slash`. | Close: icon, title, input line, counts, status (`ToolViews.swift:146-216`). Align titles and icons with the web. |
| Tool body | Tabs "Fields" and "Raw"; sections "Input" and "Result"; long output preview capped at 80 lines or 12,000 chars with "Expand"/"Collapse"; empty-state strings (`ToolCard.tsx:207-310,845-859`; `ToolCodePanel.tsx:22-282`) | Segmented `Picker` (Fields/Raw); `LabeledContent` grid; code panel with copy and wrap buttons | Input and output sections, "No output recorded." |
| Shell panel | cwd, `$ command`, output, status "running", "exit N", "timed out" (`ToolCard.tsx:608-795`) | Mono text block with a header row | Close (`ActivityRowViews.swift:59-148`) |
| Diff | Shiki `diff` highlight, +N green / −N red, title suffixes " (new file)", " (deleted)" (`FileEditBody.tsx:16-110`) | Line-tinted mono view using `DiffAdded`/`DiffRemoved` | Present without syntax highlighting (`ToolViews.swift:21-82`) |
| Reasoning | "Thinking..." with shimmer while live, then "Thought for N.N seconds" or "Thought for a few seconds"; sparkles icon; open while streaming (`components/ai-elements/reasoning.tsx:58-223`) | `DisclosureGroup` with `sparkles` | "Thinking"/"Thought" (`ActivityRowViews.swift:32-57`). Add the duration. |
| System and subagent notices | Centered "System:" line; subagent pill "Started/Completed/Failed/Stopped <title>" between dashed rules (`SystemMessage.tsx`, `SubagentActivityMessage.tsx`) | Centered `.caption` row; pill as a `Button` linking to the child session | Subagent strip "Subagent sessions" (`TranscriptView.swift:264-306`) |
| Skill and command card | `wand.and.sparkles` (brand accent) "Skill", or `command` "Command" (`SlashCommandCard.tsx`) | Row with an SF Symbol | Present as a generic row |
| Compaction | "Conversation compacted" italic; live "Compacting conversation… (Ns)" | Centered `.caption` | "Context compacted". Rename it. |

### 4.4 Markdown and code

| Element | Web | Native |
|---|---|---|
| Code block | Rounded bordered container, language label (lowercase mono) in a header, overlay buttons "Copy Code" and "Toggle word wrap", wrap on by default, Shiki `github-light`/`github-dark` (`message.tsx:523-606`, `lazyCodePlugin.ts:18`) | Rounded `.fill.tertiary` container, header with the language, copy and wrap buttons (`Toggle` with `text.word.spacing`), SF Mono, syntax colors from a GitHub light/dark equivalent. Today: copy only, no highlighting, no wrap toggle (`MarkdownView.swift:200-243`). |
| Inline code | Muted pill, 0.875em mono (`ChatMarkdown.tsx:239`) | `.fill.tertiary` background run, `.monospaced()`. Present. |
| Links | `--link` color, underlined; workspace file paths open the file viewer (`ChatMarkdown.tsx:252,297`) | `theme.link`, underlined; file paths open the Files tab of the inspector. Today: system tint; http, https and mailto only. |
| Headings | 1.65 / 1.4 / 1.2 / 1.05em (`index.css:1587-1603`) | title2 / title3 / headline / subheadline semibold (present) |
| Tables | Bordered, scrollable | `Grid` in a horizontal `ScrollView` (present) |
| Blockquote | Left bar, muted italic | Present |
| Task lists | Checkbox items without bullets | Present |
| Very long text | Plain mono fallback over 50,000 characters | Add the same fallback |

### 4.5 Approvals and questions

| Element | Web | Native control | Today |
|---|---|---|---|
| Placement | Inline card in the transcript at the pending turn. Also listed in the Inbox. | Inline card in the transcript (Q3: native also docks it above the composer) | Dock above the composer with paging "1 of 3" (`DecisionDock.swift:5-94`) |
| Titles | "Command approval" (Codex), "Plan review", "Claude has questions" / "Codex needs input" / and so on, "Choose an option", "Approval required" (`ApprovalCard.tsx:85-98,864-989`) | Card headline | "Approval requested". Use the web titles. |
| Buttons | "Approve" (primary), extras in order: "Approve for this session", "Always allow", "Approve & allow directories for this session", "Approve & switch to auto mode", "Accept & allow all edits", "Approve & don't ask again for <target>", Antigravity "Allow commands starting with … for this session" / "Always allow …"; "Reject" (outline). Codex: "Approve", "Approve and remember", "Reject". (`:463-636`) | `.borderedProminent` Approve, `.bordered` extras, Reject | "Approve" and "Decline", extras with different wording, each confirmed by "Change approval behavior?" (`DecisionCardView.swift:81-93,208-225`). Rename Decline to Reject and use the web extra labels; the confirmation is Q4. |
| Answered | "Approved", "Rejected", "Approved for this session", "Always allowed", "Plan approved · auto mode", "Prompt expired", "Resolved elsewhere" and others (`:680-862`) | Collapsed card with an icon in success, destructive or secondary | Similar set, different wording (`DecisionState.swift:338-355`) |
| Keyboard | ⌘↵ approves the newest plain pending prompt. There is no reject shortcut. (`hooks/useApproveHotkey.ts:56-91`) | `.keyboardShortcut(.return, modifiers: .command)` on Approve | Absent |
| AskUserQuestion | "Question N of M:", radio or checkbox options with descriptions, an "Other" row ("Type something"), "Prev", "Next", "Submit", "Cancel"; drafts kept (`AskUserQuestionForm.tsx`) | `Form`-style card with `Picker(.radioGroup)` and `Toggle(.checkbox)` on Mac, a list with checkmarks on iOS | Single-page form with "Submit" and "Dismiss Without Answering" (`DecisionFormView.swift`). Add paging and Cancel. |
| Plan review (ExitPlanMode) | "Claude finished planning and wants to proceed."; "Yes, and use auto mode", "Yes, manually approve edits", "Reject with feedback" (text field "What should change about the plan? (optional)", "Reject plan", "Cancel") (`ExitPlanModeReview.tsx`) | Card with the markdown plan and three buttons; inline feedback field | "Approve Plan", "Approve and Allow Edits", "Approve in Auto Mode", "Decline", feedback with "Reject" (`DecisionCardParts.swift:110-158`). Use the web labels. |
| External | "Open approval page" | `Link` | "Open Confirmation Page" |

### 4.6 Plan

- Web: a collapsible card pinned at the top of the transcript (`mt-14`). The
  header reads "Plan (completed/total)" with a list icon and a chevron. The
  body is at most 150px tall and scrolls (`shell/ChatPlanAccordion.tsx:16-50`).
  Rows: done is a green check with strikethrough text at 50% opacity; in
  progress is a blue dot with italic `activeForm` text; pending is a gray
  circle (`shell/TodoPanel.tsx:15-76`). Hidden when there are no todos.
- Native control: a `DisclosureGroup` card with `checklist`. Rows use
  `checkmark.circle.fill`, `circle.dotted`, `circle`.
- Today: an accordion above the composer, "Plan · X of Y done" with a progress
  ring (`PlanAccordion.swift`), plus a Plan section in the inspector. Match the
  web: put it at the top of the transcript and use the "(x/y)" count. Keeping
  the progress ring is styling and fine.

### 4.7 Composer

Web: one card (`components/composer/ChatComposer.tsx:112-479`). It has a text
area of 1 to ~8 lines (max 180px) and an action row:

- Leading: Add (+), Host chip, Permission chip.
- Trailing: Harness/model/effort picker, Mic, Send (or Stop).

A context tray sits above the card. In a session it shows the working
directory, branch, PR link, goal and a context ring. On the landing it shows
working directory, worktree, MCP, or repository and sandbox profile.

| Control | Web | Native control | Today |
|---|---|---|---|
| Text field | Placeholders in session: "Send a message…", "Send a follow-up (queued) — Esc to stop", "Respond to the pending request above to continue", "Session offline — reconnect below to continue", "You have read-only access to this session" (`pages/ChatPage.tsx:4037-4054`). Landing: "Describe a task to start a new session…", or "Start a new session in {project}". | `TextField(axis: .vertical).lineLimit(1...8)` (or a `TextEditor` wrapper) with the same placeholders | "Message the agent" |
| Send key | Return sends. Shift-Return and Option-Return insert a newline. The setting "Submit with ⌘ + Enter on desktop" swaps this. Touch devices always insert a newline. (`ChatComposer.tsx:244-276`, `SettingsPage.tsx:1666`) | Same, with the same setting in Settings > General | ⌘Return only (`ComposerView.swift:221-244`) |
| Add (+) | `Menu`. "Add" section: Files and images. "Session" section: Start a new side chat, Goal, Plan (toggle), Work in a project (submenu "Choose a project") (`ComposerAddMenu.tsx`). | `Menu("Add", systemImage: "plus")` with the same sections; Files opens `fileImporter`; Photos on iOS | Attach menu: Choose Files…, Photos…, Paste (`ComposerView.swift:176-194`) |
| Host chip | Laptop or cloud icon with a status dot (green online, hollow offline). Menu sections: Cloud, My machines, Offline hosts (N), Connect new host (`NewChatDialog.tsx:6990-7210`). | `Menu` with `laptopcomputer` or `cloud` and a status dot | Absent |
| Permission (approval-mode) chip | `hand.raised` icon plus the label. Single-choice menu, header label, checkmark (`ComposerControls.tsx:196-245`). Claude in a session: Manual, Auto, Accept edits, Plan. Claude on the landing adds Don't ask and Bypass permissions (`lib/claudePermissionMode.ts:31-56`). Codex live: Ask for approval, Approve for me, Full Access (`lib/codexApprovalMode.ts:22-38`). Codex create: Default, Full access, Read only, Bypass approvals & sandbox. Cursor: Default, Auto-review, Plan, Ask, Yolo. Devin: Normal, Accept edits, Smart, Dangerous. Antigravity: Ask every time, Skip permissions (`lib/nativeHarnessModes.ts`). ⇧Tab cycles in a session. | `Picker` with `.pickerStyle(.menu)`, label `Label(mode, systemImage: "hand.raised")`; ⇧Tab handled in the text field | Absent; only a read-only summary in the inspector |
| Model and effort picker | Trigger: harness glyph, model in medium weight, effort in secondary, chevron, e.g. "Default", "Opus 4.7 · High" (`ComposerControls.tsx:331-407`, `lib/composerModelLabel.ts`). Menu, 280px: optional "Smart Routing", "Harnesses" (claude, cursor, codex, then "Other..."), "Agents", "Models" (searchable "Search models…" when there are 10 or more, grouped by creator), "Effort" or "Thinking level". Effort ladders: Claude Low, Medium, High, xHigh, Max; Pi adds None and Minimal; Codex per model. The first row is "Default". ⌃⇧M opens it; ⌃⌥M and ⌃⌥E cycle model and effort. | `Menu` with `Section`s and `Picker`s inline; the model list uses a searchable popover on Mac when long | Present: "<model> · <Effort>" with Model, Reasoning and Harness sections (`ConfigurationMenu.swift`). Rename the sections to "Models" and "Effort", the default row to "Default", and capitalize "xHigh". |
| Mic | Dictation, ⌘⌥V; Return keeps the text, Esc discards (`ComposerMicButton.tsx`) | Mac: `mic` button that starts system dictation. iOS: keyboard dictation (no button). | Absent |
| Send / Stop | Send: arrow up, disabled when empty. Stop: filled square, "Interrupt", shown while working with no draft; Esc stops (`ChatPage.tsx:3024-3029,3844`). Landing: "Start session", then a spinner with "Starting session"; when blocked, a tooltip gives the reason ("Enter a message to get started", "Please choose a host and working directory"). | `Button` with `arrow.up` / `stop.fill`, `.borderedProminent` in the accent; `.keyboardShortcut(.escape)` for Stop | Send and Stop present; Stop uses ⌘. instead of Esc (`ComposerView.swift:196-244`). Add Esc and keep ⌘. as a native alias. |
| Queue and steer | While busy, a message steers by default ("Always steer" is on). Queued rows can be edited, sent now, retried, removed or reordered, and can show "Send failed" / "Waiting for host"; ⌘↵ steers all (`pages/QueuedMessagesStrip.tsx`, `lib/messageQueue.ts`) | A `List` strip above the card with swipe and context actions; `.onMove` to reorder | Absent |
| Slash commands, @ mentions | `/` menu (commands and skills), `@` file browser; Tab completes, Return runs, Esc dismisses (`hooks/useSlashCompletion.ts`, `useMentionBrowser.ts`) | Inline completion popover anchored to the text field (Mac `.popover`, iOS suggestion bar above the keyboard) | Absent |
| Attachments | Image tiles and file chips with a remove button; drop overlay "Drop files here"; limits: image 50 MB, PDF 20, text 10 (`ComposerAttachments.tsx`, `lib/attachments.ts:28-41`) | Chips in a horizontal `ScrollView`; `.dropDestination` | Present (`ComposerParts.swift:184-270`) |
| Up-arrow recall | Empty field: Up recalls the previous prompt or the last queued message | `.onKeyPress(.upArrow)` | Absent |
| Delivery uncertain | none in this form | Keep native: "Delivery uncertain" and the explicit resend acknowledgement (safety feature) | Present |

### 4.8 New-session screen

- Web (`shell/NewChatDialog.tsx:6378-7712`, `01-home.png`): centered column.
  - Otto with tracking eyes, 56px.
  - Heading "What should we build?", which server branding can override, or
    the project name inside a project.
  - The context tray with the working directory chip (Recents, "Open folder"),
    the worktree chip ("No worktree", existing worktrees, "New" branch name
    with shuffle, base branch), or for sandboxes the repository chip
    ("Repositories (optional)") and sandbox profile chip.
  - The composer card with Add, Host, Permission (shows "Manual" by default),
    the harness and model picker ("Default"), Mic and Start.
  - "Import your recent sessions" when there are zero sessions.
  - `?prompt=` seeds the draft; `?project=` scopes it.
- Native control: in the detail column, a centered `VStack`:
  - Otto view.
  - `Text("What should we build?").font(.largeTitle)`.
  - The context tray as a row of `Menu`s (folder, worktree), or a folder
    `fileImporter` when the host is this Mac.
  - The same composer view as in a session, in "start" mode.
  - On iPhone the composer docks to the bottom, as on mobile web.
- Today: a sheet `Form` "New Session" with sections Where (Host, Harness,
  Agent), Workspace and Model (Workspace text field, "Choose a Folder", Model),
  and Conversation (Title, First message). The first message is kept as a draft
  instead of being sent (`NewSessionView.swift:6-316`). There is no approval
  mode, effort, worktree or repository picker. Match the web (G12).

### 4.9 Session header and title menu

- Title menu (`shell/HeaderConversationMenu.tsx:244-376`): Pin/Unpin, Share,
  Fork, Export, Agent info (mobile), Rename, Mark as unread, Move session / Add
  to project, Archive/Unarchive, Delete.
  - Native: `toolbarTitleMenu` with the same items. Rename uses
    `.renameAction` (Mac) and ⌘⌥R.
  - Today: absent. The header is a status pill, harness and model, context
    ring and viewers (`SessionHeaderView.swift:5-80`).
- Agent info: the `info.circle` popover. It hides itself when the agent has no
  tools or policies.
- Presence: avatar stack. The context ring is not in the web header; it lives
  in the composer tray. Native: move the context ring into the composer tray
  (G18).

### 4.10 Share and fork

- Share sheet: the web opens `components/PermissionsModal.tsx`:
  - Title "Share this session", body "Invite others to view or collaborate on
    this session."
  - "General access" select.
  - "Workspace files" switch ("Let people with view access browse this
    session's files").
  - Grants list ("No grants yet."); add-person field "alice@example.com" with
    Read or Edit.
  - Footer: "Copy link" (changes to "Copied!" for 2s), "Open in mobile app" (QR
    code), "Done".
  - Disabled with a tooltip for local servers ("Sharing is unavailable from a
    local server.") or when sharing is off ("Sharing has been disabled for this
    Omnigent server.") (`ChatHeader.tsx:752-778`).
  - Native: a `.sheet` (Mac: a fixed-width sheet) with a `Form`, a `Picker`
    for General access, a `Toggle`, a `List` of grants, and a `TextField`
    with a `Picker`. The footer has Copy Link and a `ShareLink(url)` for the
    system share menu, plus Done. Not "Open in mobile app" on iOS.
  - Today: Copy Link in the row menu only.
- Fork dialog (`shell/ForkSessionDialog.tsx:2170-2252`):
  - Titles: "Clone session", "Fork from this response", "Continue in another
    directory".
  - Controls: agent (with model, effort and permission for native targets),
    directory or sandbox repositories.
  - Buttons: "Cancel", "Clone", "Clone & start", "Continue". On success it
    navigates to the new session.
  - Native: a `.sheet` with a `Form` and the same titles and buttons. The menus
    say "Fork", as on the web.
  - Today: absent.

### 4.11 Right panel (inspector) tabs

| Tab | Web | Native control | Today |
|---|---|---|---|
| Files | Search "Find files by name", sort ("Last edited"), filter, show hidden, tree or flat list; file viewer with comments; offline state "Sandbox is offline" / "Send a message in the chat to start it again." (`05-rightpanel.png`) | `OutlineGroup`/`List` with `.searchable`, toolbar `Menu` for sort; file viewer as a pushed view inside the inspector or a separate window on Mac | Absent; only a "Changed Files" section listing paths |
| Changes | Changed files and a diff viewer (Monaco diff); count badge | `List` of files; diff in the same view as tool diffs | Absent |
| Pull Requests | List of PRs with status (Merge conflicts, Checks failing, Ready to merge, Checks running, Open, Draft, Merged, Closed); empty "Pull requests created in this session appear here. You can also link an existing PR." (`PullRequestPanel.tsx:1818-2380`) | `List` rows with an SF Symbol and color per status (section 1.2) | Absent |
| Agents | Sub-agent tree with "main"; working/total count (`SubagentsPanel`) | `OutlineGroup` of sessions, each opening the child | Subagents section of buttons |
| Content search | Workspace content search (gated) | `.searchable` scope in the inspector | Absent |
| Execution logs (debug) | `#1`…`#N` JSON rows | Mac only, behind a debug setting | Absent |

### 4.12 Inbox, Canvas, Automations

- Inbox (`pages/InboxPage.tsx`):
  - Title "Inbox" with a count. Segmented filter "All", "Unread", "Awaiting
    response".
  - Groups: "Just now", "Earlier today", "Yesterday", "This week", "Older".
  - Rows: kind ("Approval needed", "Question", "Comment", unread session),
    session title, preview, time, unread dot. A row expands in place.
  - Actions: "Open session", "Mark as read", inline reply "Reply…".
  - Empty states: "Nothing waiting on you", "You’re all caught up", "No
    approvals waiting".
  - Native: `List` with a segmented `Picker` in the toolbar, `Section`s per
    group, `DisclosureGroup` rows that embed the approval card, swipe "Mark as
    Read". Today: absent. The native filters "Running" and "Needs Response" in
    the session list are partial stand-ins.
- Canvas (`pages/CanvasPage.tsx`, `canvas/`): a freeform board of session cards
  (280x132, 32pt grid), one canvas per project plus "Main". Positions are
  device-local.
  - Native: a scrollable, zoomable canvas of draggable cards on Mac and iPad.
    Hide on iPhone (web hides grid features on phones; Canvas is usable but
    cramped).
  - Today: absent.
- Automations (`pages/TasksPage.tsx`): list, "Create manually", "Create from
  template", empty "No automations yet".
  - Native: list plus a browser hand-off for create and edit initially.
  - Today: absent.

### 4.13 Empty, loading and error states

| State | Web text | Native control | Today |
|---|---|---|---|
| Empty conversation | "What should we work on?" / "Send a message to get started." (`Transcript.tsx:368-384`) | `ContentUnavailableView` | "No messages yet" / "Send a message to start the conversation." |
| Loading conversation | "Loading conversation…" | `ProgressView` | none |
| Loading earlier | "Loading earlier messages…"; jump-to-top button "Jump to the first message" on Mac | `ProgressView` row; top button on hover | "Loading earlier messages", "Load Earlier Messages" |
| Jump to latest | Round arrow-down button centered at the bottom | Present: "Latest" capsule with glass effect. Keep the native style. | Present |
| Sandbox starting | Spinner, "{stage}…" (Provisioning sandbox, Cloning repository, Connecting host, Starting agent), "Setting up your sandbox — this can take a minute." (`pages/ChatIndicators.tsx:183-215`, `lib/sandboxStatus.ts:10-17`) | Centered `ProgressView` with a title and subtitle | Absent |
| Terminal: sandbox offline | "The sandbox is offline." / "Resume it to reconnect the terminal." / secondary button "Resume sandbox", then "Resuming…"; harness variant "The harness is not running." / "Resume the session to reconnect the terminal." / "Resume session" (`shell/MainTerminalView.tsx:419-455`, `03-terminal.png`) | `ContentUnavailableView` with a `.bordered` action | Absent |
| Chat: asleep | "Sandbox is offline" / "Agent is asleep"; "Send a message in the chat to start it again." (`shell/RunnerAsleepHint.tsx`) | Inline banner above the composer | Absent |
| Host offline | "Host is offline — click to reconnect" / "Agent disconnected — click to reconnect"; dialog titles "Host is offline", "Agent disconnected" (`ChatIndicators.tsx:132-134`, `ReconnectSessionDialog.tsx:213-215`) | Banner `Button` opening an `.alert` | Absent |
| Turn error | Error pill with "Retry" or "Resume session", "Copy error", "Dismiss error message", "Related errors (N)" (`components/blocks/StatusBlocks.tsx:321-571`) | Inline `GroupBox` with buttons | Present: "Copy error", "Retry", "Dismiss" (`TranscriptView.swift:333-362`). Add "Resume session". |
| Retry in progress | "Retrying {source} · attempt a/m · waiting N.Ns" | `.caption` row | Present ("Retrying model call") |
| Policy denied | "Blocked by policy · {phase}" | Present | Present |
| Page errors | "Page not found"; "Unable to display {name}." with "Try again"; "Unable to load this page" with "Refresh page" | `ContentUnavailableView` | n/a |
| Banners | DBCert ("Refresh dbcert"), Arca shutdown ("Extend", "Not now"), Update ("Restart to update"), stream budget | Mac: window banners via `safeAreaInset(edge: .top)`. The desktop updater already exists (Sparkle "Check for Updates…"). | Partial (desktop commands) |

### 4.14 Settings

- Web (`shell/settingsNav.tsx:96-172`, `pages/SettingsPage.tsx`):
  - General group: Account, General, Appearance, MCP, Sandbox Integrations,
    Harnesses, Git, Keyboard shortcuts, Import sessions.
  - Customize: Harnesses, Custom agents.
  - Desktop: Local CLI, Updates.
  - Admin: Members, Policies, Sharing.
  - Archived: Archived sessions.
- Appearance: Mode, Terminal theme, Color theme (section 2.1); Chat defaults
  (Default transcript view Chat/Terminal; Hide unconfigured harnesses; "Show
  only the final answer"); Workspace (Workspace panel Open/Collapsed; Default
  Workspace tab); Interface and Code typography; Settings data import/export.
- General: "Submit with ⌘ + Enter on desktop", Always steer, background session
  titles, open sub-agents in panel, terminal clipboard, open links in app.
- Native control:
  - Mac: the `Settings` scene with tabs (`TabView`). Device preferences go
    there: General, Appearance, Notifications, Advanced, plus the existing
    browser engines.
  - iOS: a Settings screen pushed from the sidebar toolbar gear, a `Form` with
    the same sections.
  - Appearance: Mode as a segmented `Picker`, Color theme as a `Picker` with
    swatches, Accent and Background tint as `ColorPicker`s, Contrast as a
    `Slider`, Translucent sidebars as a `Toggle`, Terminal theme.
  - Typography settings are replaced by Dynamic Type.
  - Where server-scoped sections (Harnesses, MCP, Members, Policies, Sharing,
    Archived) live is Q5.
- Today: `ThemeSettingsView` (Appearance segmented control and a Theme picker
  with only "Standard", `UC/DesignSystem/ThemeSettingsView.swift`) is not
  mounted. The live Mac Settings has General, Notifications and Advanced
  (`OmnigentDesktop/Settings/OmnigentSettingsView.swift:34-45`).

### 4.15 Keyboard shortcuts

Web list: `components/KeyboardShortcutsDialog.tsx:78-155`. Native binds them as
menu commands (`Commands`) so they appear in the menu bar and the iPad ⌘ HUD.

| Action | Web | Native |
|---|---|---|
| New session | ⌘⇧O (browser), ⌘⌥N (desktop shell) | ⌘N (existing File menu). Also accept ⌘⌥N. |
| Command palette / find session | ⌘K / ⌘⌥S | ⌘K / ⌘⌥S |
| Settings | ⌘⌥, | ⌘, (system) |
| Toggle sidebar | ⌘⌥[ | ⌃⌘S (system), plus ⌘⌥[ |
| Toggle right panel | ⌘⌥] | ⌥⌘I (inspector convention), plus ⌘⌥] |
| Previous / next session | ⌘[ / ⌘] | same |
| Chat / Terminal | ⌘⌥\ | same |
| Rename session | ⌘⌥R | same |
| Approve | ⌘↵ | same |
| Stop | Esc | Esc and ⌘. |
| Cycle permission mode | ⇧Tab | same |
| Focus composer / model picker | ⌃⇧L / ⌃⇧M | same |
| Cycle model / effort | ⌃⌥M / ⌃⌥E | same |
| Dictation | ⌘⌥V | same (Mac) |
| Pinned session 1-10 | ⌘⌥1…0 (desktop: ⌘1…0) | ⌘1…0 |
| Keyboard shortcuts | ⌘/ | Help menu item and Settings tab |

---

## 5. Journeys

Coverage key: Covered = the component exists in native and matches the
journey; Partial = the component exists but steps differ or are missing;
Missing = no native component. Nothing is wired into a shipping app target yet.

### J1. Start a new session

1. Select "New session" in the sidebar (⌘N). The detail shows Otto and "What
   should we build?".
2. Choose the working directory from the context tray chip (Recents or "Open
   folder…"). For a git directory, optionally pick a worktree: "No worktree",
   an existing one, or "New" with a branch name and base branch. On a sandbox
   host, pick repositories and a sandbox profile instead.
3. Optionally change the host in the Host chip menu (Cloud, My machines,
   Offline hosts, Connect new host).
4. Choose the approval mode in the Permission chip. The default is "Manual";
   the options are per harness (section 4.7).
5. Choose the harness and model and the effort in the picker. "Default" means
   the harness default.
6. Type the task. Optionally attach files, add a goal, or toggle Plan.
7. Press Return or "Start session". If Start is disabled, its tooltip names
   what is missing. The session is created, the first message is sent, and the
   app navigates to `/c/<id>`.

Native: Partial. The sheet form has host, harness, agent, typed workspace and
model. It lacks the permission mode, effort, worktree, repository and sandbox
profile, and it keeps the first message as a draft instead of sending it.

### J2. Continue a conversation

1. Select the session in the sidebar.
2. Read the transcript. Settled turns are folded into "Worked for …" rows; the
   final answer is visible.
3. Type in the composer and press Return. While the agent works, Return steers
   the running turn, or queues when a message is already queued. The queue
   strip allows edit, send now, reorder and remove.
4. Esc or Stop interrupts.
5. Change the model, effort or permission mode from the composer at any time;
   ⇧Tab cycles the permission mode.

Native: Partial. Send, stop, model and effort, and attachments exist. Missing:
the Worked fold, the queue and steer, the permission mode, slash commands and
mentions, and Return-to-send.

### J3. Answer an approval

1. The sidebar row shows the brand-accent "Needs response" badge, and the Inbox
   count goes up.
2. Open the session (or answer from the Inbox). The approval card appears
   inline at the pending point. The composer placeholder reads "Respond to the
   pending request above to continue".
3. Choose "Approve" (⌘↵), an extra option, or "Reject". For questions, step
   through "Question N of M" and Submit. For a plan, choose "Yes, and use auto
   mode", "Yes, manually approve edits" or "Reject with feedback".
4. The card collapses to its answered label ("Approved for this session", and
   so on).

Native: Covered with differences: a dock instead of inline (Q3), "Decline"
instead of "Reject", confirmation dialogs (Q4), no ⌘↵, no question paging.

### J4. Switch between Chat and Terminal

1. In a terminal-first session, use the Chat/Terminal toggle in the header
   (⌘⌥\). The choice is remembered per session; the default is set in
   Settings > Appearance > Default transcript view.
2. Terminal shows the live agent terminal. If the sandbox is offline it shows
   "The sandbox is offline." with "Resume sandbox".

Native: Partial. The toggle and terminal slot exist ("Starting Terminal"
state). The real terminal (`OmnigentTerminalUI`, `OmnigentGhosttyKit`) is not
wired, and the offline and resume state is missing.

### J5. Review changes and pull requests

1. Open the right panel (⌘⌥] or the header button).
2. Files: search, sort, browse; open a file in the viewer.
3. Changes: the count badge shows changed files; select one to see its diff.
4. Pull Requests: see the PR status; follow the link; link an existing PR.
5. Agents: see sub-agents and open one.
6. On a phone, use "Session actions" instead; each tab opens full screen.

Native: Missing. The inspector shows session facts, a changed-file list and
subagent links only.

### J6. Use the Inbox

1. Select Inbox (count badge in the sidebar).
2. Filter All, Unread or Awaiting response.
3. Expand an item to approve or answer inline, or reply to a session ("Reply…").
4. "Open session" navigates; "Mark as read" clears it.

Native: Missing. Status filters in the session list only.

### J7. Share a session

1. Choose Share in the header (accent button) or in the row or title menu.
2. In "Share this session", set General access, toggle Workspace files, add
   people with Read or Edit.
3. "Copy link" copies `<server>/c/<id>`. On the web, "Open in mobile app" shows
   a QR code.
4. "Done" closes the sheet. Nothing navigates.

Native: Missing. Only Copy Link exists in the row menu.

### J8. Fork from a message

1. Hover the assistant message and choose "Fork from here" (also in its context
   menu). The header and row "Fork" copies the whole session instead.
2. The dialog "Fork from this response" offers the agent (and, for native
   harnesses, model, effort and permission) and the directory or sandbox
   repositories.
3. Choose "Clone" or "Clone & start". The app opens the new session.

Native: Missing.

### J9. Pin and archive

1. Pin from the row's hover pin button, the row menu, or the title menu. The
   session moves to Pinned (at most 30). Drag to reorder. ⌘⌥1…0 jumps to a
   pinned session.
2. Unpin shows "Unpinned session" with Undo.
3. Archive from the row or title menu. For worktree sessions, first answer
   "Also delete the worktree?" ("No, archive only" or "Yes, delete worktree",
   with Remember my choice). An open session navigates to New session. A toast
   offers Undo and "View archived".
4. Archived sessions are under the filter menu > Archived sessions, or
   Settings > Archived sessions. Unarchive from the row menu.

Native: Partial. Pin, archive and restore exist in the context menu and iOS
swipes, with Pinned grouping. Missing: Undo, the worktree prompt, drag reorder,
the pin cap, pinned shortcuts, and navigating away from an archived open
session.

### J10. Settings

1. Open Settings (⌘,).
2. Appearance: Mode (System, Light, Dark), Color theme (7 presets plus Custom
   with accent, background tint, contrast and translucent sidebars), Terminal
   theme, Default transcript view, Show only the final answer, Workspace panel
   default.
3. General: Submit with ⌘ + Enter, Always steer.
4. Server sections: Harnesses, MCP, Git, Archived, Admin (Q5).

Native: Partial. The Theme settings view exists with one theme and is not
mounted. The Mac Settings has General, Notifications and Advanced.

### J11. Find a session

1. ⌘K opens the command palette, or ⌘⌥S finds a session by name.
2. Use the filter menu for All, My, Shared or Archived, and grouping and
   sorting.

Native: Partial. `.searchable` "Search sessions" and status filters exist.

---

## 6. Gap list

"Match the web" means matching structure and behavior with native controls.
"Ask" items are summarized in section 7.

| # | Area | Native today | Decision | Change |
|---|---|---|---|---|
| G1 | Window structure | 3 columns: servers and filters, session list, detail | Match the web | 2-column `NavigationSplitView` with sidebar and detail, plus `.inspector`. The session list lives in the sidebar under nav rows. Keeping a Servers section is Q1. |
| G2 | Sidebar navigation | Filters All Sessions, Running, Needs Response, Archived | Match the web | Nav rows New session, Automations*, Inbox (badge), Canvas*, Usage* (* gated by server features). Move Archived into the filter menu. Drop Running and Needs Response as filters; the Inbox and "Group by Status" cover them. |
| G3 | Sidebar sections | Pinned plus date groups (Today, Yesterday, Previous 7 Days…) | Match the web | Sections Pinned, Projects (folders, 5 then "Show more"), Shared, Sessions. Date groups become "Group by Updated" in the display menu. |
| G4 | Display menu | none | Match the web | `Menu` with Show (All/My/Shared/Archived sessions), Group by (Default/Status/Harness/Created/Updated), Sort by (Updated/Created), row details (Updated, Environment, Repo, Branch). Persist under the web key `omnigent:sidebar-view`. |
| G5 | Session row | 3 lines; green dot; blue unread; orange attention | Match the web | One line by default (plus the optional details line); web relative time (`5m`, `3h`); state precedence and colors from 4.1; brand-accent unread dot and Needs response badge. |
| G6 | Row menu | No Share, Fork, Add to project, Stop, Delete, Leave | Match the web | Add them in the web order; confirm Delete and Leave; disabled items give a reason. Keep native extras (Open in New Window, Copy Session ID) at the end. |
| G7 | Pin and archive details | No Undo, cap, reorder or worktree prompt | Match the web | Add Undo (UndoManager and banner), the 30-pin cap, `.onMove` in Pinned, the "Also delete the worktree?" dialog, and navigate to New session after archiving the open session. |
| G8 | Accent and theme | `standard`, system blue `#007AFF`/`#0A84FF`; no theme applied in the apps | Match the web | Default theme `omni` with accent `#DF3C85`; apply `.omnigentTheme` at each app root; add the 7 palettes and Custom (section 2.3). |
| G9 | Theme ids and storage | id `standard`; not persisted | Match the web | Use the web ids and keys (`web-theme`, `omnigent:ui-theme-palette`, `omnigent:custom-theme`, `omnigent:terminal-theme`) and their value encodings; import and export the web settings JSON. |
| G10 | Theme surfaces | Theme sets accent and status only; dark canvas is system black | Match the web | Add `brandAccent`, `link`, `selection`, `canvas` with the dark glow, `sidebarTint` and translucent sidebars. Status colors move to the asset catalog values in 1.2. |
| G11 | Custom theme | none | Match the web | Accent and background tint per mode, contrast 0-100, translucent sidebars; derivation ported from `lib/customTheme.ts`, preferably into the Rust core. |
| G12 | New session | Sheet form; first message stays a draft | Match the web | Landing in the detail column: Otto, "What should we build?", context tray (directory, worktree or repositories and profile), shared composer with Host, Permission, model and effort, "Start session" that creates and sends. |
| G13 | Permission mode | Read-only summary | Match the web | Composer `Picker` with per-harness options; ⇧Tab cycles in a session. Requires core support to set it. |
| G14 | Composer send key | ⌘Return sends | Match the web | Return sends; Shift- and Option-Return insert a newline; Settings "Submit with ⌘ + Enter"; iOS Return inserts a newline. |
| G15 | Composer controls | No Host chip, Add menu sections, mic, slash, mentions, queue, up-arrow recall | Match the web | Add them per 4.7. Esc stops; keep ⌘. as an alias. |
| G16 | Model menu labels | "Model", "Reasoning", "Harness Default", "Model Default" | Match the web | Section headers "Models" and "Effort" ("Thinking level" for Pi), "Default" row, "xHigh", Smart Routing and Harnesses and Agents sections. |
| G17 | Transcript grouping | "Used N tools" groups per tool run; agent name on each run | Match the web | Per-turn "Worked for …" fold; inner tool runs as "Ran 3 shell commands"-style summaries; no assistant name; streaming tail of 3. Put the summary builder in the core. |
| G18 | Header | Status pill, model, context ring, viewers; no actions | Match the web | `toolbarTitleMenu` with the web header menu; Info popover; presence; Chat/Terminal; accent Share; inspector toggle. Move the context ring to the composer tray. Drop the header status pill; the state shows in the sidebar row. |
| G19 | User bubble | Accent 12% fill, author label | Match the web | Neutral fill; author avatar only in shared sessions; Copy Link and timestamp actions. |
| G20 | Inspector | Grouped Form of session facts, usage, plan, viewers, changed files, subagents, environment, lifecycle | Match the web | Tabs Files, Changes, Pull Requests, Agents (and gated Content search). Whether the session-facts view survives as an extra tab is Q2. |
| G21 | Plan | Above the composer and in the inspector | Match the web | One collapsible plan card at the top of the transcript, "Plan (x/y)". |
| G22 | Approvals | Docked above the composer, paged | Ask (Q3) | Web labels and titles regardless (4.5); add ⌘↵ and question paging. |
| G23 | Approval extras | Each extra asks "Change approval behavior?" | Ask (Q4) | Use the web labels either way. |
| G24 | Share | Copy Link only | Match the web | Share sheet per 4.10, accent toolbar button, disabled states with the web reasons. |
| G25 | Fork | none | Match the web | "Fork from here" on assistant messages; Fork in row and title menus; fork sheet per 4.10. |
| G26 | Inbox | none | Match the web | Inbox per 4.12, with a sidebar badge. |
| G27 | Canvas | none | Match the web | Mac and iPad canvas per 4.12; hidden on iPhone. |
| G28 | Automations, Usage | none | Match the web | Nav rows when the server enables them; list views; browser hand-off for editing at first. |
| G29 | Terminal states | Placeholder | Match the web | Wire the Ghostty terminal; add "The sandbox is offline." / "Resume sandbox", "Starting up…" / "The terminal will connect automatically.", "No terminals available.". Terminal theme preference. |
| G30 | Empty and error states | Different strings; missing sandbox, asleep and host-offline states | Match the web | Use the strings in 4.13; add "Resume session" to the error banner. |
| G31 | Markdown | No syntax highlighting, no wrap toggle, system link color | Match the web | GitHub light and dark highlighting, wrap toggle on by default, `theme.link`, workspace file links open the Files tab. |
| G32 | Harness marks | Monograms; Codex green; Kiro and Antigravity tints | Match the web | Logo glyphs from 1.3; Codex gradient; monochrome for the rest. |
| G33 | Mascot and branding | none in the conversation UI; auth uses SF Symbols | Match the web | Otto on the landing, working indicator and auth cards; wordmark in the sidebar; honor server branding (logo, app name, heading). |
| G34 | Settings | Theme view unmounted; Mac Settings has General, Notifications, Advanced | Match the web (device prefs); Ask (Q5) for server sections | Appearance and General per 4.14 on Mac and iOS. |
| G35 | Theme sync | Not stored | Ask (Q9) | Device-local, same keys as the web, unless the user wants server sync. |
| G36 | Shortcuts | ⌘N, ⌘., ⌘R reconnect | Match the web, with native aliases | Table in 4.15. |
| G37 | Multi-server | One window per server; Servers section in the sidebar | Ask (Q1) | none until answered |
| G38 | Delivery-uncertain guard | Present | Keep native (safety; no web equivalent) | none |
| G39 | iOS swipe actions, Mac Delete-to-archive | Present | Keep native (platform convention, additive) | none |
| G40 | Typography | System fonts with Dynamic Type | Keep native | Web UI font and code font settings are not ported. |
| G41 | Session status words | "Needs Response" vs "Needs response" | Match the web | Sentence case everywhere: "Needs response". |
| G42 | Settings import/export | none | Match the web | Import and export the web JSON format (`lib/settingsPortability.ts`). |
| G43 | Phone right panel | n/a | Match the web | "Session actions" toolbar menu opening each tab as a sheet. |
| G44 | Keyboard: approve, rename, chat/terminal, pinned | Missing | Match the web | Per 4.15. |

---

## 7. Questions for the user

These are the real structural or flow divergences where native may be better.

1. **Multiple servers.** The web is one server per tab. Native has a Servers
   section and one window per server on Mac. Keep native multi-server, with a
   server switcher in the sidebar header instead of a Servers section in the
   list? Recommendation: keep it. The web has no equivalent, and the Databricks
   workspace switcher plays the same role there.
2. **Session facts in the inspector.** The web right panel has only Files,
   Changes, Pull Requests and Agents. Session facts (status, model, host,
   runner, usage and cost, viewers, lifecycle) live in the Info popover or are
   absent. Keep a native "Info" tab as the fifth inspector tab? Native's view
   is denser and useful for debugging; the web spreads it across the Info
   popover and the composer tray.
3. **Where approvals appear.** The web puts approval cards inline in the
   transcript. Native docks pending requests above the composer with paging
   ("1 of 3"), so they stay visible while scrolling, which helps on a phone.
   Match the web (inline only), keep the native dock, or use both (inline card
   plus a compact dock that jumps to it)?
4. **Confirmation for permission-widening approvals.** Native asks "Change
   approval behavior?" before "Always allow", "Approve & switch to auto mode"
   and similar options. The web applies them on one click. Keep the
   confirmation (safer), or match the web (faster)?
5. **Server-scoped settings.** The web has one Settings page mixing device
   preferences with server administration (Harnesses, MCP, Git, Members,
   Policies, Sharing, Archived). Native convention puts device preferences in
   the Settings window (⌘,). Where should server sections go: inside Settings
   with a server picker, in a per-window "Server Settings" sheet, or handed off
   to the browser at first?
6. **New-session entry on Mac.** The web's New session is a landing page in the
   main area. Native today uses a modal sheet. The spec matches the web (G12).
   Confirm, or keep a sheet on Mac (with the web's controls) for a more
   document-like flow?
7. **Running and Needs-response filters.** Native has one-click "Running" and
   "Needs Response" filters with counts. The web relies on the Inbox and
   "Group by Status". The spec drops them (G2). Keep them as extra options in
   the Show picker?
8. **First message as a draft.** Native keeps the new session's first message
   as an unsent draft for review. The web sends it immediately on Start. The
   spec matches the web. Confirm?
9. **Theme sync.** The web stores mode, palette, custom theme and terminal
   theme only on the device (localStorage). The server's shared-preferences API
   has no theme key. Keep native device-local with the same keys and the web
   import/export file, or add a server-side shared preference so the theme
   follows the user across web and native? The second needs a server change.

## Decisions (user, 2026-10-31)

1. Approvals appear both inline in the transcript (as the web does) and pinned in the native
   dock above the composer, so they can never scroll out of reach.
2. New session on Mac is a web-style page in the main area (mascot, "What should we build?").
   Start sends the first message immediately.
3. Keep these native extras: multi-server windows with a server switcher; an Info tab in the
   right panel alongside Files, Changes, Pull Requests and Agents; the confirmation before
   approvals that widen permissions; and the one-click Running and Needs Response filters next
   to the web's filter menu.
4. Server settings (Harnesses, MCP, Git, Members, Policies, Sharing, Archived) are built
   natively in the Mac Settings window, with a server picker.
5. Theme preference stays per device, using the web's keys and values (no server change).
