#!/usr/bin/env bash

# apt update
# apt install -y fzf

# Download MongoDB backups from the production server.
#
# List *.archive.gz files on the production server, select one or more files,
# and download them with rsync to LOCAL_DIR (see the defaults below).
#
# Override settings with environment variables or command-line options:
#   PROD_HOST=1.2.3.4 REMOTE_DIR=/path ./backup-from-prod.sh
#   ./backup-from-prod.sh --host hrdata.eu --dir /www/server/mongo/dump --all

set -Eeuo pipefail

PROD_HOST="${PROD_HOST:-127.0.0.1}"
PROD_USER="${PROD_USER:-user}"
PROD_PORT="${PROD_PORT:-22}"

# If REMOTE_DIR is unset, check the candidate directories in order
# and use the first directory that contains archives.
REMOTE_DIRS="${REMOTE_DIR:-/www/server/mongo/dump /dump/mongo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use /data/mongo if it exists; otherwise, use dump next to this script.
if [[ -z "${LOCAL_DIR:-}" ]]; then
    if [[ -d /data/mongo ]]; then
        LOCAL_DIR="/data/mongo"
    else
        LOCAL_DIR="$SCRIPT_DIR/dump"
    fi
fi

SELECT_ALL=0
CLEAN_LOCAL=0

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BOLD="\033[1m"
DIM="\033[2m"
NC="\033[0m"

log() {
    echo -e "${CYAN}➜${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}!${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

die() {
    error "$1"
    exit 1
}

hr() {
    echo -e "${DIM}──────────────────────────────────────────────${NC}"
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

  --host HOST    production server (current: $PROD_HOST)
  --user USER    SSH user (current: $PROD_USER)
  --port PORT    SSH port (current: $PROD_PORT)
  --dir  PATH    remote backup directory (current: $REMOTE_DIRS)
  --all          download all files without the picker
  --clean        remove *.archive.gz from $LOCAL_DIR before downloading
  -h, --help     show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) PROD_HOST="${2:?--host requires a value}"; shift 2 ;;
        --user) PROD_USER="${2:?--user requires a value}"; shift 2 ;;
        --port) PROD_PORT="${2:?--port requires a value}"; shift 2 ;;
        --dir)  REMOTE_DIRS="${2:?--dir requires a value}"; shift 2 ;;
        --all)   SELECT_ALL=1; shift ;;
        --clean) CLEAN_LOCAL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown argument: $1" ;;
    esac
done

# Format byte counts as readable file sizes for the listing.
format_listing() {
    awk -F'\t' '{
        s = $2; u = "B";
        if (s >= 1073741824)  { s = s / 1073741824; u = "G" }
        else if (s >= 1048576) { s = s / 1048576;   u = "M" }
        else if (s >= 1024)    { s = s / 1024;      u = "K" }
        printf "%s  %7.1f%s  %s\n", $1, s, u, $3
    }'
}

clear 2>/dev/null || true

echo -e "${BOLD}${CYAN}"
echo "MongoDB Backup Download Utility"
echo -e "${NC}"

hr

command -v ssh   >/dev/null || die "ssh not found"
command -v rsync >/dev/null || die "rsync not found"

[[ "$SELECT_ALL" -eq 1 ]] || command -v fzf >/dev/null \
    || die "fzf is not installed — run: sudo apt install -y fzf"

echo -e "${CYAN}Server:${NC}  $PROD_USER@$PROD_HOST:$PROD_PORT"
echo -e "${CYAN}Local:${NC} $LOCAL_DIR"

hr

log "Fetching the production backup list"

# Use one SSH call to list archives in the first nonempty candidate directory.
REMOTE_CMD="for d in $REMOTE_DIRS; do
    [ -d \"\$d\" ] || continue
    out=\$(find \"\$d\" -maxdepth 1 -type f -name '*.archive.gz' -printf '%TY-%Tm-%Td %TH:%TM\t%s\t%f\n' 2>/dev/null | sort -r)
    [ -n \"\$out\" ] || continue
    echo \"DIR \$d\"
    echo \"\$out\"
    exit 0
done
exit 3"

set +e
RAW="$(ssh -n -p "$PROD_PORT" "$PROD_USER@$PROD_HOST" "$REMOTE_CMD")"
ssh_status=$?
set -e

if [[ "$ssh_status" -eq 3 ]]; then
    die "No *.archive.gz files found in: $REMOTE_DIRS (specify a directory with --dir)"
fi

[[ "$ssh_status" -eq 0 ]] || die "Could not connect to $PROD_USER@$PROD_HOST:$PROD_PORT (ssh: $ssh_status)"
[[ -n "$RAW" ]] || die "Empty response from the server"

REMOTE_PATH="${RAW%%$'\n'*}"
REMOTE_PATH="${REMOTE_PATH#DIR }"
LISTING="${RAW#*$'\n'}"

FILES=()
NAMES=()
SIZES=()
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    FILES+=("$line")
    NAMES+=("${line##*$'\t'}")
    size_field="${line#*$'\t'}"
    SIZES+=("${size_field%%$'\t'*}")
done <<< "$LISTING"

[[ ${#FILES[@]} -gt 0 ]] || die "No backups found in $REMOTE_PATH"

success "Found ${#FILES[@]} file(s) in $REMOTE_PATH"

hr

DISPLAY=()
while IFS= read -r line; do
    DISPLAY+=("$line")
done < <(printf '%s\n' "${FILES[@]}" | format_listing)

SELECTED_IDX=()

if [[ "$SELECT_ALL" -eq 1 ]]; then
    i=0
    while [[ $i -lt ${#FILES[@]} ]]; do
        SELECTED_IDX+=("$i")
        i=$((i + 1))
    done
else
    # fzf returns the marked files, or the current row if no files are marked.
    if SELECTION=$(
        printf '%s\n' "${DISPLAY[@]}" |
        fzf \
            --multi \
            --marker='☑' \
            --pointer='>' \
            --bind='space:toggle,ctrl-a:select-all,ctrl-d:deselect-all' \
            --height=20 \
            --border \
            --reverse \
            --prompt="Backup > " \
            --header="Space: ☑ | Ctrl+A: all | Ctrl+D: clear | Enter: download | Esc: cancel"
    ); then
        [[ -n "$SELECTION" ]] || die "No files selected"
    else
        fzf_status=$?
        if [[ "$fzf_status" -eq 130 ]]; then
            warn "Canceled"
            exit 0
        fi
        die "Could not select files (fzf: ${fzf_status})"
    fi

    # Match the filename in the last field to its original index.
    while IFS= read -r line; do
        picked_name="${line##* }"
        i=0
        found=0
        while [[ $i -lt ${#NAMES[@]} ]]; do
            if [[ "${NAMES[$i]}" == "$picked_name" ]]; then
                SELECTED_IDX+=("$i")
                found=1
                break
            fi
            i=$((i + 1))
        done
        [[ "$found" -eq 1 ]] || die "Could not parse the selection: '$line'"
    done <<< "$SELECTION"
fi

[[ ${#SELECTED_IDX[@]} -gt 0 ]] || die "No files selected"

total_bytes=0
for idx in "${SELECTED_IDX[@]}"; do
    total_bytes=$((total_bytes + SIZES[idx]))
done

clear 2>/dev/null || true

echo -e "${GREEN}${BOLD}Selected files:${NC} ${CYAN}${#SELECTED_IDX[@]}${NC}"
for idx in "${SELECTED_IDX[@]}"; do
    echo "  ☑ ${DISPLAY[$idx]}"
done
echo
echo -e "${CYAN}Total:${NC} $(echo "$total_bytes" | awk '{
    s = $1; u = "B";
    if (s >= 1073741824)  { s = s / 1073741824; u = "G" }
    else if (s >= 1048576) { s = s / 1048576;   u = "M" }
    else if (s >= 1024)    { s = s / 1024;      u = "K" }
    printf "%.1f%s\n", s, u
}')"

hr

mkdir -p "$LOCAL_DIR"

if [[ "$CLEAN_LOCAL" -eq 1 ]]; then
    warn "Cleaning $LOCAL_DIR"
    rm -vf "$LOCAL_DIR"/*.archive.gz
    hr
fi

log "Downloading to $LOCAL_DIR"
echo

count=0
for idx in "${SELECTED_IDX[@]}"; do
    count=$((count + 1))
    name="${NAMES[$idx]}"

    echo -e "${BOLD}[$count/${#SELECTED_IDX[@]}]${NC} $name"

    rsync -avP -e "ssh -p $PROD_PORT" \
        "$PROD_USER@$PROD_HOST:$REMOTE_PATH/$name" \
        "$LOCAL_DIR/" \
        || die "Download failed: $name"

    [[ -s "$LOCAL_DIR/$name" ]] || die "Downloaded file is empty: $name"

    echo
done

hr
echo -e "${GREEN}${BOLD}Done (files: ${#SELECTED_IDX[@]})${NC}"
echo
ls -lh "$LOCAL_DIR"
hr

#EOF#
