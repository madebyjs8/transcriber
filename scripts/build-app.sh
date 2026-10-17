#!/usr/bin/env bash
# Builds build/Transcriber.app (release, Apple Silicon).
#
# Signing: uses $SIGN_IDENTITY if set (e.g. an Apple Development certificate), otherwise a
# local self-signed identity from scripts/setup-signing.sh (created on first build), so
# macOS keeps the app's Accessibility and Microphone permissions across rebuilds.
# Set SIGN_IDENTITY=- for ad-hoc signing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Transcriber.app"
cd "$ROOT"

if [ ! -f vendor/lib/libwhisper.a ]; then
    ./scripts/build-whisper.sh
fi

echo "==> Compiling Transcriber (release)"
swift build -c release --product Transcriber

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Transcriber "$APP/Contents/MacOS/Transcriber"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> Signing with $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
    ./scripts/setup-signing.sh
    SIGNING="$ROOT/.signing"
    KEYCHAIN="$SIGNING/signing.keychain-db"
    security unlock-keychain -p "$(cat "$SIGNING/password")" "$KEYCHAIN"

    # codesign only looks in keychains on the user's search list. Add ours for this one
    # call and always put the original list back, even if signing fails.
    ORIGINAL=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#\"}"
        line="${line%\"}"
        [ -n "$line" ] && ORIGINAL+=("$line")
    done < <(security list-keychains -d user)
    trap 'security list-keychains -d user -s "${ORIGINAL[@]}"' EXIT
    security list-keychains -d user -s "${ORIGINAL[@]}" "$KEYCHAIN"

    echo "==> Signing with local identity $(cat "$SIGNING/identity")"
    codesign --force --sign "$(cat "$SIGNING/identity")" "$APP"

    security list-keychains -d user -s "${ORIGINAL[@]}"
    trap - EXIT
fi
codesign --verify "$APP"

echo "==> Done: $APP"
