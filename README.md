# Nextcloud Remote Device SSH Backup

A minimal bash-based backup solution for incremental directory and MySQL database backups (specifically for Nextcloud) to a remote device via SSH with logging, rotation, and systemd service management.

## Features

- **Single Script**: Everything in one file for simplicity
- **Incremental Backups**: Uses `rsync` for efficient incremental file backups
- **MySQL Database Dumps**: Automated MySQL dumps with compression (optimized for Nextcloud)
- **Remote Device Backup**: Secure SSH-based backup to remote device (like Raspberry Pi)
- **Logging & Rotation**: Automatic logging with log rotation
- **Systemd Integration**: Full systemd service and timer support
- **Easy Management**: Simple commands for all operations

## Project Structure

```
nextcloud-backup/
└── backup.sh                 # Single script with all functionality
```

## Quick Start

### 1. Installation

```bash
# Make the script executable
chmod +x backup.sh

# Install the backup system
sudo ./backup.sh install
```

### 2. Configuration

Edit the configuration in the script (lines 6-12):
```bash
sudo nano /usr/local/bin/backup.sh
```

Key settings to configure:
- `BACKUP_DIRS`: Directories to backup (comma-separated, typically Nextcloud data directories)
- `REMOTE_HOST`: Remote device hostname (default: raspi)
- `REMOTE_USER`: Remote device username
- `REMOTE_BACKUP_DIR`: Remote backup directory
- `DB_NAME`: MySQL database name (default: nextcloud)
- `DB_PASSWORD`: MySQL password

### 3. SSH Setup

Set up SSH key authentication to your remote device:
```bash
# Generate SSH key (if you don't have one)
ssh-keygen -t rsa -b 4096

# Copy key to remote device (e.g., Raspberry Pi)
ssh-copy-id backup@raspi
```

### 4. Test Configuration

```bash
sudo ./backup.sh test
```

### 5. Enable Automatic Backups

```bash
# Enable daily automatic backups
sudo ./backup.sh enable

# Check status
sudo ./backup.sh status
```

## Usage

### All Commands

```bash
# Installation
sudo ./backup.sh install     # Install the backup system
sudo ./backup.sh uninstall   # Uninstall the backup system

# Service Control
sudo ./backup.sh enable      # Enable automatic daily backups
sudo ./backup.sh disable     # Disable automatic backups
sudo ./backup.sh run         # Run backup manually via systemd

# Direct Operations
sudo ./backup.sh backup      # Run backup directly (not via systemd)
sudo ./backup.sh test        # Test configuration

# Monitoring
./backup.sh status           # Show service status
./backup.sh logs             # Show recent logs
./backup.sh logs 100         # Show last 100 log lines
./backup.sh help             # Show help
```

## Configuration Details

All configuration is done by editing the script itself (lines 6-12 in `/usr/local/bin/backup.sh` after installation):

```bash
# Configuration (edit these values)
BACKUP_DIRS="/home/user/documents,/home/user/pictures"
REMOTE_HOST="raspi"
REMOTE_USER="backup"
REMOTE_BACKUP_DIR="/backup"
DB_NAME="nextcloud"
DB_PASSWORD="eshu@123"
```

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
- Systemd service runs with restricted permissions
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
./backup.sh status

# View recent logs
./backup.sh logs
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
   ls -la /usr/local/bin/backup.sh
   
   # Fix permissions if needed
   sudo chmod +x /usr/local/bin/backup.sh
   ```

4. **Disk Space Issues**
   ```bash
   # Check disk space on source
   df -h
   
   # Check disk space on destination
   ssh backup@raspi "df -h"
   ```

### Debug Mode

Enable detailed logging by modifying the backup script:
```bash
# Add debug mode to backup.sh
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
2. Review logs: `./backup.sh logs`
3. Test configuration: `./backup.sh test`
4. Create an issue with detailed logs and configuration

