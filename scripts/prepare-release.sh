#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

app=${1:?Usage: prepare-release.sh /path/to/Langg.app version}
version=${2:?Missing version}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use a numeric major.minor.patch version.' >&2; exit 1; }
[[ "$app" = /* ]] || app="$PWD/$app"
[[ -d "$app" && ! -L "$app" ]] || { echo 'Pass the real application bundle.' >&2; exit 1; }
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$identifier" == app.langg.Langg && "$actual_version" == "$version" ]] || { echo 'Application identity or version does not match.' >&2; exit 1; }
codesign --verify --deep --strict "$app"
for architecture in arm64 x86_64; do
    xcrun lipo -verify_arch "$architecture" "$app/Contents/MacOS/Langg"
done

output="$PWD/dist/$version"
[[ ! -e "$output" ]] || { echo 'The release directory already exists. Keep published versions immutable.' >&2; exit 1; }
stage=$(mktemp -d "${TMPDIR:-/tmp}/langg-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Langg.app"
archive="Langg-$version-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$stage/Langg.app" "$stage/$archive"
if [[ -n "${LANGG_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$stage/$archive" --keychain-profile "$LANGG_NOTARY_PROFILE" --wait
    xcrun stapler staple "$stage/Langg.app"
    ditto -c -k --sequesterRsrc --keepParent "$stage/Langg.app" "$stage/$archive"
elif [[ "${LANGG_ALLOW_UNNOTARIZED:-0}" != 1 ]]; then
    echo 'Set LANGG_NOTARY_PROFILE, or explicitly choose LANGG_ALLOW_UNNOTARIZED=1.' >&2
    exit 1
fi

installer="Langg-$version-macOS.dmg"
mkdir "$stage/.installer"
bash scripts/create-dmg.sh "$stage/Langg.app" "$version" "$stage/.installer/$installer"

tools=${LANGG_SPARKLE_TOOLS:-}
if [[ -z "$tools" ]]; then
    scratch=${LANGG_SCRATCH_PATH:-"${TMPDIR:-/tmp}/langg-native-app-build-$UID"}
    for candidate in ".build/artifacts/sparkle/Sparkle/bin" "$scratch/arm64/artifacts/sparkle/Sparkle/bin" "$scratch/x86_64/artifacts/sparkle/Sparkle/bin"; do
        if [[ -x "$candidate/generate_appcast" ]]; then tools="$candidate"; break; fi
    done
fi
[[ -x "$tools/generate_appcast" ]] || { echo 'Resolve the Sparkle package before preparing a release.' >&2; exit 1; }
signing=(--account "${LANGG_SPARKLE_ACCOUNT:-app.langg.Langg}")
if [[ -n "${LANGG_SPARKLE_KEY_FILE:-}" ]]; then signing=(--ed-key-file "$LANGG_SPARKLE_KEY_FILE"); fi
rm -rf "$stage/Langg.app"
"$tools/generate_appcast" "${signing[@]}" --download-url-prefix "https://github.com/frlvv/Langg/releases/download/v$version/" --link 'https://github.com/frlvv/Langg' "$stage"
[[ -s "$stage/appcast.xml" ]] || { echo 'No signed update feed was generated.' >&2; exit 1; }
mv "$stage/.installer/$installer" "$stage/$installer"
rmdir "$stage/.installer"
python3 scripts/export-source.py "$stage/Langg-$version-source.zip"
(cd "$stage" && shasum -a 256 "$installer" "$archive" "Langg-$version-source.zip" appcast.xml > SHA256SUMS)
mkdir -p "$(dirname "$output")"
mv "$stage" "$output"
trap - EXIT
printf 'Release files: %s\n' "$output"
