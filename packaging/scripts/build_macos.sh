#!/usr/bin/env bash
#
# Build SQLCipherUI macOS distribution:
#   frontend → PyInstaller backend → Tauri .app / .dmg
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGING_DIR="$PROJECT_ROOT/packaging"
TAURI_DIR="$PROJECT_ROOT/src-tauri"
VENV="$PROJECT_ROOT/venv"
VERSION=$(grep '"version"' "$TAURI_DIR/tauri.conf.json" | head -1 | sed 's/.*: *"\(.*\)".*/\1/')

echo "Building SQLCipherUI v${VERSION} for macOS..."

if [ "${CI:-}" = "true" ]; then
    source "$VENV/bin/activate"
else
    if [ ! -d "$VENV" ]; then
        echo "Creating Python virtual environment..."
        python3 -m venv "$VENV"
        source "$VENV/bin/activate"
        pip install --upgrade pip
        pip install -e "$PROJECT_ROOT/packages/core" -e "$PROJECT_ROOT/packages/api"
    else
        source "$VENV/bin/activate"
    fi

    if ! python -m PyInstaller --version &>/dev/null; then
        echo "Installing PyInstaller..."
        pip install "pyinstaller>=6.12.0"
    fi

    if ! command -v node &>/dev/null; then
        echo "Installing Node.js via Homebrew..."
        if ! command -v brew &>/dev/null; then
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        brew install node
    fi

    if ! command -v cargo &>/dev/null; then
        echo "Installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi

    if ! cargo tauri --version &>/dev/null; then
        echo "Installing Tauri CLI..."
        cargo install tauri-cli
    fi
fi

# ── Step 1: Build frontend ──────────────────────────────────────────
echo "[1/5] Building frontend..."
if [ "${CI:-}" != "true" ]; then
    npm --prefix "$PROJECT_ROOT/packages/web" install --silent
fi
npm --prefix "$PROJECT_ROOT/packages/web" run build

# ── Step 2: Generate icons ──────────────────────────────────────────
echo "[2/5] Checking icon assets..."
ICON_SRC="$PACKAGING_DIR/assets/icon.png"

if [ -f "$ICON_SRC" ]; then
    ICON_ICNS="$PACKAGING_DIR/assets/icon.icns"
    if [ ! -f "$ICON_ICNS" ]; then
        echo "       Generating .icns from icon.png..."
        ICONSET_DIR=$(mktemp -d)/SQLCipherUI.iconset
        mkdir -p "$ICONSET_DIR"
        for size in 16 32 128 256 512; do
            sips -z $size $size "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null 2>&1
            double=$((size * 2))
            sips -z $double $double "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null 2>&1
        done
        iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"
        rm -rf "$(dirname "$ICONSET_DIR")"
    fi

    if [ ! -f "$TAURI_DIR/icons/icon.icns" ]; then
        echo "       Generating Tauri icons..."
        cargo tauri icon "$ICON_SRC" 2>/dev/null || echo "       (cargo tauri icon not available, copy manually)"
    fi
else
    echo "       WARNING: No icon.png at $ICON_SRC — using defaults"
fi

# ── Step 3: Build Python backend with PyInstaller ───────────────────
echo "[3/5] Building Python backend (PyInstaller)..."
cd "$PACKAGING_DIR"
python -m PyInstaller sqlcipherui.spec \
    --clean \
    --noconfirm \
    --distpath "$PACKAGING_DIR/dist" \
    --workpath "$PACKAGING_DIR/build"

# ── Step 4: Stage backend for Tauri ─────────────────────────────────
echo "[4/5] Staging backend for Tauri..."
SIDECAR_DIR="$TAURI_DIR/binaries"
rm -rf "$SIDECAR_DIR/SQLCipherUI-backend"
mkdir -p "$SIDECAR_DIR"
cp -R "$PACKAGING_DIR/dist/SQLCipherUI-backend" "$SIDECAR_DIR/SQLCipherUI-backend"

# ── Step 5: Build Tauri app ─────────────────────────────────────────
echo "[5/5] Building Tauri app..."
cd "$PROJECT_ROOT"
cargo tauri build

echo ""
echo "=== Copying installers to releases/ ==="

RELEASES_DIR="$PROJECT_ROOT/releases"
mkdir -p "$RELEASES_DIR"

DMG_FILE=$(find "$TAURI_DIR/target/release/bundle/dmg/" -name "*.dmg" 2>/dev/null | head -1)
if [ -n "$DMG_FILE" ]; then
    cp "$DMG_FILE" "$RELEASES_DIR/"
    echo "DMG: $RELEASES_DIR/$(basename "$DMG_FILE")"
    ls -lh "$RELEASES_DIR/$(basename "$DMG_FILE")"
fi

APP_PATH="$TAURI_DIR/target/release/bundle/macos/SQLCipherUI.app"
if [ -d "$APP_PATH" ]; then
    echo "App: $APP_PATH (not copied — use the DMG for distribution)"
fi

echo ""
echo "=== Build complete ==="
echo "Installers are in: $RELEASES_DIR"
