//! The `uniffi-bindgen` CLI, built from this crate so the generator version can
//! never drift from the `uniffi` runtime the library was compiled against.
//! `scripts/build-core.sh` runs it in `--library` mode against the cdylib.

fn main() {
    uniffi::uniffi_bindgen_main()
}
