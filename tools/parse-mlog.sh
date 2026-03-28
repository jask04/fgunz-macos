#!/bin/bash
# =============================================================================
# parse-mlog.sh — Parse Freestyle GunZ mlog.txt and extract phase timings
# =============================================================================
# Extracts timing data from the game log to identify performance bottlenecks.
#
# Usage:
#   ./tools/parse-mlog.sh                          # use default mlog.txt path
#   ./tools/parse-mlog.sh /path/to/mlog.txt        # specify custom path
#   ./tools/parse-mlog.sh --json                    # JSON output
#   ./tools/parse-mlog.sh --csv                     # CSV output (for tracking)
# =============================================================================

set -e

# -- Configuration --
FGUNZ_PREFIX="${FGUNZ_PREFIX:-$HOME/Games/freestyle-gunz}"
FGUNZ_GAME_DIR="$FGUNZ_PREFIX/drive_c/Program Files (x86)/Freestyle GunZ"
DEFAULT_MLOG="$FGUNZ_GAME_DIR/mlog.txt"

# -- Colors --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# -- Parse arguments --
MLOG_PATH=""
OUTPUT_FORMAT="text"

for arg in "$@"; do
    case "$arg" in
        --json) OUTPUT_FORMAT="json" ;;
        --csv)  OUTPUT_FORMAT="csv" ;;
        --help|-h)
            echo "Usage: $(basename "$0") [OPTIONS] [MLOG_PATH]"
            echo ""
            echo "Parse Freestyle GunZ mlog.txt and extract phase timings."
            echo ""
            echo "Options:"
            echo "  --json    Output as JSON"
            echo "  --csv     Output as CSV (timestamp,phase,seconds)"
            echo "  --help    Show this help"
            echo ""
            echo "Default mlog.txt path: $DEFAULT_MLOG"
            exit 0
            ;;
        *)
            if [[ -z "$MLOG_PATH" && ! "$arg" =~ ^-- ]]; then
                MLOG_PATH="$arg"
            fi
            ;;
    esac
done

MLOG_PATH="${MLOG_PATH:-$DEFAULT_MLOG}"

if [[ ! -f "$MLOG_PATH" ]]; then
    echo "ERROR: mlog.txt not found at: $MLOG_PATH" >&2
    exit 1
fi

# -- Extract metadata --
BUILD_LINE=$(head -1 "$MLOG_PATH")
LOG_TIME=$(grep -o 'Log time ([^)]*)'  "$MLOG_PATH" | head -1 | sed 's/Log time (\(.*\))/\1/')
CONFIG_STATUS=$(grep 'Load Config from file' "$MLOG_PATH" | head -1 | grep -o 'SUCCESS\|FAIL')

# -- Extract arrow timings: -------------------> PhaseName: 123.456 --
declare -a PHASE_NAMES
declare -a PHASE_TIMES

while IFS= read -r line; do
    phase=$(echo "$line" | sed 's/.*---*> *\(.*\):.*/\1/' | sed 's/[[:space:]]*$//')
    time=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+' | tail -1)
    if [[ -n "$phase" && -n "$time" ]]; then
        PHASE_NAMES+=("$phase")
        PHASE_TIMES+=("$time")
    fi
done < <(grep -- '---*>' "$MLOG_PATH")

# -- Extract inline timings: "phase name: 123.456789" (6 decimal places) --
while IFS= read -r line; do
    # Skip lines that are arrow timings (already captured)
    if echo "$line" | grep -q -- '---*>'; then
        continue
    fi
    phase=$(echo "$line" | sed 's/\(.*\):[[:space:]]*[0-9]*\.[0-9]*.*/\1/' | sed 's/^[[:space:]]*//')
    time=$(echo "$line" | grep -oE '[0-9]+\.[0-9]{6}' | tail -1)
    if [[ -n "$phase" && -n "$time" ]]; then
        # Skip if this phase was already captured as an arrow timing
        already_captured=false
        for existing in "${PHASE_NAMES[@]}"; do
            if [[ "$existing" == "$phase" ]]; then
                already_captured=true
                break
            fi
        done
        if ! $already_captured; then
            PHASE_NAMES+=("$phase")
            PHASE_TIMES+=("$time")
        fi
    fi
done < <(grep -E '[0-9]+\.[0-9]{6}' "$MLOG_PATH" | grep -v 'Video memory' | grep -v 'shader initialize')

# -- Extract device reset count --
RESET_COUNT=$(grep -c 'Reset Device\.\.\.' "$MLOG_PATH" 2>/dev/null || true)
RESET_COUNT="${RESET_COUNT:-0}"
RESET_COUNT=$(echo "$RESET_COUNT" | tr -d '[:space:]')

# -- Extract game session times --
GAME_CREATED=$(grep -o 'game created ( [^)]*)'  "$MLOG_PATH" | head -1 | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}')
GAME_DESTROYED=$(grep -o 'game destroyed ( [^)]*)' "$MLOG_PATH" | head -1 | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}')

# -- Detect crashes --
HAS_CRASH=$(grep -c '\[Exception\]\|ExpCode\|Crash' "$MLOG_PATH" 2>/dev/null || true)
HAS_CRASH="${HAS_CRASH:-0}"
HAS_CRASH=$(echo "$HAS_CRASH" | tr -d '[:space:]')

# -- Helper: format seconds as human-readable --
format_time() {
    local secs="$1"
    local int_secs=$(printf '%.0f' "$secs")
    if (( int_secs >= 60 )); then
        local mins=$((int_secs / 60))
        local remainder=$((int_secs % 60))
        echo "${mins}m ${remainder}s"
    elif awk "BEGIN{exit !($secs >= 1)}"; then
        printf '%.1fs' "$secs"
    else
        local trimmed
        trimmed=$(echo "$secs" | tr -d ' ')
        local ms
        ms=$(awk "BEGIN{printf \"%.0f\", ${trimmed} * 1000}")
        echo "${ms}ms"
    fi
}

# -- Output: JSON --
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "{"
    echo "  \"build\": \"$(echo "$BUILD_LINE" | sed 's/"/\\"/g')\","
    echo "  \"log_time\": \"$LOG_TIME\","
    echo "  \"config_status\": \"$CONFIG_STATUS\","
    echo "  \"device_resets\": $RESET_COUNT,"
    echo "  \"game_created\": \"$GAME_CREATED\","
    echo "  \"game_destroyed\": \"$GAME_DESTROYED\","
    echo "  \"has_crash\": $([ "$HAS_CRASH" -gt 0 ] && echo "true" || echo "false"),"
    echo "  \"phases\": ["
    for i in "${!PHASE_NAMES[@]}"; do
        comma=""
        if (( i < ${#PHASE_NAMES[@]} - 1 )); then comma=","; fi
        printf '    {"name": "%s", "seconds": %s}%s\n' "${PHASE_NAMES[$i]}" "${PHASE_TIMES[$i]}" "$comma"
    done
    echo "  ]"
    echo "}"
    exit 0
fi

# -- Output: CSV --
if [[ "$OUTPUT_FORMAT" == "csv" ]]; then
    echo "log_time,phase,seconds"
    for i in "${!PHASE_NAMES[@]}"; do
        echo "$LOG_TIME,${PHASE_NAMES[$i]},${PHASE_TIMES[$i]}"
    done
    exit 0
fi

# -- Output: Text (default) --
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  FGunZ Performance Report${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Metadata
echo -e "${CYAN}Build:${NC}    $BUILD_LINE"
echo -e "${CYAN}Log time:${NC} $LOG_TIME"
echo -e "${CYAN}Config:${NC}   ${CONFIG_STATUS:-unknown}"
echo -e "${CYAN}Resets:${NC}   ${RESET_COUNT} device reset(s)"
if [[ -n "$GAME_CREATED" ]]; then
    echo -e "${CYAN}Session:${NC}  created $GAME_CREATED → destroyed ${GAME_DESTROYED:-still running}"
fi
if [[ "$HAS_CRASH" -gt 0 ]]; then
    echo -e "${RED}CRASH:${NC}    Exception detected in log"
fi
echo ""

# Phase timings
echo -e "${BOLD}Phase Timings${NC}"
echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"
printf "${DIM}%-35s %12s %10s${NC}\n" "Phase" "Seconds" "Human"
echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"

# Calculate total for percentage
total=0
for t in "${PHASE_TIMES[@]}"; do
    total=$(awk "BEGIN{printf \"%.6f\", $total + $t}")
done

# Sort by duration descending — build index array
indices=()
for i in "${!PHASE_TIMES[@]}"; do
    indices+=("$i")
done
# Bubble sort by time descending
for ((i=0; i<${#indices[@]}; i++)); do
    for ((j=i+1; j<${#indices[@]}; j++)); do
        ti="${PHASE_TIMES[${indices[$i]}]}"
        tj="${PHASE_TIMES[${indices[$j]}]}"
        if awk "BEGIN{exit !($tj > $ti)}"; then
            tmp="${indices[$i]}"
            indices[$i]="${indices[$j]}"
            indices[$j]="$tmp"
        fi
    done
done

for idx in "${indices[@]}"; do
    name="${PHASE_NAMES[$idx]}"
    secs="${PHASE_TIMES[$idx]}"
    human=$(format_time "$secs")
    pct=$(awk "BEGIN{if($total>0) printf \"%.1f\", ($secs/$total)*100; else print \"0.0\"}")

    # Color based on severity
    if awk "BEGIN{exit !($secs > 60)}"; then
        color="$RED"
    elif awk "BEGIN{exit !($secs > 5)}"; then
        color="$YELLOW"
    else
        color="$GREEN"
    fi

    printf "${color}%-35s %10.3fs %10s${NC} ${DIM}(%s%%)${NC}\n" "$name" "$secs" "$human" "$pct"
done

echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"
printf "${BOLD}%-35s %10.3fs %10s${NC}\n" "TOTAL (all phases)" "$total" "$(format_time "$total")"
echo ""

# Bottleneck analysis
if [[ ${#PHASE_NAMES[@]} -gt 0 ]]; then
    top_idx="${indices[0]}"
    top_name="${PHASE_NAMES[$top_idx]}"
    top_secs="${PHASE_TIMES[$top_idx]}"
    top_pct=$(awk "BEGIN{if($total>0) printf \"%.1f\", ($top_secs/$total)*100; else print \"0.0\"}")
    echo -e "${BOLD}Bottleneck:${NC} ${RED}$top_name${NC} accounts for ${RED}${top_pct}%${NC} of total startup time"
fi
echo ""
