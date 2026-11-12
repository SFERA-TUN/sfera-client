# SFERA Client

Native clients for macOS 14+, Android 8+ (arm64 and x86_64) and iOS 17+. All three use the Rust transport from [SFERA Server](https://github.com/SFERA-TUN/sfera-server).

macOS installs and manages a self-hosted VPS over SSH. On Android and iOS, import the JSON profile exported for your device, then choose **Подключить VPN**. The mobile transport carries IPv4. The token stays in Android app-private storage or the iOS Keychain.

## Build locally

```sh
git clone https://github.com/SFERA-TUN/sfera-server.git core
git -C core checkout --detach "$(cat core.ref)"
(cd core && cargo build --locked --release --bin sfera-net)
scripts/build-selfhost-macos.sh
```

For Android, use JDK 17, Gradle 8.11.1, SDK 35 and NDK 28.1.13356709. Set `ANDROID_HOME` to the SDK directory and install Rust targets `aarch64-linux-android` and `x86_64-linux-android` with the toolchain pinned by `core`. Run `scripts/mobile/build-android.sh assembleDebug`.

For iOS, use Xcode with the iOS platform, XcodeGen 2.46.0 and Rust target `aarch64-apple-ios`. Run `scripts/mobile/build-ios.sh unsigned`. For a simulator build, use `simulator` and install `aarch64-apple-ios-sim` on Apple Silicon.

## GitHub releases

A merge into `main` builds both platforms from the merged commit and publishes `android-<run number>` and `ios-<run number>` prereleases with SHA-256 checksums as soon as each platform finishes. Pull requests build both clients with read-only permissions. Run **Mobile build and release** on `main` for the initial build or a manual rebuild.

Without signing credentials, the workflow publishes an installable Android debug APK and an unsigned iOS XCArchive. Debug APK signatures can differ between runs. An unsigned XCArchive cannot be installed on an iPhone.

| Platform | GitHub Actions secrets |
| --- | --- |
| Android | `ANDROID_KEYSTORE_B64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` |
| iOS | `IOS_P12_B64`, `IOS_P12_PASSWORD`, `IOS_APP_PROFILE_B64`, `IOS_TUNNEL_PROFILE_B64` |

Use the same Android distribution key across releases. For iOS, supply an Apple Distribution certificate and App Store distribution profiles for `dev.sfera.client` and `dev.sfera.client.tunnel`. Both IDs need Packet Tunnel and the shared Keychain group `<Team ID>.dev.sfera.client.shared`. The signed IPA is for App Store Connect and TestFlight. The pipeline rejects Ad Hoc profiles because public assets must not include registered device IDs.
