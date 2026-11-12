#!/bin/bash
set -euo pipefail
platform=${1:?Expected android, ios or windows}
revision=${RELEASE_COMMIT:?}
repository=${GITHUB_REPOSITORY:?}
number=${GITHUB_RUN_NUMBER:?}
[[ $revision =~ ^[a-f0-9]{40}$ && $number =~ ^[0-9]+$ ]]
shopt -s nullglob
case $platform in
  android)
    assets=(SFERA-Android*.apk)
    title="SFERA Android"
    if [[ -f SFERA-Android-debug.apk ]]; then
      note="The debug APK is installable. Its signing key may change between runs."
    else
      note="The APK is signed with the project distribution key."
    fi
    ;;
  ios)
    assets=(SFERA-iOS*)
    title="SFERA iOS"
    if [[ -f SFERA-iOS.ipa ]]; then
      note="The signed IPA is for App Store Connect and TestFlight."
    else
      note="The unsigned XCArchive cannot be installed on an iPhone."
    fi
    ;;
  windows)
    assets=(SFERA-Windows-x64.zip)
    [[ -f ${assets[0]} ]]
    title="SFERA Windows"
    note="Extract the full archive and open SFERA.exe. Windows 11 x64 is required."
    ;;
  *) exit 2 ;;
esac
[[ ${#assets[@]} == 1 ]]
sha256sum "${assets[@]}" > SHA256SUMS
tag="$platform-$number"
if draft=$(gh release view "$tag" --repo "$repository" --json isDraft --jq .isDraft 2>/dev/null); then
  if [[ $draft == true ]]; then
    gh release upload "$tag" "${assets[@]}" SHA256SUMS --repo "$repository" --clobber
    gh release edit "$tag" --repo "$repository" --draft=false
  fi
  exit 0
fi
printf 'Built from commit `%s`.\n\n%s\n' "$revision" "$note" > notes.md
gh release create "$tag" "${assets[@]}" SHA256SUMS --repo "$repository" \
  --target "$revision" --title "$title $number" --prerelease --notes-file notes.md
