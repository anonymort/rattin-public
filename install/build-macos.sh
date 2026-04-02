#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build-macos"
SHELL_BUILD_DIR="$REPO_ROOT/shell/build-macos"
APP_NAME="Rattin"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
ZIP_OUTPUT="$REPO_ROOT/${APP_NAME}-macOS-$(uname -m).zip"

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

log()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
die()  { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

brew_prefix() {
    brew --prefix "$1" 2>/dev/null || true
}

clear_bundle_metadata() {
    local bundle="$1"
    find "$bundle" -exec sh -c '
        for path do
            xattr -d com.apple.FinderInfo "$path" 2>/dev/null || true
            xattr -d "com.apple.fileprovider.fpfs#P" "$path" 2>/dev/null || true
        done
    ' sh {} +
}

patch_qtwebengine_helper() {
    local bundle="$1"
    local helper_app="$bundle/Contents/Frameworks/QtWebEngineCore.framework/Versions/A/Helpers/QtWebEngineProcess.app"
    local helper_contents="$helper_app/Contents"
    local helper_exec="$helper_contents/MacOS/QtWebEngineProcess"

    [ -f "$helper_exec" ] || die "QtWebEngine helper not found at $helper_exec"

    codesign --remove-signature "$helper_exec" >/dev/null 2>&1 || true
    codesign --remove-signature "$helper_app" >/dev/null 2>&1 || true

    rm -rf "$helper_contents/Frameworks"
    ln -s ../../../../../.. "$helper_contents/Frameworks"

    while IFS= read -r dep; do
        case "$dep" in
            /opt/homebrew/*/Qt*.framework/*|/usr/local/*/Qt*.framework/*)
                framework="$(printf '%s\n' "$dep" | sed -E 's#.*/(Qt[^/]+)\.framework/Versions/A/.*#\1#')"
                [ -n "$framework" ] || continue
                install_name_tool -change "$dep" \
                    "@executable_path/../Frameworks/${framework}.framework/Versions/A/${framework}" \
                    "$helper_exec"
                ;;
        esac
    done < <(otool -L "$helper_exec" | tail -n +2 | awk '{print $1}')

    if otool -L "$helper_exec" | grep -E '(/opt/homebrew|/usr/local).*/Qt[^/]+\.framework' >/dev/null 2>&1; then
        die "QtWebEngine helper still references Homebrew Qt frameworks"
    fi
}

usage() {
    cat <<'EOF'
Usage: build-macos.sh [--clean]

Builds a local macOS app bundle for Rattin.

Prerequisites:
  brew install cmake pkgconf qt qtwebengine mpv ffmpeg node@20

This produces:
  build-macos/Rattin.app
  Rattin-macOS-<arch>.zip

Notes:
  - This is a source build for your local machine.
  - A signed/notarized public release still needs Apple credentials.
  - VPN routing remains Linux-only.
EOF
}

CLEAN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "This script must be run on macOS."

for cmd in brew xcodebuild cmake pkg-config ditto; do
    require_cmd "$cmd"
done

NODE20_PREFIX="$(brew_prefix node@20)"
if [ -n "$NODE20_PREFIX" ] && [ -x "$NODE20_PREFIX/bin/node" ]; then
    NODE_BIN="$NODE20_PREFIX/bin/node"
    NPM_BIN="$NODE20_PREFIX/bin/npm"
    NPX_BIN="$NODE20_PREFIX/bin/npx"
else
    require_cmd node
    require_cmd npm
    require_cmd npx
    NODE_BIN="$(command -v node)"
    NPM_BIN="$(command -v npm)"
    NPX_BIN="$(command -v npx)"
fi

NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 20 ] || die "Node.js 20+ is required."

QT_PREFIX="$(brew_prefix qt)"
QTWEBENGINE_PREFIX="$(brew_prefix qtwebengine)"
MPV_PREFIX="$(brew_prefix mpv)"
FFMPEG_PREFIX="$(brew_prefix ffmpeg)"

[ -n "$QT_PREFIX" ] || die "Homebrew formula 'qt' is not installed."
[ -n "$QTWEBENGINE_PREFIX" ] || die "Homebrew formula 'qtwebengine' is not installed."
[ -n "$MPV_PREFIX" ] || die "Homebrew formula 'mpv' is not installed."
[ -n "$FFMPEG_PREFIX" ] || die "Homebrew formula 'ffmpeg' is not installed."
[ -x "$QT_PREFIX/bin/macdeployqt" ] || die "macdeployqt not found in $QT_PREFIX/bin."

export PATH="$QT_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$MPV_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH+:$PKG_CONFIG_PATH}"
export COPYFILE_DISABLE=1

if [ "$CLEAN" = true ]; then
    log "Cleaning previous macOS build output"
    rm -rf "$BUILD_DIR" "$SHELL_BUILD_DIR" "$ZIP_OUTPUT" "$REPO_ROOT/compiled"
fi

mkdir -p "$BUILD_DIR"

log "Installing npm dependencies"
cd "$REPO_ROOT"
"$NPM_BIN" ci

log "Building frontend"
"$NPM_BIN" run build

log "Compiling backend to JavaScript"
rm -rf "$REPO_ROOT/compiled"
"$NPX_BIN" tsc --outDir compiled --noEmit false

log "Configuring Qt shell"
cmake -S "$REPO_ROOT/shell" -B "$SHELL_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX;$QTWEBENGINE_PREFIX"

log "Building Qt shell"
cmake --build "$SHELL_BUILD_DIR" --config Release

SHELL_BUNDLE="$SHELL_BUILD_DIR/${APP_NAME}.app"
[ -d "$SHELL_BUNDLE" ] || die "Expected bundle not found at $SHELL_BUNDLE"

log "Staging app bundle"
rm -rf "$APP_BUNDLE"
cp -R "$SHELL_BUNDLE" "$APP_BUNDLE"

APP_RESOURCES="$APP_BUNDLE/Contents/Resources"
APP_PAYLOAD="$APP_RESOURCES/app"
RUNTIME_BIN="$APP_RESOURCES/runtime/bin"

mkdir -p "$APP_PAYLOAD" "$RUNTIME_BIN"

cp "$REPO_ROOT/compiled/server.js" "$APP_PAYLOAD/"
cp -R "$REPO_ROOT/compiled/routes" "$APP_PAYLOAD/"
cp -R "$REPO_ROOT/compiled/lib" "$APP_PAYLOAD/"
cp -R "$REPO_ROOT/public" "$APP_PAYLOAD/"
cp "$REPO_ROOT/package.json" "$APP_PAYLOAD/"
cp "$REPO_ROOT/package-lock.json" "$APP_PAYLOAD/"
cp "$REPO_ROOT/.env.example" "$APP_PAYLOAD/"

log "Installing production dependencies into app payload"
(
    cd "$APP_PAYLOAD"
    "$NPM_BIN" ci --omit=dev
)

log "Bundling local runtime binaries"
cp -L "$NODE_BIN" "$RUNTIME_BIN/node"
cp -L "$FFMPEG_PREFIX/bin/ffmpeg" "$RUNTIME_BIN/ffmpeg"
cp -L "$FFMPEG_PREFIX/bin/ffprobe" "$RUNTIME_BIN/ffprobe"
chmod +x "$RUNTIME_BIN/node" "$RUNTIME_BIN/ffmpeg" "$RUNTIME_BIN/ffprobe"

log "Running macdeployqt"
MACDEPLOYQT_LOG="$BUILD_DIR/macdeployqt.log"
if ! "$QT_PREFIX/bin/macdeployqt" "$APP_BUNDLE" \
    -qmldir="$REPO_ROOT/shell" \
    -no-codesign \
    >"$MACDEPLOYQT_LOG" 2>&1; then
    cat "$MACDEPLOYQT_LOG" >&2
    die "macdeployqt failed"
fi

if grep -q '^ERROR:' "$MACDEPLOYQT_LOG"; then
    warn "macdeployqt reported deployment warnings; validating and patching the bundle"
fi

log "Repairing QtWebEngine helper bundle"
patch_qtwebengine_helper "$APP_BUNDLE"

log "Removing stray macOS metadata from bundle"
clear_bundle_metadata "$APP_BUNDLE"

log "Creating ZIP archive"
rm -f "$ZIP_OUTPUT"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_OUTPUT"

cat <<EOF

Build complete
  App bundle: $APP_BUNDLE
  ZIP:        $ZIP_OUTPUT

Launch locally:
  open "$APP_BUNDLE"

If Finder blocks the app on first launch, clear the quarantine flag:
  xattr -dr com.apple.quarantine "$APP_BUNDLE"
EOF
