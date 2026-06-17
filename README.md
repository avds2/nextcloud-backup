# nextcloud-backup

[![Shell](https://img.shields.io/badge/Shell-Bash-blue)](#requirements)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-backup-blue)](#what-this-backs-up)
[![Database](https://img.shields.io/badge/Database-MariaDB-orange)](#database-user)
[![License](https://img.shields.io/badge/License-MIT-green)](#license)

`nextcloud-backup` is a production-oriented Bash backup utility for self-hosted Nextcloud installations backed by MariaDB. It creates a timestamped `.tar.xz` archive containing a full MariaDB dump and the Nextcloud installation tree, with maintenance-mode protection, pre-flight validation, structured logging, archive verification, retention-based rotation, rollback-safe cleanup, and optional ntfy push notifications.

The script is intentionally configured through a separate `nextcloud-backup.env` file. You should not edit `nextcloud-backup.sh` for normal configuration.

> **Important:** A backup is only real after you have successfully restored it in a test environment. This project creates the archive; you are still responsible for off-site storage, restore testing, encryption policy, monitoring, and disaster-recovery procedures.

---

## Table of contents

- [Features](#features)
- [What this backs up](#what-this-backs-up)
- [Archive format](#archive-format)
- [How the backup works](#how-the-backup-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Database user](#database-user)
- [Running a backup](#running-a-backup)
- [Scheduling](#scheduling)
- [Notifications](#notifications)
- [Retention and rotation](#retention-and-rotation)
- [Verifying backups](#verifying-backups)
- [Restore guide](#restore-guide)
- [Security model](#security-model)
- [Operational notes](#operational-notes)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Recommended production checklist](#recommended-production-checklist)
- [License](#license)

---

## Features

- **Single-command Nextcloud backup** using `nextcloud-backup.sh`.
- **Environment-file configuration** through `nextcloud-backup.env` located beside the script.
- **MariaDB logical dump** using `mariadb-dump`.
- **Consistent InnoDB snapshot strategy** using `--single-transaction` and `--quick`.
- **Nextcloud maintenance mode integration** through `occ maintenance:mode --on` and `--off`.
- **Full Nextcloud directory archive** by default.
- **Optional include list** for backing up only selected paths under `NC_DIR`.
- **Permanent cache exclusions** for regenerable Nextcloud cache, thumbnail, appstore, updater, and preview data.
- **Timestamped `.tar.xz` archives** for compact storage.
- **Archive integrity check** using `tar --list` after archive creation.
- **Retention-based cleanup** of old archives matching the project backup filename pattern.
- **Atomic lock directory** to prevent concurrent runs.
- **Structured log output** to terminal and `nextcloud-backup.log`.
- **Rollback-safe cleanup** via `EXIT`, `ERR`, `INT`, `TERM`, and `HUP` traps.
- **Automatic maintenance-mode recovery** on most failure paths after maintenance mode has been enabled.
- **Best-effort ntfy notifications** for start, failure, and success events.
- **Root-only execution** to avoid partial backups caused by insufficient permissions.
- **Private default file creation** through `umask 0077`.

---

## What this backs up

A successful run produces one compressed archive containing:

1. `nextcloud-database.sql`  
   A full MariaDB dump of the configured Nextcloud database.

2. `nextcloud-directory/`  
   A normalized copy of the configured Nextcloud installation directory, regardless of the original filesystem path.

By default, the script archives the entire `NC_DIR` tree. This normally includes:

- `config/`
- `data/`
- `apps/`
- `themes/`, if present
- core Nextcloud application files
- any other files stored under the configured `NC_DIR`

The default behavior aligns with the official Nextcloud backup model: retain configuration, custom apps, data, themes, and the database.

---

## Archive format

Every successful backup creates an archive like this:

```text
nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz
├── nextcloud-database.sql
└── nextcloud-directory/
    ├── config/
    ├── data/
    ├── apps/
    └── ...
```

Example:

```text
/opt/nextcloud-backup/nextcloud-backup_2026-06-17_03-00-01.tar.xz
```

The archive contains fixed internal names:

- The database dump is always stored as `nextcloud-database.sql`.
- The Nextcloud installation tree is always stored as `nextcloud-directory/`.

This makes restore procedures predictable even when the original Nextcloud path differs between systems.

---

## How the backup works

The script runs the following workflow:

1. **Initialize logging**  
   Logs are written to the terminal and to `nextcloud-backup.log` in the script directory.

2. **Bootstrap**  
   The script verifies root privileges, checks required commands, loads `nextcloud-backup.env`, applies defaults, validates required variables, creates runtime paths, and creates required directories.

3. **Acquire exclusive lock**  
   A lock directory named `.nextcloud-backup.lock` is created beside the script. If it already exists, the script aborts to avoid overlapping backups.

4. **Send start notification**  
   If `NTFY_URL` is configured, a start notification is sent.

5. **Run pre-flight checks**  
   The script verifies:
   - `NC_DIR` exists.
   - `NC_DIR/occ` exists.
   - `WEB_USER` exists.
   - MariaDB credentials can connect successfully.
   - `BACKUP_ROOT` has enough available disk space according to the script's disk-space check.

6. **Enable Nextcloud maintenance mode**  
   The script runs:

   ```bash
   sudo -u "$WEB_USER" php "$NC_DIR/occ" maintenance:mode --on
   ```

7. **Dump the database**  
   The script writes:

   ```text
   /tmp/nextcloud-backup-<pid>/nextcloud-database.sql
   ```

8. **Create the archive**  
   The SQL dump and Nextcloud directory are packed into a `.tar.xz` archive in `BACKUP_ROOT`.

9. **Verify the archive**  
   The script lists the archive with `tar --list` to confirm that the tar structure and xz stream are readable.

10. **Disable maintenance mode**  
    Nextcloud access is restored after the archive is verified.

11. **Rotate old archives**  
    Old files matching `nextcloud-backup_*.tar.xz` in `BACKUP_ROOT` are removed if they are older than `RETENTION_DAYS`.

12. **Compute statistics and notify**  
    Final archive size and runtime duration are logged. If configured, a success notification is sent.

13. **Cleanup**  
    Temporary files are removed and the lock directory is released.

---

## Requirements

### Supported target

This script is designed for a host-accessible Nextcloud installation where:

- the Nextcloud directory is available on the host filesystem;
- the `occ` command can be executed from `NC_DIR/occ`;
- the MariaDB database is reachable from the host using the configured credentials;
- the backup process can run as `root`.

It is best suited for traditional bare-metal, VM, LXC, or host-mounted deployments.

For Docker-only deployments, this script can still be adapted, but only if the host can access the Nextcloud files and run the correct `occ` command. Pure container-only deployments usually need container-aware commands such as `docker exec` or volume-level backup tooling, which this script does not currently implement.

### Runtime dependencies

The script checks for these commands:

| Command | Purpose |
|---|---|
| `bash` | script runtime |
| `php` | running Nextcloud `occ` |
| `mariadb` | database connectivity test |
| `mariadb-dump` | database dump |
| `tar` | archive creation and verification |
| `xz` | compression backend for `tar --xz` |
| `curl` | ntfy notifications |
| `find` | backup rotation |
| `df` | free-space check |
| `du` | size calculation |
| `awk` | output parsing |
| `sudo` | running `occ` as the web-server user |

### Bash version

Bash 4.3+ is recommended. Bash 5.x is preferred on modern Linux distributions.

### Example dependency installation

Debian / Ubuntu:

```bash
sudo apt update
sudo apt install bash mariadb-client php-cli tar xz-utils curl findutils coreutils gawk sudo
```

Arch Linux:

```bash
sudo pacman -S --needed bash mariadb-clients php tar xz curl findutils coreutils gawk sudo
```

RHEL / Rocky / AlmaLinux / Fedora family:

```bash
sudo dnf install bash mariadb php-cli tar xz curl findutils coreutils gawk sudo
```

Package names can differ by distribution and release. Use your distribution's package manager to map the required commands if the examples above do not match your system.

---

## Installation

Clone the repository:

```bash
git clone https://github.com/avds2/nextcloud-backup.git
cd nextcloud-backup
```

Install the files somewhere root-owned, for example:

```bash
sudo mkdir -p /opt/nextcloud-backup
sudo chown root:root /opt/nextcloud-backup
sudo chmod 700 /opt/nextcloud-backup

sudo cp nextcloud-backup.sh nextcloud-backup.env /opt/nextcloud-backup/
sudo chown root:root /opt/nextcloud-backup/nextcloud-backup.sh /opt/nextcloud-backup/nextcloud-backup.env
sudo chmod 700 /opt/nextcloud-backup/nextcloud-backup.sh
sudo chmod 600 /opt/nextcloud-backup/nextcloud-backup.env
```

The script and env file must stay in the same directory:

```text
/opt/nextcloud-backup/
├── nextcloud-backup.sh
└── nextcloud-backup.env
```

---

## Configuration

Edit only `nextcloud-backup.env`:

```bash
sudo nano /opt/nextcloud-backup/nextcloud-backup.env
```

### Required variables

| Variable | Required | Example | Description |
|---|---:|---|---|
| `DB_HOST` | yes | `localhost` | MariaDB host reachable from the backup host. |
| `DB_NAME` | yes | `nextcloud` | Nextcloud database name. |
| `DB_USER` | yes | `backup_user` | MariaDB user used for dumping the database. |
| `DB_PASSWORD` | yes | `strong-password` | Password for `DB_USER`. |
| `NC_DIR` | yes | `/var/www/nextcloud` | Absolute path to the Nextcloud installation directory containing `occ`. |
| `WEB_USER` | yes | `www-data` | OS user used to run Nextcloud/PHP and execute `occ`. |
| `BACKUP_ROOT` | yes | `/opt/nextcloud-backup` | Directory where completed archives are stored. |

### Optional variables

| Variable | Default | Description |
|---|---|---|
| `INCLUDES` | empty | Bash array of paths relative to `NC_DIR` to include. Empty means archive all of `NC_DIR`. |
| `EXCLUDES` | cache/updater/appstore defaults | Bash array of tar exclude patterns relative to `NC_DIR`. |
| `RETENTION_DAYS` | `7` | Archives older than this many days are removed after a successful backup. Set `0` to disable rotation. |
| `XZ_LEVEL` | `6` | xz compression preset. `0` is fastest/largest; `9` is slowest/smallest and uses more memory. |
| `NTFY_URL` | empty | ntfy topic URL for start, failure, and success notifications. Empty disables notifications. |

### Minimal example

```bash
DB_HOST="localhost"
DB_NAME="nextcloud"
DB_USER="backup_user"
DB_PASSWORD="CHANGE_THIS_TO_A_STRONG_PASSWORD"

NC_DIR="/var/www/nextcloud"
WEB_USER="www-data"
BACKUP_ROOT="/opt/nextcloud-backup"

INCLUDES=()
EXCLUDES=(
    "--exclude=updater-*"
    "--exclude=data/*/cache"
    "--exclude=data/*/thumbnails"
    "--exclude=data/appdata_*/preview"
    "--exclude=data/appdata_*/appstore"
)

RETENTION_DAYS=7
XZ_LEVEL=6
NTFY_URL=""
```

### Include only selected paths

By default, `INCLUDES=()` archives the entire `NC_DIR` tree. This is the safest default.

To archive only selected paths under `NC_DIR`:

```bash
INCLUDES=("config" "data" "apps" "themes")
```

Do not use absolute paths in `INCLUDES`. These entries must be relative to `NC_DIR`.

### Exclude additional paths

`EXCLUDES` entries are written as tar-style `--exclude=` patterns relative to `NC_DIR`:

```bash
EXCLUDES=(
    "--exclude=updater-*"
    "--exclude=data/*/cache"
    "--exclude=data/*/thumbnails"
    "--exclude=data/appdata_*/preview"
    "--exclude=data/appdata_*/appstore"
    "--exclude=data/*/files_trashbin"
)
```

The script automatically prefixes exclude patterns with `nextcloud-directory/` internally so they match the archive layout. Do not add `nextcloud-directory/` yourself.

> **Strong recommendation:** Be conservative with exclusions. Excluding application data without fully understanding Nextcloud's storage layout can produce backups that are technically valid but operationally incomplete.

---

## Database user

Using MariaDB `root` works, but is not recommended for routine automated backups. Create a dedicated backup user instead.

Example:

```sql
CREATE USER 'backup_user'@'localhost' IDENTIFIED BY 'strong-password-here';

GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER, EVENT, PROCESS
ON nextcloud.* TO 'backup_user'@'localhost';

FLUSH PRIVILEGES;
```

Then configure:

```bash
DB_USER="backup_user"
DB_PASSWORD="strong-password-here"
```

If `DB_HOST` is not `localhost`, adjust the MariaDB host part accordingly:

```sql
CREATE USER 'backup_user'@'backup-hostname-or-ip' IDENTIFIED BY 'strong-password-here';
```

For local Unix-socket connections, `DB_HOST="localhost"` is usually correct. For TCP connections, use an IP address or hostname reachable from the backup host.

---

## Running a backup

Run manually as root:

```bash
sudo /opt/nextcloud-backup/nextcloud-backup.sh
```

Follow logs live:

```bash
sudo tail -f /opt/nextcloud-backup/nextcloud-backup.log
```

List produced archives:

```bash
sudo ls -lh /opt/nextcloud-backup/
```

Expected archive filename pattern:

```text
nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz
```

---

## Scheduling

### Option A: systemd timer

Create a service unit:

```bash
sudo nano /etc/systemd/system/nextcloud-backup.service
```

```ini
[Unit]
Description=Nextcloud backup
Documentation=https://github.com/avds2/nextcloud-backup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/nextcloud-backup/nextcloud-backup.sh
User=root
Group=root
```

Create a timer:

```bash
sudo nano /etc/systemd/system/nextcloud-backup.timer
```

```ini
[Unit]
Description=Run Nextcloud backup daily

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=nextcloud-backup.service

[Install]
WantedBy=timers.target
```

Enable the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-backup.timer
```

Check timer status:

```bash
systemctl list-timers nextcloud-backup.timer
systemctl status nextcloud-backup.timer
```

Run immediately through systemd:

```bash
sudo systemctl start nextcloud-backup.service
```

Inspect logs:

```bash
journalctl -u nextcloud-backup.service -n 200 --no-pager
sudo tail -n 200 /opt/nextcloud-backup/nextcloud-backup.log
```

### Option B: cron

Open root's crontab:

```bash
sudo crontab -e
```

Run daily at 03:00:

```cron
0 3 * * * /opt/nextcloud-backup/nextcloud-backup.sh >/dev/null 2>&1
```

The script already writes its own log file, so redirecting cron output is acceptable.

---

## Notifications

Notifications are optional and disabled by default.

To enable ntfy notifications, set `NTFY_URL` in `nextcloud-backup.env`:

```bash
NTFY_URL="https://ntfy.sh/my-secret-nextcloud-backup-topic"
```

The script sends notifications for:

- backup started;
- backup failed;
- backup successful.

Notification delivery is best-effort. A failed ntfy request is logged as a warning and does not fail the backup.

### ntfy security note

If you use the public `ntfy.sh` service, choose a long, unguessable topic name. Treat the topic URL as a secret. For sensitive environments, self-host ntfy or use another private notification path.

---

## Retention and rotation

`RETENTION_DAYS` controls automatic deletion of old archives.

Example:

```bash
RETENTION_DAYS=14
```

This removes matching archives older than 14 days from `BACKUP_ROOT` after a successful backup.

Only files matching this pattern are considered:

```text
nextcloud-backup_*.tar.xz
```

Disable automatic rotation:

```bash
RETENTION_DAYS=0
```

> **Important:** Retention on the same host is not a complete backup strategy. Keep separate off-site or offline copies. A compromised or failed server can destroy both live data and local backups.

---

## Verifying backups

The script performs an automatic structural verification:

```bash
tar --list --file="/opt/nextcloud-backup/nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz" >/dev/null
```

You can manually list archive contents:

```bash
sudo tar --list --file="/opt/nextcloud-backup/nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz" | less
```

Show the top-level entries:

```bash
sudo tar --list --file="/opt/nextcloud-backup/nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz" | head -50
```

Check archive size:

```bash
sudo du -sh /opt/nextcloud-backup/nextcloud-backup_*.tar.xz
```

Optional: create a checksum file after each backup:

```bash
cd /opt/nextcloud-backup
sudo sha256sum nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz | sudo tee nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz.sha256
```

Verify later:

```bash
cd /opt/nextcloud-backup
sha256sum -c nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz.sha256
```

> `tar --list` confirms that the archive can be read and decompressed. It does not prove that your Nextcloud instance can be restored successfully. Perform periodic restore drills.

---

## Restore guide

This section is intentionally explicit because a backup script is incomplete without a recovery procedure.

The commands below are examples. Adjust paths, service names, database names, PHP version, and web-server user for your environment.

### 1. Choose the archive

```bash
ARCHIVE="/opt/nextcloud-backup/nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz"
RESTORE_DIR="/root/nextcloud-restore-test"
```

### 2. Extract to a staging directory

```bash
sudo rm -rf "$RESTORE_DIR"
sudo mkdir -p "$RESTORE_DIR"
sudo tar --extract --file="$ARCHIVE" --directory="$RESTORE_DIR"
```

Expected result:

```text
/root/nextcloud-restore-test/
├── nextcloud-database.sql
└── nextcloud-directory/
```

### 3. Inspect before restoring

```bash
sudo ls -lah "$RESTORE_DIR"
sudo ls -lah "$RESTORE_DIR/nextcloud-directory"
sudo test -s "$RESTORE_DIR/nextcloud-database.sql" && echo "SQL dump exists"
```

### 4. Put the current instance into maintenance mode

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on
```

For severe disaster recovery, also stop the web server, PHP-FPM, and cron jobs that may touch Nextcloud:

```bash
sudo systemctl stop nginx apache2 php*-fpm 2>/dev/null || true
sudo systemctl stop cron 2>/dev/null || true
```

Use the service names that actually exist on your system.

### 5. Preserve the current broken state

Before overwriting anything, keep a last-resort copy:

```bash
sudo rsync -Aax /var/www/nextcloud/ /root/nextcloud-before-restore/
```

### 6. Restore files

```bash
sudo rsync -Aax --delete "$RESTORE_DIR/nextcloud-directory/" /var/www/nextcloud/
```

Fix ownership if required:

```bash
sudo chown -R www-data:www-data /var/www/nextcloud
```

If your deployment uses a different web-server user, replace `www-data` with your configured `WEB_USER`.

### 7. Restore MariaDB database

Use a MariaDB administrative user for restore.

```bash
sudo mariadb -u root -p -e "DROP DATABASE nextcloud;"
sudo mariadb -u root -p -e "CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
sudo mariadb -u root -p nextcloud < "$RESTORE_DIR/nextcloud-database.sql"
```

If your original database used different character set or collation settings, recreate it accordingly.

### 8. Run maintenance commands

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:repair
```

If the restored data is older than some client-side data, evaluate whether to run:

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:data-fingerprint
```

If files were restored manually or the database and data directory may be out of sync, evaluate whether a file scan is required:

```bash
sudo -u www-data php /var/www/nextcloud/occ files:scan --all
```

### 9. Disable maintenance mode and restart services

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off
sudo systemctl start cron 2>/dev/null || true
sudo systemctl start php*-fpm nginx apache2 2>/dev/null || true
```

### 10. Validate the restored instance

Check:

```bash
sudo -u www-data php /var/www/nextcloud/occ status
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode
```

Then verify from the web UI:

- login works;
- files are visible;
- files can be uploaded and downloaded;
- shares work;
- apps load;
- background jobs run;
- logs do not show new critical errors.

---

## Security model

This project handles highly sensitive data. Treat every archive as a full copy of your Nextcloud instance.

### File permissions

Recommended permissions:

```bash
sudo chown root:root /opt/nextcloud-backup/nextcloud-backup.sh
sudo chown root:root /opt/nextcloud-backup/nextcloud-backup.env
sudo chmod 700 /opt/nextcloud-backup/nextcloud-backup.sh
sudo chmod 600 /opt/nextcloud-backup/nextcloud-backup.env
sudo chmod 700 /opt/nextcloud-backup
```

The script sets:

```bash
umask 0077
```

This makes newly created files private by default.

### Database password handling

The script passes the MariaDB password through `MYSQL_PWD` instead of placing it directly in the command-line arguments. This avoids exposing the password in normal `ps` command output.

However, the password still exists in the root-readable env file and in the process environment while the dump is running. Keep the env file root-only.

### Backup storage

Do not store backups:

- inside the Nextcloud web root;
- inside a publicly served directory;
- only on the same disk as the original data;
- only on the same server.

Recommended production pattern:

1. Create the local backup archive.
2. Verify it.
3. Generate a checksum.
4. Encrypt it if required by your threat model.
5. Copy it off-site.
6. Test restore regularly.

Example off-site copy using `rsync`:

```bash
rsync -avh --progress /opt/nextcloud-backup/ backup-server:/srv/backups/nextcloud/
```

Example encryption with `age`:

```bash
age -r "age1examplepublickey..." \
  -o nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz.age \
  nextcloud-backup_YYYY-mm-dd_HH-MM-SS.tar.xz
```

---

## Operational notes

### Maintenance mode creates downtime

The script enables maintenance mode before dumping the database and archiving files, then disables it after the archive is verified. Users cannot log in normally while maintenance mode is active.

Schedule backups during low-traffic windows.

### Disk-space check behavior

The script currently calculates required free space as:

```bash
required_kb=$(( nc_size_kb * 2 ))
```

So the implemented check requires approximately **2× `NC_DIR` size** available in `BACKUP_ROOT`.

### Archive verification is structural

The built-in verification step confirms the archive can be listed by `tar`. This catches many truncation, xz, and tar-structure problems. It does not validate application-level consistency, database importability, filesystem ownership correctness, or full restore success.

### Lock behavior

The lock directory is:

```text
.nextcloud-backup.lock
```

It is created in the same directory as the script. If a run crashes hard, the lock may remain. Confirm that no backup is running before removing it:

```bash
ps aux | grep '[n]extcloud-backup.sh'
sudo rm -rf /opt/nextcloud-backup/.nextcloud-backup.lock
```

### Log file

The log file is:

```text
nextcloud-backup.log
```

It is stored beside the script, not inside `BACKUP_ROOT`.

Consider external log rotation for long-running deployments:

```text
/opt/nextcloud-backup/nextcloud-backup.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 0600 root root
}
```

---

## Troubleshooting

### `This script must be run as root`

Run it with `sudo`:

```bash
sudo /opt/nextcloud-backup/nextcloud-backup.sh
```

### `Environment file not found`

`nextcloud-backup.env` must be in the same directory as `nextcloud-backup.sh`.

Check:

```bash
ls -lah /opt/nextcloud-backup/
```

### `Missing required commands`

Install the package that provides the missing command. For example, on Debian/Ubuntu:

```bash
sudo apt install mariadb-client php-cli xz-utils curl findutils coreutils gawk sudo
```

### `Nextcloud occ console not found`

`NC_DIR` is wrong or points to the wrong directory.

Check:

```bash
sudo ls -lah /var/www/nextcloud/occ
```

Update:

```bash
NC_DIR="/correct/path/to/nextcloud"
```

### `Configured web server user does not exist`

Check your web/PHP user:

```bash
ps aux | grep -E 'php-fpm|apache|nginx' | head
id www-data
id http
id nginx
id apache
```

Then update:

```bash
WEB_USER="www-data"
```

### `Database connection failed`

Test manually:

```bash
MYSQL_PWD='your-password' mariadb \
  --host='localhost' \
  --user='backup_user' \
  --execute='SELECT 1;' \
  nextcloud
```

Check:

- `DB_HOST`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`
- MariaDB service status
- firewall rules
- user host grants, such as `'backup_user'@'localhost'` vs `'backup_user'@'%'`

### `Insufficient disk space`

Check sizes:

```bash
sudo du -sh /var/www/nextcloud
sudo df -h /opt/nextcloud-backup
```

Free space, change `BACKUP_ROOT`, reduce unnecessary data, or move backups to a larger filesystem.

### `Database dump file is empty`

Possible causes:

- wrong database name;
- insufficient MariaDB privileges;
- broken DB connection;
- disk write failure;
- MariaDB authentication issue.

Run the dump manually with the same credentials and inspect the error.

### `Archive integrity check failed`

Possible causes:

- disk filled during archive creation;
- filesystem error;
- xz/tar failure;
- interrupted backup;
- hardware/storage problem.

The script removes partial or unverified archives when possible.

### Nextcloud remains in maintenance mode after failure

The script attempts to disable maintenance mode during cleanup. If that fails, run:

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off
```

If `occ` is unavailable, inspect `config/config.php` and set:

```php
'maintenance' => false,
```

### Stale lock exists

Confirm no backup is running:

```bash
ps aux | grep '[n]extcloud-backup.sh'
```

Remove the stale lock:

```bash
sudo rm -rf /opt/nextcloud-backup/.nextcloud-backup.lock
```

### ntfy notifications do not arrive

Test manually:

```bash
curl -H "Title: Test" -H "Tags: white_check_mark" -d "Nextcloud backup notification test" "https://ntfy.sh/your-topic"
```

Check:

- `NTFY_URL` is correct;
- topic name is correct;
- outbound HTTPS is allowed;
- self-hosted ntfy endpoint is reachable;
- phone/browser is subscribed to the topic.

---

## Limitations

- Supports MariaDB backups only. PostgreSQL, MySQL-specific tooling, and SQLite are not implemented.
- Creates full backups, not incremental or differential backups.
- Does not upload backups to remote storage.
- Does not encrypt, sign, or checksum archives by itself.
- Does not implement Docker-aware `occ` or database commands.
- Does not support distributed/multi-node Nextcloud deployments directly.
- Does not guarantee application-level restore success without restore testing.
- Uses maintenance mode, so backup windows create service downtime.
- Uses local retention only; this does not replace off-site backup policy.
- Archive verification is structural, not a full disaster-recovery validation.

---

## Recommended production checklist

Before relying on this backup system, complete the following:

- [ ] Use a dedicated MariaDB backup user instead of database root.
- [ ] Store `nextcloud-backup.env` as root-readable only.
- [ ] Store `BACKUP_ROOT` outside the web root.
- [ ] Confirm `NC_DIR` points to the real Nextcloud installation.
- [ ] Confirm `WEB_USER` matches the real web/PHP user.
- [ ] Run one manual backup successfully.
- [ ] Verify the archive with `tar --list`.
- [ ] Extract a backup in a staging directory.
- [ ] Restore into a test Nextcloud instance.
- [ ] Configure systemd timer or cron scheduling.
- [ ] Configure ntfy or another monitoring path.
- [ ] Add off-site replication.
- [ ] Add checksums.
- [ ] Add encryption if required.
- [ ] Monitor backup age and failure status.
- [ ] Document the restore procedure for your actual server.
- [ ] Periodically perform restore drills.

---

## Project structure

```text
nextcloud-backup/
├── LICENSE
├── README.md
├── nextcloud-backup.env
└── nextcloud-backup.sh
```

---

## Contributing

Contributions should preserve the current operational principles:

- configuration belongs in `nextcloud-backup.env`, not hard-coded in the script;
- failures should abort clearly and safely;
- maintenance mode must not be left enabled silently;
- partial or unverified archives should not be retained;
- logs should remain readable by humans during emergencies;
- restore documentation should stay aligned with the archive format.

Useful future improvements include:

- optional checksum generation;
- optional encryption;
- optional remote sync target;
- Docker-aware mode;
- PostgreSQL support;
- explicit backup manifest file inside each archive;
- systemd unit files in the repository;
- automated restore-test helper.

---

## License

This project is licensed under the MIT License. See `LICENSE` for details.
