# Сборка SFERA

Начните из корня клона [sfera-client](https://github.com/SFERA-TUN/sfera-client). Для всех платформ используется одна закреплённая ревизия транспорта.

```sh
git clone https://github.com/SFERA-TUN/sfera-server.git core
git -C core checkout --detach "$(cat core.ref)"
```

## macOS

Нужны Xcode Command Line Tools и Rust через `rustup`. Соберите транспорт и приложение:

```sh
(cd core && cargo build --locked --release --bin sfera-net)
scripts/build-selfhost-macos.sh
```

По умолчанию скрипт сохраняет приложение в `~/Applications/SFERA.app`. Можно передать другой абсолютный путь к `.app` первым аргументом.

## Android

Нужны JDK 17, Gradle 8.11.1, Android SDK 35 и NDK 28.1.13356709. Укажите путь к SDK в `ANDROID_HOME`. Если NDK установлен отдельно, укажите его путь в `ANDROID_NDK_HOME`.

```sh
(cd core && rustup target add aarch64-linux-android x86_64-linux-android)
scripts/mobile/build-android.sh assembleDebug
```

Результат — `mobile/android/app/build/outputs/apk/debug/app-debug.apk`.

## iOS

Нужны Xcode с платформой iOS, XcodeGen 2.46.0 и Rust через `rustup`.

```sh
(cd core && rustup target add aarch64-apple-ios)
scripts/mobile/build-ios.sh unsigned
```

Результат — `artifacts/mobile-ios/SFERA-iOS-unsigned.xcarchive.zip`. Для симулятора на Apple Silicon добавьте цель Rust `aarch64-apple-ios-sim` и запустите скрипт с аргументом `simulator`. Для Intel используйте `x86_64-apple-ios`.

Чтобы запустить приложение на iPhone, после сборки откройте `mobile/ios/SFERA.xcodeproj`. Добавьте два пользовательских параметра сборки для цели **SFERATunnel** с абсолютными путями:

| Параметр | Путь от корня репозитория |
| --- | --- |
| `SFERA_CORE_DIR` | `core` |
| `SFERA_NATIVE_LIB` | `artifacts/mobile-rust/aarch64-apple-ios/release/libsfera_mobile.a` |

В **Signing & Capabilities** выберите одну команду Apple Developer для целей SFERA и SFERATunnel. Профили подписи должны разрешать Packet Tunnel и общую группу Keychain. Выберите подключённый iPhone и запустите схему SFERA. При запросе включите на iPhone режим разработчика.

Для публикации через TestFlight нужны сертификат Apple Distribution и два профиля App Store Distribution: `dev.sfera.client` и `dev.sfera.client.tunnel`. Обоим идентификаторам нужны Packet Tunnel и общая группа Keychain `<Team ID>.dev.sfera.client.shared`.

## Публикация через GitHub Actions

Проверка PR собирает Android и iOS без секретов. При push в `main` workflow публикует отдельные пререлизы `android-<номер запуска>` и `ios-<номер запуска>` с файлами `SHA256SUMS`. Для ручного запуска выберите **Mobile build and release** на ветке `main`.

| Платформа | Секреты репозитория |
| --- | --- |
| **Android** | `ANDROID_KEYSTORE_B64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` |
| **iOS** | `IOS_P12_B64`, `IOS_P12_PASSWORD`, `IOS_APP_PROFILE_B64`, `IOS_TUNNEL_PROFILE_B64` |

Без секретов Android получает APK с отладочной подписью. Ключ такой сборки может меняться между запусками. Для обновления установленного релизного APK используйте один и тот же ключ подписи. Без секретов iOS получает неподписанный XCArchive. Подписанный IPA предназначен для App Store Connect и TestFlight. Workflow отклоняет профили Ad Hoc, чтобы идентификаторы устройств не попали в публичные артефакты.

[Вернуться к README](../README.md)
