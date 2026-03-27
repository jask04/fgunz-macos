# Freestyle GunZ on macOS

Play [Freestyle GunZ](https://fgunz.net) on your Mac — no Windows, no VM, no Boot Camp.

Uses Wine to run the game natively on macOS with DirectX 9 → OpenGL translation.

## Compatibility

| Mac Type | Status |
|----------|--------|
| Apple Silicon (M1/M2/M3/M4) | Tested and working |
| Intel Mac | Should work (untested) |
| macOS 11 (Big Sur) or later | Required |

## Quick Install

1. Download the Freestyle GunZ installer from [fgunz.net](https://fgunz.net)
2. Clone this repo or download `install-fgunz-macos.sh`
3. Run:

```bash
chmod +x install-fgunz-macos.sh
./install-fgunz-macos.sh
```

The script handles everything automatically:
- Installs Homebrew (if needed)
- Installs Rosetta 2 (Apple Silicon only)
- Installs Wine (wine-crossover via Gcenx tap)
- Installs Winetricks and MSXML dependencies
- Runs the game installer
- Creates a launch script and macOS `.app` bundle

## Launching the Game

After installation, you have three options:

```bash
# Option 1: Launch script
~/Games/launch-fgunz.sh

# Option 2: macOS app (also available in Spotlight)
open ~/Applications/Freestyle\ GunZ.app

# Option 3: Direct Wine command
WINEPREFIX=~/Games/freestyle-gunz wine64 Launcher.exe
```

## Important: First Launch is Slow

The first time you launch, the game will sit at a black screen / "Loading Pictures" for **20-30 minutes**. This is normal on macOS — Wine is compiling OpenGL shaders from the game's DirectX 9 shaders.

- Do NOT kill the process during loading
- High CPU usage (100-200%) during this time is expected
- Subsequent launches may also be slow but should improve over time

## How It Works

| Component | Purpose |
|-----------|---------|
| [Wine](https://www.winehq.org/) (wine-crossover) | Runs Windows executables on macOS |
| [WineD3D](https://wiki.winehq.org/WineD3D) | Translates DirectX 9 → OpenGL |
| [Rosetta 2](https://support.apple.com/en-us/HT211861) | Translates x86 → ARM (Apple Silicon) |
| [Winetricks](https://github.com/Winetricks/winetricks) | Installs MSXML dependencies |
| MSXML (msxml3, msxml6, xmllite) | Windows XML libraries the game needs for config parsing |

## Manual Installation

If you prefer to install step by step instead of using the script:

### 1. Install Rosetta 2 (Apple Silicon only)

```bash
softwareupdate --install-rosetta --agree-to-license
```

### 2. Install Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 3. Install Wine and Winetricks

```bash
brew tap gcenx/wine
brew install --cask gcenx/wine/wine-crossover
brew install winetricks
```

### 4. Create Wine Prefix

```bash
mkdir -p ~/Games/freestyle-gunz
WINEPREFIX=~/Games/freestyle-gunz WINEARCH=win64 wine64 wineboot --init
```

Set Windows version to Windows 10:
```bash
WINEPREFIX=~/Games/freestyle-gunz wine64 reg add \
    "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion" \
    /v CurrentBuildNumber /t REG_SZ /d 19041 /f

WINEPREFIX=~/Games/freestyle-gunz wine64 reg add \
    "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion" \
    /v ProductName /t REG_SZ /d "Windows 10 Pro" /f
```

Apply macOS OpenGL fix:
```bash
WINEPREFIX=~/Games/freestyle-gunz wine64 reg add \
    "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" \
    /v ForceOpenGLBackingStore /t REG_SZ /d y /f
```

### 5. Install MSXML Dependencies

```bash
WINEPREFIX=~/Games/freestyle-gunz winetricks -q msxml3
WINEPREFIX=~/Games/freestyle-gunz winetricks -q msxml6
WINEPREFIX=~/Games/freestyle-gunz winetricks -q xmllite
```

> **Note:** Skip msxml4 — its winetricks installer fails on modern Wine and is not required.

### 6. Run the Game Installer

```bash
WINEPREFIX=~/Games/freestyle-gunz wine64 "Freestyle GunZ Installer.exe"
```

### 7. Launch

```bash
cd ~/Games/freestyle-gunz/drive_c/Program\ Files\ \(x86\)/Freestyle\ GunZ/
WINEPREFIX=~/Games/freestyle-gunz WINEDEBUG=-all wine64 Launcher.exe
```

> **Important:** Always launch via `Launcher.exe`, not `Gunz.exe` directly. The launcher sets up configs that the game expects.

## Troubleshooting

### Game crashes immediately
- Make sure you're launching `Launcher.exe`, not `Gunz.exe`
- Verify MSXML installed: `WINEPREFIX=~/Games/freestyle-gunz winetricks list-installed`
- Check Wine output: remove `WINEDEBUG=-all` to see debug logs

### Black screen for a long time
- This is normal on first launch (20-30 min). Don't kill the process.

### "Application is damaged" error for Wine
- Run: `xattr -cr "/Applications/Wine Crossover.app"`

### Graphics glitches or flickering
- The `ForceOpenGLBackingStore` registry key (set by the install script) should fix most flicker issues
- macOS OpenGL is deprecated but functional for DX9 games

### Do NOT install .NET Framework
- The Launcher.exe is a C#/.NET app, but installing .NET 4.0/4.5 in Wine actually breaks it
- Without .NET installed, the launcher uses a simpler fallback path that works correctly

## Known Issues

- 20-30 minute initial load time (shader compilation)
- High CPU during loading is normal
- Some initial menu/game lag that settles down after a minute
- DXVK does not work (requires Vulkan 1.3; MoltenVK only supports 1.2)

## Uninstalling

```bash
# Remove the game and Wine prefix
rm -rf ~/Games/freestyle-gunz
rm -f ~/Games/launch-fgunz.sh
rm -rf ~/Applications/Freestyle\ GunZ.app

# Optionally remove Wine and Winetricks
brew uninstall --cask gcenx/wine/wine-crossover
brew uninstall winetricks
```

## Credits

- Made for the [Freestyle GunZ](https://fgunz.net) community
- Uses [Gcenx's Wine builds](https://github.com/Gcenx/wine-on-mac) for macOS
- Thanks to the FGunZ Discord community for testing and confirming the setup works
