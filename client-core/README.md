# client-core

The Rust core shared by the native Omnigent clients. Apple uses it now. Android (UniFFI/Kotlin)
and the web (WASM) can use it later. The core holds all logic that does not need an OS SDK.
The host app supplies I/O, and owns UI and platform features.

## Crates

| Crate | Role |
|---|---|
| `omnigent-protocol` | serde wire models (currently the `/.well-known/omnigent.json` manifest). No I/O. |
| `omnigent-core` | Sans-IO client logic: URL normalization, request building, response mapping, `ClientCore<T: HttpTransport>`. |
| `omnigent-ffi` | UniFFI surface (proc-macros, no UDL). Mirror types plus `From` conversions; no logic. Builds `staticlib`/`cdylib`/`lib`. |
| `uniffi-bindgen` | `uniffi-bindgen` built from the workspace's pinned `uniffi`, so the generated bindings always match the runtime. |

`fixtures/` holds JSON shared by the Rust, Swift and (later) web tests.

## Sans-IO and the host-trait contract

`omnigent-protocol` and `omnigent-core` must not use tokio, threads, `std::time::Instant`, or any
I/O. Every side effect goes through a host trait, and CI checks them for `wasm32-unknown-unknown`.

`HttpTransport::send(HttpRequest) -> Result<HttpResponse, TransportError>`:

- Return every HTTP status as a response, including 3xx, 4xx and 5xx. Do **not** follow redirects.
  The core decides what a redirect means.
- Do not add cookies, credentials or caching that the request did not ask for.
- Use `TransportError` only when there is no response at all. Report the kind accurately
  (`Offline`, `Timeout`, `Cancelled`, `Tls`, `Other`) and include the platform's message. The
  core passes the kind and message to the caller and never collapses them into one generic error.
- Timeouts are the host's job. The manifest fetch expects a short one (the old shell used 5 s).

Errors are never swallowed. Every failure reaches the caller as a typed `CoreError`. A few cases
have meaning defined by the server contract, and those are mapped explicitly. For example, a
manifest 404, or an older server's SPA catch-all answering with HTML, means "pre-manifest
server". That case yields a `ServerDiscovery` with `auth_mode: None`.

## Building

The toolchain is pinned in `rust-toolchain.toml`.

```sh
cd client-core
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo check -p omnigent-core -p omnigent-protocol --target wasm32-unknown-unknown
cargo deny check
```

For Apple, run `apps/apple/scripts/build-core.sh [debug|release] [--sim-only|--all-slices]`. It
builds the static libraries and generates the Swift bindings. It then assembles
`apps/apple/Packages/OmnigentCoreFFI/omnigent_ffiFFI.xcframework` and copies
`omnigent_ffi.swift` into that package. By default, debug builds only the iOS simulator and
host-macOS slices. Release builds the iOS device and simulator slices plus a universal macOS
slice. Neither output is checked in. Test the result with
`swift test --package-path apps/apple/Packages/OmnigentCoreFFI`.

The generated Swift target builds in the Swift 5 language mode. UniFFI 0.32.2's async
foreign-trait runtime captures non-Sendable closures in a `Task`. Swift 6 rejects that, and no
`uniffi.toml` option changes it. The module's public types are `Sendable`, so Swift 6 clients
still get full checking.

## Lints

The workspace lints in `Cargo.toml` apply to every crate: rustc `missing_docs`,
`unreachable_pub` and others, plus clippy `pedantic`, `nursery` and `cargo`. Several
panic-prone lints are denied: `unwrap_used`, `expect_used`, `panic`, `indexing_slicing` and
`as_conversions`. `clippy.toml` relaxes the panic-related ones in tests only. Every `#[allow]`
must carry a `reason`.

## FFI change rules

- The FFI surface in `omnigent-ffi` is a contract with Swift. Renaming or removing an exported
  item, field or variant breaks the apps. Change it in the same PR as the Swift callers.
- Keep logic out of `omnigent-ffi`. Add it to `omnigent-core` with tests there, then expose it
  through a mirror type and a `From` conversion.
- Adding a variant to an exported enum is a breaking change for exhaustive Swift `switch`es.
  Wire enums keep an `Unknown { .. }` variant so that new server values never map onto a known
  one.
- Async foreign traits use `#[uniffi::export(with_foreign)]` together with
  `#[async_trait::async_trait]` and need `Send + Sync`. Errors returned by a foreign trait must
  implement `From<uniffi::UnexpectedUniFFICallbackError>`.
- `uniffi` is pinned to an exact version (`=0.32.2`). The bindgen and the runtime must match, so
  bump both by changing the workspace dependency only. Then rerun `build-core.sh` and
  `swift test`, and check whether the Swift 5 mode workaround above can go.

## Ported test cases

| Swift source | Rust tests |
|---|---|
| `web/ios/OmnigentTests/ServerURLTests.swift` | `omnigent-core` `server_url::tests` |
| `web/ios/OmnigentTests/ServerManifestTests.swift` (parsing) | `omnigent-protocol` `manifest::tests` |
| `web/ios/OmnigentTests/ServerManifestTests.swift` (fetch/status) | `omnigent-core` `client::tests` |

Some behavior intentionally differs from the Swift oracle. An unknown auth mode is kept as
`AuthMode::Unknown` instead of dropping the auth block. Malformed JSON, a non-numeric
`manifest_version`, a non-JSON and non-HTML content type, and any non-2xx status other than 404
are errors rather than the silent baseline. Cancellation and redirect blocking belong to the
host transport.
