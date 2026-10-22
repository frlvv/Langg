#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

app=${1:?Usage: create-dmg.sh /path/to/Langg.app version /path/to/output.dmg}
version=${2:?Missing version}
output=${3:?Missing destination}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use a numeric major.minor.patch version.' >&2; exit 1; }
[[ "$app" = /* ]] || app="$PWD/$app"
[[ "$output" = /* ]] || output="$PWD/$output"
[[ ! -e "$output" ]] || { echo 'Destination already exists.' >&2; exit 1; }
[[ -d "$app" && ! -L "$app" ]] || { echo 'Pass the real application bundle.' >&2; exit 1; }
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$identifier" == app.langg.Langg && "$actual_version" == "$version" ]] || { echo 'Application identity or version does not match.' >&2; exit 1; }
codesign --verify --deep --strict "$app"

stage=$(mktemp -d "${TMPDIR:-/tmp}/langg-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/contents"
ditto "$app" "$stage/contents/Langg.app"
ln -s /Applications "$stage/contents/Applications"
cp Resources/INSTALL.txt "$stage/contents/Установка.txt"
hdiutil create -quiet -volname "Langg $version" -fs HFS+ -format UDZO \
    -srcfolder "$stage/contents" "$stage/Langg.dmg"
hdiutil verify -quiet "$stage/Langg.dmg"
mkdir -p "$(dirname "$output")"
mv "$stage/Langg.dmg" "$output"
printf 'Installer: %s\n' "$output"
