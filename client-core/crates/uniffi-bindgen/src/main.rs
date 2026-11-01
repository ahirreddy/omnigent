//! `uniffi-bindgen` built from the workspace's `uniffi`, so generated bindings always match the
//! runtime linked into `omnigent-ffi`.

#![allow(
    clippy::multiple_crate_versions,
    reason = "uniffi 0.32 depends on both syn 2 and syn 3; not fixable from this workspace"
)]

fn main() {
    uniffi::uniffi_bindgen_main();
}
