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
    DUMP_FILE="$TEMP_DIR/mysql_dump_$(date +%Y%m%d_%H%M%S).sql"
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
    REMOTE_DB_DIR="$REMOTE_BACKUP_DIR/mysql"
    if ! ssh "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_DB_DIR" 2>>"$LOG_DIR/backup.log"; then
        log "ERROR: Failed to create remote MySQL directory"
        exit 1
    fi

    if ! rsync -avz --progress "$DUMP_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DB_DIR/" 2>>"$LOG_DIR/backup.log"; then
        log "ERROR: Failed to sync MySQL dump to remote server"
        exit 1
    fi

    # 4. Perform incremental directory backup
    log "Starting incremental directory backup..."
    IFS=',' read -ra DIRS <<< "$BACKUP_DIRS"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)
        if [[ -d "$dir" ]]; then
            log "Backing up directory: $dir"
            DIR_NAME=$(basename "$dir")
            REMOTE_DIR_PATH="$REMOTE_BACKUP_DIR/directories/$DIR_NAME"
            
            ssh "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_DIR_PATH" 2>>"$LOG_DIR/backup.log"
            
            if ! rsync -avz --delete --progress \
                --exclude=".git" --exclude=".DS_Store" --exclude="*.tmp" \
                "$dir/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR_PATH/" 2>>"$LOG_DIR/backup.log"; then
                log "ERROR: Failed to backup directory: $dir"
                exit 1
            fi
            log "Successfully backed up directory: $dir"
        else
            log "WARNING: Directory not found: $dir"
        fi
    done

    # 5. Clean up
    rm -f "$TEMP_DIR"/*.sql.gz 2>/dev/null
    ssh "$REMOTE_USER@$REMOTE_HOST" "find $REMOTE_DB_DIR -name '*.sql.gz' -mtime +7 -delete" 2>/dev/null

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
    
    # Test SSH
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" "echo 'SSH OK'" 2>/dev/null; then
        success "✓ SSH connection successful"
    else
        error "✗ SSH connection failed"
        info "Run: ssh-copy-id $REMOTE_USER@$REMOTE_HOST"
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

show_help() {
    echo "Nextcloud Remote Device SSH Backup System"
    echo ""
    echo "Usage: $0 {install|uninstall|backup|test|enable|disable|status|logs|run|help}"
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
    echo "  run       - Run backup manually via systemd"
    echo "  help      - Show this help"
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
    "run")
        run_manual
        ;;
    *)
        show_help
        ;;
esac

