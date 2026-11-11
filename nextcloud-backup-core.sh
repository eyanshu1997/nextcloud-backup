#!/bin/bash
# Nextcloud Core Backup Script, v2.1 (2026-11-11)
# Runs as a systemd service (backup.service). Management operations: backup-manager.sh.
#
# v2 changes (see ~/server-docs/backup-design.md):
#   * gentle on the server: nice/ionice idle, rsync --bwlimit, a per-night time limit (--stop-after); no -z (CPU), no --progress (log flood)
#   * safe: refuses to sync if the source data disk is not mounted or the Nextcloud marker file is missing, if the target is not a mounted
#     disk, and caps deletions (--max-delete); the DB password is passed via MYSQL_PWD, not argv
#   * differential history: files changed or deleted since the last run are moved to changes/<date>/ on the target (kept KEEP_CHANGED_DAYS)
#   * integrity: the DB dump is stream-compressed, gzip-tested, checked for mysqldump's completion marker, and its sha256 is compared after upload
#   * a run cut off by the time limit logs "PARTIAL:" (not an error) and simply continues the next night
# Log lines the monitoring parses: "Starting backup process...", "ERROR:", "PARTIAL:", "Backup process completed successfully", "Backup stats:".

export NC_BACKUP_V2=1   # backup.conf refuses to be used by the old v1 script unless this is set
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"
if [[ "$SCRIPT_DIR" == "/usr/local/bin" ]]; then
    CONFIG_FILE="/usr/local/bin/backup.conf"
fi
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# ---- tunables (override in backup.conf) ----
: "${RSYNC_BWLIMIT_KBPS:=1500}"        # KB/s cap on uploads (the Tailscale relay manages about 2500 KB/s)
: "${BACKUP_MAX_MINUTES:=420}"          # stop the data sync after this long; it resumes the next night
: "${KEEP_CHANGED_DAYS:=30}"            # how long changed/deleted files are kept in changes/
: "${MAX_DELETE:=2000}"                 # refuse to delete more than this many files in one run
: "${DUMP_KEEP_DAYS:=${MYSQL_RETENTION_DAYS:-14}}"
: "${DUMP_KEEP_MIN:=7}"                 # always keep at least this many newest dumps
: "${REMOTE_MOUNTPOINT:=/mnt/harddisk}" # must be a mounted disk on the target
: "${SOURCE_MARKER:=.ncdata}"           # Nextcloud's data-directory marker file (.ocdata on older versions)
: "${SOURCE_MOUNTPOINT:=/mnt/exdisk}"   # must be mounted on this server (empty = skip the check)
: "${MIN_DUMP_BYTES:=1000000}"
: "${RSYNC_EXCLUDES:=/nextcloud.log*,/appdata_*/preview,/*/uploads}"  # only Nextcloud-internal, regenerable or transient items; user files are never excluded
: "${MYSQLDUMP_EXTRA:=}"                # test hook (e.g. a table name)
: "${LOCAL_DUMP_KEEP_DAYS:=3}"

LOW="nice -n 19 ionice -c3"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'

get_ssh_target() {
    if [[ -n "$SSH_HOST" ]]; then echo "$SSH_HOST"; else echo "$REMOTE_USER@$REMOTE_HOST"; fi
}
log()     { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_DIR/backup.log"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
rsh()     { ssh $SSH_OPTS "$SSH_TARGET" "$@"; }

build_excludes() {
    EXCL=()
    IFS=',' read -ra E <<< "$RSYNC_EXCLUDES"
    for e in "${E[@]}"; do e=$(echo "$e" | xargs); [[ -n "$e" ]] && EXCL+=("--exclude=$e"); done
}

run_backup() {
    mkdir -p "$LOG_DIR" "$TEMP_DIR"
    # only one backup at a time (manual runs, the nightly timer and any bridge timer can never overlap)
    exec 9>/tmp/nextcloud-backup.lock
    if ! flock -n 9; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - SKIPPED: another backup run is still active" | tee -a "$LOG_DIR/backup.log"
        exit 0
    fi
    log "Starting backup process..."
    START=$(date +%s)
    SSH_TARGET=$(get_ssh_target)

    # 0. preflight: the target must be reachable AND be a mounted disk (never write into an empty mountpoint on the SD card)
    if ! rsh "mountpoint -q '$REMOTE_MOUNTPOINT'" 2>>"$LOG_DIR/backup.log"; then
        log "ERROR: Backup target is not reachable or $REMOTE_MOUNTPOINT is not a mounted disk on $SSH_TARGET"
        exit 1
    fi

    # 1. MySQL dump, streamed straight into gzip (no multi-GB temp file); password via environment, not argv
    log "Creating MySQL dump for database: $DB_NAME"
    TIMESTAMP=$(date +%Y-%m-%d_%H:%M:%S)
    DUMP_FILE="$TEMP_DIR/mysql_dump_${TIMESTAMP}.sql.gz"
    if ! ( set -o pipefail
           MYSQL_PWD="$DB_PASSWORD" $LOW mysqldump --single-transaction --quick -u"$DB_USER" "$DB_NAME" $MYSQLDUMP_EXTRA 2>>"$LOG_DIR/backup.log" \
             | $LOW gzip -1 > "$DUMP_FILE" ); then
        rm -f "$DUMP_FILE"
        log "ERROR: Failed to create MySQL dump"
        exit 1
    fi
    log "MySQL dump created and compressed: $DUMP_FILE"

    # 2. dump integrity: gzip test, completion marker written by mysqldump, plausible size
    if ! $LOW gzip -t "$DUMP_FILE" 2>>"$LOG_DIR/backup.log" \
       || ! $LOW zcat "$DUMP_FILE" | tail -c 400 | grep -q "Dump completed" \
       || [[ $(stat -c%s "$DUMP_FILE") -lt $MIN_DUMP_BYTES ]]; then
        log "ERROR: MySQL dump failed the integrity check (gzip test / completion marker / size)"
        exit 1
    fi
    log "MySQL dump verified (gzip test, completion marker, size)"

    # 3. upload the dump and compare checksums on both ends
    REMOTE_DB_DIR="$REMOTE_BACKUP_DIR/mysql"
    if ! rsh "mkdir -p '$REMOTE_DB_DIR'" 2>>"$LOG_DIR/backup.log"; then
        log "ERROR: Failed to create remote MySQL directory"
        exit 1
    fi
    if ! $LOW rsync -a --partial-dir=.rsync-partial --bwlimit="$RSYNC_BWLIMIT_KBPS" -e "ssh $SSH_OPTS" \
            "$DUMP_FILE" "$SSH_TARGET:$REMOTE_DB_DIR/" 2>>"$LOG_DIR/backup.log"; then
        log "ERROR: Failed to sync MySQL dump to remote server"
        exit 1
    fi
    LSUM=$($LOW sha256sum "$DUMP_FILE" | awk '{print $1}')
    RSUM=$(rsh "sha256sum '$REMOTE_DB_DIR/$(basename "$DUMP_FILE")'" 2>>"$LOG_DIR/backup.log" | awk '{print $1}')
    if [[ -z "$LSUM" || "$LSUM" != "$RSUM" ]]; then
        log "ERROR: MySQL dump checksum mismatch after upload (local $LSUM, remote ${RSUM:-none})"
        exit 1
    fi
    log "MySQL dump uploaded and checksum verified"

    # 4. data directories: differential (rsync only sends what changed), throttled, guarded
    log "Starting incremental directory backup..."
    build_excludes
    PARTIAL=0
    IFS=',' read -ra DIRS <<< "$BACKUP_DIRS"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)
        if [[ ! -d "$dir" ]]; then log "WARNING: Directory not found: $dir"; continue; fi
        if [[ -n "$SOURCE_MOUNTPOINT" ]] && ! mountpoint -q "$SOURCE_MOUNTPOINT"; then
            log "ERROR: Source guard: $SOURCE_MOUNTPOINT is not mounted, refusing to sync $dir"; exit 1
        fi
        if [[ -n "$SOURCE_MARKER" && ! -e "$dir/$SOURCE_MARKER" ]]; then
            log "ERROR: Source guard: $dir/$SOURCE_MARKER is missing, refusing to sync (an empty source would erase the backup)"; exit 1
        fi
        log "Backing up directory: $dir"
        DIR_NAME=$(basename "$dir")
        REMOTE_DIR_PATH="$REMOTE_BACKUP_DIR/directories/$DIR_NAME"
        CHANGES_DIR="$REMOTE_BACKUP_DIR/changes/$(date +%F)/$DIR_NAME"
        rsh "mkdir -p '$REMOTE_DIR_PATH' '$CHANGES_DIR'" 2>>"$LOG_DIR/backup.log"
        log "Using throttled differential rsync (limit ${RSYNC_BWLIMIT_KBPS} KB/s, stop after ${BACKUP_MAX_MINUTES} min)"
        STATS=$(mktemp)
        $LOW rsync -rlptD --no-human-readable --info=stats2,name0 \
            --partial-dir=.rsync-partial --delete-delay --max-delete="$MAX_DELETE" \
            --backup --backup-dir="$CHANGES_DIR" \
            --bwlimit="$RSYNC_BWLIMIT_KBPS" --stop-after="$BACKUP_MAX_MINUTES" \
            "${EXCL[@]}" -e "ssh $SSH_OPTS" \
            "$dir/" "$SSH_TARGET:$REMOTE_DIR_PATH/" > "$STATS" 2>>"$LOG_DIR/backup.log"
        rc=$?
        ELAPSED=$(( $(date +%s) - START ))
        FILES=$(awk -F': ' '/Number of regular files transferred/{gsub(/[^0-9]/,"",$2);print $2}' "$STATS")
        BYTES=$(awk -F': ' '/Total transferred file size/{gsub(/[^0-9]/,"",$2);print $2}' "$STATS")
        rm -f "$STATS"
        case $rc in
            0|24) log "Successfully backed up directory: $dir" ;;
            30)
                if [[ $ELAPSED -ge $(( BACKUP_MAX_MINUTES * 60 - 120 )) ]]; then
                    PARTIAL=1
                    log "PARTIAL: time limit of ${BACKUP_MAX_MINUTES} min reached for $dir; it will continue at the next run"
                else
                    log "ERROR: rsync timed out after ${ELAPSED}s while backing up $dir"; exit 1
                fi ;;
            25) log "ERROR: rsync refused to delete more than $MAX_DELETE files in $dir (source may be damaged)"; exit 1 ;;
            *)  log "ERROR: Failed to backup directory: $dir (rsync exit $rc)"; exit 1 ;;
        esac
        log "Backup stats: dir=$DIR_NAME files_transferred=${FILES:-0} bytes_transferred=${BYTES:-0} seconds=$(( $(date +%s) - START ))"

        # how much is still missing on the target? A dry run (file lists only, no data) gives the exact remaining size: it drives the
        # "first copy progress" in Home Assistant and doubles as a quick completeness check when the sync finished
        RSTATS=$(mktemp)
        timeout 1800 $LOW rsync -rlptD -n --no-human-readable --info=stats2,name0 "${EXCL[@]}" -e "ssh $SSH_OPTS" \
            "$dir/" "$SSH_TARGET:$REMOTE_DIR_PATH/" > "$RSTATS" 2>>"$LOG_DIR/backup.log"
        if [[ $? -eq 0 ]]; then
            RFILES=$(awk -F': ' '/Number of regular files transferred/{gsub(/[^0-9]/,"",$2);print $2}' "$RSTATS")
            RBYTES=$(awk -F': ' '/Total transferred file size/{gsub(/[^0-9]/,"",$2);print $2}' "$RSTATS")
            TFILES=$(awk -F': ' '/Number of files:/{gsub(/[^0-9].*/,"",$2);print $2}' "$RSTATS")
            log "Backup remaining: dir=$DIR_NAME files=${RFILES:-0} bytes=${RBYTES:-0} source_files=${TFILES:-0}"
        else
            log "WARNING: could not measure the remaining size for $dir"
        fi
        rm -f "$RSTATS"
    done

    # 4b. disaster-recovery config bundle (config.php, store-app list, Apache/PHP/MariaDB settings, compose files): needed to rebuild on a fresh VM; never fatal
    BUNDLE="$SCRIPT_DIR/dr-config-bundle.sh"; [[ -x "$BUNDLE" ]] || BUNDLE=/usr/local/bin/dr-config-bundle.sh
    if [[ -x "$BUNDLE" ]]; then "$BUNDLE" >/dev/null 2>>"$LOG_DIR/backup.log" || log "WARNING: config bundle step failed"; else log "WARNING: dr-config-bundle.sh is not installed next to the backup script"; fi

    # 5. housekeeping (never fatal)
    find "$TEMP_DIR" -name 'mysql_dump_*.sql.gz' -mtime +"$LOCAL_DUMP_KEEP_DAYS" -delete 2>/dev/null   # keep the newest few for cross-checks
    rsh "cd '$REMOTE_DB_DIR' && find . -maxdepth 1 -name '.mysql_dump_*' -mtime +2 -delete; \
         ls -1t mysql_dump_*.sql.gz 2>/dev/null | tail -n +$((DUMP_KEEP_MIN + 1)) | while read -r f; do \
           [ -n \"\$(find \"\$f\" -mtime +$DUMP_KEEP_DAYS 2>/dev/null)\" ] && rm -f \"\$f\"; done; \
         find '$REMOTE_BACKUP_DIR/changes' -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' -mtime +$KEEP_CHANGED_DAYS -exec rm -rf {} +" \
        2>>"$LOG_DIR/backup.log" || log "WARNING: housekeeping on the target failed"

    if [[ $PARTIAL -eq 1 ]]; then
        log "Backup process paused at the time limit (database dump done; data sync continues next run)"
    else
        log "Backup process completed successfully"
    fi
}

test_config() {
    info "Testing configuration..."
    SSH_TARGET=$(get_ssh_target)
    if rsh "echo 'SSH OK'" >/dev/null 2>&1; then success "SSH connection to $SSH_TARGET"; else error "SSH connection failed to $SSH_TARGET"; exit 1; fi
    if rsh "mountpoint -q '$REMOTE_MOUNTPOINT'" 2>/dev/null; then success "$REMOTE_MOUNTPOINT is a mounted disk on the target"; else error "$REMOTE_MOUNTPOINT is not mounted on the target"; exit 1; fi
    if MYSQL_PWD="$DB_PASSWORD" mysql -u"$DB_USER" -e "USE $DB_NAME; SELECT 1;" >/dev/null 2>&1; then success "MySQL connection (database $DB_NAME)"; else error "MySQL connection failed"; exit 1; fi
    IFS=',' read -ra DIRS <<< "$BACKUP_DIRS"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)
        [[ -d "$dir" ]] && success "Directory exists: $dir" || { error "Directory not found: $dir"; exit 1; }
        [[ -z "$SOURCE_MARKER" || -e "$dir/$SOURCE_MARKER" ]] && success "Source marker present" || { error "$dir/$SOURCE_MARKER missing"; exit 1; }
    done
    rsync --help 2>&1 | grep -q -- '--stop-after' && success "rsync supports --stop-after" || { error "rsync too old for --stop-after"; exit 1; }
    success "Configuration test completed"
}

case "${1:-backup}" in
    "backup") run_backup ;;
    "test")   test_config ;;
    *) echo "Core backup script - Usage: $0 {backup|test}"; echo "For management operations, use backup-manager.sh"; exit 1 ;;
esac
