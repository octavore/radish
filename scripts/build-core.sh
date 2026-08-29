#!/bin/bash
#
# Builds the Rust core and generates its Swift bindings.
#
# Everything the Swift app needs from Rust lands in target/uniffi/:
#
#   librd_core.a                              linked by the RepoDocs target
#   rd                                        copied into the app bundle
#   Sources/RepoDocsCore/rd_core.swift        generated bindings
#   Sources/rd_coreFFI/include/rd_coreFFI.h   generated C header
#   Sources/rd_coreFFI/include/module.modulemap
#
# Set ARCHS to build a universal binary, matching strudel.toml's [build] archs:
#
#   ARCHS="arm64 x86_64" scripts/build-core.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)

archs=${ARCHS:-$(uname -m)}
out="$root/target/uniffi"
mkdir -p "$out"

triple_for() {
  case "$1" in
    arm64 | aarch64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *)
      echo "build-core.sh: unknown arch '$1'" >&2
      exit 1
      ;;
  esac
}

triples=()
for arch in $archs; do
  triples+=("$(triple_for "$arch")")
done

for triple in "${triples[@]}"; do
  echo "==> cargo build --release --target $triple"
  cargo build --release --target "$triple" -p rd-core -p rd
done

# lipo is a no-op joiner for one arch, so the same path handles both cases.
libs=()
bins=()
for triple in "${triples[@]}"; do
  libs+=("$root/target/$triple/release/librd_core.a")
  bins+=("$root/target/$triple/release/rd")
done

echo "==> lipo -> $out"
lipo -create "${libs[@]}" -output "$out/librd_core.a"
lipo -create "${bins[@]}" -output "$out/rd"

# Bindings are arch-independent, so generate from whichever cdylib we built
# first. --library mode reads the metadata compiled into the library itself,
# which is why there is no .udl file to keep in sync.
echo "==> uniffi-bindgen"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
# Built for the host, not --target: this one runs here. It only reads the
# library, and goblin parses any arch.
cargo run --release --quiet -p rd-core --bin uniffi-bindgen -- \
  generate --library "$root/target/${triples[0]}/release/librd_core.dylib" \
  --language swift --no-format --out-dir "$staging"

mkdir -p "$root/Sources/RepoDocsCore" "$root/Sources/rd_coreFFI/include"
mv "$staging/rd_core.swift" "$root/Sources/RepoDocsCore/rd_core.swift"
mv "$staging/rd_coreFFI.h" "$root/Sources/rd_coreFFI/include/rd_coreFFI.h"
# uniffi emits a modulemap named after the crate; SwiftPM only looks for
# module.modulemap inside a target's include directory.
mv "$staging/rd_coreFFI.modulemap" "$root/Sources/rd_coreFFI/include/module.modulemap"

echo "==> core ready in target/uniffi"
