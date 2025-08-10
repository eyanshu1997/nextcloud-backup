#!/bin/bash

# Nextcloud Core Backup Script
# This script only performs backup operations and is designed to run as a systemd service
# For management operations, use the backup-manager.sh script

# Configuration file path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"

# If running from system location, use system config path
if [[ "$SCRIPT_DIR" == "/usr/local/bin" ]]; then
    CONFIG_FILE="/usr/local/bin/backup.conf"
fi

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to check if filename is NTFS compatible
is_ntfs_compatible() {
    local file_path="$1"
    local filename=$(basename "$file_path")
    
    # Check for forbidden characters: < > : " | ? * \
    if [[ "$file_path" =~ [\<\>\:\"\|\?\*\\] ]]; then
        return 1
    fi
    
    # Check if filename ends with space or period
    if [[ "$filename" =~ [\ \.]+$ ]]; then
        return 1
    fi
    
    # Check for Windows reserved names (case insensitive)
    if echo "$filename" | grep -iE '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)' >/dev/null; then
        return 1
    fi
    
    return 0
}

# Function to get SSH connection string
get_ssh_target() {
    if [[ -n "$SSH_HOST" ]]; then
        echo "$SSH_HOST"
    else
        echo "$REMOTE_USER@$REMOTE_HOST"
    fi
}

# Function to log skipped files
log_skipped() {
    local file_path="$1"
    local reason="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - SKIPPED: $file_path - $reason" >> "$LOG_DIR/backup_skipped.log"
}

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_DIR/backup.log"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Main backup function
run_backup() {
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    mkdir -p "$TEMP_DIR"

    log "Starting backup process..."

    # 1. Create MySQL dump
    log "Creating MySQL dump for database: $DB_NAME"
    
    # Create NTFS-safe timestamp if needed
    if [[ "$NTFS_COMPATIBILITY" == "true" ]]; then
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    else
        TIMESTAMP=$(date +%Y-%m-%d_%H:%M:%S)
    fi
    
    DUMP_FILE="$TEMP_DIR/mysql_dump_${TIMESTAMP}.sql"
    if ! mysqldump --single-transaction -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" > "$DUMP_FILE" 2>>"$LOG_DIR/backup.log"; then
        log "ERROR: Failed to create MySQL dump"
        exit 1
    fi

    # 2. Compress the dump
    if ! gzip "$DUMP_FILE" 2>>"$LOG_DIR/backup.log"; then
        log "ERROR: Failed to compress MySQL dump"
        exit 1
    fi
    DUMP_FILE="${DUMP_FILE}.gz"
    log "MySQL dump created and compressed: $DUMP_FILE"

    # 3. Sync MySQL dump to remote server
    log "Syncing MySQL dump to remote server..."
    SSH_TARGET=$(get_ssh_target)
    REMOTE_DB_DIR="$REMOTE_BACKUP_DIR/mysql"
    if ! ssh "$SSH_TARGET" "mkdir -p $REMOTE_DB_DIR" 2>>"$LOG_DIR/backup.log"; then
        log "ERROR: Failed to create remote MySQL directory"
        exit 1
    fi

    # Use appropriate rsync options based on NTFS compatibility
    if [[ "$NTFS_COMPATIBILITY" == "true" ]]; then
        if ! rsync -avz --progress --modify-window=1 "$DUMP_FILE" "$SSH_TARGET:$REMOTE_DB_DIR/" 2>>"$LOG_DIR/backup.log"; then
            log "ERROR: Failed to sync MySQL dump to remote server"
            exit 1
        fi
    else
        if ! rsync -avz --progress "$DUMP_FILE" "$SSH_TARGET:$REMOTE_DB_DIR/" 2>>"$LOG_DIR/backup.log"; then
            log "ERROR: Failed to sync MySQL dump to remote server"
            exit 1
        fi
    fi

    # 4. Perform incremental directory backup
    log "Starting incremental directory backup..."
    SSH_TARGET=$(get_ssh_target)
    IFS=',' read -ra DIRS <<< "$BACKUP_DIRS"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)
        if [[ -d "$dir" ]]; then
            log "Backing up directory: $dir"
            DIR_NAME=$(basename "$dir")
            REMOTE_DIR_PATH="$REMOTE_BACKUP_DIR/directories/$DIR_NAME"
            
            ssh "$SSH_TARGET" "mkdir -p $REMOTE_DIR_PATH" 2>>"$LOG_DIR/backup.log"
            
            # Check if NTFS compatibility is required
            if [[ "$NTFS_COMPATIBILITY" == "true" ]]; then
                log "Using NTFS compatibility mode - checking for incompatible files..."
                
                # Create exclude file for NTFS incompatible items
                EXCLUDE_FILE="$TEMP_DIR/ntfs_excludes.txt"
                > "$EXCLUDE_FILE"  # Clear the file
                
                # Find and exclude NTFS incompatible files/directories
                while IFS= read -r -d '' item; do
                    if ! is_ntfs_compatible "$item"; then
                        # Get relative path for exclusion
                        rel_path="${item#$dir/}"
                        echo "$rel_path" >> "$EXCLUDE_FILE"
                        log_skipped "$item" "NTFS incompatible filename"
                        log "SKIPPED: $item (NTFS incompatible)"
                    fi
                done < <(find "$dir" -print0)
                
                # Perform rsync with exclusions
                if [[ -s "$EXCLUDE_FILE" ]]; then
                    log "Excluding $(wc -l < "$EXCLUDE_FILE") incompatible items"
                    if ! rsync -avz --delete --progress \
                        --exclude-from="$EXCLUDE_FILE" \
                        --exclude=".git" --exclude=".DS_Store" --exclude="*.tmp" \
                        --modify-window=1 \
                        "$dir/" "$SSH_TARGET:$REMOTE_DIR_PATH/" 2>>"$LOG_DIR/backup.log"; then
                        log "ERROR: Failed to backup directory: $dir"
                        exit 1
                    fi
                else
                    log "No incompatible files found"
                    if ! rsync -avz --delete --progress \
                        --exclude=".git" --exclude=".DS_Store" --exclude="*.tmp" \
                        --modify-window=1 \
                        "$dir/" "$SSH_TARGET:$REMOTE_DIR_PATH/" 2>>"$LOG_DIR/backup.log"; then
                        log "ERROR: Failed to backup directory: $dir"
                        exit 1
                    fi
                fi
                
                # Clean up exclude file
                rm -f "$EXCLUDE_FILE"
            else
                log "Using standard rsync (no NTFS compatibility mode)"
                # Standard rsync without NTFS compatibility
                if ! rsync -avz --delete --progress \
                    --exclude=".git" --exclude=".DS_Store" --exclude="*.tmp" \
                    "$dir/" "$SSH_TARGET:$REMOTE_DIR_PATH/" 2>>"$LOG_DIR/backup.log"; then
                    log "ERROR: Failed to backup directory: $dir"
                    exit 1
                fi
            fi
            
            log "Successfully backed up directory: $dir"
        else
            log "WARNING: Directory not found: $dir"
        fi
    done

    # 5. Clean up
    rm -f "$TEMP_DIR"/*.sql.gz 2>/dev/null
    SSH_TARGET=$(get_ssh_target)
    # Use configured retention period, default to 7 days if not set
    RETENTION_DAYS="${MYSQL_RETENTION_DAYS:-7}"
    ssh "$SSH_TARGET" "find $REMOTE_DB_DIR -name '*.sql.gz' -mtime +$RETENTION_DAYS -delete" 2>/dev/null

    # Show skipped files summary if any
    if [[ -f "$LOG_DIR/backup_skipped.log" ]]; then
        SKIPPED_COUNT=$(wc -l < "$LOG_DIR/backup_skipped.log" 2>/dev/null || echo "0")
        if [[ "$SKIPPED_COUNT" -gt 0 ]]; then
            log "WARNING: $SKIPPED_COUNT files were skipped due to NTFS incompatibility"
            log "Check $LOG_DIR/backup_skipped.log for details"
        fi
    fi

    log "Backup process completed successfully"
}

# Test configuration (minimal version for core script)
test_config() {
    info "Testing configuration..."
    
    # Test SSH connection
    SSH_TARGET=$(get_ssh_target)
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET" "echo 'SSH OK'" 2>/dev/null; then
        success "✓ SSH connection successful to $SSH_TARGET"
    else
        error "✗ SSH connection failed to $SSH_TARGET"
        exit 1
    fi
    
    # Test MySQL connection
    if mysql -u"$DB_USER" -p"$DB_PASSWORD" -e "USE $DB_NAME; SELECT 1;" >/dev/null 2>&1; then
        success "✓ MySQL connection successful (database: $DB_NAME, user: $DB_USER)"
    else
        error "✗ MySQL connection failed (database: $DB_NAME, user: $DB_USER)"
        exit 1
    fi
    
    # Check directories
    IFS=',' read -ra DIRS <<< "$BACKUP_DIRS"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)
        if [[ -d "$dir" ]]; then
            success "✓ Directory exists: $dir"
        else
            error "✗ Directory not found: $dir"
            exit 1
        fi
    done
    
    success "Configuration test completed"
}

# Main logic - only backup and test operations
case "${1:-backup}" in
    "backup")
        run_backup
        ;;
    "test")
        test_config
        ;;
    *)
        echo "Core backup script - Usage: $0 {backup|test}"
        echo "For management operations, use backup-manager.sh"
        exit 1
        ;;
esac
