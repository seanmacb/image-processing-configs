#!/usr/bin/env bash
#
# setup_butler_backups.sh
#
# Sets up daily logical backups of every database on this instance's
# PostgreSQL server (the instance configured by setup_butler_postgres.sh),
# scheduled via cron.
#
# WHAT THIS DOES
#   - Creates a backup directory on the data volume (NOT the ephemeral OS
#     disk), owned by the postgres user.
#   - Installs butler_pg_backup.sh (the worker: pg_dump -Fc per database +
#     pg_dumpall --globals-only + retention pruning) into /usr/local/bin.
#   - Installs a cron.d entry that runs it daily as the postgres user (local
#     Unix-socket auth, so no password is stored anywhere for this).
#   - Installs a logrotate rule for its log file.
#   - Creates a dedicated, unprivileged PULL_USER account and installs the
#     public keys from PULL_KEYS_FILE into its authorized_keys, each
#     restricted (via a forced command) to running "rsync --server" under
#     NOPASSWD sudo as postgres -- i.e. only enough access for a secondary
#     machine to pull BACKUP_DIR over SSH (see pull_butler_backups.sh in
#     utilities/), nothing else.
#
# WHAT THIS DELIBERATELY DOES NOT DO
#   - Does NOT run the pull itself. This script only prepares the SOURCE
#     side (PULL_USER + authorized_keys + sudo rule) so a separate,
#     secondary machine CAN pull BACKUP_DIR -- see utilities/
#     pull_butler_backups.sh, which is installed/scheduled on that other
#     machine, not here.
#   - Does NOT set up WAL archiving / point-in-time recovery. This is
#     daily-granularity, pg_dump-based backup (RPO up to 24h), which is
#     sufficient for a Butler registry (metadata, not irreplaceable pixel
#     data). Add WAL archiving separately if a tighter RPO is ever needed.
#
# USAGE:
#   sudo ./setup_butler_backups.sh [path/to/pull_authorized_keys.conf]
#
# The SSH public keys allowed to pull backups are read from a plain-text
# file, one "authorized_keys"-format public key per line (blank lines and
# '#' comments ignored) -- see examples/butler_pull_keys.conf.example.
# Defaults to PULL_KEYS_FILE (see Configuration below) if no path is given
# on the command line.
#
# Re-runnable: recreates the backup dir, worker script, cron entry,
# logrotate rule, and PULL_USER's authorized_keys idempotently -- fine to
# re-run after changing config (e.g. a new RETENTION_DAYS, CRON_SCHEDULE,
# or PULL_KEYS_FILE).
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Configuration -- review and adjust before running
# ---------------------------------------------------------------------------

# Must match DATA_MOUNT in setup_butler_postgres.sh -- the persistent data
# volume, not the ephemeral OS disk.
DATA_MOUNT="${DATA_MOUNT:-/mnt/pgdata}"
BACKUP_DIR="${BACKUP_DIR:-${DATA_MOUNT}/backups/postgresql}"

RETENTION_DAYS="${RETENTION_DAYS:-14}"

# Standard 5-field cron schedule, interpreted in the system timezone
# (setup_butler_postgres.sh sets this to Europe/Zurich). Default: 03:00
# daily. NOTE: batch pipeline jobs are expected to run overnight too, so
# this window is NOT assumed to be free of database activity -- see
# LOCK_WAIT_TIMEOUT_SECONDS below, which is what actually protects against
# that overlap, not the choice of hour.
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * *}"

# Passed through to the worker (butler_pg_backup.sh) via the cron.d entry
# below. pg_dump/pg_dumpall only ever take an ACCESS SHARE lock, which
# conflicts with NOTHING except ACCESS EXCLUSIVE -- so this never blocks
# (or is blocked by) ordinary read/write pipeline traffic. It's scoped
# purely to DDL-class conflicts: Butler issues CREATE TABLE when a batch
# run registers a new DatasetType (possible at any point during active
# processing, not just at repo setup), and plain pg_dump locks ALL tables
# it will dump up front, in one pass, before copying any data. If that
# pass gets stuck on one DDL-locked table, pg_dump keeps holding the locks
# it already acquired on every other table for as long as it's stuck,
# which can block unrelated DDL elsewhere. LOCK_WAIT_TIMEOUT_SECONDS
# doesn't get the contested table any faster, but it bounds that
# collateral lock-holding by aborting the whole attempt (releasing
# everything acquired so far) instead of waiting indefinitely.
# RETRY_ATTEMPTS/RETRY_DELAY_SECONDS then give it a few chances to catch a
# moment where the blocking transaction has actually closed.
LOCK_WAIT_TIMEOUT_SECONDS="${LOCK_WAIT_TIMEOUT_SECONDS:-30}"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-60}"

INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin}"
LOG_FILE="${LOG_FILE:-/var/log/butler_pg_backup.log}"
CRON_FILE="/etc/cron.d/butler-pg-backup"
LOGROTATE_FILE="/etc/logrotate.d/butler-pg-backup"

# Unprivileged local account a secondary machine SSHes into (pubkey auth
# only) to pull BACKUP_DIR -- see "Backup-pull SSH access" below. Kept
# separate from any human/admin account so its authorized_keys can be
# fully managed (regenerated) by this script without touching anyone else's.
PULL_USER="${PULL_USER:-butler-backup-pull}"

# File listing the SSH public keys (one per line, "authorized_keys"
# format) allowed to log in as PULL_USER to pull backups. Can also be
# given as $1 on the command line, which takes precedence over this
# default/env var -- same pattern as DB_LIST_FILE in
# setup_butler_postgres.sh.
PULL_KEYS_FILE="${1:-${PULL_KEYS_FILE:-pull_authorized_keys.conf}}"
SUDOERS_FILE="/etc/sudoers.d/butler-backup-pull"

# Directory this script lives in, so we can install its sibling worker
# script (same pattern as setup_butler_postgres.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo -e "\n>>> $*\n"; }

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must be run as root (use sudo)." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 0. Pre-flight checks
# ---------------------------------------------------------------------------

require_root

if ! systemctl is-active --quiet postgresql; then
    echo "ERROR: PostgreSQL is not running. Run setup_butler_postgres.sh first." >&2
    exit 1
fi

if ! mountpoint -q "${DATA_MOUNT}"; then
    echo "ERROR: ${DATA_MOUNT} is not a mountpoint." >&2
    echo "BACKUP_DIR (${BACKUP_DIR}) must live on the persistent data volume," >&2
    echo "not the ephemeral OS disk -- refusing to proceed until it is mounted." >&2
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/butler_pg_backup.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/butler_pg_backup.sh not found next to this script." >&2
    exit 1
fi

if [[ ! -f "${PULL_KEYS_FILE}" ]]; then
    echo "ERROR: pull-keys file '${PULL_KEYS_FILE}' not found." >&2
    echo "Create it (one SSH public key per line, 'authorized_keys' format;" >&2
    echo "see examples/butler_pull_keys.conf.example), or pass its path as" >&2
    echo "the first argument / PULL_KEYS_FILE env var." >&2
    exit 1
fi

# This script runs 'chown -R'/'chmod' against BACKUP_DIR below, and the
# worker script (butler_pg_backup.sh) later runs 'rm -f'/'find ... -delete'
# against it. BACKUP_DIR is env-overridable, so guard against it resolving
# to the data volume root (where PGDATA also lives) or "/" -- e.g. a
# mistyped 'BACKUP_DIR=/mnt/pgdata sudo -E ./setup_butler_backups.sh' should
# fail loudly here, not recurse ownership changes over the whole volume.
# readlink -m (not -f) resolves lexically even when multiple trailing
# components don't exist yet (-f only tolerates the last one) -- BACKUP_DIR
# is normally created by this script, not pre-existing, and on a first run
# neither its parent ("backups") nor itself exist yet.
RESOLVED_BACKUP_DIR="$(readlink -m "${BACKUP_DIR}")"
RESOLVED_DATA_MOUNT="$(readlink -m "${DATA_MOUNT}")"
if [[ "${RESOLVED_BACKUP_DIR}" == "/" || "${RESOLVED_BACKUP_DIR}" == "${RESOLVED_DATA_MOUNT}" \
      || "${RESOLVED_BACKUP_DIR}" != "${RESOLVED_DATA_MOUNT}"/* ]]; then
    echo "ERROR: BACKUP_DIR (${BACKUP_DIR} -> ${RESOLVED_BACKUP_DIR}) must be a" >&2
    echo "path strictly inside DATA_MOUNT (${DATA_MOUNT} -> ${RESOLVED_DATA_MOUNT})," >&2
    echo "not the volume root itself or somewhere else entirely -- this script" >&2
    echo "recursively chowns/chmods it, and the worker script later runs" >&2
    echo "rm/find-delete against it." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Ensure cron is installed
# ---------------------------------------------------------------------------

if ! command -v crontab >/dev/null 2>&1; then
    log "Installing cron"
    apt update
    apt install -y cron
fi
systemctl enable --now cron

# ---------------------------------------------------------------------------
# 2. Backup directory
# ---------------------------------------------------------------------------

log "Creating backup directory ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
chown -R postgres:postgres "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

# Marker file the worker script (butler_pg_backup.sh) requires to be
# present before it will run rm/find-delete against BACKUP_DIR -- see the
# BACKUP_DIR validation above and the check in butler_pg_backup.sh for why.
touch "${BACKUP_DIR}/.butler_pg_backup_dir"
chown postgres:postgres "${BACKUP_DIR}/.butler_pg_backup_dir"
chmod 600 "${BACKUP_DIR}/.butler_pg_backup_dir"

# ---------------------------------------------------------------------------
# 3. Install the worker script
# ---------------------------------------------------------------------------

log "Installing worker script into ${INSTALL_BIN}"
install -m 0755 "${SCRIPT_DIR}/butler_pg_backup.sh" "${INSTALL_BIN}/butler_pg_backup.sh"

# ---------------------------------------------------------------------------
# 4. Log file + logrotate
# ---------------------------------------------------------------------------

log "Preparing log file ${LOG_FILE}"
touch "${LOG_FILE}"
chown postgres:postgres "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

log "Writing logrotate rule ${LOGROTATE_FILE}"
cat > "${LOGROTATE_FILE}" <<EOF
${LOG_FILE} {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    su postgres postgres
}
EOF

# ---------------------------------------------------------------------------
# 5. Backup-pull SSH access
# ---------------------------------------------------------------------------
# Prepares this (SOURCE) instance to be pulled from by a secondary machine
# running utilities/pull_butler_backups.sh: a dedicated PULL_USER account,
# reachable only via one of the pubkeys in PULL_KEYS_FILE, each restricted
# to running exactly "rsync --server ..." (the command an rsync client
# sends over SSH) under NOPASSWD sudo as postgres -- the only access
# BACKUP_DIR (owned postgres:postgres, mode 700) actually needs to be
# pulled, and nothing else a stolen key could be used for.

log "Creating pull user '${PULL_USER}' (if missing)"
if ! id -u "${PULL_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --shell /bin/bash "${PULL_USER}"
fi
PULL_USER_HOME="$(getent passwd "${PULL_USER}" | cut -d: -f6)"

log "Installing authorized_keys for '${PULL_USER}' from ${PULL_KEYS_FILE}"
PULL_SSH_DIR="${PULL_USER_HOME}/.ssh"
mkdir -p "${PULL_SSH_DIR}"
chmod 700 "${PULL_SSH_DIR}"

# Regenerated in full on every run (same pattern as CRON_FILE below), so
# re-running after editing PULL_KEYS_FILE converges instead of leaving
# stale/removed keys still authorized.
AUTHORIZED_KEYS_FILE="${PULL_SSH_DIR}/authorized_keys"
{
    echo "# Managed by setup_butler_backups.sh from ${PULL_KEYS_FILE} -- do not"
    echo "# edit by hand, this file is regenerated (overwritten) on every re-run."
} > "${AUTHORIZED_KEYS_FILE}"

# SSH_ORIGINAL_COMMAND is whatever pull_butler_backups.sh's rsync client
# sends ("rsync --server ..."); passed through verbatim under sudo only
# when it actually starts with that, so a key can't be used to run
# anything else on this box. Built via plain bash quoting (not printf's
# format string, which would eat the backslash-escaped inner double
# quotes) so the literal backslashes survive into the file.
FORCED_COMMAND_OPT='command="case \"$SSH_ORIGINAL_COMMAND\" in rsync\ --server*) exec sudo -n -u postgres $SSH_ORIGINAL_COMMAND;; *) echo '"'"'command not allowed'"'"' >&2; exit 1;; esac",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding'

# Only lines that look like an actual public key (type field + base64
# blob) are used -- guards against a stray comment/typo in PULL_KEYS_FILE
# silently becoming an unrestricted authorized_keys line.
KEY_COUNT=0
while IFS= read -r key_line || [[ -n "${key_line}" ]]; do
    key_line="${key_line%$'\r'}"
    [[ -z "${key_line}" || "${key_line}" == \#* ]] && continue
    if [[ ! "${key_line}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+)\  ]]; then
        echo "WARNING: skipping line in ${PULL_KEYS_FILE} that doesn't look like" >&2
        echo "  a public key: ${key_line}" >&2
        continue
    fi
    printf '%s %s\n' "${FORCED_COMMAND_OPT}" "${key_line}" >> "${AUTHORIZED_KEYS_FILE}"
    KEY_COUNT=$((KEY_COUNT + 1))
done < "${PULL_KEYS_FILE}"

if [[ "${KEY_COUNT}" -eq 0 ]]; then
    echo "ERROR: no valid public keys found in ${PULL_KEYS_FILE}." >&2
    exit 1
fi

chown -R "${PULL_USER}:${PULL_USER}" "${PULL_SSH_DIR}"
chmod 600 "${AUTHORIZED_KEYS_FILE}"

log "Writing sudoers rule ${SUDOERS_FILE}"
SUDOERS_TMP="$(mktemp)"
cat > "${SUDOERS_TMP}" <<EOF
# Managed by setup_butler_backups.sh -- do not edit by hand.
# Lets ${PULL_USER} run rsync as postgres without a password, scoped to the
# rsync binary only (the authorized_keys forced command above additionally
# restricts it to "rsync --server ..." invocations).
${PULL_USER} ALL=(postgres) NOPASSWD: /usr/bin/rsync
EOF
visudo -cf "${SUDOERS_TMP}" >/dev/null
install -m 0440 -o root -g root "${SUDOERS_TMP}" "${SUDOERS_FILE}"
rm -f "${SUDOERS_TMP}"

# ---------------------------------------------------------------------------
# 6. Cron schedule
# ---------------------------------------------------------------------------

log "Writing cron.d entry ${CRON_FILE} (schedule: '${CRON_SCHEDULE}', as postgres)"
# Regenerated in full on every run (like the pg_hba.conf managed block in
# setup_butler_postgres.sh), so re-running with a changed RETENTION_DAYS or
# CRON_SCHEDULE always converges instead of leaving a stale entry behind.
cat > "${CRON_FILE}" <<EOF
# Managed by setup_butler_backups.sh -- do not edit by hand, this file is
# regenerated (overwritten) on every re-run.
#
# Daily logical backup of every database on this PostgreSQL instance.
# Runs as 'postgres' (local Unix-socket peer auth, no password needed) so
# no credentials are stored here. Retention (${RETENTION_DAYS} days) is
# enforced by the worker script itself. LOCK_WAIT_TIMEOUT_SECONDS/
# RETRY_ATTEMPTS/RETRY_DELAY_SECONDS handle DDL possibly running
# concurrently (batch pipeline jobs are expected overnight too).
BACKUP_DIR=${BACKUP_DIR}
RETENTION_DAYS=${RETENTION_DAYS}
LOCK_WAIT_TIMEOUT_SECONDS=${LOCK_WAIT_TIMEOUT_SECONDS}
RETRY_ATTEMPTS=${RETRY_ATTEMPTS}
RETRY_DELAY_SECONDS=${RETRY_DELAY_SECONDS}
${CRON_SCHEDULE} postgres ${INSTALL_BIN}/butler_pg_backup.sh >> ${LOG_FILE} 2>&1
EOF
chmod 644 "${CRON_FILE}"

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------

log "Setup complete."
cat <<SUMMARY
Backups will run daily on schedule '${CRON_SCHEDULE}' (system timezone),
as the 'postgres' user, writing to:
  ${BACKUP_DIR}

Each run:
  - pg_dump -Fc (custom format, restorable with pg_restore) for every
    database on the instance (auto-discovered, so newly added Butler
    databases are picked up without editing anything here)
  - pg_dumpall --globals-only for roles/grants (cluster-wide, not part of
    any per-database dump)
  - prunes dump files older than ${RETENTION_DAYS} days

Both dump commands use --lock-wait-timeout=${LOCK_WAIT_TIMEOUT_SECONDS}s and
retry up to ${RETRY_ATTEMPTS} times (${RETRY_DELAY_SECONDS}s apart) -- batch
pipeline jobs are expected to run overnight too, and Butler issues DDL
(CREATE TABLE) whenever a run registers a new DatasetType, which can happen
at any point during processing, not just at repo setup. pg_dump's ACCESS
SHARE lock never blocks concurrent reads/writes, but it does conflict with
that DDL; the timeout+retry makes a dump back off and try again instead of
queuing indefinitely and stalling a table for everyone behind it.

Log: ${LOG_FILE} (rotated weekly, 8 kept, via ${LOGROTATE_FILE})

To run a backup right now (e.g. to verify it works before waiting for the
first scheduled run):
  sudo BACKUP_DIR=${BACKUP_DIR} RETENTION_DAYS=${RETENTION_DAYS} \\
      LOCK_WAIT_TIMEOUT_SECONDS=${LOCK_WAIT_TIMEOUT_SECONDS} \\
      RETRY_ATTEMPTS=${RETRY_ATTEMPTS} RETRY_DELAY_SECONDS=${RETRY_DELAY_SECONDS} \\
      ${INSTALL_BIN}/butler_pg_backup.sh

Off-instance pulling: '${PULL_USER}' now accepts SSH pubkey logins from the
${KEY_COUNT} key(s) in ${PULL_KEYS_FILE}, each restricted to running
"rsync --server ..." via NOPASSWD sudo as postgres -- enough to read
${BACKUP_DIR} (owned postgres:postgres, mode 700) and nothing else. On the
SECONDARY machine, run/schedule utilities/pull_butler_backups.sh with:
  SOURCE_HOST=${PULL_USER}@<this-host> SOURCE_BACKUP_DIR=${BACKUP_DIR} \\
      /path/to/pull_butler_backups.sh
To add/remove keys later, edit ${PULL_KEYS_FILE} and re-run this script --
authorized_keys is regenerated in full each time.

STILL TO DO (not handled by this script):
  1. Test a restore at least once, not just that dump files get created:
       pg_restore -d <scratch_db> ${BACKUP_DIR}/<db>/<db>_<timestamp>.dump
     When restoring globals.sql + a database dump together, also check
     ownership/grants on the restored objects, not just that the restore
     completed -- see the role-skew note in butler_pg_backup.sh (globals
     and each database are dumped sequentially, not atomically, so a role
     created/renamed in between can be referenced by a database's dump
     without being in globals.sql).
  2. Consider a monitoring/alert on backup failures (this script only logs
     to ${LOG_FILE} and exits non-zero on failure -- nothing currently
     reads that exit code or ships an alert).
SUMMARY
