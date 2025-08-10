# Nextcloud Remote Device SSH Backup

A minimal bash-based backup solution for incremental directory and MySQL database backups (specifically for Nextcloud) to a remote device via SSH with logging, rotation, and systemd service management.

## Features

- **Modular Design**: Separate core backup engine and management wrapper
- **Incremental Backups**: Uses `rsync` for efficient incremental file backups
- **MySQL Database Dumps**: Automated MySQL dumps with compression (optimized for Nextcloud)
- **Remote Device Backup**: Secure SSH-based backup to remote device (like Raspberry Pi)
- **SSH Config Support**: Use SSH config hosts for complex connection setups
- **Configuration File**: External configuration file for easy management
- **Logging & Rotation**: Automatic logging with log rotation
- **Systemd Integration**: Full systemd service and timer support
- **Easy Management**: Simple commands for all operations

## Project Structure

```
nextcloud-backup/
├── nextcloud-backup-core.sh   # Core backup engine (runs via systemd)
├── backup-manager.sh          # Management wrapper (install/config/monitor)
├── backup.conf                # Configuration file
└── README.md                  # This file
```

## Architecture

This backup system uses a **modular design** with two main components:

### 1. Core Backup Engine (`nextcloud-backup-core.sh`)
- **Purpose**: Handles only backup operations
- **Execution**: Runs via systemd service for automated backups
- **Features**: Database dumps, file syncing, logging
- **Security**: Minimal attack surface, focused functionality

### 2. Management Wrapper (`backup-manager.sh`)
- **Purpose**: System administration and monitoring
- **Execution**: Run manually by administrators
- **Features**: Installation, configuration testing, service management, log viewing
- **Benefits**: Separation of concerns, easier maintenance

### 3. Configuration File (`backup.conf`)
- **Purpose**: Centralized configuration management
- **Security**: Restricted permissions (600) to protect database credentials
- **Convenience**: Easy editing without touching script code

## Quick Start

### 1. Configuration

First, edit the configuration file:
```bash
nano backup.conf
```

Key settings to configure:
- `BACKUP_DIRS`: Directories to backup (comma-separated, typically Nextcloud data directories)
- `REMOTE_HOST`: Remote device hostname (default: raspi)
- `REMOTE_USER`: Remote device username
- `REMOTE_BACKUP_DIR`: Remote backup directory
- `DB_NAME`: MySQL database name (default: nextcloud)
- `DB_USER`: MySQL username
- `DB_PASSWORD`: MySQL password
- `BACKUP_USER`: System user to run the backup service (should have SSH keys and MySQL access)

### 2. Installation

```bash
# Make the scripts executable
chmod +x nextcloud-backup-core.sh backup-manager.sh

# Install the backup system
sudo ./backup-manager.sh install
```
### 3. SSH Setup

Set up SSH key authentication for your backup user to the remote device:
```bash
# Generate SSH key (if you don't have one) as the backup user
ssh-keygen -t rsa -b 4096

# Copy key to remote device (e.g., Raspberry Pi)
ssh-copy-id eyanshu@raspi
```

**Important**: Make sure to run the SSH setup as the same user specified in `BACKUP_USER` configuration.

**Alternative: Using SSH Config**

For complex SSH setups, you can use SSH config instead:

```bash
# Edit SSH config
nano ~/.ssh/config

# Add configuration like:
Host mybackup
    HostName raspi.local
    User eyanshu
    Port 2222
    IdentityFile ~/.ssh/backup_key
    
# Then set SSH_HOST="mybackup" in backup.conf
```

### 4. Test Configuration

```bash
./backup-manager.sh test
```

### 5. Enable Automatic Backups

```bash
# Enable daily automatic backups
sudo ./backup-manager.sh enable

# Check status
./backup-manager.sh status
```

## Usage

### Management Commands

```bash
# Installation & Setup
sudo ./backup-manager.sh install     # Install the backup system
sudo ./backup-manager.sh uninstall   # Uninstall the backup system
./backup-manager.sh test             # Test configuration

# Service Control
sudo ./backup-manager.sh enable      # Enable automatic daily backups
sudo ./backup-manager.sh disable     # Disable automatic backups
sudo ./backup-manager.sh run         # Run backup via systemd service

# Manual Operations
./backup-manager.sh backup           # Run backup manually (bypasses systemd)
./nextcloud-backup-core.sh backup    # Run core backup script directly

# Monitoring
./backup-manager.sh status           # Show service status and schedule
./backup-manager.sh logs             # Show recent logs
./backup-manager.sh logs 100         # Show last 100 log lines
./backup-manager.sh help             # Show help
```

## Configuration Details

All configuration is done by editing the `backup.conf` file:

```bash
# Edit local configuration
nano backup.conf

# Edit installed configuration (after installation)
sudo nano /usr/local/bin/backup.conf
```

### Configuration Options

```bash
# Directories to backup (comma-separated)
BACKUP_DIRS="/var/www/nextcloud/data/"

# Remote server settings
REMOTE_HOST="raspi"
REMOTE_USER="eyanshu"
REMOTE_BACKUP_DIR="/mnt/harddisk/home-server-backup/"

# MySQL/MariaDB settings
DB_NAME="nextcloud"
DB_USER="eyanshu"
DB_PASSWORD="your_password_here"

# Local directories
LOG_DIR="/var/log/backup"
TEMP_DIR="/tmp/backup"

# System user to run the backup service (should have SSH keys and MySQL access)
BACKUP_USER="eyanshu"

# SSH host from ~/.ssh/config (leave empty to use REMOTE_HOST directly)
SSH_HOST=""

# MySQL dump retention (days)
MYSQL_RETENTION_DAYS="7"
```


### Backup User Configuration

The `BACKUP_USER` setting is important for proper operation:

- **SSH Access**: This user must have SSH key authentication set up to the remote device
- **MySQL Access**: This user must have the necessary MySQL permissions for the database
- **File Permissions**: This user must have read access to the directories being backed up
- **SSH Config**: The systemd service will run as this user and can access their `~/.ssh/config` file

**Important**: Make sure the specified user exists on the system and has the required permissions before installation.

### Systemd Timer Schedule

The default schedule runs backups daily at 2:00 AM. To modify:

```bash
sudo systemctl edit backup.timer
```

Example schedules:
- `OnCalendar=daily` - Once per day
- `OnCalendar=*-*-* 02,08,14,20:00:00` - Every 6 hours
- `OnCalendar=Mon,Wed,Fri *-*-* 02:00:00` - Monday, Wednesday, Friday

## Backup Process

1. **MySQL Dump**: Creates compressed SQL dump using `mysqldump --single-transaction` (optimized for Nextcloud database)
2. **Directory Sync**: Performs incremental backup using `rsync` with `--delete` flag
3. **Remote Transfer**: Securely transfers files via SSH to remote device
4. **Cleanup**: Removes temporary files and old backups based on retention policy
5. **Logging**: Records all operations with timestamps

## Security Features

- SSH key-based authentication (no passwords)
- Systemd service runs as user (not root) for better security and SSH config access
- Read-only access to home directories
- Isolated temporary directories
- Comprehensive logging for audit trails

## Monitoring and Logs

### Log Locations
- **Application Logs**: `/var/log/backup/backup.log`
- **Systemd Logs**: `journalctl -u backup.service`

### Log Rotation
- Logs rotate daily
- Keeps 30 days of logs
- Automatic compression of old logs

### Monitoring Commands
```bash
# Real-time log following
sudo tail -f /var/log/backup/backup.log

# Check last backup status
./backup-manager.sh status

# View recent logs
./backup-manager.sh logs
```

## Troubleshooting

### Common Issues

1. **SSH Connection Failed**
   ```bash
   # Test SSH connection
   ssh backup@raspi
   
   # Set up SSH keys if needed
   ssh-copy-id backup@raspi
   ```

2. **MySQL Connection Failed**
   ```bash
   # Test MySQL connection
   mysqladmin -u root -p"your_password" ping
   ```

3. **Permission Denied**
   ```bash
   # Check file permissions
   ls -la /usr/local/bin/nextcloud-backup-core.sh
   ls -la /usr/local/bin/backup-manager.sh
   
   # Fix permissions if needed
   sudo chmod +x /usr/local/bin/nextcloud-backup-core.sh
   sudo chmod +x /usr/local/bin/backup-manager.sh
   ```

4. **Disk Space Issues**
   ```bash
   # Check disk space on source
   df -h
   
   # Check disk space on destination
   ssh backup@raspi "df -h"
   ```

5. **SSH Config Issues**
   ```bash
   # Test SSH config host
   ssh your_ssh_host_name
   
   # Debug SSH connection
   ssh -v your_ssh_host_name
   ```

6. **Systemd Service User Issues**
   ```bash
   # If you get namespace errors (exit code 226), check the backup user configuration
   # Verify the BACKUP_USER setting in backup.conf
   grep BACKUP_USER /usr/local/bin/backup.conf
   
   # Check service configuration
   systemctl cat backup.service
   
   # The service should run as the configured backup user to access SSH config
   # Reinstall if needed:
   sudo ./backup-manager.sh uninstall
   sudo ./backup-manager.sh install
   ```

7. **User Permission Issues**
   ```bash
   # Ensure backup user has required permissions
   # Check MySQL access
   mysql -u"$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1;"
   
   # Check SSH access
   ssh REMOTE_USER@REMOTE_HOST "echo 'SSH OK'"
   
   # Check directory read permissions
   ls -la /var/www/nextcloud/data/
   ```

### Debug Mode

Enable detailed logging by modifying the core backup script:
```bash
# Add debug mode to nextcloud-backup-core.sh
set -x  # Enable debug output
```



## Requirements

### Source Machine (Nextcloud Server)
- Linux with bash, rsync, mysql-client
- SSH client
- systemd (for service management)
- Root access for installation
- Nextcloud installation with MySQL database

### Destination Machine (Remote Device)
- Linux with SSH server (e.g., Raspberry Pi)
- Sufficient disk space for backups
- User account with backup directory write permissions

## License

This project is open source and available under the MIT License.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## Support

For issues and questions:
1. Check the troubleshooting section
2. Review logs: `./backup-manager.sh logs`
3. Test configuration: `./backup-manager.sh test`
4. Create an issue with detailed logs and configuration
