#!/usr/bin/env bash
#
# restore_and_verify.sh
#
# Runs INSIDE the postgres_backup_test container - see ../run_backup_test.sh
# for the host-side invocation.
#
# Restores one backup run from
# ../../../postgres-setup/scripts/butler_pg_backup.sh into a throwaway,
# unix-socket-only PostgreSQL instance and prints a summary of what
# landed, without ever touching the live database.
#
# PGDATA/socket live under mktemp -d on the container's writable overlay,
# sized by run_backup_test.sh. Restore logs go to PG_TEST_LOG_DIR when set
# (LOG_DIR), else next to PGDATA - only the former survives the container
# exiting. `apptainer exec` tears PostgreSQL down on exit; `apptainer
# shell` leaves it running at $SOCKET_DIR until you exit.
#
# USAGE (normally invoked via run_backup_test.sh):
#   restore_and_verify.sh <backup_dir> [database ...]
#
# <backup_dir> (bind-mounted read-only at /backups) contains:
#   globals_<timestamp>.sql
#   <db>/<db>_<timestamp>.dump
#
# With no database names given, every database with a dump matching the
# chosen run is restored. BACKUP_TIMESTAMP picks a specific run (matching
# butler_pg_backup.sh's TIMESTAMP); defaults to the newest globals_*.sql.
#
# LIVE_HOST (subset comparison against the live database): NOT IMPLEMENTED,
# see ../README.md.
#
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*"; }

BACKUP_DIR="${1:?Usage: restore_and_verify.sh <backup_dir> [database ...]}"
shift
REQUESTED_DATABASES=("$@")

# Avoid writing a history file into the host's real $HOME (bind-mounted by
# default).
export PSQL_HISTORY=/dev/null

if [[ -n "${LIVE_HOST:-}" ]]; then
    echo "ERROR: LIVE_HOST is set, but comparing against the live database is" >&2
    echo "not implemented yet (see README.md) - refusing to silently ignore it." >&2
    exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
    echo "ERROR: refusing to run as root - PostgreSQL itself refuses to" >&2
    echo "initdb/start as root. Invoke apptainer as your normal user (no" >&2
    echo "sudo), not as root." >&2
    exit 1
fi

if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "ERROR: backup dir '${BACKUP_DIR}' not found (should be bind-mounted" >&2
    echo "by run_backup_test.sh - check the host path you passed it)." >&2
    exit 1
fi

# Match globals + per-db dumps by shared timestamp, not independently-newest
# - avoids pairing files from two different runs (see butler_pg_backup.sh's
# FAILURES handling).
if [[ -n "${BACKUP_TIMESTAMP:-}" ]]; then
    TIMESTAMP="${BACKUP_TIMESTAMP}"
else
    TIMESTAMP="$(find "${BACKUP_DIR}" -maxdepth 1 -name 'globals_*.sql' -printf '%f\n' \
        | sed -E 's/^globals_(.*)\.sql$/\1/' | sort | tail -1)"
fi

if [[ -z "${TIMESTAMP}" ]]; then
    echo "ERROR: no globals_*.sql found under ${BACKUP_DIR}, and/or" >&2
    echo "BACKUP_TIMESTAMP did not match one - nothing to restore." >&2
    exit 1
fi

GLOBALS_FILE="${BACKUP_DIR}/globals_${TIMESTAMP}.sql"
if [[ ! -f "${GLOBALS_FILE}" ]]; then
    echo "ERROR: ${GLOBALS_FILE} not found - BACKUP_TIMESTAMP=${TIMESTAMP} does" >&2
    echo "not match an actual backup run under ${BACKUP_DIR}." >&2
    exit 1
fi

log "Testing backup run ${TIMESTAMP} (globals: ${GLOBALS_FILE})"

DATABASES=()
if [[ "${#REQUESTED_DATABASES[@]}" -gt 0 ]]; then
    DATABASES=("${REQUESTED_DATABASES[@]}")
else
    while IFS= read -r db; do
        DATABASES+=("${db}")
    done < <(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
fi

if [[ "${#DATABASES[@]}" -eq 0 ]]; then
    echo "ERROR: no per-database backup directories found under ${BACKUP_DIR}." >&2
    exit 1
fi

log "Databases to restore: ${DATABASES[*]}"

WORKDIR="$(mktemp -d)"
PGDATA="${WORKDIR}/pgdata"
SOCKET_DIR="${WORKDIR}/socket"
mkdir -p "${SOCKET_DIR}"

# See header comment.
LOGDIR="${PG_TEST_LOG_DIR:-${WORKDIR}}"

log "Initializing throwaway PGDATA at ${PGDATA} (superuser named 'postgres', matching the source cluster)"
# trust is fine here (unix-socket-only, no network); peer auth would
# require the OS user running this script to literally be named 'postgres'.
initdb -D "${PGDATA}" --username=postgres --auth=trust --no-instructions >/dev/null

log "Starting PostgreSQL (unix socket only, no TCP listener - never exposed on the network)"
pg_ctl -D "${PGDATA}" -w -l "${LOGDIR}/postgres.log" \
    -o "-c listen_addresses='' -c unix_socket_directories=${SOCKET_DIR}" start

PSQL_ADMIN=(psql -h "${SOCKET_DIR}" -U postgres -X -q)

# Not ON_ERROR_STOP: CREATE ROLE postgres is expected to fail on this fresh
# cluster (see --username=postgres above) - the same role skew
# butler_pg_backup.sh already documents as acceptable.
log "Restoring globals from ${GLOBALS_FILE}"
"${PSQL_ADMIN[@]}" -d postgres -f "${GLOBALS_FILE}" > "${LOGDIR}/globals_restore.log" 2>&1 || true
log "Globals restore log: ${LOGDIR}/globals_restore.log ($(wc -l < "${LOGDIR}/globals_restore.log") line(s) - some are expected, see comment above)"

OVERALL_STATUS=0

# Row counts are pg_class.reltuples estimates (post-ANALYZE), not
# SELECT COUNT(*) - a real Butler registry can have tables too large for a
# full scan here. Checks every user schema, not just 'public' - Butler's
# Postgres registry backend supports a non-default schema ("namespace"),
# so a public-only check could report a healthy restore as empty.
summarize_database() {
    local db="$1"
    local psql_db=(psql -h "${SOCKET_DIR}" -U postgres -d "${db}" -X -q -t -A)

    "${psql_db[@]}" -c "ANALYZE;" 2>&1 | sed 's/^/    [ANALYZE] /' || true

    local size
    if ! size="$("${psql_db[@]}" -c "SELECT pg_size_pretty(pg_database_size('${db}'));" 2>&1)"; then
        echo "  Size: unknown (query failed: ${size})"
        size=""
    fi

    local extensions
    if ! extensions="$("${psql_db[@]}" -c "SELECT coalesce(string_agg(extname, ', ' ORDER BY extname), '') FROM pg_extension;" 2>&1)"; then
        echo "  Extensions: unknown (query failed: ${extensions})"
        extensions=""
    fi

    echo ""
    echo "  Database: ${db}"
    [[ -n "${size}" ]] && echo "  Size: ${size}"
    [[ -n "${extensions}" ]] && echo "  Extensions: ${extensions:-<none>}"
    echo "  Tables (estimated row counts, from pg_class.reltuples after ANALYZE):"

    local table_rows
    if ! table_rows="$("${psql_db[@]}" -c "
        SELECT n.nspname, c.relname, GREATEST(c.reltuples, 0)::bigint
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        ORDER BY n.nspname, c.relname;
    " 2>&1)"; then
        echo "    <table listing query failed: ${table_rows}>"
        return 1
    fi

    if [[ -z "${table_rows}" ]]; then
        echo "    <no tables found in any non-system schema>"
        return 1
    fi

    while IFS='|' read -r schema_name table_name row_count; do
        printf '    %-20s %-40s ~%s rows\n' "${schema_name}" "${table_name}" "${row_count}"
    done <<< "${table_rows}"

    return 0
}

for db in "${DATABASES[@]}"; do
    DUMP_FILE="${BACKUP_DIR}/${db}/${db}_${TIMESTAMP}.dump"
    if [[ ! -f "${DUMP_FILE}" ]]; then
        log "WARNING: skipping '${db}' - no dump for run ${TIMESTAMP} at ${DUMP_FILE}"
        OVERALL_STATUS=1
        continue
    fi

    log "Restoring '${db}' from ${DUMP_FILE}"
    # initdb already creates a database named 'postgres' - butler_pg_backup.sh
    # backs that one up too (it holds the monitoring schema), so restoring
    # it hits an "already exists" here rather than needing CREATE DATABASE.
    CREATEDB_LOG="${LOGDIR}/${db}_createdb.log"
    if ! "${PSQL_ADMIN[@]}" -d postgres -c "CREATE DATABASE \"${db}\";" >/dev/null 2>"${CREATEDB_LOG}"; then
        if ! grep -q "already exists" "${CREATEDB_LOG}"; then
            log "FAILED: could not create database '${db}':"
            sed 's/^/    /' "${CREATEDB_LOG}"
            OVERALL_STATUS=1
            continue
        fi
        log "'${db}' already exists (e.g. initdb's own default 'postgres') - restoring into it as-is"
    fi

    RESTORE_LOG="${LOGDIR}/${db}_restore.log"
    if pg_restore -h "${SOCKET_DIR}" -U postgres -d "${db}" "${DUMP_FILE}" > "${RESTORE_LOG}" 2>&1; then
        log "pg_restore reported no errors for '${db}'"
    else
        # Not fatal by itself: pg_restore exits non-zero on any error,
        # including the benign role/ownership skew butler_pg_backup.sh
        # already documents as acceptable. Judged from the data summary
        # below, not this exit status.
        log "WARNING: pg_restore reported error(s) for '${db}':"
        sed 's/^/    /' "${RESTORE_LOG}"
    fi

    if ! summarize_database "${db}"; then
        log "FAILED: '${db}' has no usable data after restore."
        OVERALL_STATUS=1
    fi
done

echo ""
if [[ "${OVERALL_STATUS}" -eq 0 ]]; then
    log "=== Backup test finished: all requested databases restored with data present ==="
else
    log "=== Backup test finished with problems - see WARNING/FAILED lines above ==="
fi

log "PostgreSQL is still running (socket: ${SOCKET_DIR}) - if you're in an" \
    "'apptainer shell' session, e.g.: psql -h ${SOCKET_DIR} -U postgres -d <db>." \
    "It stops (and everything above disappears) when this session's" \
    "container exits."

exit "${OVERALL_STATUS}"
