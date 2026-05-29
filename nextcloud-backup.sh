#!/usr/bin/env bash
# ==============================================================================
# nextcloud-backup.sh — Production-ready automated backup script for Nextcloud
# ==============================================================================
# Reads ALL configuration from a companion nextcloud-backup.env file located
# in the same directory as this script.  No modification to this file should
# ever be necessary for configuration purposes.
#
# Archive structure produced on every successful run:
#   nextcloud-backup_<YYYY-mm-dd_HH-MM-SS>.tar.xz
#     ├── nextcloud-database.sql     (full MariaDB dump)
#     └── nextcloud-directory/       (Nextcloud installation tree)
#           ├── config/
#           ├── data/
#           ├── apps/
#           └── ...
#
# Version : 1.0.0
# Requires: bash >= 4.2, mariadb-client, php, tar, xz, curl,
#           find, df, du, awk, sudo
# ==============================================================================

set -Eeuo pipefail          # Exit on error (-e), unbound vars (-u), pipe fail (-o pipefail),
                             # and propagate ERR traps into functions/subshells (-E)
IFS=$'\n\t'                  # Safer word-splitting: split only on newline and tab, never space
umask 0077                   # All files created by this script are private to root by default


# ==============================================================================
#  SCRIPT IDENTITY
# ==============================================================================
# Immutable constants that describe this script's own location and version.
# Resolved before any other logic so every subsequent section can reference
# SCRIPT_DIR reliably.

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_START_EPOCH="$(date +%s)"


# ==============================================================================
#  LOGGING
# ==============================================================================
# The logging subsystem is defined before ALL other code so that every
# subsequent statement — including early bootstrap failures — can emit
# structured, timestamped log entries.
#
# Each entry is written to two sinks simultaneously:
#   1. Terminal  — ANSI-colored output on stdout (INFO/WARN/SUCCESS) or
#                  stderr (ERROR); color is suppressed when the fd is not a tty.
#   2. Log file  — Plain-text append to nextcloud-backup.log in SCRIPT_DIR.
#
# Entry format:  [YYYY-mm-dd HH:MM:SS] [LEVEL  ] MESSAGE
# Levels:
#   INFO    — plain white, stdout  — routine progress information
#   WARN    — bold yellow, stdout  — non-fatal anomaly; backup continues
#   ERROR   — bold red,   stderr   — fatal condition; backup will abort
#   SUCCESS — bold green, stdout   — phase completed successfully

readonly LOG_FILE="${SCRIPT_DIR}/nextcloud-backup.log"

# ANSI escape sequences (applied to terminal output only)
readonly _CLR_RESET='\033[0m'
readonly _CLR_YELLOW='\033[1;33m'
readonly _CLR_RED='\033[1;31m'
readonly _CLR_GREEN='\033[1;32m'

# log <LEVEL> <MESSAGE>
# Emits one timestamped, level-tagged line to the appropriate stream and to
# the log file.  Uses printf exclusively (built-in; no external process fork).
log() {
    local level="${1}"
    local message="${2}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Left-align the level name into a 7-character field so all columns align:
    #   INFO    → "INFO   "   WARN → "WARN   "
    #   ERROR   → "ERROR  "   SUCCESS → "SUCCESS"
    local padded_level
    printf -v padded_level '%-7s' "${level}"

    local plain_line="[${timestamp}] [${padded_level}] ${message}"

    # Resolve the target file descriptor and optional ANSI color for this level
    local color="" fd=1
    case "${level}" in
        WARN)    color="${_CLR_YELLOW}"          ;;
        ERROR)   color="${_CLR_RED}"   ; fd=2    ;;
        SUCCESS) color="${_CLR_GREEN}"           ;;
    esac

    # Write colored output when connected to a real terminal; plain otherwise
    if [[ -t ${fd} && -n "${color}" ]]; then
        printf '%b\n' "${color}${plain_line}${_CLR_RESET}" >&"${fd}"
    else
        printf '%s\n' "${plain_line}" >&"${fd}"
    fi

    # Always append the plain-text entry to the log file (>> never truncates)
    printf '%s\n' "${plain_line}" >>"${LOG_FILE}"
}

# log_section <TITLE>
# Emits a bold "===" decorated header that visually separates the major phases
# of the backup in both terminal output and the log file.
log_section() {
    local title="${1}"
    local bar
    bar="$(printf '=%.0s' {1..72})"
    log INFO "${bar}"
    log INFO "=== ${title}"
    log INFO "${bar}"
}


# ==============================================================================
#  RUNTIME STATE
# ==============================================================================
# Mutable variables tracking how far the backup has progressed.  The STAGE
# integer is the single source of truth for the cleanup function; it determines
# exactly which side effects must be rolled back on any exit path.
#
# STAGE progression:
#   0 — Script is initializing; no side effects yet
#   1 — Nextcloud maintenance mode has been enabled
#   2 — Database dump written to TEMP_DIR
#   3 — Archive file created in BACKUP_ROOT (integrity not yet confirmed)
#   4 — Archive integrity verified; the file is safe to keep
#   5 — Maintenance mode disabled; backup fully complete

STAGE=0

# Paths set during bootstrap; used by cleanup for rollback
TEMP_DIR=""       # Removed unconditionally on every exit
ARCHIVE_PATH=""   # Removed only when STAGE == 3 (created but unverified)

# Lock state flag; cleanup releases the lock only when it was actually acquired
LOCK_ACQUIRED=false


# ==============================================================================
#  CLEANUP & ERROR HANDLERS
# ==============================================================================
# Defined immediately after runtime state so the trap declarations that follow
# can reference these functions by name.

# cleanup
# Registered on the EXIT pseudo-signal.  Runs unconditionally on every exit —
# whether due to success, a runtime error, or a caught OS signal.  Uses STAGE
# to decide which side effects to roll back, ensuring the system is always left
# in a consistent state regardless of where the script was interrupted.
cleanup() {
    local exit_code=$?

    log_section "CLEANUP"

    # ── Temporary directory ────────────────────────────────────────────────────
    # Always removed: it contains only intermediate artifacts (SQL dump,
    # the NC_DIR symlink) that are no longer needed once the archive exists.
    if [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
        log INFO "Temporary directory removed: ${TEMP_DIR}"
    fi

    # ── Partial archive ────────────────────────────────────────────────────────
    # The archive exists on disk at STAGE=3 but its integrity has not yet been
    # confirmed.  Remove it so a potentially corrupted file is never retained.
    # At STAGE=4+ the archive has been verified and must be preserved.
    if [[ "${STAGE}" -eq 3 && -n "${ARCHIVE_PATH}" && -f "${ARCHIVE_PATH}" ]]; then
        rm -f "${ARCHIVE_PATH}"
        log WARN "Partial / unverified archive removed: ${ARCHIVE_PATH}"
    fi

    # ── Maintenance mode ───────────────────────────────────────────────────────
    # Lift maintenance mode whenever it was enabled (STAGE >= 1) but not yet
    # explicitly disabled by the happy path (STAGE < 5).
    # By the time STAGE reaches 1, both WEB_USER and NC_DIR are guaranteed to
    # be non-empty (they are validated in bootstrap before maintenance is enabled).
    if [[ "${STAGE}" -ge 1 && "${STAGE}" -lt 5 ]]; then
        log WARN "Disabling Nextcloud maintenance mode during cleanup..."
        if sudo -u "${WEB_USER}" php "${NC_DIR}/occ" maintenance:mode --off \
                >/dev/null 2>&1; then
            log INFO "Maintenance mode disabled successfully."
        else
            log ERROR "FAILED to disable maintenance mode."
            log ERROR "Run manually: sudo -u ${WEB_USER} php ${NC_DIR}/occ maintenance:mode --off"
        fi
    fi

    # ── Lock ───────────────────────────────────────────────────────────────────
    # Released last: keeps competing processes blocked for as long as possible
    # while the rest of cleanup is in progress.
    if [[ "${LOCK_ACQUIRED}" == true && -d "${LOCK_DIR:-}" ]]; then
        rmdir "${LOCK_DIR}"
        LOCK_ACQUIRED=false
        log INFO "Lock released: ${LOCK_DIR}"
    fi

    # ── Final exit summary ─────────────────────────────────────────────────────
    if [[ ${exit_code} -eq 0 ]]; then
        log SUCCESS "Script exited cleanly (exit code 0)."
    else
        log ERROR "Script exited with code ${exit_code}."
    fi
}

# handle_error <LINE_NUMBER>
# Registered on the ERR pseudo-signal (requires set -E to propagate into
# functions).  Invoked automatically whenever a command exits non-zero.
# Does NOT call exit itself — set -e causes the script to exit after this
# handler returns, which in turn fires the EXIT trap (cleanup).
handle_error() {
    local line_number="${1:-unknown}"
    log ERROR "Unexpected error detected at line ${line_number}."
    log ERROR "Initiating rollback and cleanup..."
    # Attempt to deliver a failure notification; suppress all output so that
    # a secondary ntfy failure never obscures the original error.
    ntfy_failed "${line_number}" >/dev/null 2>&1 || true
}


# ==============================================================================
#  TRAPS
# ==============================================================================
# Declared immediately after the handler functions to ensure that any error
# arising during the remaining function definitions is caught and handled.
#
# Signal exit codes follow the POSIX convention: 128 + signal number.
#   SIGHUP  =  1  →  exit 129
#   SIGINT  =  2  →  exit 130
#   SIGTERM = 15  →  exit 143

trap 'cleanup'                                           EXIT
trap 'handle_error "${BASH_LINENO[0]}"'                 ERR
trap 'log WARN "Caught SIGINT  — aborting."; exit 130'  INT
trap 'log WARN "Caught SIGTERM — aborting."; exit 143'  TERM
trap 'log WARN "Caught SIGHUP  — aborting."; exit 129'  HUP


# ==============================================================================
#  BOOTSTRAP
# ==============================================================================

# check_root
# Aborts immediately if the script is not running with root privileges.
# Root is required to invoke occ as WEB_USER, read NC_DIR, and write BACKUP_ROOT.
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log ERROR "This script must be run as root (current EUID: ${EUID})."
        exit 1
    fi
    log INFO "Privilege check passed — running as root."
}

# check_required_commands
# Verifies that every external binary used by this script is present in PATH.
# Emits a single consolidated error listing all missing commands rather than
# failing on the first missing one, so the operator can install everything at once.
check_required_commands() {
    local -a required_commands=(
        php             # Nextcloud occ CLI
        mariadb         # Database connectivity test
        mariadb-dump    # Database dump
        tar             # Archive creation and verification
        xz              # Compression (invoked by tar; also used via XZ_OPT)
        curl            # NTFY push notifications
        find            # Locating old archives for rotation
        df              # Disk space availability check
        du              # Directory and file size measurement
        awk             # Field extraction from df/du output
        sudo            # Running occ as WEB_USER
    )
    local -a missing_commands=()

    for cmd in "${required_commands[@]}"; do
        command -v "${cmd}" >/dev/null 2>&1 || missing_commands+=("${cmd}")
    done

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log ERROR "Missing required commands: ${missing_commands[*]}"
        log ERROR "Install the missing packages and retry."
        exit 1
    fi

    log INFO "All required commands are present in PATH."
}

# load_env_file
# Sources the companion .env file from SCRIPT_DIR.  All configuration
# variables are expected to be defined there.  The path is fixed and
# intentionally non-configurable to prevent ambiguity.
load_env_file() {
    local env_file="${SCRIPT_DIR}/nextcloud-backup.env"

    if [[ ! -f "${env_file}" ]]; then
        log ERROR "Environment file not found: ${env_file}"
        log ERROR "Create the file alongside this script and configure it."
        exit 1
    fi

    if [[ ! -r "${env_file}" ]]; then
        log ERROR "Environment file is not readable (check permissions): ${env_file}"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${env_file}"
    log INFO "Environment file loaded: ${env_file}"
}

# apply_defaults
# Applies built-in default values to optional configuration variables that
# were not set or were left empty in the env file.
# Also merges the three permanent default exclude patterns into EXCLUDES,
# regardless of whether the user defined custom excludes or not.
apply_defaults() {
    # Scalar defaults
    RETENTION_DAYS="${RETENTION_DAYS:-7}"
    XZ_LEVEL="${XZ_LEVEL:-6}"
    NTFY_URL="${NTFY_URL:-}"

    # Array defaults — safe even when the variables were never declared
    # in the env file (the ${array[@]+"${array[@]}"} idiom expands to
    # nothing rather than an error when the array is unset under set -u).
    INCLUDES=("${INCLUDES[@]+"${INCLUDES[@]}"}")
    EXCLUDES=("${EXCLUDES[@]+"${EXCLUDES[@]}"}")

    # These three patterns are always excluded to prevent storing large,
    # regenerable Nextcloud caches in the backup archive.
    local -ra permanent_excludes=(
        "--exclude=updater-*"
        "--exclude=data/*/cache"
        "--exclude=data/*/thumbnails"
        "--exclude=data/appdata_*/preview"
        "--exclude=data/appdata_*/appstore"
    )

    # Merge permanent excludes into EXCLUDES, skipping any exact duplicates
    # so the resulting array never contains redundant entries.
    local perm_entry existing_entry already_present
    for perm_entry in "${permanent_excludes[@]}"; do
        already_present=false
        for existing_entry in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
            if [[ "${existing_entry}" == "${perm_entry}" ]]; then
                already_present=true
                break
            fi
        done
        if [[ "${already_present}" == false ]]; then
            EXCLUDES+=("${perm_entry}")
        fi
    done

    log INFO "Configuration defaults applied."
    log INFO "  RETENTION_DAYS : ${RETENTION_DAYS}"
    log INFO "  XZ_LEVEL       : ${XZ_LEVEL}"
    log INFO "  NTFY           : ${NTFY_URL:-disabled}"
}

# validate_required_vars
# Ensures every mandatory configuration variable was supplied and is non-empty.
# Collects all missing variables before aborting so the operator sees everything
# that needs to be fixed in a single run.
validate_required_vars() {
    local -a required_vars=(
        DB_HOST
        DB_NAME
        DB_USER
        DB_PASSWORD
        NC_DIR
        WEB_USER
        BACKUP_ROOT
    )
    local var missing_count=0

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log ERROR "Required variable is unset or empty: ${var}"
            missing_count=$(( missing_count + 1 ))
        fi
    done

    if [[ ${missing_count} -gt 0 ]]; then
        log ERROR "${missing_count} required variable(s) are missing — aborting."
        exit 1
    fi

    log INFO "All required configuration variables are present."
}

# initialize_paths
# Derives all runtime path constants from validated configuration.
# Called after validate_required_vars so it can safely reference config vars.
initialize_paths() {
    # Timestamp is captured once here and reused everywhere so archive name
    # and log entries are perfectly consistent throughout the run.
    readonly TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
    readonly ARCHIVE_NAME="nextcloud-backup_${TIMESTAMP}.tar.xz"
    readonly ARCHIVE_PATH="${BACKUP_ROOT}/${ARCHIVE_NAME}"

    # Temp dir uses the process ID ($$) to guarantee uniqueness when multiple
    # invocations overlap briefly (e.g., during stale-lock recovery).
    readonly TEMP_DIR="/tmp/nextcloud-backup-$$"

    # Lock dir lives alongside the script so it is always on a local filesystem,
    # avoiding NFS-related mkdir atomicity issues.
    readonly LOCK_DIR="${SCRIPT_DIR}/.nextcloud-backup.lock"

    log INFO "Derived paths:"
    log INFO "  Timestamp    : ${TIMESTAMP}"
    log INFO "  Archive      : ${ARCHIVE_PATH}"
    log INFO "  Temp dir     : ${TEMP_DIR}"
    log INFO "  Lock dir     : ${LOCK_DIR}"
}

# create_directories
# Creates BACKUP_ROOT and TEMP_DIR, failing loudly if either cannot be made.
create_directories() {
    if [[ ! -d "${BACKUP_ROOT}" ]]; then
        mkdir -p "${BACKUP_ROOT}"
        log INFO "Backup root directory created: ${BACKUP_ROOT}"
    else
        log INFO "Backup root directory already exists: ${BACKUP_ROOT}"
    fi

    # Fresh temp dir per run; inherits the restrictive umask set at the top
    mkdir -p "${TEMP_DIR}"
    log INFO "Temporary working directory created: ${TEMP_DIR}"
}

# bootstrap
# Orchestrates all startup steps in their required order.
# Nothing meaningful happens in the script until bootstrap succeeds.
bootstrap() {
    log_section "BOOTSTRAP"
    check_root
    check_required_commands
    load_env_file
    apply_defaults
    validate_required_vars
    initialize_paths
    create_directories
    log SUCCESS "Bootstrap complete."
}


# ==============================================================================
#  LOCK MANAGEMENT
# ==============================================================================
# Uses a lock directory instead of a lock file because mkdir(2) is atomic on
# all POSIX-compliant local filesystems, eliminating any TOCTOU race condition.
# The lock is created by acquire_lock and destroyed in cleanup (EXIT trap).

# acquire_lock
# Creates the lock directory.  Exits immediately if the lock already exists,
# indicating another instance is running (or a previous run died without
# cleaning up — the operator must remove a stale lock manually).
acquire_lock() {
    log_section "LOCK"

    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        log ERROR "Could not acquire lock — another backup instance may be running."
        log ERROR "Lock directory: ${LOCK_DIR}"
        log ERROR "If the previous run crashed, remove the stale lock manually:"
        log ERROR "  rm -rf ${LOCK_DIR}"
        exit 1
    fi

    LOCK_ACQUIRED=true
    log INFO "Lock acquired: ${LOCK_DIR}"
}


# ==============================================================================
#  NOTIFICATIONS (NTFY)
# ==============================================================================
# All notification functions are strictly best-effort.  A delivery failure
# emits a WARN log entry and never causes the backup to abort.
# When NTFY_URL is empty, ntfy_send returns immediately without any network I/O.

# ntfy_send <TITLE> <MESSAGE> <EMOJI_TAG>
# Posts a single push notification to the configured NTFY endpoint.
ntfy_send() {
    local title="${1}"
    local message="${2}"
    local emoji="${3:-}"

    # Skip silently when notifications are not configured
    [[ -z "${NTFY_URL:-}" ]] && return 0

    if ! curl \
            --silent \
	    --max-time 10 \
            --header "Title: ${title}" \
            --header "Tags: ${emoji}" \
            --data "${message}" \
            "${NTFY_URL}" >/dev/null 2>&1; then
        log WARN "NTFY notification delivery failed (endpoint: ${NTFY_URL})"
    fi
}

# ntfy_started — posted right after the lock is acquired
ntfy_started() {
    ntfy_send \
        "Nextcloud Backup Started" \
        "Backup started at $(hostname)." \
        "hourglass_flowing_sand"
    log INFO "NTFY: 'started' notification dispatched."
}

# ntfy_failed <LINE_NUMBER> — posted from handle_error
ntfy_failed() {
    local line_number="${1:-unknown}"
    ntfy_send \
        "Nextcloud Backup FAILED" \
        "Backup failed at line ${line_number} on $(hostname)." \
        "rotating_light"
    log INFO "NTFY: 'failed' notification dispatched (line ${line_number})."
}

# ntfy_success <ARCHIVE_SIZE> <DURATION> — posted at the very end of main
ntfy_success() {
    local archive_size="${1}"
    local duration="${2}"
    ntfy_send \
        "Nextcloud Backup Successful" \
        "Backup successful on $(hostname). Size: ${archive_size}, Duration: ${duration}." \
        "white_check_mark"
    log INFO "NTFY: 'success' notification dispatched."
}


# ==============================================================================
#  MAINTENANCE MODE
# ==============================================================================
# Maintenance mode gates all user activity on the Nextcloud instance.
# It is enabled before any data is read so the database and filesystem are
# quiescent during the backup, and disabled immediately after the archive is
# verified.  The cleanup function handles disabling it on all error paths.

# enable_maintenance_mode
# Switches Nextcloud into maintenance mode via the occ CLI.
# Advances STAGE to 1 so cleanup knows to disable maintenance on any exit.
enable_maintenance_mode() {
    log INFO "Enabling Nextcloud maintenance mode..."
    sudo -u "${WEB_USER}" php "${NC_DIR}/occ" maintenance:mode --on
    STAGE=1
    log SUCCESS "Maintenance mode enabled."
}

# disable_maintenance_mode
# Lifts Nextcloud maintenance mode and advances STAGE to 5 so cleanup knows
# not to attempt a redundant disable on clean exits.
disable_maintenance_mode() {
    log INFO "Disabling Nextcloud maintenance mode..."
    sudo -u "${WEB_USER}" php "${NC_DIR}/occ" maintenance:mode --off
    STAGE=5
    log SUCCESS "Maintenance mode disabled."
}


# ==============================================================================
#  PRE-FLIGHT CHECKS
# ==============================================================================
# All validations that can be performed without modifying system state run here,
# before maintenance mode is enabled and before any data is touched.

# check_nc_dir_and_occ
# Confirms NC_DIR exists and contains the occ console script.
check_nc_dir_and_occ() {
    if [[ ! -d "${NC_DIR}" ]]; then
        log ERROR "Nextcloud installation directory not found: ${NC_DIR}"
        exit 1
    fi

    if [[ ! -f "${NC_DIR}/occ" ]]; then
        log ERROR "Nextcloud occ console not found: ${NC_DIR}/occ"
        exit 1
    fi

    log INFO "Nextcloud installation directory verified: ${NC_DIR}"
}

# check_web_user
# Verifies that the configured WEB_USER account actually exists on the system.
check_web_user() {
    if ! id "${WEB_USER}" >/dev/null 2>&1; then
        log ERROR "Configured web server user does not exist: ${WEB_USER}"
        exit 1
    fi
    log INFO "Web server user verified: ${WEB_USER}"
}

# check_db_connectivity
# Opens a live test connection to the database using the configured credentials.
# Failing here is far less disruptive than failing mid-backup after maintenance
# mode has already been activated.
check_db_connectivity() {
    log INFO "Testing database connectivity — ${DB_USER}@${DB_HOST}/${DB_NAME}..."

    if ! MYSQL_PWD="${DB_PASSWORD}" mariadb \
            --host="${DB_HOST}" \
            --user="${DB_USER}" \
            --execute="SELECT 1;" \
            "${DB_NAME}" >/dev/null 2>&1; then
        log ERROR "Database connection failed."
        log ERROR "Verify DB_HOST, DB_NAME, DB_USER, and DB_PASSWORD in the env file."
        exit 1
    fi

    log INFO "Database connectivity verified."
}

# check_disk_space
# Estimates that at least 3× the current size of NC_DIR is free in BACKUP_ROOT.
# The multiplier accounts for: the raw directory tree (1×), the uncompressed
# SQL dump (overhead), and the final .tar.xz archive (typically < 1× but worst
# case 1×), with a safety margin.
check_disk_space() {
    log INFO "Estimating required disk space (3× NC_DIR size)..."

    local nc_size_kb available_kb required_kb
    nc_size_kb="$(du -sk "${NC_DIR}" 2>/dev/null | awk '{print $1}')"
    required_kb=$(( nc_size_kb * 3 ))
    available_kb="$(df -k "${BACKUP_ROOT}" | awk 'NR==2 {print $4}')"

    local nc_mb required_mb available_mb
    nc_mb=$(( nc_size_kb  / 1024 ))
    required_mb=$(( required_kb / 1024 ))
    available_mb=$(( available_kb / 1024 ))

    log INFO "  NC_DIR size      : ${nc_mb} MB"
    log INFO "  Required (3×)    : ${required_mb} MB"
    log INFO "  Available        : ${available_mb} MB in ${BACKUP_ROOT}"

    if [[ ${available_kb} -lt ${required_kb} ]]; then
        log ERROR "Insufficient disk space — required: ${required_mb} MB, available: ${available_mb} MB."
        exit 1
    fi

    log INFO "Disk space check passed."
}

# run_preflight_checks
# Runs all pre-flight verifications in order.  Separating each check into its
# own function keeps this orchestrator readable and each check independently
# testable.
run_preflight_checks() {
    log_section "PRE-FLIGHT CHECKS"
    check_nc_dir_and_occ
    check_web_user
    check_db_connectivity
    check_disk_space
    log SUCCESS "All pre-flight checks passed."
}


# ==============================================================================
#  DATABASE BACKUP
# ==============================================================================

# backup_database
# Dumps the entire Nextcloud database to a .sql file in TEMP_DIR.
#
# Security note: credentials are passed via the MYSQL_PWD environment variable
# rather than as CLI arguments, so they never appear in /proc/<pid>/cmdline,
# ps output, or shell history.
#
# Consistency note: --single-transaction starts a repeatable-read transaction
# before the dump begins, guaranteeing a consistent snapshot of all InnoDB
# tables without acquiring global locks.  --quick streams rows directly rather
# than buffering the entire table in memory, making it safe for large databases.
backup_database() {
    log_section "DATABASE BACKUP"

    local dump_file="${TEMP_DIR}/nextcloud-database.sql"

    log INFO "Dumping database '${DB_NAME}' from host '${DB_HOST}'..."
    log INFO "  Destination: ${dump_file}"

    MYSQL_PWD="${DB_PASSWORD}" mariadb-dump \
        --host="${DB_HOST}" \
        --user="${DB_USER}" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --routines \
        --events \
        "${DB_NAME}" > "${dump_file}"

    # A zero-byte dump file indicates a silent failure (e.g., permission denied,
    # wrong database name, or an empty target database where none was expected).
    if [[ ! -s "${dump_file}" ]]; then
        log ERROR "Database dump file is empty — the dump likely failed silently."
        log ERROR "Dump path: ${dump_file}"
        exit 1
    fi

    local dump_size
    dump_size="$(du -sh "${dump_file}" | awk '{print $1}')"

    STAGE=2
    log SUCCESS "Database dump complete: ${dump_file} (${dump_size})"
}


# ==============================================================================
#  ARCHIVE CREATION
# ==============================================================================
# The archive is always structured with two top-level entries:
#   nextcloud-database.sql       — SQL dump, added directly from TEMP_DIR
#   nextcloud-directory/         — Nextcloud tree, named consistently regardless
#                                  of the actual installation path
#
# Consistent naming strategy:
#   A symlink  TEMP_DIR/nextcloud-directory → NC_DIR  is created in TEMP_DIR.
#   tar's --dereference flag causes it to follow the symlink and archive the
#   actual NC_DIR contents under the "nextcloud-directory/" prefix.  This means
#   the resulting archive always has the same internal structure, independent of
#   where Nextcloud is installed on the host.
#
# Exclude path convention:
#   Patterns in EXCLUDES are written relative to NC_DIR (e.g., "data/cache").
#   build_exclude_args() automatically prefixes each pattern with
#   "nextcloud-directory/" so they match the actual in-archive paths.

# build_exclude_args <nameref_array>
# Populates the nameref array with properly prefixed --exclude= arguments
# ready to be passed to tar.
build_exclude_args() {
    local -n _exclude_args_ref="${1}"
    _exclude_args_ref=()

    local raw_entry bare_pattern
    for raw_entry in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
        # Strip the "--exclude=" prefix to obtain the bare pattern
        bare_pattern="${raw_entry#--exclude=}"
        # Prepend "nextcloud-directory/" so the pattern matches paths as they
        # appear inside the archive (e.g., "data/cache" →
        # "nextcloud-directory/data/cache").
        _exclude_args_ref+=("--exclude=nextcloud-directory/${bare_pattern}")
    done
}

# create_archive
# Builds the final .tar.xz archive from the SQL dump and the Nextcloud tree.
# Sets STAGE=3 so cleanup removes a partial archive if anything goes wrong
# before the integrity verification step.
create_archive() {
    log_section "ARCHIVE CREATION"

    log INFO "Target archive : ${ARCHIVE_PATH}"
    log INFO "XZ level       : ${XZ_LEVEL}"

    # Create the naming symlink: nextcloud-directory → NC_DIR
    # tar --dereference will follow this link and store the real content under
    # the "nextcloud-directory/" prefix in the archive.
    ln -sf "${NC_DIR}" "${TEMP_DIR}/nextcloud-directory"
    log INFO "Staging symlink : ${TEMP_DIR}/nextcloud-directory → ${NC_DIR}"

    # Build the prefixed exclude argument list
    local -a effective_excludes
    build_exclude_args effective_excludes

    # Resolve which NC content entries to archive:
    #   INCLUDES empty  → the entire NC_DIR via the "nextcloud-directory" symlink
    #   INCLUDES set    → only the specified names under "nextcloud-directory/"
    local -a nc_entries=()
    if [[ ${#INCLUDES[@]} -eq 0 ]]; then
        nc_entries=("nextcloud-directory")
        log INFO "NC scope       : full installation (INCLUDES not set)"
    else
        local item
        for item in "${INCLUDES[@]}"; do
            nc_entries+=("nextcloud-directory/${item}")
        done
        log INFO "NC scope       : ${nc_entries[*]}"
    fi

    if [[ ${#effective_excludes[@]} -gt 0 ]]; then
        log INFO "Excludes       : ${effective_excludes[*]}"
    fi

    # Assemble the tar command as an array to prevent any word-splitting or
    # glob expansion of paths and patterns that contain special characters.
    local -a tar_cmd=(
        tar
        --create
        --xz
        --dereference                    # Follow the nextcloud-directory symlink into NC_DIR
        --file="${ARCHIVE_PATH}"
        --directory="${TEMP_DIR}"        # All positional arguments are relative to TEMP_DIR
    )

    # Append exclude arguments (must precede the positional file list for tar)
    if [[ ${#effective_excludes[@]} -gt 0 ]]; then
        tar_cmd+=("${effective_excludes[@]}")
    fi

    # Append the SQL dump and the NC tree entries
    tar_cmd+=("nextcloud-database.sql" "${nc_entries[@]}")

    # XZ_OPT is scoped to this single tar invocation via the VAR=val prefix
    # syntax; it is never exported into the broader shell environment.
    XZ_OPT="-${XZ_LEVEL}" "${tar_cmd[@]}"

    STAGE=3
    log SUCCESS "Archive created: ${ARCHIVE_PATH}"
}


# ==============================================================================
#  ARCHIVE VERIFICATION
# ==============================================================================

# verify_archive
# Confirms the archive is structurally valid and that the xz stream is intact
# without extracting any content to disk.
#
# tar --list reads and decompresses the entire xz stream and parses every tar
# header.  Any truncation, bit-flip, or write error that occurred during archive
# creation will produce a non-zero exit code, which set -e will catch.
verify_archive() {
    log_section "ARCHIVE VERIFICATION"

    log INFO "Verifying integrity of: ${ARCHIVE_PATH}"

    if ! tar --list --file="${ARCHIVE_PATH}" >/dev/null 2>&1; then
        log ERROR "Archive integrity check failed — the file is corrupt or truncated."
        log ERROR "Archive path: ${ARCHIVE_PATH}"
        exit 1
    fi

    STAGE=4
    log SUCCESS "Archive integrity verified — the archive is structurally sound."
}


# ==============================================================================
#  BACKUP ROTATION
# ==============================================================================

# rotate_old_backups
# Finds and removes backup archives in BACKUP_ROOT that are older than
# RETENTION_DAYS days.  Only files matching the exact backup naming pattern
# are considered; no other files in BACKUP_ROOT are ever touched.
# Uses -print0 / read -d '' to handle filenames with whitespace correctly.
rotate_old_backups() {
    log_section "BACKUP ROTATION"

    if [[ "${RETENTION_DAYS}" -eq 0 ]]; then
        log INFO "RETENTION_DAYS=0 — automatic rotation is disabled."
        return 0
    fi

    log INFO "Removing archives older than ${RETENTION_DAYS} day(s) from ${BACKUP_ROOT}..."

    local removed_count=0
    local old_archive

    while IFS= read -r -d '' old_archive; do
        rm -f "${old_archive}"
        log INFO "Removed old archive: ${old_archive}"
        removed_count=$(( removed_count + 1 ))
    done < <(
        find "${BACKUP_ROOT}" \
            -maxdepth 1 \
            -type f \
            -name "nextcloud-backup_*.tar.xz" \
            -mtime "+${RETENTION_DAYS}" \
            -print0 \
        | sort -z
    )

    if [[ ${removed_count} -eq 0 ]]; then
        log INFO "No archives older than ${RETENTION_DAYS} day(s) found — nothing to remove."
    else
        log SUCCESS "Rotation complete: ${removed_count} old archive(s) removed."
    fi
}


# ==============================================================================
#  STATISTICS
# ==============================================================================

# compute_backup_stats <size_nameref> <duration_nameref>
# Calculates the final archive size and the total elapsed wall-clock time.
# Results are stored in the two nameref variables provided by the caller.
compute_backup_stats() {
    local -n _size_ref="${1}"
    local -n _duration_ref="${2}"

    # Human-readable archive size (e.g., "1.4G", "823M")
    _size_ref="$(du -sh "${ARCHIVE_PATH}" | awk '{print $1}')"

    # Elapsed time formatted as HH:MM:SS
    local elapsed_seconds=$(( $(date +%s) - SCRIPT_START_EPOCH ))
    printf -v _duration_ref '%02d:%02d:%02d' \
        $(( elapsed_seconds / 3600 )) \
        $(( (elapsed_seconds % 3600) / 60 )) \
        $(( elapsed_seconds % 60 ))
}


# ==============================================================================
#  MAIN
# ==============================================================================

# main
# Orchestrates the full backup workflow.  Each phase is clearly separated and
# logged so the operator can pinpoint exactly where a failure occurred by
# reading either the terminal output or the log file.
main() {
    log_section "NEXTCLOUD BACKUP  v${SCRIPT_VERSION}"
    log INFO "Host      : $(hostname)"
    log INFO "Script    : ${SCRIPT_DIR}/${SCRIPT_NAME}"
    log INFO "Log file  : ${LOG_FILE}"

    # ── Phase 1: Bootstrap ────────────────────────────────────────────────────
    # Load and validate all configuration; derive runtime paths; create dirs.
    bootstrap

    # ── Phase 2: Exclusive lock ───────────────────────────────────────────────
    # Prevent concurrent backup runs from interfering with each other.
    acquire_lock

    # ── Phase 3: Notify — backup started ──────────────────────────────────────
    ntfy_started

    # ── Phase 4: Pre-flight checks ────────────────────────────────────────────
    # Validate Nextcloud, credentials, and disk space before touching anything.
    run_preflight_checks

    # ── Phase 5: Enable maintenance mode ──────────────────────────────────────
    # Gate all user activity on the instance; STAGE advances to 1 here.
    log_section "MAINTENANCE MODE — ENABLE"
    enable_maintenance_mode

    # ── Phase 6: Database backup ──────────────────────────────────────────────
    # Dump the database to TEMP_DIR while the instance is quiescent; STAGE → 2.
    backup_database

    # ── Phase 7: Archive creation ─────────────────────────────────────────────
    # Compress the SQL dump and the NC tree into a single .tar.xz; STAGE → 3.
    create_archive

    # ── Phase 8: Archive verification ─────────────────────────────────────────
    # Confirm the archive is structurally sound before taking anything offline;
    # STAGE → 4.  A failure here removes the partial archive (cleanup, STAGE=3).
    verify_archive

    # ── Phase 9: Disable maintenance mode ─────────────────────────────────────
    # Restore user access as soon as the archive is confirmed safe; STAGE → 5.
    log_section "MAINTENANCE MODE — DISABLE"
    disable_maintenance_mode

    # ── Phase 10: Rotate old archives ─────────────────────────────────────────
    # Remove archives that have exceeded the configured retention period.
    rotate_old_backups

    # ── Phase 11: Statistics & final notification ──────────────────────────────
    log_section "BACKUP STATISTICS"
    local archive_size backup_duration
    compute_backup_stats archive_size backup_duration

    log SUCCESS "Archive  : ${ARCHIVE_PATH}"
    log SUCCESS "Size     : ${archive_size}"
    log SUCCESS "Duration : ${backup_duration}"

    ntfy_success "${archive_size}" "${backup_duration}"

    log_section "BACKUP COMPLETE"
    log SUCCESS "Nextcloud backup finished successfully."
    # EXIT trap (cleanup) fires here; it sees exit code 0 and skips all rollback
}


# ==============================================================================
#  ENTRY POINT
# ==============================================================================

main "$@"
