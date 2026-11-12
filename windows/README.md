# SFERA для Windows

Поддерживается Windows 11 x64. Скачайте `SFERA-Windows-x64.zip` из [релизов клиента](https://github.com/SFERA-TUN/sfera-client/releases), распакуйте папку целиком и запустите `SFERA.exe`. Windows запросит права администратора для создания адаптера Wintun и настройки маршрутов. Среда .NET включена в архив.

1. На Mac откройте **Сервер → Пользователи** и экспортируйте отдельный JSON-профиль для Windows.
2. В приложении для Windows нажмите **Импортировать профиль** и выберите JSON. Приложение хранит профиль в данных пользователя и защищает его через Windows DPAPI.
3. Нажмите **Подключить VPN**. Для завершения нажмите **Отключить VPN** или закройте окно.

Чтобы настроить исключения, при отключённом VPN откройте **Сайты без VPN**. Включите общий переключатель, выберите готовый набор или добавьте домены и URL по одному на строку. Адреса вычисляются при подключении. Сайты на общем IPv4 используют один маршрут, а поддомены добавляются отдельно. После смены адресов переподключитесь.

Клиент работает с существующим сервером SFERA. Установка и управление VPS выполняются через приложение macOS. Транспорт переносит IPv4, а глобальный IPv6 направляется в адаптер и отбрасывается. VPN задаёт DNS-серверы на своём адаптере. Браузер может использовать собственный DNS и получить другие адреса для исключений.

## Сборка на Windows

Нужны .NET SDK 10, Rust через `rustup` и Visual Studio Build Tools с компонентом C++ для MSVC. Из корня `sfera-client`:

```powershell
git clone https://github.com/SFERA-TUN/sfera-server.git core
git -C core checkout --detach (Get-Content core.ref -Raw).Trim()
Push-Location core
rustup target add x86_64-pc-windows-msvc
cargo build --locked --release --target x86_64-pc-windows-msvc --bin sfera-net
Pop-Location
.\scripts\package-windows.ps1 -Transport .\core\target\x86_64-pc-windows-msvc\release\sfera-net.exe -Output .\SFERA-Windows-x64.zip
```

Скрипт сверяет SHA-256 официального архива [Wintun](https://www.wintun.net/) и включает DLL x64 вместе с лицензией. Workflow **Windows build and release** публикует архив и контрольную сумму при push в `main`.
