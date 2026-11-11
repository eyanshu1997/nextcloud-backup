#!/usr/bin/env bash
# Disaster-recovery config bundle: everything needed to rebuild the Nextcloud install on a fresh VM that is NOT in the data folder and NOT in the database dump.
# Runs as the backup user (eyanshu, no sudo), at the lowest priority, and sends a mode-600 tarball to the Pi backup disk (<backup>/config/), verified by sha256.
# Contains secrets (config.php, .env files): it lives on the same private disk as the user data, mode 600. Not included: the TLS private key and the Cloudflare
# tunnel token (root-only, regenerable from the Cloudflare dashboard).   Usage: dr-config-bundle.sh [--keep N]
set -u
umask 077
KEEP=30; [ "${1:-}" = "--keep" ] && KEEP="${2:-30}"
NC=/var/www/nextcloud
CONF=/usr/local/bin/backup.conf
[ -f "$CONF" ] || { echo "ERROR: $CONF missing"; exit 1; }
. "$CONF"
LOG="${LOG_DIR:-/var/log/backup}/backup.log"
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG"; }
LOW="nice -n 19 ionice -c3"
SSH_TARGET="${SSH_HOST:-$REMOTE_USER@$REMOTE_HOST}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
REMOTE_CFG_DIR="$REMOTE_BACKUP_DIR/config"
STAMP=$(date +%Y-%m-%d_%H%M%S)
W=$(mktemp -d /tmp/nc-config-bundle.XXXXXX); trap 'rm -rf "$W"' EXIT
NAME="nextcloud-server-config-$STAMP"; B="$W/$NAME"; mkdir -p "$B"

if ! ssh $SSH_OPTS "$SSH_TARGET" "mountpoint -q '${REMOTE_MOUNTPOINT:-/mnt/harddisk}'" 2>/dev/null; then
    log "ERROR: Config bundle: backup target not reachable or not mounted"; exit 1
fi
log "Config bundle: collecting files"

# 1. the files (rsync --relative keeps the full paths; missing or unreadable ones are skipped and listed in the manifest)
PATHS=(
  $NC/config $NC/themes $NC/version.php
  /etc/apache2/sites-available /etc/apache2/conf-available /etc/apache2/ports.conf /etc/apache2/certs/cert.pem
  /etc/php/8.3/apache2/php.ini /etc/php/8.3/cli/php.ini /etc/php/8.3/apache2/conf.d /etc/php/8.3/cli/conf.d
  /etc/mysql/my.cnf /etc/mysql/mariadb.conf.d /etc/redis/redis.conf
  /etc/updatedb.conf /etc/fstab /etc/logrotate.d/backup /etc/logrotate.d/nextcloud-backup
  /etc/systemd/system/backup.service /etc/systemd/system/backup.timer /etc/systemd/system/backup.service.d
  /usr/local/bin/backup.conf /usr/local/bin/nextcloud-backup-core.sh /usr/local/bin/backup-manager.sh
  $HOME/.config/systemd/user $HOME/server-docs $HOME/configs $HOME/scripts $HOME/code/nextcloudbackup $HOME/code/container-updates
  # compose stacks and their .env files live in $HOME/configs/stacks/<project>/ and secrets in $HOME/configs/secrets/ (both inside $HOME/configs, 2026-11-11)
  # secrets of the docs server, its Google login and the UptimeRobot key (were missing from the bundle until 2026-11-11)
  # (oauth2-proxy cfg + emails: $HOME/configs/secrets/oauth2-proxy/, covered by $HOME/configs)
  $HOME/code/coherence/.env $HOME/.uptimekey $HOME/.local/bin/oauth2-proxy
)
$LOW rsync -aR --ignore-missing-args --no-specials --no-devices \
  --exclude='config.sample.php' --exclude='/home/*/server-docs/archive' --exclude='/home/*/server-docs/pkgs' --exclude='/home/*/server-docs/coherence-trial' \
  --exclude='/home/*/server-docs/verification' --exclude='/home/*/code/nextcloudbackup/.git' --exclude='*.key' --exclude='key.pem' \
  --exclude='/etc/apache2/certs/*.key' --exclude='.rsync-partial' \
  "${PATHS[@]}" "$B/" 2>"$W/rsync.err"

# 2. manifest: versions and facts a rebuild needs
{
echo "# Nextcloud server configuration bundle $STAMP"
echo "host: $(hostname)   os: $(lsb_release -ds 2>/dev/null)   kernel: $(uname -r)"
echo "nextcloud: $(php -r 'require "/var/www/nextcloud/version.php"; echo $OC_VersionString;' 2>/dev/null)  (install this exact release from download.nextcloud.com/server/releases/)"
echo "data directory (config.php): $(grep -E "'datadirectory'" $NC/config/config.php | sed -E "s/.*=> *'([^']*)'.*/\1/")   instanceid folder: $(ls $NC/data 2>/dev/null | grep -E '^appdata_')"
echo
echo "## store apps installed inside apps/ (not shipped with the tarball): reinstall with 'occ app:install <id>' after restoring config"
python3 - <<'PY'
import json, os, re
nc = "/var/www/nextcloud"
try:
    shipped = set(json.load(open(nc + "/core/shipped.json")).get("shippedApps", []))
except Exception:
    shipped = set()
for d in sorted(os.listdir(nc + "/apps")):
    if d in shipped:
        continue
    try:
        v = re.search(r"<version>([^<]+)</version>", open(f"{nc}/apps/{d}/appinfo/info.xml").read()).group(1)
    except Exception:
        v = "?"
    print(f"  {d} {v}")
if os.path.isdir(nc + "/custom_apps"):
    print("  custom_apps/: " + ", ".join(sorted(os.listdir(nc + "/custom_apps"))))
PY
echo
echo "## packages"; dpkg-query -W -f='  ${Package} ${Version}\n' apache2 libapache2-mod-php8.3 'php8.3-*' php-apcu mariadb-server redis-server 2>/dev/null | head -60
echo "## php modules"; php -m | tr '\n' ' '; echo
echo "## apache modules"; apache2ctl -M 2>/dev/null | tr '\n' ' '; echo
echo "## mariadb (version, charset, create statement; password never printed)"
MYSQL_PWD="$DB_PASSWORD" mysql -u"$DB_USER" -N -e "SELECT @@version, @@character_set_server, @@collation_server; SHOW CREATE DATABASE $DB_NAME" 2>&1 | sed 's/^/  /'
echo "## cron: eyanshu"; crontab -l 2>/dev/null | grep -v '^#' | sed 's/^/  /'
echo "## cron: www-data (root-only to read; as installed by tune-load.sh): cron.php every 5 min; occ preview:pre-generate nightly 03:40; see nextcloud-disaster-recovery.md"
echo "## mounts"; findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /mnt/exdisk / 2>/dev/null | sed 's/^/  /'; blkid 2>/dev/null | grep -E 'sdb1|sda2' | sed -E 's/^/  /' | head -3
echo "## docker containers"; docker ps --format '  {{.Names}} {{.Image}}' 2>/dev/null
echo "## enabled services"; systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print "  "$1}' | grep -vE 'getty|dbus|systemd-|snap|apt|fwupd|motd|e2scrub|fstrim|man-db|logrotate|plocate|anacron|phpsessionclean|dpkg' | head -40
echo "## not captured (root-only or regenerable)"; echo "  TLS private key for Apache :9000, Cloudflare tunnel token, www-data crontab file, Redis data, preview thumbnails"
echo "## skipped / unreadable during collection"; sed 's/^/  /' "$W/rsync.err" | head -20
} > "$B/MANIFEST.txt" 2>&1
cp "$B/MANIFEST.txt" "$W/MANIFEST.txt"

# 3. pack, verify, upload, verify again, rotate
$LOW tar -C "$W" -czf "$W/$NAME.tgz" "$NAME" 2>>"$W/rsync.err" || { log "ERROR: Config bundle: tar failed"; exit 1; }
chmod 600 "$W/$NAME.tgz"
if ! tar tzf "$W/$NAME.tgz" >/dev/null 2>&1 || ! tar tzf "$W/$NAME.tgz" | grep -q 'config/config.php'; then log "ERROR: Config bundle failed its check (archive unreadable or config.php missing)"; exit 1; fi
SIZE=$(stat -c%s "$W/$NAME.tgz"); LSUM=$(sha256sum "$W/$NAME.tgz" | awk '{print $1}')
ssh $SSH_OPTS "$SSH_TARGET" "mkdir -p '$REMOTE_CFG_DIR' && chmod 700 '$REMOTE_CFG_DIR'" || { log "ERROR: Config bundle: cannot create $REMOTE_CFG_DIR"; exit 1; }
$LOW rsync -a --chmod=F600 --partial-dir=.rsync-partial -e "ssh $SSH_OPTS" "$W/$NAME.tgz" "$W/MANIFEST.txt" "$SSH_TARGET:$REMOTE_CFG_DIR/" 2>>"$W/rsync.err" || { log "ERROR: Config bundle upload failed"; exit 1; }
ssh $SSH_OPTS "$SSH_TARGET" "cd '$REMOTE_CFG_DIR' && mv -f MANIFEST.txt 'MANIFEST-latest.txt' && ln -sf '$NAME.tgz' latest.tgz"
RSUM=$(ssh $SSH_OPTS "$SSH_TARGET" "sha256sum '$REMOTE_CFG_DIR/$NAME.tgz'" | awk '{print $1}')
[ "$LSUM" = "$RSUM" ] || { log "ERROR: Config bundle checksum mismatch after upload"; exit 1; }
ssh $SSH_OPTS "$SSH_TARGET" "cd '$REMOTE_CFG_DIR' && ls -1t nextcloud-server-config-*.tgz | tail -n +$((KEEP+1)) | xargs -r rm -f" 2>/dev/null
log "Config bundle uploaded and verified: $NAME.tgz ($((SIZE/1024)) KB)"
