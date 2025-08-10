#!/bin/bash

# Nextcloud Remote Device SSH Backup Script
# Single script solution for backing up Nextcloud installations to remote devices via SSH
# Performs incremental directory and MySQL backups with systemd service management

# Configuration (edit these values)
BACKUP_DIRS="/var/www/nextcloud/data/"
REMOTE_HOST="raspi"
REMOTE_USER="backup"
REMOTE_BACKUP_DIR="/mnt/harddisk/home-server-backup/"
DB_NAME="nextcloud"
DB_PASSWORD=""
LOG_DIR="/var/log/backup"
TEMP_DIR="/tmp/backup"
# Set to "true" if remote backup location is NTFS filesystem (skips incompatible files)
NTFS_COMPATIBILITY="true"
# SSH host from ~/.ssh/config (leave empty to use REMOTE_HOST directly)
SSH_HOST=""

# NTFS Compatibility Notes:
# When NTFS_COMPATIBILITY is set to "true", the script will:
# 1. Use NTFS-safe timestamps (no colons)
# 2. Add --modify-window=1 to rsync (NTFS has 2-second timestamp resolution)
# 3. Skip files/folders with NTFS-incompatible characters and log them
# 4. Create a separate log file for skipped items: backup_skipped.log
# 
# NTFS incompatible characters: : * ? " < > | \
# Also skips files ending with spaces or periods, and Windows reserved names

# Script locations
SCRIPT_PATH="/usr/local/bin/backup.sh"
SERVICE_FILE="/etc/systemd/system/backup.service"
TIMER_FILE="/etc/systemd/system/backup.timer"
LOGROTATE_FILE="/etc/logrotate.d/backup"

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

# Function to check if rsync supports character translation
check_rsync_iconv() {
    if rsync --help 2>/dev/null | grep -q "iconv"; then
        return 0
    else
        return 1
    fi
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
    if ! mysqldump --single-transaction "$DB_NAME" -p"$DB_PASSWORD" > "$DUMP_FILE" 2>>"$LOG_DIR/backup.log"; then
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
    ssh "$SSH_TARGET" "find $REMOTE_DB_DIR -name '*.sql.gz' -mtime +7 -delete" 2>/dev/null

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

# Install function
install() {
    if [[ $EUID -ne 0 ]]; then
        error "Installation must be run as root"
        exit 1
    fi

    info "Installing backup system..."

    # Copy this script to system location
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    # Create systemd service file
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Backup Service - Incremental backup of directories and MySQL to remote server
After=network.target mysql.service
Wants=network.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/local/bin/backup.sh backup
StandardOutput=journal
StandardError=journal
TimeoutSec=3600
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/log/backup /tmp/backup
ProtectHome=read-only
EOF

    # Create systemd timer file
    cat > "$TIMER_FILE" << 'EOF'
[Unit]
Description=Run backup service daily
Requires=backup.service

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    # Create logrotate configuration
    cat > "$LOGROTATE_FILE" << 'EOF'
/var/log/backup/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF

    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Reload systemd
    systemctl daemon-reload

    success "Installation completed!"
    info "Next steps:"
    info "1. Edit configuration in $SCRIPT_PATH (lines 6-12)"
    info "2. Set up SSH key authentication: ssh-copy-id $REMOTE_USER@$REMOTE_HOST"
    info "3. Test: $SCRIPT_PATH test"
    info "4. Enable: $SCRIPT_PATH enable"
}

# Uninstall function
uninstall() {
    if [[ $EUID -ne 0 ]]; then
        error "Uninstall must be run as root"
        exit 1
    fi

    info "Uninstalling backup system..."
    
    systemctl stop backup.timer 2>/dev/null || true
    systemctl disable backup.timer 2>/dev/null || true
    
    rm -f "$SCRIPT_PATH" "$SERVICE_FILE" "$TIMER_FILE" "$LOGROTATE_FILE"
    systemctl daemon-reload
    
    success "Uninstallation completed!"
}

# Test configuration
test_config() {
    info "Testing configuration..."
    
    # Test NTFS compatibility settings
    if [[ "$NTFS_COMPATIBILITY" == "true" ]]; then
        info "NTFS compatibility mode: ENABLED (skipping incompatible files)"
        
        # Test NTFS-safe timestamp
        NTFS_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        info "NTFS-safe timestamp format: $NTFS_TIMESTAMP"
    else
        info "NTFS compatibility mode: DISABLED"
    fi
    
    # Test SSH configuration
    SSH_TARGET=$(get_ssh_target)
    if [[ -n "$SSH_HOST" ]]; then
        info "Using SSH host from config: $SSH_HOST"
    else
        info "Using direct connection: $REMOTE_USER@$REMOTE_HOST"
    fi
    
    # Test SSH connection
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET" "echo 'SSH OK'" 2>/dev/null; then
        success "✓ SSH connection successful to $SSH_TARGET"
    else
        error "✗ SSH connection failed to $SSH_TARGET"
        if [[ -z "$SSH_HOST" ]]; then
            info "Run: ssh-copy-id $REMOTE_USER@$REMOTE_HOST"
        else
            info "Check your SSH config for host: $SSH_HOST"
        fi
        return 1
    fi
    
    # Test MySQL
    if mysqladmin -u root -p"$DB_PASSWORD" ping 2>/dev/null | grep -q "mysqld is alive"; then
        success "✓ MySQL connection successful"
    else
        error "✗ MySQL connection failed"
        return 1
    fi
    
    # Check directories
    IFS=',' read -ra DIRS <<< "$BACKUP_DIRS"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)
        if [[ -d "$dir" ]]; then
            success "✓ Directory exists: $dir"
        else
            error "✗ Directory not found: $dir"
        fi
    done
    
    success "Configuration test completed"
}

# Service management functions
enable_service() {
    if [[ $EUID -ne 0 ]]; then
        error "Must be run as root"
        exit 1
    fi
    systemctl enable backup.timer
    systemctl start backup.timer
    success "Automatic backups enabled"
}

disable_service() {
    if [[ $EUID -ne 0 ]]; then
        error "Must be run as root"
        exit 1
    fi
    systemctl disable backup.timer
    systemctl stop backup.timer
    success "Automatic backups disabled"
}

show_status() {
    systemctl status backup.service --no-pager || true
    echo ""
    systemctl status backup.timer --no-pager || true
    echo ""
    systemctl list-timers backup.timer --no-pager || true
}

show_logs() {
    local lines="${1:-50}"
    journalctl -u backup.service -n "$lines" --no-pager || true
    echo ""
    if [[ -f "$LOG_DIR/backup.log" ]]; then
        echo "=== Application Logs ==="
        tail -n "$lines" "$LOG_DIR/backup.log"
    fi
}

run_manual() {
    if [[ $EUID -ne 0 ]]; then
        error "Must be run as root"
        exit 1
    fi
    systemctl start backup.service
    info "Backup started. Check logs with: $0 logs"
}

show_skipped() {
    local lines="${1:-50}"
    if [[ -f "$LOG_DIR/backup_skipped.log" ]]; then
        echo "=== Recently Skipped Files (NTFS Incompatible) ==="
        tail -n "$lines" "$LOG_DIR/backup_skipped.log"
        echo ""
        echo "Total skipped files: $(wc -l < "$LOG_DIR/backup_skipped.log")"
    else
        info "No skipped files log found"
    fi
}

show_help() {
    echo "Nextcloud Remote Device SSH Backup System"
    echo ""
    echo "Usage: $0 {install|uninstall|backup|test|enable|disable|status|logs|skipped|run|help}"
    echo ""
    echo "Commands:"
    echo "  install   - Install backup system"
    echo "  uninstall - Remove backup system"
    echo "  backup    - Run backup process"
    echo "  test      - Test configuration"
    echo "  enable    - Enable automatic daily backups"
    echo "  disable   - Disable automatic backups"
    echo "  status    - Show service status"
    echo "  logs      - Show logs"
    echo "  skipped   - Show skipped files (NTFS incompatible)"
    echo "  run       - Run backup manually via systemd"
    echo "  help      - Show this help"
    echo ""
    echo "Configuration:"
    echo "  NTFS_COMPATIBILITY  - Set to 'true' to skip NTFS-incompatible files"
    echo "  SSH_HOST           - Use SSH config host instead of REMOTE_USER@REMOTE_HOST"
    echo ""
    echo "NTFS Mode:"
    echo "  When enabled, skips files with characters: : * ? \" < > | \\"
    echo "  Skipped files are logged to: /var/log/backup/backup_skipped.log"
}

# Main script logic
case "${1:-help}" in
    "install")
        install
        ;;
    "uninstall")
        uninstall
        ;;
    "backup")
        run_backup
        ;;
    "test")
        test_config
        ;;
    "enable")
        enable_service
        ;;
    "disable")
        disable_service
        ;;
    "status")
        show_status
        ;;
    "logs")
        show_logs "$2"
        ;;
    "skipped")
        show_skipped "$2"
        ;;
    "run")
        run_manual
        ;;
    *)
        show_help
        ;;
esac
