#!/bin/bash
set -euo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
signing=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sfera-signing.XXXXXX")
keychain="$signing/sfera.keychain-db"
password=$(openssl rand -hex 24)
cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    python3 - "$signing" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}
trap cleanup EXIT

printf '%s' "${SFERA_IOS_P12_B64:?}" | base64 -D > "$signing/distribution.p12"
printf '%s' "${SFERA_IOS_APP_PROFILE_B64:?}" | base64 -D > "$signing/app.mobileprovision"
printf '%s' "${SFERA_IOS_TUNNEL_PROFILE_B64:?}" | base64 -D > "$signing/tunnel.mobileprovision"
for target in app tunnel; do
    security cms -D -i "$signing/$target.mobileprovision" > "$signing/$target.plist"
done
python3 - "$signing" <<'PY'
from pathlib import Path
import plistlib, re, shutil, sys

work = Path(sys.argv[1])
profile_dir = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
records = {}
for target, bundle in (("app", "dev.sfera.client"), ("tunnel", "dev.sfera.client.tunnel")):
    with (work / f"{target}.plist").open("rb") as stream:
        profile = plistlib.load(stream)
    team = profile["TeamIdentifier"][0]
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SystemExit("Unexpected Apple team identifier")
    entitlements = profile["Entitlements"]
    if ("ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices") or
            entitlements.get("get-task-allow") or
            entitlements.get("application-identifier") != f"{team}.{bundle}" or
            "packet-tunnel-provider" not in entitlements.get("com.apple.developer.networking.networkextension", []) or
            not any(group in {f"{team}.*", f"{team}.dev.sfera.client.shared"}
                    for group in entitlements.get("keychain-access-groups", []))):
        raise SystemExit(f"Use an App Store distribution profile for {bundle} with Network Extension and shared Keychain")
    uuid = profile["UUID"]
    if not re.fullmatch(r"[a-fA-F0-9-]{36}", uuid):
        raise SystemExit("Unexpected provisioning profile UUID")
    records[bundle] = (team, uuid, target)
teams = {value[0] for value in records.values()}
if len(teams) != 1:
    raise SystemExit("Both targets must use the same Apple Developer team")

profile_dir.mkdir(parents=True, exist_ok=True)
for _, uuid, target in records.values():
    shutil.copyfile(work / f"{target}.mobileprovision", profile_dir / f"{uuid}.mobileprovision")
    (work / f"{target}-uuid").write_text(uuid)
team = teams.pop()
(work / "team").write_text(team)
with (work / "export.plist").open("wb") as stream:
    plistlib.dump({
        "method": "app-store-connect",
        "destination": "export",
        "signingStyle": "manual",
        "teamID": team,
        "provisioningProfiles": {bundle: value[1] for bundle, value in records.items()},
    }, stream)
PY
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 14400 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$signing/distribution.p12" -k "$keychain" -P "${SFERA_IOS_P12_PASSWORD:?}" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
SFERA_APPLE_TEAM_ID=$(cat "$signing/team") \
SFERA_APP_PROFILE=$(cat "$signing/app-uuid") \
SFERA_TUNNEL_PROFILE=$(cat "$signing/tunnel-uuid") \
SFERA_IOS_EXPORT_OPTIONS="$signing/export.plist" "$script_dir/build-ios.sh" signed
