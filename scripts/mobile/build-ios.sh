#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
core=${SFERA_CORE_DIR:-"$root/core"}
if [[ ! -d $core/bindings/mobile && -d $root/bindings/mobile ]]; then core=$root; fi
target_dir=${CARGO_TARGET_DIR:-"$root/artifacts/mobile-rust"}
output=${SFERA_IOS_OUTPUT:-"$root/artifacts/mobile-ios"}
mode=${1:-unsigned}
mkdir -p "$output"
cd "$core"

case $mode in
    simulator)
        if [[ $(uname -m) == arm64 ]]; then target=aarch64-apple-ios-sim; else target=x86_64-apple-ios; fi
        sdk=iphonesimulator
        ;;
    unsigned|signed)
        target=aarch64-apple-ios
        sdk=iphoneos
        ;;
    *) echo "Usage: build-ios.sh simulator|unsigned|signed" >&2; exit 2 ;;
esac
SDKROOT=$(xcrun --sdk "$sdk" --show-sdk-path) IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    CARGO_TARGET_DIR="$target_dir" cargo build --locked --release \
    --manifest-path bindings/mobile/Cargo.toml --target "$target"
xcodegen generate --spec "$root/mobile/ios/project.yml"

options=(-project "$root/mobile/ios/SFERA.xcodeproj" -scheme SFERA
    -configuration Release -derivedDataPath "$output/DerivedData"
    "SFERA_CORE_DIR=$core"
    "SFERA_NATIVE_LIB=$target_dir/$target/release/libsfera_mobile.a"
    "CURRENT_PROJECT_VERSION=${SFERA_BUILD_NUMBER:-1}")
if [[ $mode == simulator ]]; then
    xcodebuild "${options[@]}" -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
elif [[ $mode == unsigned ]]; then
    xcodebuild "${options[@]}" -destination 'generic/platform=iOS' \
        -archivePath "$output/SFERA.xcarchive" CODE_SIGNING_ALLOWED=NO archive
    ditto -c -k --keepParent "$output/SFERA.xcarchive" "$output/SFERA-iOS-unsigned.xcarchive.zip"
else
    xcodebuild "${options[@]}" -destination 'generic/platform=iOS' \
        -archivePath "$output/SFERA.xcarchive" CODE_SIGN_STYLE=Manual \
        "DEVELOPMENT_TEAM=${SFERA_APPLE_TEAM_ID:?}" "CODE_SIGN_IDENTITY=Apple Distribution" \
        "SFERA_APP_PROFILE=${SFERA_APP_PROFILE:?}" "SFERA_TUNNEL_PROFILE=${SFERA_TUNNEL_PROFILE:?}" archive
    xcodebuild -exportArchive -archivePath "$output/SFERA.xcarchive" \
        -exportPath "$output/export" -exportOptionsPlist "${SFERA_IOS_EXPORT_OPTIONS:?}"
    cp "$output/export/SFERA.ipa" "$output/SFERA-iOS.ipa"
fi
