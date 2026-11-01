# Third-party notices: OmnigentTerminalUI and OmnigentGhosttyKit

## Ghostty (libghostty / GhosttyKit)

Source: https://github.com/manaflow-ai/ghostty (a fork of https://github.com/ghostty-org/ghostty),
commit `2c1a19d7e4fae25ed2224da65592215c9013c785`, built by `apps/apple/scripts/fetch-ghostty.sh`.

Linked as `GhosttyKit.xcframework`. Several files in this package adapt code from Ghostty's macOS
app (`macos/Sources/Ghostty/`), and each one says so in its header:

- `Sources/OmnigentTerminalUI/Ghostty/GhosttyRuntime.swift`
- `Sources/OmnigentTerminalUI/Ghostty/TerminalSurfaceController*.swift`
- `Sources/OmnigentTerminalUI/Platform/TerminalSurfaceNSView*.swift`
- `Sources/OmnigentTerminalUI/Platform/TerminalSurfaceUIView.swift` (surface sizing only)

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The GhosttyKit static library also contains the third-party code Ghostty vendors under `pkg/`
and `build.zig.zon`, each under its own license as listed in the Ghostty source tree. That
includes glslang, SPIRV-Cross, FreeType, HarfBuzz, Oniguruma, simdutf, Highway, Wuffs, zlib,
libpng and Dear ImGui. It also embeds the JetBrains Mono and Nerd Fonts Symbols fonts (SIL Open
Font License 1.1). Sentry is not linked: `fetch-ghostty.sh` builds with `-Dsentry=false`. The
apps' acknowledgements must include these notices; generate them from the pinned Ghostty
source.

## Chromium keycode table

`Sources/OmnigentTerminalUI/Platform/HIDKeyCodes.swift` is generated from Ghostty's
`src/input/keycodes.zig`, which is based on Chromium's
`ui/events/keycodes/dom/dom_code_data.inc`:

```
Copyright 2013 The Chromium Authors
Use of this source code is governed by a BSD-style license (BSD-3-Clause):
https://source.chromium.org/chromium/chromium/src/+/main:LICENSE
```
