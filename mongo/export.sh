#!/usr/bin/env bash

# apt update
# apt install -y fzf

set -Eeuo pipefail

ENV_FILE=".env"
CONTAINER_NAME="mongo7"
BACKUP_DIR="/www/server/mongo/dump"
TIMESTAMP="$(date +%F_%H-%M-%S)"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
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

spinner() {
    local pid="$1"
    local message="$2"
    local frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${BLUE}%s${NC} %s" "${frames:i++%${#frames}:1}" "$message"
        sleep 0.1
    done

    wait "$pid"
    local status=$?

    printf "\r\033[K"

    return "$status"
}

human_size() {
    du -h "$1" | awk '{print $1}'
}

cleanup_partial() {
    if [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]]; then
        rm -f "$BACKUP_FILE"
    fi
}

# Dump one database to a separate archive. Set the global BACKUP_FILE
# so cleanup_partial can remove the incomplete archive if interrupted.
dump_one() {
    local db="$1"

    BACKUP_FILE="${BACKUP_DIR}/${db}_${TIMESTAMP}.archive.gz"

    (
        docker exec "$CONTAINER_NAME" mongodump \
            --host "$MONGO_HOST" \
            --port "$MONGO_PORT" \
            --username "$MONGO_USER" \
            --password "$MONGO_PASS" \
            --authenticationDatabase "$MONGO_AUTHDB" \
            --db "$db" \
            --archive \
            --gzip \
            > "$BACKUP_FILE"
    ) &

    local dump_pid=$!

    if spinner "$dump_pid" "Running mongodump: ${db}"; then
        success "Backup created successfully"
    else
        cleanup_partial
        die "Failed to back up database '${db}'"
    fi

    [[ -s "$BACKUP_FILE" ]] || die "Empty backup file for database '${db}'"

    local size
    size=$(human_size "$BACKUP_FILE")

    echo -e "${CYAN}Database:${NC} $db"
    echo -e "${CYAN}File:${NC}     $BACKUP_FILE"
    echo -e "${CYAN}Size:${NC}     $size"
    echo
}

trap 'cleanup_partial' INT TERM

clear

echo -e "${BOLD}${CYAN}"
echo "MongoDB Backup Utility"
echo -e "${NC}"

hr

command -v docker >/dev/null || die "docker not found"
command -v fzf >/dev/null || die "fzf is not installed"

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

docker exec "$CONTAINER_NAME" mongosh \
    --host "$MONGO_HOST" \
    --port "$MONGO_PORT" \
    --username "$MONGO_USER" \
    --password "$MONGO_PASS" \
    --authenticationDatabase "$MONGO_AUTHDB" \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' \
    | grep -q 1 \
    || die "MongoDB connection or authentication check failed"

success "MongoDB is reachable"

hr

log "Fetching the database list"

mapfile -t DATABASES < <(
    docker exec "$CONTAINER_NAME" mongosh \
        --host "$MONGO_HOST" \
        --port "$MONGO_PORT" \
        --username "$MONGO_USER" \
        --password "$MONGO_PASS" \
        --authenticationDatabase "$MONGO_AUTHDB" \
        --quiet \
        --eval '
            db.adminCommand("listDatabases")
              .databases
              .map(x => x.name)
              .filter(x => !["admin","config","local"].includes(x))
              .join("\n")
        '
)

[[ ${#DATABASES[@]} -gt 0 ]] || die "No databases found"

# fzf returns the marked databases, or the current row if none are marked.
if SELECTED_DBS=$(
    printf '%s\n' "${DATABASES[@]}" |
    fzf \
        --multi \
        --marker='☑' \
        --pointer='>' \
        --bind='space:toggle,ctrl-a:select-all,ctrl-d:deselect-all' \
        --height=15 \
        --border \
        --reverse \
        --prompt="Mongo DB > " \
        --header="Space: ☑ | Ctrl+A: all | Ctrl+D: clear | Enter: back up | Esc: cancel"
); then
    [[ -n "$SELECTED_DBS" ]] || die "No databases selected"
else
    selection_status=$?
    if [[ "$selection_status" -eq 130 ]]; then
        warn "Backup canceled"
        exit 0
    fi
    die "Could not select databases (fzf: ${selection_status})"
fi

mapfile -t SELECTED_DATABASES <<< "$SELECTED_DBS"

mkdir -p "$BACKUP_DIR"

clear

echo -e "${GREEN}${BOLD}Selected databases:${NC} ${CYAN}${#SELECTED_DATABASES[@]}${NC}"
printf '  ☑ %s\n' "${SELECTED_DATABASES[@]}"
hr
log "Creating backups"
echo

for db in "${SELECTED_DATABASES[@]}"; do
    dump_one "$db"
done

hr
echo -e "${GREEN}${BOLD}Backup completed (databases: ${#SELECTED_DATABASES[@]})${NC}"
echo
hr

#EOF#