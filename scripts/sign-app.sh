#!/usr/bin/env bash
set -euo pipefail

app_path=${1:?Usage: sign-app.sh /path/to/Langg.app}
identity=${LANGG_SIGNING_IDENTITY:-}

if [[ "$identity" == "-" ]]; then
    echo 'Ad-hoc signing changes app identity on every update. Use a persistent certificate.' >&2
    exit 1
fi

if [[ -z "$identity" ]]; then
    # Keep the local identity outside build/ and the repository: clean builds and
    # app updates must never generate another certificate behind the user's back.
    signing_dir=${LANGG_SIGNING_DIR:-"$HOME/Library/Application Support/Langg/Signing"}
    keychain="$signing_dir/local.keychain-db"
    password_file="$signing_dir/keychain-password"
    fingerprint_file="$signing_dir/certificate-sha1"
    umask 077
    if [[ ! -e "$signing_dir" ]]; then
        mkdir -p "$signing_dir"
        /usr/bin/openssl rand -hex 32 > "$password_file"
        cat > "$signing_dir/certificate.cnf" <<'EOF'
[req]
distinguished_name = name
x509_extensions = extensions
prompt = no
[name]
CN = Langg Local Development
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
        /usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -days 36500 \
            -config "$signing_dir/certificate.cnf" -keyout "$signing_dir/private-key.pem" \
            -out "$signing_dir/certificate.pem" >/dev/null 2>&1
        signing_password=$(cat "$password_file")
        /usr/bin/openssl pkcs12 -export -inkey "$signing_dir/private-key.pem" \
            -in "$signing_dir/certificate.pem" -out "$signing_dir/identity.p12" \
            -passout "pass:$signing_password"
        security create-keychain -p "$signing_password" "$keychain"
        security unlock-keychain -p "$signing_password" "$keychain"
        security import "$signing_dir/identity.p12" -k "$keychain" \
            -P "$signing_password" -T /usr/bin/codesign >/dev/null
        security set-key-partition-list -S apple-tool:,apple: -s \
            -k "$signing_password" "$keychain" >/dev/null
        /usr/bin/openssl x509 -in "$signing_dir/certificate.pem" -noout -fingerprint -sha1 \
            | sed 's/.*=//; s/://g' > "$fingerprint_file"
        # Only the protected keychain retains the private key after import.
        unlink "$signing_dir/private-key.pem"
        unlink "$signing_dir/identity.p12"
        echo 'Created persistent local signing identity (no system trust settings changed).' >&2
    fi
    if [[ ! -f "$keychain" || ! -s "$password_file" || ! -s "$fingerprint_file" ]]; then
        echo "Signing identity is incomplete at $signing_dir. Restore it; it will not be silently replaced." >&2
        exit 1
    fi
    identity=$(cat "$fingerprint_file")
    security unlock-keychain -p "$(cat "$password_file")" "$keychain"
    trap 'security lock-keychain "$keychain" >/dev/null 2>&1 || true' EXIT
    signing_options=(--force --sign "$identity" --keychain "$keychain" --timestamp=none)
else
    signing_options=(--force --sign "$identity" --options runtime --timestamp)
fi

sparkle="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$sparkle" ]]; then
    for component in "$sparkle/Autoupdate" "$sparkle/Updater.app" \
        "$sparkle/XPCServices/Downloader.xpc" "$sparkle/XPCServices/Installer.xpc" \
        "$app_path/Contents/Frameworks/Sparkle.framework"; do
        codesign "${signing_options[@]}" --preserve-metadata=identifier,entitlements "$component"
    done
fi
codesign "${signing_options[@]}" "$app_path"
codesign --verify --deep --strict "$app_path"
