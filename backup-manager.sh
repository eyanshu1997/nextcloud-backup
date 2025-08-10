#!/bin/bash

# Nextcloud Backup Manager Script
# This script handles installation, management, and monitoring of the backup system
# The actual backup operations are performed by nextcloud-backup-core.sh

# Configuration file path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"

# If running from system location, use system config path
if [[ "$SCRIPT_DIR" == "/usr/local/bin" ]]; then
    CONFIG_FILE="/usr/local/bin/backup.conf"
fi

# Load configuration if available (for some operations)
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE" 2>/dev/null || true
fi

# Script locations
CORE_SCRIPT_NAME="nextcloud-backup-core.sh"
CORE_SCRIPT_PATH="/usr/local/bin/$CORE_SCRIPT_NAME"
MANAGER_SCRIPT_PATH="/usr/local/bin/backup-manager.sh"
CONFIG_PATH="/usr/local/bin/backup.conf"
SERVICE_FILE="/etc/systemd/system/backup.service"
TIMER_FILE="/etc/systemd/system/backup.timer"
LOGROTATE_FILE="/etc/logrotate.d/backup"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to get SSH connection string
get_ssh_target() {
    if [[ -n "$SSH_HOST" ]]; then
        echo "$SSH_HOST"
    else
        echo "$REMOTE_USER@$REMOTE_HOST"
    fi
}

# Install function
install() {
    if [[ $EUID -ne 0 ]]; then
        error "Installation must be run as root"
        exit 1
    fi

    info "Installing Nextcloud backup system..."

    # Check if core script exists
    if [[ ! -f "$SCRIPT_DIR/$CORE_SCRIPT_NAME" ]]; then
        error "Core backup script not found: $SCRIPT_DIR/$CORE_SCRIPT_NAME"
        exit 1
    fi

    # Copy core script to system location
    cp "$SCRIPT_DIR/$CORE_SCRIPT_NAME" "$CORE_SCRIPT_PATH"
    chmod +x "$CORE_SCRIPT_PATH"
    
    # Copy manager script (this script) to system location
    cp "$0" "$MANAGER_SCRIPT_PATH"
    chmod +x "$MANAGER_SCRIPT_PATH"
    
    # Copy configuration file to system location
    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "$CONFIG_PATH"
        chmod 600 "$CONFIG_PATH"  # Restrict access due to password
        info "Configuration file copied to $CONFIG_PATH"
    else
        error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    # Create systemd service file
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Nextcloud Backup Service - Incremental backup of directories and MySQL to remote server
After=network.target mysql.service
Wants=network.target

[Service]
Type=oneshot
User=${BACKUP_USER:-eyanshu}
Group=${BACKUP_USER:-eyanshu}
WorkingDirectory=/usr/local/bin
ExecStart=$CORE_SCRIPT_PATH backup
StandardOutput=journal
StandardError=journal
TimeoutSec=3600
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="HOME=/home/${BACKUP_USER:-eyanshu}"
EOF

    # Create systemd timer file
    cat > "$TIMER_FILE" << 'EOF'
[Unit]
Description=Run Nextcloud backup service daily
Requires=backup.service

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    # Create logrotate configuration
    cat > "$LOGROTATE_FILE" << EOF
/var/log/backup/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 ${BACKUP_USER:-eyanshu} ${BACKUP_USER:-eyanshu}
}
EOF

    # Create log directory with proper ownership
    mkdir -p "${LOG_DIR:-/var/log/backup}"
    chown "${BACKUP_USER:-eyanshu}:${BACKUP_USER:-eyanshu}" "${LOG_DIR:-/var/log/backup}"
    
    # Reload systemd
    systemctl daemon-reload

    success "Installation completed!"
    info "Files installed:"
    info "  Core backup script: $CORE_SCRIPT_PATH"
    info "  Manager script: $MANAGER_SCRIPT_PATH"
    info "  Configuration: $CONFIG_PATH"
    info ""
    info "Next steps:"
    info "1. Edit configuration: $CONFIG_PATH"
    info "2. Set up SSH key authentication: ssh-copy-id REMOTE_USER@REMOTE_HOST"
    info "3. Test: $MANAGER_SCRIPT_PATH test"
    info "4. Enable: $MANAGER_SCRIPT_PATH enable"
}

# Uninstall function
uninstall() {
    if [[ $EUID -ne 0 ]]; then
        error "Uninstall must be run as root"
        exit 1
    fi

    info "Uninstalling Nextcloud backup system..."
    
    # Stop and disable services
    systemctl stop backup.timer 2>/dev/null || true
    systemctl disable backup.timer 2>/dev/null || true
    systemctl stop backup.service 2>/dev/null || true
    
    # Remove files
    rm -f "$CORE_SCRIPT_PATH" "$MANAGER_SCRIPT_PATH" "$CONFIG_PATH"
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$LOGROTATE_FILE"
    
    # Reload systemd
    systemctl daemon-reload
    
    success "Uninstallation completed!"
    warning "Log files in ${LOG_DIR:-/var/log/backup} were not removed"
}

# Test configuration
test_config() {
    info "Testing backup configuration..."
    
    # Check if configuration is loaded
    if [[ -z "$REMOTE_HOST" ]]; then
        error "Configuration not loaded. Please ensure backup.conf exists and is valid."
        exit 1
    fi
    
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
    
    # Test MySQL connection
    if mysql -u"$DB_USER" -p"$DB_PASSWORD" -e "USE $DB_NAME; SELECT 1;" >/dev/null 2>&1; then
        success "✓ MySQL connection successful (database: $DB_NAME, user: $DB_USER)"
    else
        error "✗ MySQL connection failed (database: $DB_NAME, user: $DB_USER)"
        info "Check database name, username, password, and user permissions"
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
    
    # Test remote backup directory permissions
    info "Testing remote backup directory permissions..."
    SSH_TARGET=$(get_ssh_target)
    if ssh "$SSH_TARGET" "mkdir -p $REMOTE_BACKUP_DIR/test && echo 'test' > $REMOTE_BACKUP_DIR/test/test.txt && rm -rf $REMOTE_BACKUP_DIR/test" 2>/dev/null; then
        success "✓ Remote backup directory writable: $REMOTE_BACKUP_DIR"
    else
        error "✗ Cannot write to remote backup directory: $REMOTE_BACKUP_DIR"
        info "Check directory permissions and user access on remote server"
        return 1
    fi
    
    success "Configuration test completed successfully!"
}

# Run backup manually (outside systemd)
run_backup_manual() {
    if [[ ! -f "$CORE_SCRIPT_PATH" ]] && [[ ! -f "$SCRIPT_DIR/$CORE_SCRIPT_NAME" ]]; then
        error "Core backup script not found. Please install the system first."
        exit 1
    fi
    
    # Use installed version if available, otherwise local version
    if [[ -f "$CORE_SCRIPT_PATH" ]]; then
        BACKUP_SCRIPT="$CORE_SCRIPT_PATH"
    else
        BACKUP_SCRIPT="$SCRIPT_DIR/$CORE_SCRIPT_NAME"
    fi
    
    info "Running backup manually using: $BACKUP_SCRIPT"
    "$BACKUP_SCRIPT" backup
}

# Service management functions
enable_service() {
    if [[ $EUID -ne 0 ]]; then
        error "Must be run as root"
        exit 1
    fi
    
    if [[ ! -f "$SERVICE_FILE" ]]; then
        error "Backup service not installed. Run 'install' first."
        exit 1
    fi
    
    systemctl enable backup.timer
    systemctl start backup.timer
    success "Automatic backups enabled"
    info "Backup will run daily. Use 'status' to check the schedule."
}

disable_service() {
    if [[ $EUID -ne 0 ]]; then
        error "Must be run as root"
        exit 1
    fi
    systemctl disable backup.timer 2>/dev/null || true
    systemctl stop backup.timer 2>/dev/null || true
    success "Automatic backups disabled"
}

show_status() {
    echo "=== Backup Service Status ==="
    systemctl status backup.service --no-pager -l || true
    echo ""
    echo "=== Backup Timer Status ==="
    systemctl status backup.timer --no-pager -l || true
    echo ""
    echo "=== Next Scheduled Runs ==="
    systemctl list-timers backup.timer --no-pager || true
}

show_logs() {
    local lines="${1:-50}"
    echo "=== Systemd Journal Logs ==="
    journalctl -u backup.service -n "$lines" --no-pager || true
    echo ""
    if [[ -f "${LOG_DIR:-/var/log/backup}/backup.log" ]]; then
        echo "=== Application Logs ==="
        tail -n "$lines" "${LOG_DIR:-/var/log/backup}/backup.log"
    else
        info "No application logs found at ${LOG_DIR:-/var/log/backup}/backup.log"
    fi
}

run_via_systemd() {
    if [[ $EUID -ne 0 ]]; then
        error "Must be run as root"
        exit 1
    fi
    
    if [[ ! -f "$SERVICE_FILE" ]]; then
        error "Backup service not installed. Run 'install' first."
        exit 1
    fi
    
    systemctl start backup.service
    info "Backup started via systemd. Check logs with: $0 logs"
}

show_skipped() {
    local lines="${1:-50}"
    if [[ -f "${LOG_DIR:-/var/log/backup}/backup_skipped.log" ]]; then
        echo "=== Recently Skipped Files (NTFS Incompatible) ==="
        tail -n "$lines" "${LOG_DIR:-/var/log/backup}/backup_skipped.log"
        echo ""
        echo "Total skipped files: $(wc -l < "${LOG_DIR:-/var/log/backup}/backup_skipped.log")"
    else
        info "No skipped files log found"
    fi
}

show_help() {
    echo "Nextcloud Backup Manager"
    echo ""
    echo "Usage: $0 {install|uninstall|backup|test|enable|disable|status|logs|skipped|run|help}"
    echo ""
    echo "Installation & Management:"
    echo "  install   - Install backup system (requires root)"
    echo "  uninstall - Remove backup system (requires root)"
    echo "  test      - Test configuration and connections"
    echo ""
    echo "Service Management:"
    echo "  enable    - Enable automatic daily backups (requires root)"
    echo "  disable   - Disable automatic backups (requires root)"
    echo "  status    - Show service status and schedule"
    echo "  run       - Run backup via systemd service (requires root)"
    echo ""
    echo "Manual Operations:"
    echo "  backup    - Run backup manually (bypasses systemd)"
    echo "  logs      - Show backup logs"
    echo "  skipped   - Show skipped files (NTFS incompatible)"
    echo "  help      - Show this help"
    echo ""
    echo "Configuration:"
    echo "  Edit backup.conf to configure directories, remote server, and database settings"
    echo "  NTFS_COMPATIBILITY  - Set to 'true' to skip NTFS-incompatible files"
    echo "  SSH_HOST           - Use SSH config host instead of REMOTE_USER@REMOTE_HOST"
    echo ""
    echo "Files:"
    echo "  Core backup: $CORE_SCRIPT_PATH"
    echo "  Manager: $MANAGER_SCRIPT_PATH"
    echo "  Config: $CONFIG_PATH"
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
        run_backup_manual
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
        run_via_systemd
        ;;
    *)
        show_help
        ;;
esac
