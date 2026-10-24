#!/bin/sh
# Compiles Relay, installs it in /Applications and launches it.
# Only Apple's "Command Line Tools" are needed (xcode-select --install).
set -eu
cd "$(dirname "$0")"

APP=build/Relay.app
CERT="Relais Local"
# Keychain reserved for the signing key, protected by its own password.
# It is only unlocked while signing: no other program can therefore sign
# with this key to pass itself off as Relay.
KEYCHAIN="$HOME/Library/Keychains/relay-signing.keychain-db"
LOGIN="$HOME/Library/Keychains/login.keychain-db"

# 1. Build
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos14" \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Relay"
cp Info.plist "$APP/Contents/Info.plist"

# 2. Signing keychain and certificate, created only once.
# macOS ties permissions (Accessibility…) to the signature: with a fixed
# certificate, they stay valid from one build to the next.
# The certificate is self-signed and never leaves the Mac.
if [ ! -f "$KEYCHAIN" ]; then
    # Unreleased 1.0 builds kept the key in the login keychain, usable
    # without a password: delete it.
    security delete-identity -c "$CERT" "$LOGIN" 2>/dev/null || true

    cat <<'TEXT'

== Password for Relay's signing key ==

macOS ties Relay's permissions (Accessibility, and Screen Recording if you
turn previews on) to the key that signs the app. To keep other programs from
using that key to pass themselves off as Relay and borrow these permissions,
the key is stored in its own keychain, locked with a password.

Choose that password now. You will be asked for it each time you build or
update Relay. Pick one you can easily remember, or save it in your password
manager. If you ever lose it, delete
~/Library/Keychains/relay-signing.keychain-db and build again: a new key is
created and macOS asks for Relay's permissions again.

When you type a password in Terminal, NOTHING is displayed, not even dots.
This is normal. Type it, then press Enter.

TEXT
    echo "Choose the password, then type it again to confirm (invisible, then Enter):"
    security create-keychain "$KEYCHAIN"
    # Locks itself after 5 minutes and on sleep.
    security set-keychain-settings -l -u -t 300 "$KEYCHAIN"
    # codesign only finds a key in a keychain on the search list.
    # shellcheck disable=SC2046
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"
fi

echo ""
echo "Password of Relay's signing keychain, to sign the app."
echo "(Nothing is displayed while you type. Press Enter when done.)"
security unlock-keychain "$KEYCHAIN"
# Locked again as soon as the script ends, even on error.
trap 'security lock-keychain "$KEYCHAIN" 2>/dev/null || true' EXIT

if ! security find-certificate -c "$CERT" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Creating the \"$CERT\" certificate…"
    TMP=$(mktemp -d)
    cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $CERT
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -config "$TMP/cert.cfg" -extensions ext \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -name "$CERT" -passout pass:relais \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12"
    security import "$TMP/cert.p12" -P relais -T /usr/bin/codesign -k "$KEYCHAIN"
    rm -rf "$TMP"
    # Keeps codesign from showing a confirmation window at each signature.
    echo ""
    echo "Same password once more, to let codesign use the new key."
    echo "(Nothing is displayed while you type. Press Enter when done.)"
    security set-key-partition-list -S apple-tool:,apple: -s "$KEYCHAIN" >/dev/null
    # The signature changes: clear Relay's old permissions.
    tccutil reset Accessibility local.relais || true
    tccutil reset ScreenCapture local.relais || true
fi

# 3. Signing, with the "hardened runtime": macOS then refuses to inject
# code into Relay (DYLD_INSERT_LIBRARIES, unsigned libraries…).
codesign --force --options runtime --keychain "$KEYCHAIN" --sign "$CERT" "$APP"
security lock-keychain "$KEYCHAIN"
codesign --verify --strict "$APP"

# 4. Install and launch
pkill -x Relay || true
pkill -x Relais || true          # ancien nom de l'app
sleep 1
rm -rf /Applications/Relay.app /Applications/Relais.app
mv "$APP" /Applications/
open /Applications/Relay.app
echo "OK: Relay is installed and running."
