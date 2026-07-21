#!/usr/bin/env bash
#
# butler_pg_backup.sh
#
# Worker script: takes a logical backup of every database on this
# instance's PostgreSQL server (installed and scheduled by
# setup_butler_backups.sh -- not meant to be run standalone on a box that
# hasn't been through that setup).
#
# WHAT IT DOES
#   - pg_dump -Fc (custom format, compressed, restorable with pg_restore)
#     of every non-template database, discovered from pg_database rather
#     than a hardcoded/config list -- so a newly added Butler database is
#     picked up automatically, without editing this script.
#   - pg_dumpall --globals-only for roles/grants, which are cluster-wide
#     and NOT included in any per-database dump.
#   - Prunes dump files older than RETENTION_DAYS from BACKUP_DIR.
#
# This produces LOCAL, on-volume backups only. Getting a copy off this
# instance is deliberately NOT done here -- see setup_butler_backups.sh.
#
# RUNNING WHILE THE DATABASE IS ACTIVE:
#   pg_dump takes only an ACCESS SHARE lock per table, which conflicts with
#   NOTHING except ACCESS EXCLUSIVE. So it never blocks (and is never
#   blocked by) ordinary SELECT/INSERT/UPDATE/DELETE or plain autovacuum --
#   this whole concern is scoped to DDL-class operations only (CREATE
#   TABLE/ALTER TABLE/TRUNCATE/DROP, non-concurrent CREATE INDEX/REINDEX,
#   VACUUM FULL), never to normal pipeline read/write traffic.
#
#   The DDL case that matters here: Butler issues CREATE TABLE when a batch
#   pipeline run registers a new DatasetType it hasn't produced before --
#   not just a one-time setup event, this can happen at any point during
#   active processing, and that lock is held for the DDL's *enclosing
#   transaction*, not just the CREATE TABLE statement itself.
#
#   Plain (non-parallel) pg_dump locks ALL tables it's going to dump up
#   front, in one pass, before copying any table's data. If that pass gets
#   stuck waiting on one table (because a DDL transaction holds ACCESS
#   EXCLUSIVE there), pg_dump keeps holding the ACCESS SHARE locks it
#   already acquired on every OTHER table from earlier in that same pass,
#   for as long as it's stuck -- so a wedged pg_dump can block DDL on
#   tables that have nothing to do with the original conflict. Without a
#   bound, that collateral footprint can persist indefinitely (as long as
#   the blocking transaction stays open).
#
#   --lock-wait-timeout below (implemented via statement_timeout, per
#   pg_dump's own source) doesn't get the contested table any faster -- if
#   the blocking transaction is still open on retry, the retry hits the
#   same wall -- but it bounds that collateral footprint: a timeout aborts
#   the whole attempt, which releases every lock it had acquired so far,
#   instead of holding an ever-growing set of tables hostage. RETRY_ATTEMPTS/
#   RETRY_DELAY_SECONDS then give it a few chances to catch a moment where
#   the DDL's transaction has actually closed.
#
# USAGE:
#   sudo -u postgres /usr/local/bin/butler_pg_backup.sh
#   (or run as root -- it re-execs itself as postgres via sudo, so it can
#   also be invoked directly from a root cron job)
#
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/mnt/pgdata/backups/postgresql}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

# Seconds pg_dump/pg_dumpall will wait to acquire each table lock before
# aborting that attempt, rather than waiting indefinitely and holding
# already-acquired locks on unrelated tables the whole time (see "RUNNING
# WHILE THE DATABASE IS ACTIVE" above).
LOCK_WAIT_TIMEOUT_SECONDS="${LOCK_WAIT_TIMEOUT_SECONDS:-30}"

# How many times to retry a dump that fails (for any reason, most plausibly
# the lock-wait timeout above), and how long to wait between attempts.
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-60}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*"; }

# Runs "$@" up to RETRY_ATTEMPTS times, sleeping RETRY_DELAY_SECONDS between
# attempts, succeeding as soon as one attempt succeeds.
run_with_retry() {
    local attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [[ "${attempt}" -ge "${RETRY_ATTEMPTS}" ]]; then
            return 1
        fi
        log "Attempt ${attempt}/${RETRY_ATTEMPTS} failed -- retrying in ${RETRY_DELAY_SECONDS}s"
        sleep "${RETRY_DELAY_SECONDS}"
        attempt=$((attempt + 1))
    done
}

# Local Unix-socket auth as the postgres superuser needs no password, but
# does need to actually BE that OS user (peer auth) -- so if invoked as
# root (e.g. from a root cron job), re-exec as postgres rather than fail.
if [[ "${EUID}" -eq 0 ]]; then
    SCRIPT_PATH="$(readlink -f "$0")"
    exec sudo -u postgres --preserve-env=BACKUP_DIR,RETENTION_DAYS,LOCK_WAIT_TIMEOUT_SECONDS,RETRY_ATTEMPTS,RETRY_DELAY_SECONDS \
        "${SCRIPT_PATH}" "$@"
fi

CURRENT_USER="$(id -un)"
if [[ "${CURRENT_USER}" != "postgres" ]]; then
    echo "ERROR: this script must run as the 'postgres' user (got '${CURRENT_USER}')." >&2
    echo "Run it as root (it re-execs itself as postgres), or:" >&2
    echo "  sudo -u postgres $0" >&2
    exit 1
fi

if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "ERROR: backup directory ${BACKUP_DIR} does not exist." >&2
    echo "Run setup_butler_backups.sh first to create it." >&2
    exit 1
fi

# This script runs 'rm -f' and 'find ... -delete' against BACKUP_DIR below.
# BACKUP_DIR is an env-overridable variable (e.g. a manual invocation with a
# mistyped 'BACKUP_DIR=/mnt/pgdata ...' would point it at the data volume
# root, where PGDATA also lives). Requiring a marker file that only
# setup_butler_backups.sh creates means a wrong/mistyped BACKUP_DIR fails
# closed here instead of running destructive operations against whatever
# directory it happens to resolve to.
BACKUP_DIR_MARKER=".butler_pg_backup_dir"
if [[ ! -f "${BACKUP_DIR}/${BACKUP_DIR_MARKER}" ]]; then
    echo "ERROR: ${BACKUP_DIR} is missing its ${BACKUP_DIR_MARKER} marker file." >&2
    echo "Refusing to run rm/find-delete against a directory that" >&2
    echo "setup_butler_backups.sh did not create -- if BACKUP_DIR was" >&2
    echo "overridden, double-check it points at the actual backup directory" >&2
    echo "and not e.g. the data volume root or PGDATA. Run" >&2
    echo "setup_butler_backups.sh against the intended BACKUP_DIR first (it" >&2
    echo "creates this marker)." >&2
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
FAILURES=0

log "=== Backup run starting (timestamp ${TIMESTAMP}) ==="

# --- Global objects (roles, grants) -----------------------------------------
# Cluster-wide, not part of any per-database dump -- lost without this if a
# restore ever needs to recreate roles from scratch (e.g. onto a fresh
# instance).
GLOBALS_FILE="${BACKUP_DIR}/globals_${TIMESTAMP}.sql"
log "Dumping global objects (roles) to ${GLOBALS_FILE}"
if run_with_retry pg_dumpall --globals-only --lock-wait-timeout="${LOCK_WAIT_TIMEOUT_SECONDS}" -f "${GLOBALS_FILE}"; then
    log "OK: globals dump ($(du -h "${GLOBALS_FILE}" | cut -f1))"
else
    log "FAILED: globals dump (after ${RETRY_ATTEMPTS} attempt(s))"
    rm -f "${GLOBALS_FILE}"
    FAILURES=$((FAILURES + 1))
fi

# NOTE on ordering: globals are dumped once, above, then each database is
# dumped in sequence below -- there's no concurrency issue (nothing runs in
# parallel), but there IS a small window for role skew: if a role is
# created/renamed and then used (GRANT / ALTER ... OWNER TO) in a database
# between the globals dump and that database's dump, the database's dump
# file will reference a role globals_${TIMESTAMP}.sql doesn't know about
# (or knows under its old name). Restoring globals.sql then that database's
# dump won't fail outright -- pg_restore just errors on that one GRANT/OWNER
# statement and continues -- but the restored database can end up with the
# wrong owner or a missing grant on whatever object was affected. Table
# DATA is unaffected either way (each pg_dump is its own consistent MVCC
# snapshot); this only touches ownership/privilege metadata. Low likelihood
# (role changes are rare/administrative) and consistent with this backup's
# already-accepted up-to-24h RPO, so not worth engineering around -- just
# worth checking ownership/grants after any restore, not only that the
# restore completed.

# --- Per-database dumps ------------------------------------------------------
# datistemplate = false excludes template0/template1 but keeps the 'postgres'
# maintenance DB, which also holds the monitoring schema (see
# setup_butler_monitoring.sh) -- worth backing up too, and it costs nothing.
if ! DB_LIST_RAW="$(psql -tAc "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;")"; then
    log "ERROR: failed to list databases via psql"
    exit 1
fi

DATABASES=()
while IFS= read -r db; do
    [[ -n "${db}" ]] && DATABASES+=("${db}")
done <<< "${DB_LIST_RAW}"

if [[ "${#DATABASES[@]}" -eq 0 ]]; then
    log "WARNING: no databases found -- nothing to back up."
fi

# Restrict database names to safe path-component characters before using
# them to build DB_DIR/DUMP_FILE below -- datname comes from pg_database
# (so it requires existing CREATEDB privilege to influence, not literally
# untrusted input), but a name containing e.g. '..' or '/' has no
# legitimate reason to exist here and must not be allowed to steer where
# rm/find -delete later operate.
DB_NAME_RE='^[A-Za-z_][A-Za-z0-9_]*$'

for db in "${DATABASES[@]}"; do
    if [[ ! "${db}" =~ ${DB_NAME_RE} ]]; then
        log "FAILED: skipping database with unexpected name '${db}' (must match ${DB_NAME_RE})"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    DB_DIR="${BACKUP_DIR}/${db}"
    mkdir -p "${DB_DIR}"
    DUMP_FILE="${DB_DIR}/${db}_${TIMESTAMP}.dump"
    log "Dumping database '${db}' to ${DUMP_FILE}"
    if run_with_retry pg_dump -Fc --lock-wait-timeout="${LOCK_WAIT_TIMEOUT_SECONDS}" -d "${db}" -f "${DUMP_FILE}"; then
        log "OK: ${db} ($(du -h "${DUMP_FILE}" | cut -f1))"
    else
        log "FAILED: ${db} (after ${RETRY_ATTEMPTS} attempt(s))"
        rm -f "${DUMP_FILE}"
        FAILURES=$((FAILURES + 1))
    fi
done

# --- Retention ---------------------------------------------------------------
log "Pruning backups older than ${RETENTION_DAYS} days from ${BACKUP_DIR}"
find "${BACKUP_DIR}" -type f \( -name '*.dump' -o -name 'globals_*.sql' \) -mtime "+${RETENTION_DAYS}" -print -delete

if [[ "${FAILURES}" -gt 0 ]]; then
    log "=== Backup run finished with ${FAILURES} failure(s) ==="
    exit 1
fi
log "=== Backup run finished successfully ==="
