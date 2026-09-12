#!/usr/bin/env bash
# Builds a self-contained macOS application bundle at vx-ui/build/vx.app.
#
# Run from anywhere in the repository with:
#
#   Scripts/package-app.sh
#
# The bundle includes the release Swift app, Rust transcription backend, UI
# sounds, icon, and (by default) the tiny English Whisper model. Set
# VX_SKIP_MODEL=1 to avoid copying the roughly 78 MB model when repackaging;
# without a bundled model, the app safely prompts the user to download one on
# first launch. SKIP_PUBLISH is accepted for compatibility with callers that
# use the same command before a publishing step, but this repository has no
# publishing step and the variable has no effect.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/vx-ui/build/vx.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT/vx-rs"
cargo build --release

cd "$ROOT/vx-ui"
# Keep this a release build: #Preview blocks are guarded by DEBUG, while their
# PreviewsMacros plugin is unavailable when only Command Line Tools is installed.
swift build -c release

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES/Backend" "$RESOURCES/Models"

cp "$ROOT/vx-ui/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/vx-ui/.build/release/vx-ui" "$MACOS/vx"
cp "$ROOT/vx-ui/Resources/vx.icns" "$RESOURCES/vx.icns"
cp "$ROOT/vx-ui/Resources/start.mp3" "$RESOURCES/start.mp3"
cp "$ROOT/vx-ui/Resources/transcribe.mp3" "$RESOURCES/transcribe.mp3"
cp "$ROOT/vx-rs/target/release/vx-rs" "$RESOURCES/Backend/vx-rs"
chmod +x "$RESOURCES/Backend/vx-rs"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# CFBundleExecutable is what ties a running process back to the bundle. Without it
# macOS still launches the app by falling back to CFBundleName, but TCC cannot
# match the process to the app the user authorised, so Accessibility and
# Microphone grants silently never apply.
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string vx' "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string vx' "$CONTENTS/Info.plist"
if [[ -n "${VX_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VX_VERSION" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VX_VERSION" "$CONTENTS/Info.plist"
fi

if [[ "${VX_SKIP_MODEL:-}" != "1" ]]; then
  MODEL="$($ROOT/Scripts/ensure-model.sh)"
  cp "$MODEL" "$RESOURCES/Models/"
fi

if otool -L "$MACOS/vx" | awk 'NR > 1 { print $1 }' | grep -qx '@rpath/libVXLib.dylib'; then
  cp "$ROOT/vx-ui/.build/release/libVXLib.dylib" "$MACOS/"
fi

# macOS keys Accessibility and Microphone grants to the code signature. An
# unsigned bundle receives a new identity on every build, forcing re-grants;
# ad-hoc signing gives locally packaged builds a stable identity.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "[vx] Packaged app: $APP"
echo "[vx] Install with: cp -R \"$APP\" /Applications/  (or open it in place)"
