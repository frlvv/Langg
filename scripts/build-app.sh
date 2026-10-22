#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

output=${1:-"/Applications/Langg.app"}
if [[ "$output" != /* ]]; then output="$PWD/$output"; fi
if [[ -L "$output" ]]; then
    echo 'Use the real installation path rather than a symbolic link.' >&2
    exit 1
fi
if [[ -d "$output" ]]; then
    previous_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output/Contents/Info.plist")
    if [[ "$previous_identifier" != app.langg.Langg ]]; then
        echo 'The destination contains a different application; it was kept.' >&2
        exit 1
    fi
fi
mkdir -p "$(dirname "$output")"
build_lock="$output.build-lock"
if ! mkdir "$build_lock" 2>/dev/null; then
    echo "Another build owns $build_lock. Wait for it to finish." >&2
    exit 1
fi
trap 'rmdir "$build_lock" 2>/dev/null || true' EXIT
app_is_running() {
    # comm contains the executable path without arguments, including for login
    # launches or diagnostics started with additional command-line arguments.
    ps -axo comm= | /usr/bin/grep -Fx -- "$output/Contents/MacOS/Langg" >/dev/null
}
if app_is_running; then
    echo 'Quit the running app before replacing it, or provide a different output path.' >&2
    exit 1
fi
configuration=${LANGG_BUILD_CONFIGURATION:-release}
scratch=${LANGG_SCRATCH_PATH:-"${TMPDIR:-/tmp}/langg-native-app-build-$UID"}
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-"${TMPDIR:-/tmp}/langg-clang-cache-$UID"}
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
# Link against the installed SDK while retaining the package's deployment target.
read -r -a architectures <<< "${LANGG_BUILD_ARCHS:-$(uname -m)}"
binaries=()
framework_path=""
for architecture in "${architectures[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) echo 'Unsupported architecture.' >&2; exit 1 ;; esac
    build_scratch="$scratch/$architecture"
    build_options=(--build-system native --sdk "$sdk_path" --arch "$architecture" -c "$configuration" --disable-sandbox --scratch-path "$build_scratch")
    swift build "${build_options[@]}"
    bin_path=$(swift build "${build_options[@]}" --show-bin-path)
    linked_sdk=$(xcrun vtool -show-build "$bin_path/Langg" | awk '$1 == "sdk" { print $2; exit }')
    if [[ "$linked_sdk" != "$sdk_version" ]]; then
        echo "Incorrect linked SDK: $linked_sdk (expected $sdk_version). The existing app was kept." >&2
        exit 1
    fi
    binaries+=("$bin_path/Langg")
    framework_path="$build_scratch/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
done
if [[ ! -d "$framework_path" ]]; then echo 'Sparkle framework is missing.' >&2; exit 1; fi
stage=$(mktemp -d "${TMPDIR:-/tmp}/langg-package.XXXXXX")
app="$stage/Langg.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
if [[ ${#binaries[@]} -eq 1 ]]; then
    cp "${binaries[0]}" "$app/Contents/MacOS/Langg"
else
    xcrun lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Langg"
fi
ditto "$framework_path" "$app/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
ditto Resources/Brand "$app/Contents/Resources/Brand"
cp Resources/Sparkle-LICENSE.txt "$app/Contents/Resources/Sparkle-LICENSE.txt"
# Bundles copied from an iCloud-backed project must not carry Finder metadata
# into the sealed app. Never strip attributes from the sources or installed app.
xattr -cr "$app"
bash scripts/sign-app.sh "$app"

if app_is_running; then
    echo 'The app was opened during the build. The running copy was kept.' >&2
    exit 1
fi

if [[ -d "$output" ]]; then
    previous_requirement=$(codesign -d -r- "$output" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p')
    if [[ -z "$previous_requirement" ]]; then
        echo 'Cannot verify the previous app identity; the existing app was kept.' >&2
        exit 1
    elif [[ "$previous_requirement" == cdhash* ]]; then
        echo 'One-time migration from ad-hoc signing: macOS may require granting permissions again.' >&2
    elif ! codesign --verify --strict --test-requirement "=$previous_requirement" "$app"; then
        echo 'Signing identity changed. The existing app was kept to preserve permissions.' >&2
        exit 1
    fi
    backup_dir="$HOME/Library/Application Support/Langg/Backups"
    mkdir -p "$backup_dir"
    previous_app="$backup_dir/Langg.$(date +%Y%m%d-%H%M%S).$$.backup"
    mv "$output" "$previous_app"
    if ! mv "$app" "$output"; then
        mv "$previous_app" "$output"
        exit 1
    fi
else
    mv "$app" "$output"
fi
if ! codesign --verify --strict "$output"; then
    mv "$output" "$stage/Langg.failed.app"
    if [[ -n "${previous_app:-}" ]]; then mv "$previous_app" "$output"; fi
    echo 'The destination changed the app signature. Use ~/Applications outside synced folders.' >&2
    exit 1
fi
rmdir "$stage"
printf 'Built %s\n' "$output"
