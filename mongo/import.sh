#!/usr/bin/env bash

# apt update
# apt install -y fzf

# Restore a backup (*.archive.gz) to the configured MongoDB instance.
#
# Read archives from DUMP_DIR, including files downloaded by backup-from-prod.sh,
# select an archive, target database, and restore mode, then run mongorestore.
#
#   ./import.sh
#   ./import.sh --file dump/geekjob_2026-09-14_03-00-01.archive.gz --db geekjob --mode replace --yes

set -Eeuo pipefail

ENV_FILE=".env"
CONTAINER_NAME="${MONGO_CONTAINER:-mongo7}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use /data/mongo if it exists; otherwise, use dump next to this script.
if [[ -z "${DUMP_DIR:-}" ]]; then
    if [[ -d /data/mongo ]]; then
        DUMP_DIR="/data/mongo"
    else
        DUMP_DIR="$SCRIPT_DIR/dump"
    fi
fi

ARCHIVE_FILE=""
TARGET_DB=""
MODE=""
ASSUME_YES=0

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

flush_tty() {
    { : < /dev/tty; } 2>/dev/null || return 0
    while read -r -t 0.05 -n 10000 _ < /dev/tty 2>/dev/null; do :; done
    true
}

# Select one item from the supplied lines with fzf.
# $1 is the prompt, $2 is the header, and the remaining arguments are items.
pick_one() {
    local prompt="$1" header="$2"
    shift 2
    flush_tty
    printf '%s\n' "$@" |
        fzf \
            --height=15 \
            --border \
            --reverse \
            --prompt="$prompt" \
            --header="$header" || true
}

# Treat an empty selection as a cancellation.
cancel_if_empty() {
    [[ -n "$1" ]] || {
        warn "Canceled"
        exit 0
    }
}

# Read the modification time and byte count using GNU stat, then BSD stat.
file_meta() {
    stat -c '%Y %s' "$1" 2>/dev/null || stat -f '%m %z' "$1"
}

fmt_date() {
    date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M'
}

fmt_size() {
    echo "$1" | awk '{
        s = $1; u = "B";
        if (s >= 1073741824)  { s = s / 1073741824; u = "G" }
        else if (s >= 1048576) { s = s / 1048576;   u = "M" }
        else if (s >= 1024)    { s = s / 1024;      u = "K" }
        printf "%.1f%s\n", s, u
    }'
}

# Derive the database name by removing the _YYYY-MM-DD_HH-MM-SS.archive.gz suffix
# added by export.sh.
db_from_filename() {
    printf '%s\n' "$1" |
        sed -E 's/\.archive\.gz$//; s/_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$//'
}

mongosh_eval() {
    docker exec "$CONTAINER_NAME" mongosh \
        --host "$MONGO_HOST" \
        --port "$MONGO_PORT" \
        --username "$MONGO_USER" \
        --password "$MONGO_PASS" \
        --authenticationDatabase "$MONGO_AUTHDB" \
        --quiet \
        --eval "$1"
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

  --file PATH    archive to restore (default: select from $DUMP_DIR)
  --db NAME      target database (default: choose interactively)
  --mode MODE    replace | drop | append
                   replace — dropDatabase + restore (replace the entire database)
                   drop    — mongorestore --drop (replace collections in the archive)
                   append  — restore without dropping existing collections
  --yes          skip the confirmation prompt
  -h, --help     show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file) ARCHIVE_FILE="${2:?--file requires a value}"; shift 2 ;;
        --db)   TARGET_DB="${2:?--db requires a value}"; shift 2 ;;
        --mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown argument: $1" ;;
    esac
done

clear 2>/dev/null || true

echo -e "${BOLD}${CYAN}"
echo "MongoDB Dump Import Utility (mongorestore)"
echo -e "${NC}"

hr

command -v docker >/dev/null || die "docker not found"
[[ -n "$ARCHIVE_FILE" && -n "$TARGET_DB" && -n "$MODE" ]] || command -v fzf >/dev/null \
    || die "fzf is not installed — run: sudo apt install -y fzf"

[[ -f "$ENV_FILE" ]] || die ".env not found in the current working directory"

log "Loading .env"

set -a
source "$ENV_FILE"
set +a

: "${MONGO_AUTHDB:?}"
: "${MONGO_USER:?}"
: "${MONGO_PASS:?}"

MONGO_HOST="${MONGO_HOST:-mongo}"
MONGO_PORT="${MONGO_PORT:-27017}"

success "Configuration loaded"

hr

docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 \
    || die "Container '$CONTAINER_NAME' not found"

success "Container found"

hr

log "Checking MongoDB access"

mongosh_eval 'db.runCommand({ ping: 1 }).ok' | grep -q 1 \
    || die "MongoDB connection or authentication check failed"

success "MongoDB is reachable"

hr

# --- Select an archive ---

if [[ -z "$ARCHIVE_FILE" ]]; then
    [[ -d "$DUMP_DIR" ]] || die "Directory $DUMP_DIR not found — download backups first (backup-from-prod.sh)"

    NAMES=()
    DISPLAY=()
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        name="$(basename "$path")"
        meta="$(file_meta "$path")"
        mtime="${meta%% *}"
        size="${meta##* }"
        NAMES+=("$name")
        DISPLAY+=("$(printf '%s  %8s  %s' "$(fmt_date "$mtime")" "$(fmt_size "$size")" "$name")")
    done < <(find "$DUMP_DIR" -maxdepth 1 -type f -name '*.archive.gz' | sort)

    [[ "${#NAMES[@]}" -gt 0 ]] || die "No *.archive.gz files in $DUMP_DIR"

    # Sort by date, newest first.
    SORTED=()
    while IFS= read -r line; do
        SORTED+=("$line")
    done < <(printf '%s\n' "${DISPLAY[@]}" | sort -r)

    SELECTED="$(pick_one "Dump > " "Select an archive to restore" "${SORTED[@]}")"
    cancel_if_empty "$SELECTED"

    ARCHIVE_FILE="$DUMP_DIR/${SELECTED##* }"
fi

[[ -f "$ARCHIVE_FILE" ]] || die "File not found: $ARCHIVE_FILE"
[[ -s "$ARCHIVE_FILE" ]] || die "File is empty: $ARCHIVE_FILE"

ARCHIVE_NAME="$(basename "$ARCHIVE_FILE")"
ARCHIVE_META="$(file_meta "$ARCHIVE_FILE")"
ARCHIVE_SIZE="$(fmt_size "${ARCHIVE_META##* }")"
SOURCE_DB="$(db_from_filename "$ARCHIVE_NAME")"

[[ -n "$SOURCE_DB" ]] || die "Could not determine the database name from '$ARCHIVE_NAME'"

hr

# --- Select the target database ---

log "Fetching databases from the configured MongoDB instance"

LOCAL_DBS=()
while IFS= read -r dbname; do
    [[ -n "$dbname" ]] && LOCAL_DBS+=("$dbname")
done < <(
    mongosh_eval '
        db.adminCommand("listDatabases")
          .databases
          .map(x => x.name)
          .filter(x => !["admin","config","local"].includes(x))
          .join("\n")
    '
)

if [[ -z "$TARGET_DB" ]]; then
    OPT_SAME="Same as the archive: $SOURCE_DB"
    OPT_PICK="Choose an existing database"
    OPT_MANUAL="Enter a name manually"

    TARGET_OPTS=("$OPT_SAME")
    [[ "${#LOCAL_DBS[@]}" -gt 0 ]] && TARGET_OPTS+=("$OPT_PICK")
    TARGET_OPTS+=("$OPT_MANUAL")

    TARGET_CHOICE="$(pick_one "Target > " "Choose a target for archive '$ARCHIVE_NAME'" "${TARGET_OPTS[@]}")"
    cancel_if_empty "$TARGET_CHOICE"

    case "$TARGET_CHOICE" in
        "$OPT_SAME")
            TARGET_DB="$SOURCE_DB"
            ;;
        "$OPT_PICK")
            TARGET_DB="$(pick_one "Database > " "Existing databases in the configured MongoDB instance" "${LOCAL_DBS[@]}")"
            cancel_if_empty "$TARGET_DB"
            ;;
        "$OPT_MANUAL")
            flush_tty
            read -r -p "Target database name: " TARGET_DB
            [[ -n "$TARGET_DB" ]] || die "Empty database name"
            ;;
        *)
            die "Invalid selection"
            ;;
    esac
fi

case "$TARGET_DB" in
    admin|config|local) die "Restoring to system database '$TARGET_DB' is not allowed" ;;
    *[/\\.\ \"\$]*)     die "Invalid database name: '$TARGET_DB'" ;;
esac

# Check whether the target database already exists.
TARGET_EXISTS=0
for dbname in ${LOCAL_DBS[@]+"${LOCAL_DBS[@]}"}; do
    [[ "$dbname" == "$TARGET_DB" ]] && TARGET_EXISTS=1
done

hr

# --- Select the restore mode ---

MODE_REPLACE="Replace database — dropDatabase + restore (full replacement)"
MODE_DROP="Replace collections — mongorestore --drop (collections in the archive only)"
MODE_APPEND="Append — restore without dropping existing collections"

if [[ -z "$MODE" ]]; then
    STRATEGY="$(pick_one "Strategy > " "Choose how to restore into '$TARGET_DB'" \
        "$MODE_REPLACE" "$MODE_DROP" "$MODE_APPEND")"
    cancel_if_empty "$STRATEGY"

    case "$STRATEGY" in
        "$MODE_REPLACE") MODE="replace" ;;
        "$MODE_DROP")    MODE="drop" ;;
        "$MODE_APPEND")  MODE="append" ;;
        *) die "Unknown restore mode" ;;
    esac
else
    case "$MODE" in
        replace) STRATEGY="$MODE_REPLACE" ;;
        drop)    STRATEGY="$MODE_DROP" ;;
        append)  STRATEGY="$MODE_APPEND" ;;
        *) die "Unknown --mode: '$MODE' (replace|drop|append)" ;;
    esac
fi

RESTORE_ARGS=()
[[ "$MODE" == "drop" ]] && RESTORE_ARGS+=(--drop)

# Remap namespaces only when restoring to a different database.
if [[ "$TARGET_DB" != "$SOURCE_DB" ]]; then
    RESTORE_ARGS+=(--nsFrom="${SOURCE_DB}.*" --nsTo="${TARGET_DB}.*")
fi

# --- Summary and confirmation ---

clear 2>/dev/null || true

echo -e "${GREEN}${BOLD}Restore settings${NC}"
echo -e "${CYAN}File:${NC}      $ARCHIVE_NAME"
echo -e "${CYAN}Size:${NC}    $ARCHIVE_SIZE"
echo -e "${CYAN}Source database:${NC} $SOURCE_DB"
echo -e "${CYAN}Target database:${NC} $TARGET_DB$([[ "$TARGET_EXISTS" -eq 1 ]] && echo " ${DIM}(exists)${NC}" || echo " ${DIM}(will be created)${NC}")"
echo -e "${CYAN}Mode:${NC} $STRATEGY"
echo -e "${CYAN}Container:${NC} $CONTAINER_NAME"

hr

case "$MODE" in
    replace)
        warn "Database '$TARGET_DB' will be DROPPED (dropDatabase) if it exists and restored from the archive" ;;
    drop)
        warn "Collections in the archive will be DROPPED in '$TARGET_DB' and restored; other collections will remain" ;;
    append)
        warn "Data will be restored into '$TARGET_DB' without dropping existing collections; this is not an upsert" ;;
esac

if [[ "$ASSUME_YES" -ne 1 ]]; then
    flush_tty
    read -r -p "Type YES to confirm: " CONFIRM
    [[ "$CONFIRM" == "YES" ]] || die "Canceled by the user"
fi

hr

if [[ "$MODE" == "replace" && "$TARGET_EXISTS" -eq 1 ]]; then
    log "Dropping database '$TARGET_DB'"
    mongosh_eval "db.getSiblingDB('$TARGET_DB').dropDatabase()" >/dev/null \
        || die "Could not drop database '$TARGET_DB'"
    success "Database dropped"
    hr
fi

log "Running mongorestore"
echo

docker exec -i "$CONTAINER_NAME" mongorestore \
    --host "$MONGO_HOST" \
    --port "$MONGO_PORT" \
    --username "$MONGO_USER" \
    --password "$MONGO_PASS" \
    --authenticationDatabase "$MONGO_AUTHDB" \
    --archive \
    --gzip \
    ${RESTORE_ARGS[@]+"${RESTORE_ARGS[@]}"} \
    < "$ARCHIVE_FILE" \
    || die "mongorestore failed"

echo

success "Archive restored"

hr

log "Collections in '$TARGET_DB'"

mongosh_eval "
    db.getSiblingDB('$TARGET_DB')
      .getCollectionNames()
      .map(c => '  ' + c + ': ' + db.getSiblingDB('$TARGET_DB').getCollection(c).countDocuments({}))
      .join('\n')
"

hr
echo -e "${GREEN}${BOLD}Done${NC}"
hr

#EOF#
