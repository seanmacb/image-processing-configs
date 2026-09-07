#!/usr/bin/env bash
#
# test_butler_postgres.sh
#
# Quick reachability test for the Butler Postgres databases set up by
# setup_butler_postgres.sh: checks the port is open, then connects as each
# role from a database list file and runs a couple of sanity queries
# (current_database()/current_user, and that btree_gist is enabled).
#
# Run this from a UZH-internal client machine (e.g. your workstation on the
# UZH network/VPN, or the ScienceCluster) -- see README.md "Testing the
# Connection".
#
# USAGE:
#   ./test_butler_postgres.sh [path/to/databases.conf] [host]
#
# Both arguments are optional:
#   - databases.conf defaults to DB_LIST_FILE env var, or "databases.conf"
#   - host defaults to HOST env var, or 172.23.211.243
#
# Uses the same "database_name:role_name:password" file format as
# setup_butler_postgres.sh (see examples/butler_databases.conf.example).
# If a password is left empty in the file, you will be prompted for it.
#
# Requires the postgresql-client package (`pg_isready`, `psql`) on the
# machine running this script:
#   sudo apt install postgresql-client
#
set -euo pipefail

DB_LIST_FILE="${1:-${DB_LIST_FILE:-databases.conf}}"
HOST="${2:-${HOST:-172.23.211.243}}"
PORT="${PORT:-5432}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo -e "\n>>> $*\n"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: '$1' not found. Install the postgresql-client package:" >&2
        echo "  sudo apt install postgresql-client" >&2
        exit 1
    fi
}

prompt_password() {
    # $1 = variable name to set, $2 = label for prompt
    local __varname="$1"
    local __label="$2"
    local __value="${!__varname:-}"

    if [[ -z "${__value}" ]]; then
        read -r -s -p "Enter password for ${__label}: " __value
        echo
        if [[ -z "${__value}" ]]; then
            echo "Password cannot be empty." >&2
            exit 1
        fi
    fi
    printf -v "${__varname}" '%s' "${__value}"
}

# Populates the parallel arrays DB_NAMES / DB_USERS / DB_PASSWORDS from
# DB_LIST_FILE, using the exact same file format/validation as
# setup_butler_postgres.sh, so any file that was valid for setup is valid
# here too.
DB_NAMES=()
DB_USERS=()
DB_PASSWORDS=()

read_db_list() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        echo "ERROR: database list file '${file}' not found." >&2
        echo "Pass its path as the first argument, or set DB_LIST_FILE," >&2
        echo "e.g. see examples/butler_databases.conf.example." >&2
        exit 1
    fi

    local -r name_re='^[A-Za-z_][A-Za-z0-9_]*$'

    local line_num=0
    local line db_name role_name role_password
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_num=$((line_num + 1))

        line="${line%$'\r'}"
        line="$(echo -n "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        [[ -z "${line}" || "${line}" == \#* ]] && continue

        IFS=':' read -r db_name role_name role_password <<< "${line}"

        db_name="$(echo -n "${db_name}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        role_name="$(echo -n "${role_name}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        if [[ -z "${db_name}" || -z "${role_name}" ]]; then
            echo "ERROR: ${file}:${line_num}: expected 'database_name:role_name:password'," \
                 "got '${line}'." >&2
            exit 1
        fi

        if [[ ! "${db_name}" =~ ${name_re} || ! "${role_name}" =~ ${name_re} ]]; then
            echo "ERROR: ${file}:${line_num}: invalid database/role name in '${line}'." >&2
            exit 1
        fi

        if [[ -z "${role_password}" ]]; then
            prompt_password role_password "${role_name} (${db_name}, from ${file}:${line_num})"
        fi

        DB_NAMES+=("${db_name}")
        DB_USERS+=("${role_name}")
        DB_PASSWORDS+=("${role_password}")
    done < "${file}"

    if [[ "${#DB_NAMES[@]}" -eq 0 ]]; then
        echo "ERROR: ${file} contains no database entries." >&2
        exit 1
    fi
}

# Connects as one role/database and checks it can query and that
# btree_gist is enabled. Never lets set -e abort the whole run on a single
# failed database -- the caller inspects the return value.
test_one_db() {
    local db_name="$1"
    local role_name="$2"
    local role_password="$3"

    local whoami_out
    if ! whoami_out="$(PGPASSWORD="${role_password}" PGCONNECT_TIMEOUT="${CONNECT_TIMEOUT}" \
        psql -h "${HOST}" -p "${PORT}" -U "${role_name}" -d "${db_name}" -tAc \
        "SELECT current_database() || ' / ' || current_user;" 2>&1)"
    then
        echo "  FAIL  ${db_name} (user: ${role_name}) -- could not connect/query:"
        echo "${whoami_out}" | sed 's/^/        /'
        return 1
    fi

    local ext_out
    if ! ext_out="$(PGPASSWORD="${role_password}" PGCONNECT_TIMEOUT="${CONNECT_TIMEOUT}" \
        psql -h "${HOST}" -p "${PORT}" -U "${role_name}" -d "${db_name}" -tAc \
        "SELECT 1 FROM pg_extension WHERE extname = 'btree_gist';" 2>&1)"
    then
        echo "  FAIL  ${db_name} (user: ${role_name}) -- connected (${whoami_out})" \
             "but could not check extensions:"
        echo "${ext_out}" | sed 's/^/        /'
        return 1
    fi

    if [[ "${ext_out}" != "1" ]]; then
        echo "  WARN  ${db_name} (user: ${role_name}) -- connected (${whoami_out})," \
             "but btree_gist is NOT enabled"
        return 1
    fi

    echo "  OK    ${db_name} (user: ${role_name}) -- ${whoami_out}, btree_gist enabled"
    return 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

require_cmd pg_isready
require_cmd psql

log "Reading database list from ${DB_LIST_FILE}"
read_db_list "${DB_LIST_FILE}"
log "Found ${#DB_NAMES[@]} database(s) to test: ${DB_NAMES[*]}"

log "Checking port ${PORT} on ${HOST} is reachable"
if pg_isready -h "${HOST}" -p "${PORT}" -t "${CONNECT_TIMEOUT}"; then
    echo "Network/port OK."
else
    echo "WARNING: pg_isready could not reach ${HOST}:${PORT}." >&2
    echo "This is almost always the ScienceCloud Security Group or network" >&2
    echo "(not Postgres itself) -- see README.md. Continuing with per-database" >&2
    echo "connection attempts anyway, but they will likely also fail." >&2
fi

log "Testing each database"
FAIL_COUNT=0
for i in "${!DB_NAMES[@]}"; do
    if ! test_one_db "${DB_NAMES[$i]}" "${DB_USERS[$i]}" "${DB_PASSWORDS[$i]}"; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo
if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    echo "All ${#DB_NAMES[@]} database(s) reachable and OK."
    exit 0
else
    echo "${FAIL_COUNT} of ${#DB_NAMES[@]} database(s) FAILED. See above for details." >&2
    exit 1
fi
