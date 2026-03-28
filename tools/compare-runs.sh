#!/bin/bash
# =============================================================================
# compare-runs.sh — Compare timing data across profiling runs
# =============================================================================
# Usage:
#   ./tools/compare-runs.sh run1/mlog.txt run2/mlog.txt
#   ./tools/compare-runs.sh --label "baseline" run1/ --label "optimized" run2/
#   ./tools/compare-runs.sh tools/profiles/2026-*  # compare all runs in profiles/
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSE_SCRIPT="$SCRIPT_DIR/parse-mlog.sh"

# -- Colors --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

if [[ ! -x "$PARSE_SCRIPT" ]]; then
    echo "ERROR: parse-mlog.sh not found at $PARSE_SCRIPT" >&2
    exit 1
fi

# -- Parse arguments --
declare -a RUN_PATHS
declare -a RUN_LABELS

label_next=""
for arg in "$@"; do
    case "$arg" in
        --label)
            label_next="pending"
            ;;
        --help|-h)
            echo "Usage: $(basename "$0") [--label NAME] PATH [--label NAME] PATH ..."
            echo ""
            echo "Compare timing data across multiple profiling runs."
            echo "PATH can be an mlog.txt file or a profile directory."
            exit 0
            ;;
        *)
            if [[ "$label_next" == "pending" ]]; then
                label_next="$arg"
            else
                # Resolve path to mlog.txt
                if [[ -d "$arg" ]]; then
                    if [[ -f "$arg/mlog.txt" ]]; then
                        RUN_PATHS+=("$arg/mlog.txt")
                    else
                        echo "WARNING: No mlog.txt found in $arg, skipping" >&2
                        label_next=""
                        continue
                    fi
                elif [[ -f "$arg" ]]; then
                    RUN_PATHS+=("$arg")
                else
                    echo "WARNING: $arg not found, skipping" >&2
                    label_next=""
                    continue
                fi

                if [[ -n "$label_next" && "$label_next" != "pending" ]]; then
                    RUN_LABELS+=("$label_next")
                    label_next=""
                else
                    RUN_LABELS+=("Run ${#RUN_PATHS[@]}")
                    label_next=""
                fi
            fi
            ;;
    esac
done

if [[ ${#RUN_PATHS[@]} -lt 2 ]]; then
    echo "ERROR: Need at least 2 runs to compare." >&2
    echo "Usage: $(basename "$0") [--label NAME] PATH [--label NAME] PATH ..." >&2
    exit 1
fi

# -- Collect timing data from each run --
declare -a ALL_PHASES

# Temporary directory for JSON outputs
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

for i in "${!RUN_PATHS[@]}"; do
    "$PARSE_SCRIPT" --json "${RUN_PATHS[$i]}" > "$TMPDIR/run_$i.json"

    # Extract phase names
    while IFS= read -r phase; do
        phase=$(echo "$phase" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        if [[ -n "$phase" ]]; then
            # Add to ALL_PHASES if not already present
            found=false
            for existing in "${ALL_PHASES[@]}"; do
                if [[ "$existing" == "$phase" ]]; then
                    found=true
                    break
                fi
            done
            if ! $found; then
                ALL_PHASES+=("$phase")
            fi
        fi
    done < <(grep '"name"' "$TMPDIR/run_$i.json" | sed 's/.*"name": "\([^"]*\)".*/\1/')
done

# -- Helper: get timing for a phase from a run's JSON --
get_time() {
    local json_file="$1"
    local phase="$2"
    # Extract seconds for the matching phase
    local result
    result=$(awk -v phase="$phase" '
        /"name":/ {
            gsub(/.*"name": "/, "")
            gsub(/".*/, "")
            name = $0
        }
        /"seconds":/ && name == phase {
            gsub(/.*"seconds": /, "")
            gsub(/[,}].*/, "")
            print $0
            exit
        }
    ' "$json_file")
    echo "${result:-0}"
}

# -- Display comparison --
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  FGunZ Performance Comparison${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Header with run labels
for i in "${!RUN_LABELS[@]}"; do
    log_time=$(grep '"log_time"' "$TMPDIR/run_$i.json" | sed 's/.*"log_time": "\([^"]*\)".*/\1/')
    echo -e "  ${CYAN}${RUN_LABELS[$i]}:${NC} ${log_time} (${RUN_PATHS[$i]})"
done
echo ""

# Column header
printf "${DIM}%-30s" "Phase"
for label in "${RUN_LABELS[@]}"; do
    printf " %14s" "$label"
done
if [[ ${#RUN_PATHS[@]} -eq 2 ]]; then
    printf " %10s %8s" "Delta" "Change"
fi
printf "${NC}\n"

printf "${DIM}"
printf "%-30s" "──────────────────────────────"
for _ in "${RUN_LABELS[@]}"; do
    printf " %14s" "──────────────"
done
if [[ ${#RUN_PATHS[@]} -eq 2 ]]; then
    printf " %10s %8s" "──────────" "────────"
fi
printf "${NC}\n"

# Phase rows
total_times=()
for i in "${!RUN_PATHS[@]}"; do
    total_times+=("0")
done

for phase in "${ALL_PHASES[@]}"; do
    printf "%-30s" "$phase"

    times=()
    for i in "${!RUN_PATHS[@]}"; do
        t=$(get_time "$TMPDIR/run_$i.json" "$phase")
        times+=("$t")
        total_times[$i]=$(awk "BEGIN{printf \"%.3f\", ${total_times[$i]} + $t}")
        printf " %13.3fs" "$t"
    done

    # Delta for 2-run comparison
    if [[ ${#RUN_PATHS[@]} -eq 2 ]]; then
        t1="${times[0]}"
        t2="${times[1]}"
        delta=$(awk "BEGIN{printf \"%.3f\", $t2 - $t1}")
        if awk "BEGIN{exit !($t1 > 0.001)}"; then
            pct=$(awk "BEGIN{printf \"%.1f\", (($t2 - $t1) / $t1) * 100}")
            if awk "BEGIN{exit !($delta < -0.5)}"; then
                printf " ${GREEN}%+9.3fs %+7.1f%%${NC}" "$delta" "$pct"
            elif awk "BEGIN{exit !($delta > 0.5)}"; then
                printf " ${RED}%+9.3fs %+7.1f%%${NC}" "$delta" "$pct"
            else
                printf " ${DIM}%+9.3fs %+7.1f%%${NC}" "$delta" "$pct"
            fi
        else
            printf " %10s %8s" "new" ""
        fi
    fi
    echo ""
done

# Totals
printf "${BOLD}%-30s" "TOTAL"
for i in "${!RUN_PATHS[@]}"; do
    printf " %13.3fs" "${total_times[$i]}"
done
if [[ ${#RUN_PATHS[@]} -eq 2 ]]; then
    delta=$(awk "BEGIN{printf \"%.3f\", ${total_times[1]} - ${total_times[0]}}")
    pct=$(awk "BEGIN{if(${total_times[0]} > 0) printf \"%.1f\", (($delta) / ${total_times[0]}) * 100; else print \"0.0\"}")
    if awk "BEGIN{exit !($delta < -0.5)}"; then
        printf " ${GREEN}%+9.3fs %+7.1f%%${NC}" "$delta" "$pct"
    elif awk "BEGIN{exit !($delta > 0.5)}"; then
        printf " ${RED}%+9.3fs %+7.1f%%${NC}" "$delta" "$pct"
    else
        printf " ${DIM}%+9.3fs %+7.1f%%${NC}" "$delta" "$pct"
    fi
fi
printf "${NC}\n"
echo ""
