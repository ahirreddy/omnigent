default:
    @just --list

export FASTLANE_SKIP_UPDATE_CHECK := "1"

# iOS simulator name override (default: an available iPhone, preferring a booted one)
DEVICE := env("OMNIGENT_IOS_SIMULATOR", "")

# --- uv Python env ---

_check-uv:
    uv run --no-sync ruff --version
    uv run --no-sync pyrefly --version
    uv run --no-sync pre-commit --version

_ensure-uv:
    uv sync --extra all --group dev

# Installs the pre-commit and pre-push git hooks (see default_install_hook_types
# in .pre-commit-config.yaml). Worktrees share the main checkout's .git, so one
# install covers all of them.
_ensure-hooks: _ensure-uv
    uv run --no-sync pre-commit install

# --- iOS Ruby dependencies ---

_check-ios:
    cd web/ios && bundle check

_ensure-ios:
    cd web/ios && (bundle check || bundle install)

# --- omnidev Rust dev tool ---

_install-omnidev:
    cargo install --path dev/omnidev --locked --force

_check-omnidev:
    command -v omnidev >/dev/null 2>&1

_ensure-omnidev:
    command -v omnidev >/dev/null 2>&1 || just _install-omnidev

# --- Aggregate setup checks / installs ---

[group('setup')]
check: _check-uv _check-ios _check-omnidev

[group('setup')]
ensure: _ensure-uv _ensure-hooks _ensure-ios _ensure-omnidev

# --- Local dev ---

[group('dev')]
dev: _ensure-omnidev
    omnidev

[group('dev')]
dev-mobile: _ensure-omnidev
    omnidev --vite-host 0.0.0.0 --trust-lan-origins

[group('dev')]
crdb-up:
    docker compose -f deploy/cockroachdb/docker-compose.yml up -d --wait --wait-timeout 90
    docker compose -f deploy/cockroachdb/docker-compose.yml exec -T crdb-23-2-28 cockroach sql --insecure --execute="SET CLUSTER SETTING sql.txn.read_committed_isolation.enabled = true"

[group('dev')]
crdb-stop:
    docker compose -f deploy/cockroachdb/docker-compose.yml stop

[group('dev')]
crdb-test: crdb-up
    ./scripts/test_crdb_matrix.sh

# Destructive: stops CRDB and deletes all four persistent development volumes.
[group('dev')]
crdb-reset:
    docker compose -f deploy/cockroachdb/docker-compose.yml down --volumes

# --- Mobile builds ---

[group('mobile')]
run-ios: _ensure-ios
    cd web/ios && bundle exec fastlane simulator device:"{{ DEVICE }}"

[group('mobile')]
run-android:
    cd web/android && ./gradlew installDebug runDebug

[group('mobile')]
android-reverse:
    cd web/android && ./gradlew reverseProxy

# --- Web ---

_ensure-web:
    cd web && test -d node_modules || pnpm install

[group('web')]
storybook: _ensure-web
    pnpm --filter web run storybook

[group('web')]
storybook-build: _ensure-web
    pnpm --filter web run build:storybook

[group('web')]
generate-theme-palettes: _ensure-web
    cd web && node --experimental-strip-types scripts/generate-theme-palettes.mjs

# --- Electron desktop app ---

_ensure-electron:
    cd web/electron && test -d node_modules || pnpm install

[group('electron')]
electron-dev: _ensure-web _ensure-electron
    pnpm --filter ./web/electron run dev

[group('electron')]
electron-build: _ensure-web _ensure-electron
    pnpm --filter ./web/electron run build

# Build (if needed) and launch the development package (reads dev-domain prefs).
# Flags: --rebuild (force a fresh build even if one exists),
#        --v2-flow (force the new server-selector wizard on),
#        --reset-state (first uninstall the CLI + wipe app data for a fresh
#                       user; destructive, asks for confirmation).
[group('electron')]
electron-run *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    # Validate flags and get reset confirmation BEFORE any side effect (dep
    # install, build, quitting the app), so declining leaves the machine
    # untouched.
    [ "$(uname)" = "Darwin" ] || { echo "electron-run is macOS-only (managed-prefs testing); build with 'just electron-build' and open the app for your OS."; exit 1; }
    # just delivers variadic args via {{flags}} substitution; put them into
    # positional params so the loop treats each as one datum. (Local dev recipe:
    # the caller already has shell access, so this isn't a trust boundary.)
    set -- {{flags}}
    rebuild=0; v2=0; reset_state=0
    for f in "$@"; do
        case "$f" in
            --rebuild) rebuild=1 ;;
            --v2-flow) v2=1 ;;
            --reset-state) reset_state=1 ;;
            *) echo "unknown flag: $f (supported: --rebuild, --v2-flow, --reset-state)"; exit 2 ;;
        esac
    done
    if [ "$reset_state" = 1 ]; then
        echo "--reset-state will UNINSTALL the omnigent CLI and remove the desktop"
        echo "app's data (session cookies, recent servers) for a fresh-user test."
        read -r -p 'Type "yes" to proceed: ' reply
        [ "$reply" = "yes" ] || { echo "Aborted."; exit 1; }
    fi
    # Pick the bundle for THIS machine's architecture (electron-builder emits both
    # mac-arm64 and mac-x64/mac); a bare glob could launch the wrong one on Intel.
    case "$(uname -m)" in
        arm64) archdir="mac-arm64" ;;
        *) archdir="mac" ;;  # electron-builder names the x64 output "mac"
    esac
    find_app() { ls -d "web/electron/dist-dev/$archdir/Omnigent Dev.app" 2>/dev/null | head -1 || true; }
    app="$(find_app)"
    if [ "$rebuild" = 1 ] || [ -z "$app" ]; then
        echo "Building the packaged app (this takes a few minutes)…"
        just _ensure-web _ensure-electron
        pnpm --filter ./web/electron run build
        app="$(find_app)"
    fi
    [ -n "$app" ] || { echo "No $archdir build found after building."; exit 1; }
    echo "Quitting any running Omnigent Dev…"
    osascript -e 'quit app "Omnigent Dev"' 2>/dev/null || true
    pkill -x 'Omnigent Dev' 2>/dev/null || true
    sleep 1
    if [ "$reset_state" = 1 ]; then
        # Uninstall the CLI. The shared uninstaller exits non-zero both when no
        # install exists (fine) and on a genuine failure (e.g. removal blocked) —
        # and its exit codes don't distinguish those. So verify the OUTCOME
        # instead: after running it, if the binary is still resolvable the
        # uninstall really failed — abort BEFORE deleting data or launching, so a
        # half-reset can't masquerade as a clean fresh-user state.
        sh scripts/uninstall_oss.sh cli --yes || true
        hash -r 2>/dev/null || true
        if command -v omnigent >/dev/null 2>&1; then
            echo "CLI uninstall did not remove 'omnigent' (still on PATH). Aborting" >&2
            echo "before touching app data. Remove it manually, then retry." >&2
            exit 1
        fi
        # Wipe the desktop app data directly so a fresh-user reset works even with
        # no CLI installed (the uninstaller's global guard skips desktop-data in
        # that case). Intentional destroy — see the confirmation above.
        rm -rf "$HOME/Library/Application Support/Omnigent Dev" \
               "$HOME/Library/Caches/Omnigent Dev" \
               "$HOME/Library/Logs/Omnigent Dev"
    fi
    if [ "$v2" = 1 ]; then
        echo "Launching $app (v2 flow forced)"
        open -n "$app" --env OMNIGENT_SERVER_SELECTOR_V2=1
    else
        echo "Launching $app"
        open -n "$app"
    fi

#   set <url>[,<url>...] [--internal]   offer servers; --internal sets databricksInternalFeaturesEnabled
#   import                              copy this Mac's MDM values for the release app
#   show | clear
# Relaunch to apply. Real MDM profiles and release builds are untouched.
# Test managed preferences for local builds (ai.omnigent.desktop-dev).
[group('electron')]
[positional-arguments]
electron-mdm cmd="show" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    [ "$(uname)" = "Darwin" ] || { echo "electron-mdm is macOS-only."; exit 1; }
    domain=ai.omnigent.desktop-dev
    managed="/Library/Managed Preferences/ai.omnigent.desktop.plist"
    usage="usage: just electron-mdm [set <url>[,<url>...] [--internal] | import | show | clear]"
    unset_all() {
        defaults delete "$domain" serverUrls 2>/dev/null || true
        defaults delete "$domain" databricksInternalFeaturesEnabled 2>/dev/null || true
    }
    cmd="${1:-show}"
    shift || true
    case "$cmd" in
        set)
            [ $# -ge 1 ] || { echo "$usage"; exit 2; }
            IFS=',' read -ra urls <<< "$1"
            shift
            internal=0
            for f in "$@"; do
                case "$f" in
                    --internal) internal=1 ;;
                    *) echo "unknown flag: $f"; echo "$usage"; exit 2 ;;
                esac
            done
            unset_all
            defaults write "$domain" serverUrls -array "${urls[@]}"
            [ "$internal" = 0 ] || defaults write "$domain" databricksInternalFeaturesEnabled -bool true
            ;;
        import)
            [ -r "$managed" ] || { echo "No managed preferences for ai.omnigent.desktop on this Mac."; exit 1; }
            # import merges, so drop the old values first for an exact copy.
            unset_all
            defaults import "$domain" "$managed"
            ;;
        clear) unset_all ;;
        show) ;;
        *) echo "$usage"; exit 2 ;;
    esac
    for key in serverUrls databricksInternalFeaturesEnabled; do
        printf '%s = ' "$key"
        defaults read "$domain" "$key" 2>/dev/null || echo "(unset)"
    done

# --- Native Apple client (client-core Rust + apps/apple) ---
# macOS (OmnigentMac) is the primary target; iOS/iPad recipes carry an -ios
# suffix. See apps/apple/README.md.

# iOS simulator for the apple-*-ios recipes (override per call or via env).
APPLE_SIMULATOR := env("OMNIGENT_APPLE_SIMULATOR", "iPhone 17 Pro")
APPLE_WORKSPACE := "apps/apple/Omnigent.xcworkspace"
# Under the root .gitignore's `build/` rule.
APPLE_DERIVED_DATA := "apps/apple/build/DerivedData"
# CEF slice for Debug builds (the host arch); Release distribution uses `universal`.
APPLE_CEF_ARCH := env("OMNIGENT_CEF_ARCH", if arch() == "aarch64" { "arm64" } else { "x86_64" })

# Rust core: format check, clippy (warnings are errors), and the full test suite.
[group('client')]
core-test:
    cd client-core && cargo fmt --all --check
    cd client-core && cargo clippy --workspace --all-targets -- -D warnings
    cd client-core && cargo test --workspace

# Type-check the platform-neutral core crates for wasm32 (no JS facade yet).
[group('client')]
core-wasm-check:
    cd client-core && cargo check -p omnigent-core -p omnigent-protocol --target wasm32-unknown-unknown

# config: debug | release; flags: e.g. --sim-only.
# Build the Rust xcframework and regenerate the Swift UniFFI bindings.
[group('client')]
apple-core config="debug" *flags:
    bash apps/apple/scripts/build-core.sh {{ config }} {{ flags }}

# Build the debug core, fetch the pinned CEF and libghostty, resolve Tuist dependencies, and generate the workspace.
[group('client')]
apple-generate:
    bash apps/apple/scripts/build-core.sh debug
    bash apps/apple/scripts/fetch-cef.sh --arch {{ APPLE_CEF_ARCH }}
    bash apps/apple/scripts/fetch-ghostty.sh
    cd apps/apple && mise exec -- tuist install
    cd apps/apple && mise exec -- tuist generate --no-open

_ensure-apple:
    test -d {{ APPLE_WORKSPACE }} || just apple-generate

# Build the macOS desktop app, Developer ID edition (OmnigentMac, Chromium + WebKit).
[group('client')]
apple-build: _ensure-apple
    xcodebuild build -workspace {{ APPLE_WORKSPACE }} -scheme OmnigentMac \
        -destination 'platform=macOS' -derivedDataPath {{ APPLE_DERIVED_DATA }}

# Build the Mac App Store edition (OmnigentMacAppStore: App Sandbox, WebKit only, no CEF).
[group('client')]
apple-build-appstore: _ensure-apple
    xcodebuild build -workspace {{ APPLE_WORKSPACE }} -scheme OmnigentMacAppStore \
        -destination 'platform=macOS' -derivedDataPath {{ APPLE_DERIVED_DATA }}

# Build the iOS/iPad app (Omnigent) for a simulator.
[group('client')]
apple-build-ios device=APPLE_SIMULATOR: _ensure-apple
    xcodebuild build -workspace {{ APPLE_WORKSPACE }} -scheme Omnigent \
        -destination 'platform=iOS Simulator,name={{ device }}' -derivedDataPath {{ APPLE_DERIVED_DATA }}

# Runs `swift test` for every apps/apple/Packages/* that has a Tests dir.
# Swift package tests, then the Developer ID app's hosted tests (UI tests: apple-test-ui).
[group('client')]
apple-test: _ensure-apple
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    for pkg in apps/apple/Packages/*/; do
        if [ -d "$pkg/Tests" ]; then
            echo "==> swift test --package-path $pkg"
            swift test --package-path "$pkg"
        fi
    done
    xcodebuild test -workspace {{ APPLE_WORKSPACE }} -scheme OmnigentMac \
        -destination 'platform=macOS' -derivedDataPath {{ APPLE_DERIVED_DATA }} \
        -skip-testing:OmnigentMacUITests

# Line coverage of the Apple packages from their fast tests; pass --package NAME, --files or --uncovered TEXT.
apple-coverage *flags: _ensure-apple
    python3 apps/apple/Tools/coverage.py {{ flags }}

# Hosted tests of the Mac App Store edition (inside its sandboxed app).
[group('client')]
apple-test-appstore: _ensure-apple
    xcodebuild test -workspace {{ APPLE_WORKSPACE }} -scheme OmnigentMacAppStore \
        -destination 'platform=macOS' -derivedDataPath {{ APPLE_DERIVED_DATA }} \
        -skip-testing:OmnigentMacAppStoreUITests

# Both Mac editions' UI tests; they take the real mouse and keyboard, so run on an idle Mac.
[group('client')]
apple-test-ui: _ensure-apple
    #!/usr/bin/env bash
    set -euo pipefail
    for pair in OmnigentMac:OmnigentMacUITests OmnigentMacAppStore:OmnigentMacAppStoreUITests; do
        xcodebuild test -workspace {{ APPLE_WORKSPACE }} -scheme "${pair%%:*}" \
            -destination 'platform=macOS' -derivedDataPath {{ APPLE_DERIVED_DATA }} \
            -only-testing:"${pair##*:}"
    done

# device: simulator name or UDID; filter: a class or Class/testMethod (default: all).
# iOS/iPad UI tests on a simulator against the local server, seeding their fixture session first.
[group('client')]
apple-uitest-ios device=APPLE_SIMULATOR filter="": _ensure-apple
    #!/usr/bin/env bash
    set -euo pipefail
    read -r session workspace < <(.venv/bin/python apps/apple/Tools/seed-ui-test-fixtures.py)
    if [[ "{{ device }}" =~ ^[0-9A-Fa-f-]{36}$ ]]; then key=id; else key=name; fi
    TEST_RUNNER_OMNIGENT_UITEST_SESSION="$session" \
    TEST_RUNNER_OMNIGENT_UITEST_WORKSPACE="$workspace" \
    TEST_RUNNER_OMNIGENT_E2E_SERVER_URL="http://127.0.0.1:6767" \
    TEST_RUNNER_OMNIGENT_LINK_SESSION_ID="$session" \
    TEST_RUNNER_OMNIGENT_FILES_SESSION_ID="$session" \
    TEST_RUNNER_OMNIGENT_GLASS_SESSION_ID="$session" \
    xcodebuild test -workspace {{ APPLE_WORKSPACE }} -scheme Omnigent \
        -destination "platform=iOS Simulator,$key={{ device }}" \
        -derivedDataPath {{ APPLE_DERIVED_DATA }}-iOS \
        -only-testing:"OmnigentUITests{{ if filter == "" { "" } else { "/" + filter } }}"

# filter: a class or Class/testMethod (default: all). Takes the real mouse and keyboard.
# The Developer ID app's UI tests, or some of them (`apple-test-ui` runs both editions').
[group('client')]
apple-uitest-mac filter="": _ensure-apple
    xcodebuild test -workspace {{ APPLE_WORKSPACE }} -scheme OmnigentMac \
        -destination 'platform=macOS' -derivedDataPath {{ APPLE_DERIVED_DATA }} \
        -only-testing:"OmnigentMacUITests{{ if filter == "" { "" } else { "/" + filter } }}"

# Strict SwiftLint over apps/apple (config: apps/apple/.swiftlint.yml).
[group('client')]
apple-lint:
    cd apps/apple && mise exec -- swiftlint lint --strict --config .swiftlint.yml

# Test the iOS/iPad app (Omnigent) on a simulator.
[group('client')]
apple-test-ios device=APPLE_SIMULATOR: _ensure-apple
    xcodebuild test -workspace {{ APPLE_WORKSPACE }} -scheme Omnigent \
        -destination 'platform=iOS Simulator,name={{ device }}' -derivedDataPath {{ APPLE_DERIVED_DATA }}

# Prints the built .app path for a scheme/destination (read from xcodebuild).
_apple-app-path scheme destination:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild -showBuildSettings -json -workspace {{ APPLE_WORKSPACE }} -scheme {{ scheme }} \
        -destination '{{ destination }}' -derivedDataPath {{ APPLE_DERIVED_DATA }} \
        | python3 -c '
    import json, sys
    apps = [t["buildSettings"] for t in json.load(sys.stdin) if t["buildSettings"].get("WRAPPER_EXTENSION") == "app"]
    if len(apps) != 1:
        sys.exit(f"expected exactly one app target, found {len(apps)}")
    s = apps[0]
    print(s["TARGET_BUILD_DIR"] + "/" + s["WRAPPER_NAME"])
    '

# Build and launch the macOS desktop app.
[group('client')]
apple-run: apple-build
    #!/usr/bin/env bash
    set -euo pipefail
    app="$(just _apple-app-path OmnigentMac 'platform=macOS')"
    echo "Launching $app"
    open -n "$app"

alias apple-run-mac := apple-run

# flags: --release (optimized, for daily use), --skip-prereqs, --no-launch, --full-priority.
# Build the Mac app (Debug by default, ad hoc signed) and install it as ~/Applications/Omnigent Native.app.
[group('client')]
apple-install-local *flags:
    bash apps/apple/scripts/install-local.sh {{ flags }}

# Build and launch the Mac App Store edition.
[group('client')]
apple-run-appstore: apple-build-appstore
    #!/usr/bin/env bash
    set -euo pipefail
    app="$(just _apple-app-path OmnigentMacAppStore 'platform=macOS')"
    echo "Launching $app"
    open -n "$app"

# Build, install, and launch the iOS app on a simulator (booting it if needed).
[group('client')]
apple-run-ios device=APPLE_SIMULATOR: (apple-build-ios device)
    #!/usr/bin/env bash
    set -euo pipefail
    destination='platform=iOS Simulator,name={{ device }}'
    app="$(just _apple-app-path Omnigent "$destination")"
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
    # bootstatus -b boots the device if needed and waits until it is usable.
    xcrun simctl bootstatus "{{ device }}" -b
    open -a Simulator
    xcrun simctl install "{{ device }}" "$app"
    xcrun simctl launch "{{ device }}" "$bundle_id"

# Isolated local API + host LaunchAgents (install|start|status|stop|uninstall).
[group('client')]
[positional-arguments]
apple-services *args:
    bash apps/apple/Tools/local-services.sh "$@"

# Mock LLM on 127.0.0.1:6796 that streams a canned markdown reply to every turn (foreground).
[group('client')]
apple-mock-model:
    .venv/bin/python apps/apple/Tools/mock-model.py serve

# Install the "mock-model" agent on the local API; it answers through apple-mock-model.
[group('client')]
apple-mock-agent:
    .venv/bin/python apps/apple/Tools/mock-model.py install-agent

# Seed the local API with stored test conversations (no model calls).
[group('client')]
apple-seed:
    .venv/bin/python apps/apple/Tools/seed-local-fixtures.py

# Seed 320 sessions in six projects and three 500+ turn transcripts for profiling (no model calls).
[group('client')]
[positional-arguments]
apple-seed-large *args:
    .venv/bin/python apps/apple/Tools/seed-large-fixtures.py "$@"

# Timed Mac app scenarios (launch, open, switch, stream) with a main-thread hitch monitor.
[group('client')]
[positional-arguments]
apple-perf *args:
    .venv/bin/python apps/apple/Tools/perf/perf.py "$@"

# Fails unless SSE text arrives in several temporally separated chunks. Known
# to fail today (single-chunk delivery); never weaken or fake it.
# Strict real-model streaming gate (needs apple-services and a signed-in harness).
[group('client')]
apple-smoke-stream:
    .venv/bin/python apps/apple/Tools/smoke-live-chat.py --create-session --send-test-prompt \
        --require-incremental --evidence-dir "${TMPDIR:?TMPDIR is not set}/omni-streaming"

# --- Lint ---

[group('lint')]
lint: _ensure-uv
    uv run --no-sync pre-commit run

[group('lint')]
lint-all: _ensure-uv
    uv run --no-sync pre-commit run --all-files

# Install (or reinstall) the git hooks without the rest of `just ensure`.
[group('lint')]
hooks: _ensure-hooks

[group('lint')]
typecheck-python: _ensure-uv
    uv run --no-sync pyrefly check

[group('lint')]
lint-ts:
    pnpm install --frozen-lockfile --filter web --filter omnigent-vscode
    pnpm --filter web run lint
    pnpm --filter web run type-check
    pnpm --filter omnigent-vscode run type-check

# --- Lockfile maintenance ---

[group('lint')]
normalize-locks: _ensure-uv
    uv run --no-sync scripts/normalize_uv_lock_registry.py uv.lock || true

# Resolve the declared dependencies through a package mirror without writing
# uv.lock; fails when a floor needs a release the mirror does not serve yet.
# Dependency groups resolve too, so a dev-only gap can fail it as well.
# No `_ensure-uv`: its `uv sync` would re-resolve and rewrite uv.lock first.
[group('lint')]
check-internal-mirror index="https://pypi-proxy.cloud.databricks.com/simple":
    uv lock --dry-run --default-index {{ index }}
