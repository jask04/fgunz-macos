#!/bin/bash
# =============================================================================
# profile-launch.sh — Launch FGunZ with full performance profiling
# =============================================================================
# Launches the game while capturing:
#   - System resource usage (CPU, memory) sampled every 2 seconds
#   - Complete mlog.txt copy on exit
#   - Wine debug output (if --wine-debug is specified)
#   - Parsed timing report via parse-mlog.sh
#
# Usage:
#   ./tools/profile-launch.sh                     # standard profiling
#   ./tools/profile-launch.sh --wine-debug d3d    # with Wine debug channels
#   ./tools/profile-launch.sh --interval 5        # sample every 5 seconds
#   ./tools/profile-launch.sh --label "baseline"  # name this run
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FGUNZ_PREFIX="${FGUNZ_PREFIX:-$HOME/Games/freestyle-gunz}"
FGUNZ_GAME_DIR="$FGUNZ_PREFIX/drive_c/Program Files (x86)/Freestyle GunZ"
MLOG="$FGUNZ_GAME_DIR/mlog.txt"
PROFILES_DIR="$SCRIPT_DIR/profiles"

# -- Colors --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# -- Defaults --
SAMPLE_INTERVAL=2
WINE_DEBUG="-all"
RUN_LABEL=""

# -- Parse arguments --
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wine-debug)
            shift
            case "$1" in
                d3d)     WINE_DEBUG="+d3d,+d3d_shader" ;;
                file)    WINE_DEBUG="+file,+vfs" ;;
                texture) WINE_DEBUG="+d3d_surface,+d3d_texture" ;;
                gl)      WINE_DEBUG="+wgl,+opengl" ;;
                all)     WINE_DEBUG="+d3d,+d3d_shader,+file" ;;
                *)       WINE_DEBUG="$1" ;;
            esac
            shift ;;
        --interval)
            shift; SAMPLE_INTERVAL="$1"; shift ;;
        --label)
            shift; RUN_LABEL="$1"; shift ;;
        --help|-h)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Launch FGunZ with performance profiling."
            echo ""
            echo "Options:"
            echo "  --wine-debug PRESET  Enable Wine debug channels"
            echo "                       Presets: d3d, file, texture, gl, all"
            echo "                       Or pass a custom WINEDEBUG string"
            echo "  --interval SECS      Resource sampling interval (default: 2)"
            echo "  --label NAME         Label for this profiling run"
            echo "  --help               Show this help"
            echo ""
            echo "Wine debug presets:"
            echo "  d3d      +d3d,+d3d_shader          DX9 calls and shader compilation"
            echo "  file     +file,+vfs                 File I/O tracing"
            echo "  texture  +d3d_surface,+d3d_texture  Texture loading"
            echo "  gl       +wgl,+opengl               OpenGL calls"
            echo "  all      +d3d,+d3d_shader,+file     Combined performance channels"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# -- Create profile directory --
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
PROFILE_DIR="$PROFILES_DIR/${TIMESTAMP}"
if [[ -n "$RUN_LABEL" ]]; then
    PROFILE_DIR="${PROFILE_DIR}_${RUN_LABEL}"
fi
mkdir -p "$PROFILE_DIR"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  FGunZ Performance Profiler${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Profile dir:${NC}    $PROFILE_DIR"
echo -e "${CYAN}Wine debug:${NC}     $WINE_DEBUG"
echo -e "${CYAN}Sample interval:${NC} ${SAMPLE_INTERVAL}s"
if [[ -n "$RUN_LABEL" ]]; then
    echo -e "${CYAN}Label:${NC}          $RUN_LABEL"
fi
echo ""

# -- Capture game config snapshot --
CONFIG_FILE="$FGUNZ_GAME_DIR/config.xml"
if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "$PROFILE_DIR/config.xml"
    # Extract key performance-related settings
    {
        echo "# Config snapshot at launch"
        echo "DYNAMICLOADING=$(grep -o '<DYNAMICLOADING>[^<]*</DYNAMICLOADING>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
        echo "FULLSCREEN=$(grep -o '<FULLSCREEN>[^<]*</FULLSCREEN>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
        echo "WIDTH=$(grep -o '<WIDTH>[^<]*</WIDTH>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
        echo "HEIGHT=$(grep -o '<HEIGHT>[^<]*</HEIGHT>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
        echo "SHADER=$(grep -o '<SHADER>[^<]*</SHADER>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
        echo "REFLECTION=$(grep -o '<REFLECTION>[^<]*</REFLECTION>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
        echo "LIGHTMAP=$(grep -o '<LIGHTMAP>[^<]*</LIGHTMAP>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
        echo "CHARACTORTEXTURELEVEL=$(grep -o '<CHARACTORTEXTURELEVEL>[^<]*</CHARACTORTEXTURELEVEL>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
        echo "MAPTEXTURELEVEL=$(grep -o '<MAPTEXTURELEVEL>[^<]*</MAPTEXTURELEVEL>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
        echo "EFFECTLEVEL=$(grep -o '<EFFECTLEVEL>[^<]*</EFFECTLEVEL>' "$CONFIG_FILE" | sed 's/<[^>]*>//g')"
    } > "$PROFILE_DIR/config-snapshot.txt"
fi

# -- Capture system info --
{
    echo "# System info"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "hostname=$(hostname)"
    echo "os=$(sw_vers -productName) $(sw_vers -productVersion)"
    echo "arch=$(uname -m)"
    echo "cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    echo "ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))"
    echo "wine_version=$(wine64 --version 2>/dev/null || echo unknown)"
    echo "wine_debug=$WINE_DEBUG"
    echo "label=$RUN_LABEL"
} > "$PROFILE_DIR/system-info.txt"

# -- Resource monitor function --
monitor_resources() {
    local csv_file="$1"
    local interval="$2"

    echo "timestamp,elapsed_s,wine_cpu_pct,wine_rss_kb,wine_vsz_kb,sys_free_mb,sys_active_mb,sys_wired_mb" > "$csv_file"

    local start_time=$(date +%s)

    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        local ts=$(date +%H:%M:%S)

        # Find wine-related processes
        local wine_pids
        wine_pids=$(pgrep -f "wine" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

        local wine_cpu=0
        local wine_rss=0
        local wine_vsz=0

        if [[ -n "$wine_pids" ]]; then
            # Sum CPU and memory across all wine processes
            while IFS= read -r line; do
                local cpu rss vsz
                cpu=$(echo "$line" | awk '{print $1}')
                rss=$(echo "$line" | awk '{print $2}')
                vsz=$(echo "$line" | awk '{print $3}')
                wine_cpu=$(awk "BEGIN{printf \"%.1f\", $wine_cpu + $cpu}")
                wine_rss=$((wine_rss + rss))
                wine_vsz=$((wine_vsz + vsz))
            done < <(ps -p "$(echo "$wine_pids" | tr ',' ' ' | xargs echo)" -o pcpu=,rss=,vsz= 2>/dev/null || true)
        fi

        # System memory via vm_stat
        local vm_output
        vm_output=$(vm_stat 2>/dev/null)
        local page_size=16384  # Apple Silicon uses 16K pages
        local free_pages active_pages wired_pages
        free_pages=$(echo "$vm_output" | awk '/Pages free/{gsub(/\./,"",$NF); print $NF}')
        active_pages=$(echo "$vm_output" | awk '/Pages active/{gsub(/\./,"",$NF); print $NF}')
        wired_pages=$(echo "$vm_output" | awk '/Pages wired/{gsub(/\./,"",$NF); print $NF}')

        local free_mb=$(( (free_pages * page_size) / 1048576 ))
        local active_mb=$(( (active_pages * page_size) / 1048576 ))
        local wired_mb=$(( (wired_pages * page_size) / 1048576 ))

        echo "$ts,$elapsed,$wine_cpu,$wine_rss,$wine_vsz,$free_mb,$active_mb,$wired_mb" >> "$csv_file"

        sleep "$interval"
    done
}

# -- Start resource monitor in background --
RESOURCE_CSV="$PROFILE_DIR/resources.csv"
monitor_resources "$RESOURCE_CSV" "$SAMPLE_INTERVAL" &
MONITOR_PID=$!

echo -e "${GREEN}Resource monitor started${NC} (PID: $MONITOR_PID, interval: ${SAMPLE_INTERVAL}s)"

# -- Cleanup handler --
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping profiler...${NC}"

    # Stop resource monitor
    if kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null
        wait "$MONITOR_PID" 2>/dev/null || true
    fi

    # Calculate wall-clock time
    local end_time=$(date +%s)
    local wall_clock=$((end_time - LAUNCH_TIME))

    # Copy mlog.txt
    if [[ -f "$MLOG" ]]; then
        cp "$MLOG" "$PROFILE_DIR/mlog.txt"
    fi

    # Generate summary
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Profiling Complete${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Wall clock:${NC} $(format_duration $wall_clock)"
    echo -e "${CYAN}Profile:${NC}    $PROFILE_DIR"
    echo ""

    # Resource summary from CSV
    if [[ -f "$RESOURCE_CSV" ]] && [[ $(wc -l < "$RESOURCE_CSV") -gt 1 ]]; then
        local peak_cpu peak_rss_kb peak_rss_mb avg_cpu samples
        peak_cpu=$(tail -n +2 "$RESOURCE_CSV" | awk -F',' '{if($3+0 > max) max=$3+0} END{printf "%.1f", max}')
        peak_rss_kb=$(tail -n +2 "$RESOURCE_CSV" | awk -F',' '{if($4+0 > max) max=$4+0} END{print max}')
        peak_rss_mb=$((peak_rss_kb / 1024))
        avg_cpu=$(tail -n +2 "$RESOURCE_CSV" | awk -F',' '{sum+=$3+0; n++} END{if(n>0) printf "%.1f", sum/n; else print "0"}')
        samples=$(tail -n +2 "$RESOURCE_CSV" | wc -l | tr -d ' ')

        echo -e "${BOLD}Resource Summary${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"
        echo -e "  Peak CPU:     ${peak_cpu}%"
        echo -e "  Avg CPU:      ${avg_cpu}%"
        echo -e "  Peak Memory:  ${peak_rss_mb} MB"
        echo -e "  Samples:      ${samples}"
        echo ""
    fi

    # Wine debug log size
    if [[ -f "$PROFILE_DIR/wine-debug.log" ]]; then
        local log_size
        log_size=$(du -h "$PROFILE_DIR/wine-debug.log" | cut -f1)
        echo -e "${CYAN}Wine debug log:${NC} $log_size"
        echo ""
    fi

    # Run parse-mlog.sh
    if [[ -f "$PROFILE_DIR/mlog.txt" ]] && [[ -x "$SCRIPT_DIR/parse-mlog.sh" ]]; then
        "$SCRIPT_DIR/parse-mlog.sh" "$PROFILE_DIR/mlog.txt"

        # Also save JSON version
        "$SCRIPT_DIR/parse-mlog.sh" --json "$PROFILE_DIR/mlog.txt" > "$PROFILE_DIR/timing.json"
    fi

    # Save summary
    {
        echo "Profile: $PROFILE_DIR"
        echo "Label: ${RUN_LABEL:-none}"
        echo "Date: $(date)"
        echo "Wall clock: $(format_duration $wall_clock)"
        echo "Wine debug: $WINE_DEBUG"
        [[ -n "$peak_cpu" ]] && echo "Peak CPU: ${peak_cpu}%"
        [[ -n "$avg_cpu" ]] && echo "Avg CPU: ${avg_cpu}%"
        [[ -n "$peak_rss_mb" ]] && echo "Peak Memory: ${peak_rss_mb} MB"
    } > "$PROFILE_DIR/summary.txt"

    echo -e "${GREEN}Files saved to: $PROFILE_DIR${NC}"
    echo ""
}

format_duration() {
    local secs=$1
    if (( secs >= 3600 )); then
        printf '%dh %dm %ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif (( secs >= 60 )); then
        printf '%dm %ds' $((secs/60)) $((secs%60))
    else
        printf '%ds' "$secs"
    fi
}

trap cleanup EXIT INT TERM

# -- Launch the game --
echo -e "${GREEN}Launching FGunZ...${NC}"
echo ""

export WINEPREFIX="$FGUNZ_PREFIX"
export WINEDEBUG="$WINE_DEBUG"
LAUNCH_TIME=$(date +%s)

if [[ "$WINE_DEBUG" != "-all" ]]; then
    echo -e "${YELLOW}Wine debug channels enabled — expect slower performance and large log files.${NC}"
    echo ""
    wine64 explorer /desktop=FGunZ,1440x900 \
        "C:\Program Files (x86)\Freestyle GunZ\launch.bat" \
        2>"$PROFILE_DIR/wine-debug.log"
else
    wine64 explorer /desktop=FGunZ,1440x900 \
        "C:\Program Files (x86)\Freestyle GunZ\launch.bat" \
        2>/dev/null
fi

# The game has exited — cleanup runs via trap
