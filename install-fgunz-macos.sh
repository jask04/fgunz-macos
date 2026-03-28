#!/bin/bash
# =============================================================================
# Freestyle GunZ - macOS Installer Script
# =============================================================================
# This script installs and configures Freestyle GunZ on macOS (Apple Silicon
# and Intel Macs) using Wine. No Windows installation or virtual machine needed.
#
# Tested on: macOS with Apple Silicon (M1/M2/M3/M4)
# Game: Freestyle GunZ (https://fgunz.net)
#
# How it works:
#   - Uses wine-crossover (Gcenx tap) to run Windows executables
#   - WineD3D translates DirectX 9 to OpenGL for rendering
#   - MSXML dependencies are installed for the game's XML config parsing
#
# Requirements:
#   - macOS 11 (Big Sur) or later
#   - Rosetta 2 (for Apple Silicon Macs — installed automatically)
#   - ~4 GB free disk space (Wine + game + dependencies)
#   - Internet connection (to download dependencies)
#
# Usage:
#   chmod +x install-fgunz-macos.sh
#   ./install-fgunz-macos.sh
#
# If you already have the installer .exe on your Mac, place it in the same
# directory as this script. Otherwise, the script will prompt you to download it.
#
# IMPORTANT: The first launch may take 5-10 minutes at the "Loading Pictures"
# screen. This is normal on macOS — the game is compiling OpenGL shaders.
# Do NOT kill the process during loading.
# =============================================================================

set -e

# -- Configuration --
WINEPREFIX="$HOME/Games/freestyle-gunz"
GAME_NAME="Freestyle GunZ"
INSTALLER_NAME="Freestyle GunZ Installer.exe"
GAME_EXE="Launcher.exe"

# -- Colors for output --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_step() {
    echo ""
    echo -e "${BLUE}==>${NC} ${GREEN}$1${NC}"
    echo ""
}

print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

print_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

# =============================================================================
# Step 0: System checks
# =============================================================================
print_step "Step 0: Checking system requirements"

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    print_error "This script is for macOS only."
    exit 1
fi

# Check architecture and Rosetta
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    print_info "Apple Silicon detected. Checking Rosetta 2..."
    if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        print_step "Installing Rosetta 2 (required for Wine)"
        softwareupdate --install-rosetta --agree-to-license
    else
        print_info "Rosetta 2 is already installed."
    fi
elif [[ "$ARCH" == "x86_64" ]]; then
    print_info "Intel Mac detected."
else
    print_error "Unknown architecture: $ARCH"
    exit 1
fi

# =============================================================================
# Step 1: Install Homebrew (if needed)
# =============================================================================
print_step "Step 1: Checking for Homebrew"

if ! command -v brew &>/dev/null; then
    print_info "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH for Apple Silicon
    if [[ "$ARCH" == "arm64" ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
else
    print_info "Homebrew is already installed."
fi

# =============================================================================
# Step 2: Install Wine (wine-crossover via Gcenx tap)
# =============================================================================
print_step "Step 2: Installing Wine (wine-crossover)"

if ! brew list --cask gcenx/wine/wine-crossover &>/dev/null 2>&1; then
    print_info "Adding Gcenx tap and installing wine-crossover..."
    print_info "This includes 32-bit support via Rosetta 2 (needed for GunZ)."
    brew tap gcenx/wine
    brew install --cask gcenx/wine/wine-crossover
else
    print_info "wine-crossover is already installed."
fi

# Verify wine is working
if ! command -v wine64 &>/dev/null; then
    if [[ -f "/Applications/Wine Crossover.app/Contents/Resources/wine/bin/wine64" ]]; then
        export PATH="/Applications/Wine Crossover.app/Contents/Resources/wine/bin:$PATH"
    else
        print_error "Wine was installed but 'wine64' is not in PATH."
        print_info "You may need to restart your terminal or add Wine to your PATH manually."
        exit 1
    fi
fi

print_info "Wine version: $(wine64 --version 2>/dev/null || echo 'unknown')"

# =============================================================================
# Step 3: Install Winetricks
# =============================================================================
print_step "Step 3: Installing Winetricks"

if ! command -v winetricks &>/dev/null; then
    brew install winetricks
else
    print_info "Winetricks is already installed."
fi

# =============================================================================
# Step 4: Create Wine prefix
# =============================================================================
print_step "Step 4: Creating Wine prefix (Windows 10 64-bit environment)"

if [[ -d "$WINEPREFIX" ]]; then
    print_warning "Wine prefix already exists at: $WINEPREFIX"
    echo -n "Do you want to recreate it? This will delete the existing installation. (y/N): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        rm -rf "$WINEPREFIX"
    else
        print_info "Keeping existing prefix."
    fi
fi

if [[ ! -d "$WINEPREFIX" ]]; then
    mkdir -p "$WINEPREFIX"
    print_info "Creating new Wine prefix at: $WINEPREFIX"
    WINEPREFIX="$WINEPREFIX" WINEARCH=win64 wine64 wineboot --init 2>/dev/null

    # Set Windows version to Windows 10
    print_info "Setting Windows version to Windows 10..."
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion" \
        /v CurrentBuildNumber /t REG_SZ /d 19041 /f 2>/dev/null
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion" \
        /v ProductName /t REG_SZ /d "Windows 10 Pro" /f 2>/dev/null

    # macOS-specific: fix OpenGL rendering flicker
    print_info "Applying macOS OpenGL rendering fix..."
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" \
        /v ForceOpenGLBackingStore /t REG_SZ /d y /f 2>/dev/null

    # WineD3D performance tweaks
    print_info "Applying WineD3D performance optimizations..."

    # Report 4GB VRAM to prevent conservative rendering fallbacks
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" \
        /v VideoMemorySize /t REG_SZ /d "4096" /f 2>/dev/null

    # Relaxed shader math — faster shader compilation
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" \
        /v strict_shader_math /t REG_DWORD /d 0 /f 2>/dev/null

    # Cap shader model at SM3 (DX9 level) — avoids unnecessary complexity
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" \
        /v MaxShaderModelVS /t REG_DWORD /d 3 /f 2>/dev/null
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" \
        /v MaxShaderModelPS /t REG_DWORD /d 3 /f 2>/dev/null

    # Explicit GL 4.1 (macOS max) — skips capability probing overhead
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" \
        /v MaxVersionGL /t REG_DWORD /d 262145 /f 2>/dev/null

    # Enable command stream multi-threading (should be default, but be explicit)
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" \
        /v csmt /t REG_DWORD /d 1 /f 2>/dev/null

    # Disable per-draw float constant validation
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" \
        /v CheckFloatConstants /t REG_SZ /d "disabled" /f 2>/dev/null

    # Prevent macOS from capturing displays on fullscreen transitions
    print_info "Configuring Mac Driver settings..."
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" \
        /v CaptureDisplaysForFullscreen /t REG_SZ /d "n" /f 2>/dev/null

    # Use native d3dx9_43 — Wine's builtin fails to decompress DXT textures,
    # causing character skins to render as flat gray. The game ships its own
    # native Microsoft D3DX9_43.dll which handles DDS textures correctly.
    print_info "Setting D3DX9 to use native DLL (fixes character skin rendering)..."
    WINEPREFIX="$WINEPREFIX" wine64 reg add \
        "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides" \
        /v d3dx9_43 /t REG_SZ /d "native,builtin" /f 2>/dev/null

    print_info "Wine prefix created."
fi

# =============================================================================
# Step 5: Install MSXML dependencies via Winetricks
# =============================================================================
print_step "Step 5: Installing MSXML dependencies (required by FGunZ)"
print_info "FGunZ uses MSXML for configuration parsing."
print_info "Installing msxml3, msxml6, and xmllite..."
print_info "This may take a few minutes on first run (downloads ~900MB of Windows updates)."
print_info "Subsequent runs will use cached files."
echo ""

# Install each component individually for better error handling
# Note: msxml4 is intentionally skipped — its winetricks installer fails on
# modern Wine versions and is not required for the game to run.
for component in msxml3 msxml6 xmllite; do
    print_info "Installing $component..."
    WINEPREFIX="$WINEPREFIX" winetricks -q "$component" 2>/dev/null || {
        print_warning "$component installation had issues — the game may still work."
    }
done

print_info "MSXML dependencies installed."

# =============================================================================
# Step 6: Install Freestyle GunZ
# =============================================================================
print_step "Step 6: Installing Freestyle GunZ"

# Look for the installer in the current directory or common locations
INSTALLER_PATH=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEARCH_DIRS=("$SCRIPT_DIR" "." "$HOME/Downloads" "$HOME/Desktop")

for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -f "$dir/$INSTALLER_NAME" ]]; then
        INSTALLER_PATH="$dir/$INSTALLER_NAME"
        break
    fi
    # Also check for partial matches
    found=$(find "$dir" -maxdepth 1 -iname "*freestyle*gunz*installer*" -o -iname "*fgunz*installer*" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        INSTALLER_PATH="$found"
        break
    fi
done

if [[ -z "$INSTALLER_PATH" ]]; then
    echo ""
    print_warning "Freestyle GunZ installer not found!"
    echo ""
    echo "Please download the installer from: https://fgunz.net"
    echo "Then either:"
    echo "  1. Place '$INSTALLER_NAME' in the same directory as this script and re-run"
    echo "  2. Or drag and drop the installer file here and press Enter:"
    echo ""
    echo -n "Installer path (or press Enter to exit): "
    read -r INSTALLER_PATH

    if [[ -z "$INSTALLER_PATH" ]]; then
        print_info "Exiting. Re-run this script after downloading the installer."
        exit 0
    fi

    # Remove quotes that might come from drag-and-drop
    INSTALLER_PATH="${INSTALLER_PATH//\'/}"
    INSTALLER_PATH="${INSTALLER_PATH//\"/}"
    # Trim leading/trailing whitespace
    INSTALLER_PATH="$(echo -e "${INSTALLER_PATH}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
fi

if [[ ! -f "$INSTALLER_PATH" ]]; then
    print_error "File not found: $INSTALLER_PATH"
    exit 1
fi

print_info "Using installer: $INSTALLER_PATH"
print_info "Running the Freestyle GunZ installer..."
print_info "Follow the setup wizard — accept the license, use default install path, click Next/Install."
echo ""

WINEPREFIX="$WINEPREFIX" wine64 "$INSTALLER_PATH"

print_info "Installer finished."

# =============================================================================
# Step 7: Verify installation and create launch script
# =============================================================================
print_step "Step 7: Creating launch script"

# Find the game directory
GAME_DIR=""
for candidate in \
    "$WINEPREFIX/drive_c/Program Files (x86)/Freestyle GunZ" \
    "$WINEPREFIX/drive_c/Program Files/Freestyle GunZ"; do
    if [[ -f "$candidate/$GAME_EXE" ]]; then
        GAME_DIR="$candidate"
        break
    fi
done

if [[ -z "$GAME_DIR" ]]; then
    print_warning "Could not find $GAME_EXE at the expected location."
    print_info "Searching for it..."
    FOUND=$(find "$WINEPREFIX/drive_c" -iname "$GAME_EXE" 2>/dev/null | head -1)
    if [[ -n "$FOUND" ]]; then
        GAME_DIR=$(dirname "$FOUND")
        print_info "Found at: $GAME_DIR"
    else
        print_error "$GAME_EXE not found. The installation may have failed."
        print_info "Check $WINEPREFIX/drive_c for the game files."
        exit 1
    fi
fi

# Create a Windows batch file wrapper that sets the correct working directory.
# This is needed because explorer /desktop= changes the CWD, which breaks
# config.xml loading. The batch file uses %~dp0 to cd to its own directory.
LAUNCH_BAT="$GAME_DIR/launch.bat"
cat > "$LAUNCH_BAT" << 'BATEOF'
@echo off
cd /d "%~dp0"
Launcher.exe %*
:waitloop
tasklist /fi "imagename eq Gunz.exe" 2>nul | find /i "Gunz.exe" >nul
if %errorlevel%==0 (
    timeout /t 2 /nobreak >nul
    goto waitloop
)
BATEOF
print_info "Created launch.bat wrapper in game directory."

# Convert game dir to Windows path for explorer
GAME_DIR_WIN="C:\\Program Files (x86)\\Freestyle GunZ"

# Create the launch script
LAUNCH_SCRIPT="$HOME/Games/launch-fgunz.sh"
cat > "$LAUNCH_SCRIPT" << EOF
#!/bin/bash
# Freestyle GunZ - macOS Launcher
# Generated by install-fgunz-macos.sh
# Uses explorer /desktop= for virtual desktop (prevents minimize on device resets).
# Uses launch.bat to preserve working directory (fixes config.xml loading).

export WINEPREFIX="\$HOME/Games/freestyle-gunz"
export WINEDEBUG=-all

wine64 explorer /desktop=FGunZ,1920x1080 "$GAME_DIR_WIN\\launch.bat" "\$@"
EOF

chmod +x "$LAUNCH_SCRIPT"
print_info "Launch script created at: $LAUNCH_SCRIPT"

# =============================================================================
# Step 8: Create macOS .app bundle (for Dock/Launchpad/Spotlight)
# =============================================================================
print_step "Step 8: Creating macOS app bundle"

APP_DIR="$HOME/Applications/Freestyle GunZ.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/MacOS/launch" << EOF
#!/bin/bash
# Freestyle GunZ - macOS Launcher (App Bundle)
# Uses explorer /desktop= for virtual desktop (prevents minimize on device resets).
# Uses launch.bat to preserve working directory (fixes config.xml loading).

export WINEPREFIX="\$HOME/Games/freestyle-gunz"
export WINEDEBUG=-all

wine64 explorer /desktop=FGunZ,1920x1080 "$GAME_DIR_WIN\\launch.bat" "\$@"
EOF
chmod +x "$APP_DIR/Contents/MacOS/launch"

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Freestyle GunZ</string>
    <key>CFBundleDisplayName</key>
    <string>Freestyle GunZ</string>
    <key>CFBundleIdentifier</key>
    <string>net.fgunz.freestylegunz</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>launch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
</dict>
</plist>
PLIST_EOF

print_info "App bundle created at: $APP_DIR"
print_info "You can find 'Freestyle GunZ' in ~/Applications or via Spotlight."

# =============================================================================
# Done!
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Freestyle GunZ installation complete!     ${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "To launch the game:"
echo "  Option 1: Run '$LAUNCH_SCRIPT'"
echo "  Option 2: Open 'Freestyle GunZ' from ~/Applications"
echo "  Option 3: Search 'Freestyle GunZ' in Spotlight"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC} The first launch may take 5-10 minutes at"
echo "the 'Loading Pictures' screen. This is normal on macOS — the game"
echo "is compiling OpenGL shaders. Do NOT kill the process during loading."
echo "High CPU usage during this time is expected."
echo "Subsequent launches should be faster thanks to shader caching."
echo ""
echo "Game files are stored at: $WINEPREFIX"
echo ""
echo "Have fun! - Made for the FGunZ community"
echo ""
