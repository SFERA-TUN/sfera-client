#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
app=${1:-"$HOME/Applications/SFERA.app"}
core=${SFERA_CORE_DIR:-"$root"}
if [[ ! -f $core/Cargo.toml ]]; then core="$root/core"; fi
binary=${SFERA_MAC_BINARY:-"$core/target/release/sfera-net"}
[[ $app == /* && $(basename -- "$app") == *.app ]] || { echo "Use an absolute .app path." >&2; exit 1; }
[[ -x $binary ]] || { echo "Build sfera-net first: cargo build --release --locked --bin sfera-net" >&2; exit 1; }

arch=$(uname -m)
parent=$(dirname -- "$app")
mkdir -p "$parent"
staging=$(mktemp -d "$parent/.sfera-build.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
bundle="$staging/$(basename -- "$app")"
mkdir -p "$bundle/Contents/"{MacOS,Resources}
install -m 0755 "$binary" "$bundle/Contents/Resources/sfera-net"
install -m 0644 "$root/root-helper.py" "$root/macos/service-helper.py" "$bundle/Contents/Resources/"
install -m 0644 "$root/macos/Selfhost/Info.plist" "$bundle/Contents/Info.plist"
swiftc -swift-version 6 -parse-as-library -target "$arch-apple-macosx14.0" -O -D SFERA_SELFHOST \
  "$root/macos/SferaTest.swift" "$root/macos/Selfhost/"*.swift -o "$bundle/Contents/MacOS/SFERA"
xattr -cr "$bundle"
codesign --force --deep --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
if [[ -e $app ]]; then
  mv -- "$app" "$staging/previous.app"
fi
if ! mv -- "$bundle" "$app"; then
  if [[ -e $staging/previous.app ]]; then
    mv -- "$staging/previous.app" "$app"
  fi
  exit 1
fi
printf 'Built %s\n' "$app"
