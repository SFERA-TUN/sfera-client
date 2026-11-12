#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
core=${SFERA_CORE_DIR:-"$root/core"}
if [[ ! -d $core/bindings/mobile && -d $root/bindings/mobile ]]; then core=$root; fi
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:?Set ANDROID_SDK_ROOT}}
ndk=${ANDROID_NDK_HOME:-"$sdk/ndk/28.1.13356709"}
if [[ $(uname -s) == Darwin ]]; then host=darwin-x86_64; else host=linux-x86_64; fi
toolchain="$ndk/toolchains/llvm/prebuilt/$host/bin"
target_dir=${CARGO_TARGET_DIR:-"$root/artifacts/mobile-rust"}
out="$root/mobile/android/app/build/sfera-jni"

cd "$core"
for target in aarch64-linux-android x86_64-linux-android; do
    case $target in
        aarch64-linux-android) abi=arm64-v8a; variable=AARCH64_LINUX_ANDROID ;;
        x86_64-linux-android) abi=x86_64; variable=X86_64_LINUX_ANDROID ;;
    esac
    compiler="$toolchain/${target}26-clang"
    env "CARGO_TARGET_${variable}_LINKER=$compiler" "CC_${target//-/_}=$compiler" \
        "AR_${target//-/_}=$toolchain/llvm-ar" "CARGO_TARGET_DIR=$target_dir" \
        cargo build --locked --release --manifest-path bindings/mobile/Cargo.toml --target "$target"
    mkdir -p "$out/$abi"
    "$compiler" -shared -fPIC -fvisibility=hidden -O2 -Wl,--exclude-libs,ALL \
        -Wl,-z,max-page-size=16384 -Wl,--no-undefined -Wl,-soname,libsfera_android.so \
        -I"$core/bindings/mobile/include" "$root/mobile/android/app/src/main/cpp/sfera_jni.c" \
        "$target_dir/$target/release/libsfera_mobile.a" -ldl -llog -lm \
        -o "$out/$abi/libsfera_android.so"
done

gradle -p "$root/mobile/android" "${1:-assembleDebug}"
