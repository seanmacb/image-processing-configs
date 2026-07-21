#!/usr/bin/env bash
#
# setup_butler_postgres.sh
#
# Sets up a Debian instance on UZH ScienceCloud as a PostgreSQL host for an
# arbitrary number of independent LSST Butler registries, each as a separate
# database with its own role, within a single shared Postgres server.
#
# Storage layout assumed:
#   - Root disk: ephemeral, OS only
#   - A separate ScienceCloud Volume attached as a block device (default:
#     /dev/sdb) is used for PGDATA, so the database survives instance
#     rebuild/replacement independently of the VM itself.
#
# This script is idempotent where practical: it checks before formatting,
# before creating roles/databases, and before enabling extensions.
#
# USAGE:
#   sudo ./setup_butler_postgres.sh [path/to/databases.conf]
#
# The databases to create are read from a plain-text file, one entry per
# line, colon-separated:
#
#   database_name:role_name:password
#
# - Blank lines and lines starting with '#' are ignored.
# - The password field may be left empty (database_name:role_name:), in
#   which case you will be prompted for it interactively when the script
#   runs -- this avoids putting the password in the file at all.
# - Defaults to DB_LIST_FILE (see Configuration below) if no path is given
#   on the command line.
#
# See examples/butler_databases.conf.example for a template.
#
# ASSUMPTIONS / THINGS TO VERIFY BEFORE RUNNING:
#   1. The data volume is already attached to this instance via the
#      ScienceCloud Web Interface (Volumes -> Manage Attachments).
#   2. DATA_DEVICE below matches the actual device name (check with
#      `lsblk` after attaching -- it is commonly /dev/sdb on ScienceCloud,
#      but confirm rather than assume).
#   3. This script does NOT configure ScienceCloud Security Groups --
#      that is a separate step in the ScienceCloud Web Interface, and is
#      the actual mechanism restricting this instance to UZH-internal
#      access (no public floating IP). Confirm that is in place; this
#      script assumes it, but cannot verify or configure it.
#   4. This script configures pg_hba.conf to allow connections from
#      ALLOWED_NETWORK (default 0.0.0.0/0 -- see config section below
#      for why, and the tradeoff this implies given point 3 above).
#
set -euo pipefail

# Keep apt fully non-interactive (e.g. needrestart, conffile prompts) so an
# unattended run can't hang waiting for input.
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Configuration -- review and adjust before running
# ---------------------------------------------------------------------------

DATA_DEVICE="${DATA_DEVICE:-/dev/sda}"          # block device for the attached Volume
DATA_MOUNT="${DATA_MOUNT:-/mnt/pgdata}"         # where the volume will be mounted
PG_DATA_SUBDIR="${PG_DATA_SUBDIR:-postgresql/data}"  # PGDATA path under the mount

# File listing the databases/roles/passwords to create -- one entry per
# line, "database_name:role_name:password" (password may be left empty to
# be prompted for interactively). Can also be given as $1 on the command
# line, which takes precedence over this default/env var.
DB_LIST_FILE="${1:-${DB_LIST_FILE:-databases.conf}}"

TIMEZONE="${TIMEZONE:-Europe/Zurich}"

# CIDR range allowed to connect to PostgreSQL over the network, written
# into pg_hba.conf.
#
# Set to 0.0.0.0/0 (no restriction at the Postgres level) because actual
# network reachability is already restricted to UZH-internal traffic by
# the ScienceCloud Security Group / lack of a public floating IP on this
# instance -- not by pg_hba.conf. Traffic that isn't UZH-internal never
# reaches Postgres in the first place, so pg_hba.conf doesn't need to
# duplicate that restriction, and leaving it open here simplifies access
# from any UZH-internal host (e.g. the ScienceCluster, or your own
# workstation when on the UZH network / VPN) for testing.
#
# IMPORTANT: this means the Security Group is now the ONLY thing standing
# between this database and broad UZH-internal access -- if that Security
# Group configuration ever changes (e.g. a public IP is later added, or
# inbound rules are loosened), Postgres would become reachable from
# wherever that change permits, with no second layer of defense here.
# If you want pg_hba.conf to remain a real second layer of defense
# regardless of Security Group changes, set ALLOWED_NETWORK to the actual
# UZH-internal CIDR instead, e.g.:
#   ALLOWED_NETWORK=160.85.0.0/16 ./setup_butler_postgres.sh
ALLOWED_NETWORK="${ALLOWED_NETWORK:-0.0.0.0/0}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo -e "\n>>> $*\n"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must be run as root (use sudo)." >&2
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
# DB_LIST_FILE. Each non-comment, non-blank line must be
# "database_name:role_name:password" -- if password is empty, the user is
# prompted for it interactively (once per line, not just once overall).
DB_NAMES=()
DB_USERS=()
DB_PASSWORDS=()

read_db_list() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        echo "ERROR: database list file '${file}' not found." >&2
        echo "Create it (one 'database_name:role_name:password' entry per line;" >&2
        echo "see examples/butler_databases.conf.example), or pass its path as" >&2
        echo "the first argument / DB_LIST_FILE env var." >&2
        exit 1
    fi

    # Deliberately restrictive: plain lower/upper-case letters, digits, and
    # underscore, not starting with a digit. This is a safe, unquoted
    # Postgres identifier (no need for sql_ident's quoting to prevent it
    # being misparsed) AND safe as a whitespace-delimited pg_hba.conf field
    # (no spaces, '#', quotes, commas, or other characters that would either
    # split into extra fields or start a comment there). Butler DB/role names
    # have no legitimate need for anything outside this set.
    local -r name_re='^[A-Za-z_][A-Za-z0-9_]*$'

    local line_num=0
    local line db_name role_name role_password
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_num=$((line_num + 1))

        # Strip trailing CR (in case the file has CRLF line endings) and
        # surrounding whitespace.
        line="${line%$'\r'}"
        line="$(echo -n "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        [[ -z "${line}" || "${line}" == \#* ]] && continue

        IFS=':' read -r db_name role_name role_password <<< "${line}"

        # Trim whitespace around the name fields individually (e.g. a file
        # written as "decam_butler : decam_user : pass") -- not done for
        # role_password, so an intentionally-crafted password isn't altered.
        db_name="$(echo -n "${db_name}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        role_name="$(echo -n "${role_name}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        if [[ -z "${db_name}" || -z "${role_name}" ]]; then
            echo "ERROR: ${file}:${line_num}: expected 'database_name:role_name:password'," \
                 "got '${line}'." >&2
            exit 1
        fi

        if [[ ! "${db_name}" =~ ${name_re} ]]; then
            echo "ERROR: ${file}:${line_num}: invalid database name '${db_name}' --" \
                 "must match ${name_re} (letters, digits, underscore, not starting" \
                 "with a digit)." >&2
            exit 1
        fi
        if [[ ! "${role_name}" =~ ${name_re} ]]; then
            echo "ERROR: ${file}:${line_num}: invalid role name '${role_name}' --" \
                 "must match ${name_re} (letters, digits, underscore, not starting" \
                 "with a digit)." >&2
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

# ---------------------------------------------------------------------------
# 0. Pre-flight checks
# ---------------------------------------------------------------------------

require_root

log "Checking for attached data volume at ${DATA_DEVICE}"
if [[ ! -b "${DATA_DEVICE}" ]]; then
    echo "ERROR: ${DATA_DEVICE} not found." >&2
    echo "Attach the ScienceCloud Volume to this instance first, then" >&2
    echo "run 'lsblk' to confirm the correct device name, and set" >&2
    echo "DATA_DEVICE accordingly if it differs from ${DATA_DEVICE}." >&2
    exit 1
fi

log "Reading database list from ${DB_LIST_FILE}"
read_db_list "${DB_LIST_FILE}"
log "Found ${#DB_NAMES[@]} database(s) to set up: ${DB_NAMES[*]}"

# ---------------------------------------------------------------------------
# 1. System update and timezone
# ---------------------------------------------------------------------------

log "Updating package lists and upgrading existing packages"
apt update
apt upgrade -y

log "Setting timezone to ${TIMEZONE}"
timedatectl set-timezone "${TIMEZONE}" || true

# ---------------------------------------------------------------------------
# 2. Install PostgreSQL
# ---------------------------------------------------------------------------

log "Installing PostgreSQL and contrib package (needed for btree_gist)"
# rsync is included here because it is NOT present on a minimal Debian image
# and is required later (step 5) to relocate PGDATA onto the data volume.
# postgresql-contrib provides btree_gist; postgresql pulls in postgresql-common
# (which provides pg_lsclusters / pg_ctlcluster, used just below).
apt install -y postgresql postgresql-contrib rsync

PG_VERSION="$(pg_lsclusters -h | awk 'NR==1 {print $1; exit}')"
if [[ -z "${PG_VERSION}" ]]; then
    echo "ERROR: could not determine installed PostgreSQL version via pg_lsclusters." >&2
    exit 1
fi
log "Detected PostgreSQL version: ${PG_VERSION}"

# Stop the default cluster before we relocate its data directory.
systemctl stop postgresql

# ---------------------------------------------------------------------------
# 3. Prepare and mount the data volume
# ---------------------------------------------------------------------------

log "Checking filesystem on ${DATA_DEVICE}"
# blkid exits 0 with output when a filesystem is found, exit 2 with no
# output when the device genuinely has none -- both are legitimate outcomes
# here. Any other exit code (permissions, device busy, I/O error, etc.) is a
# real failure and must NOT be treated the same as "blank device," since
# that would walk straight into the mkfs.ext4 confirmation prompt below as
# if a volume that may actually hold existing Butler data were empty.
FSTYPE=""
# NOTE: deliberately not written as "if ! FSTYPE=$(blkid ...); then ...".
# The leading "!" negates the exit status to a plain 0/1 boolean, which
# clobbers blkid's actual numeric exit code before we get a chance to
# inspect it below -- so a genuine exit-2 ("no filesystem found") would be
# misreported as exit 0 inside the failure branch. Testing the un-negated
# command directly keeps $? intact on the else (failure) path.
if BLKID_OUTPUT="$(blkid -s TYPE -o value "${DATA_DEVICE}")"; then
    FSTYPE="${BLKID_OUTPUT}"
else
    BLKID_STATUS=$?
    if [[ "${BLKID_STATUS}" -ne 2 ]]; then
        echo "ERROR: blkid failed on ${DATA_DEVICE} with exit code ${BLKID_STATUS}," >&2
        echo "which is not the expected 'no filesystem found' result (exit 2)." >&2
        echo "Refusing to guess whether this device has a filesystem -- investigate" >&2
        echo "manually (e.g. re-run 'blkid ${DATA_DEVICE}') before proceeding." >&2
        exit 1
    fi
    FSTYPE=""
fi

if [[ -z "${FSTYPE}" ]]; then
    log "No filesystem detected on ${DATA_DEVICE} -- formatting as ext4"
    echo "This will ERASE all data on ${DATA_DEVICE}."
    read -r -p "Type 'yes' to continue: " CONFIRM
    if [[ "${CONFIRM}" != "yes" ]]; then
        echo "Aborted by user." >&2
        exit 1
    fi
    mkfs.ext4 "${DATA_DEVICE}"
else
    log "Existing filesystem detected (${FSTYPE}) -- skipping format"
fi

mkdir -p "${DATA_MOUNT}"

if ! mountpoint -q "${DATA_MOUNT}"; then
    log "Mounting ${DATA_DEVICE} at ${DATA_MOUNT}"
    mount "${DATA_DEVICE}" "${DATA_MOUNT}"
else
    log "${DATA_MOUNT} already mounted -- skipping"
fi

# ---------------------------------------------------------------------------
# 4. Configure /etc/fstab (UUID-based, noauto -- deliberately NOT using
#    x-systemd.automount / idle-timeout here)
#
#    Rationale: the automount-on-access + idle-timeout-unmount pattern
#    (recommended by ScienceCloud docs for general-purpose volumes) is a
#    poor fit for a Postgres data directory:
#      - Postgres background processes (autovacuum, checkpointer, WAL
#        writer) touch PGDATA continuously while running, so the mount
#        is effectively never idle -- the timeout provides no benefit
#        during normal operation.
#      - If it ever did unmount (e.g. after Postgres crashes and the
#        mount goes genuinely idle), it adds an unnecessary extra
#        mount/unmount cycle to the crash-recovery path without
#        improving data safety, which already comes from Postgres's own
#        WAL/fsync discipline rather than from mount timing.
#    Instead we keep noauto (so a missing volume never blocks instance
#    boot, per ScienceCloud's own guidance) but mount it explicitly and
#    deterministically via a systemd dependency on the PostgreSQL instance
#    unit (configured in the next step), rather than relying on access-
#    triggered automount timing.
# ---------------------------------------------------------------------------

VOL_UUID="$(blkid -s UUID -o value "${DATA_DEVICE}")"
FSTAB_LINE="UUID=${VOL_UUID} ${DATA_MOUNT} ext4 rw,noauto 0 0"

if ! grep -qF "${VOL_UUID}" /etc/fstab; then
    log "Adding fstab entry (noauto, explicit mount via systemd dependency)"
    cp /etc/fstab /etc/fstab.bak.$(date +%s)
    echo "${FSTAB_LINE}" >> /etc/fstab
    systemctl daemon-reload
else
    log "fstab entry for this volume already present -- skipping"
fi

# Mount unit name systemd derives from the mount point path, used below
# to make postgresql.service depend on it explicitly.
MOUNT_UNIT="$(systemd-escape -p --suffix=mount "${DATA_MOUNT}")"

# ---------------------------------------------------------------------------
# 5. Relocate PGDATA onto the volume
# ---------------------------------------------------------------------------

NEW_PGDATA="${DATA_MOUNT}/${PG_DATA_SUBDIR}"
OLD_PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"

if [[ ! -d "${NEW_PGDATA}" ]]; then
    log "Relocating PGDATA from ${OLD_PGDATA} to ${NEW_PGDATA}"
    mkdir -p "$(dirname "${NEW_PGDATA}")"
    rsync -av "${OLD_PGDATA}/" "${NEW_PGDATA}/"
    chown -R postgres:postgres "$(dirname "${NEW_PGDATA}")" "${NEW_PGDATA}"
    chmod 700 "${NEW_PGDATA}"
else
    log "Target PGDATA ${NEW_PGDATA} already exists -- existing data volume detected (e.g. instance recreate); skipping copy"

    # --- Verify the existing data is usable by THIS instance ---------------
    # Recreate-with-existing-volume case: we deliberately do NOT modify the
    # existing data (no reformat, no overwrite, no chown). We only check that
    # it is compatible with this instance and abort with a clear message if
    # not, since Postgres would otherwise fail to start in a confusing way.

    # (a) PostgreSQL major-version compatibility. The server refuses to start
    #     on a data directory written by a different major version (that needs
    #     pg_upgrade). The PG_VERSION file inside PGDATA records the major
    #     version that wrote it; compare it to the version apt just installed.
    if [[ ! -f "${NEW_PGDATA}/PG_VERSION" ]]; then
        echo "ERROR: ${NEW_PGDATA} exists but has no PG_VERSION file -- this does not" >&2
        echo "look like a valid PostgreSQL data directory. Verify the volume contents" >&2
        echo "and DATA_MOUNT/PG_DATA_SUBDIR before proceeding. Aborting without changes." >&2
        exit 1
    fi
    DATA_PG_VERSION="$(cat "${NEW_PGDATA}/PG_VERSION")"
    if [[ "${DATA_PG_VERSION}" != "${PG_VERSION}" ]]; then
        echo "ERROR: PostgreSQL major-version mismatch." >&2
        echo "  Data on the volume was written by PostgreSQL ${DATA_PG_VERSION}," >&2
        echo "  but the installed/running version is ${PG_VERSION}." >&2
        echo "  PostgreSQL will not start on a data directory from a different major" >&2
        echo "  version. Install PostgreSQL ${DATA_PG_VERSION} (e.g. from the PGDG apt" >&2
        echo "  repository) and re-run, or migrate the data with pg_upgrade." >&2
        echo "  No changes were made to the existing data. Aborting." >&2
        exit 1
    fi
    log "Existing data major version (${DATA_PG_VERSION}) matches installed version -- OK"

    # (b) Ownership. PGDATA must be owned by the postgres user's numeric UID,
    #     which is allocated at package-install time and can differ on a newly
    #     created instance. If it differs, Postgres cannot read its own data
    #     directory and fails to start. We do NOT chown automatically -- flag
    #     it and stop so the operator can decide.
    POSTGRES_UID="$(id -u postgres)"
    DATA_OWNER_UID="$(stat -c '%u' "${NEW_PGDATA}")"
    if [[ "${DATA_OWNER_UID}" != "${POSTGRES_UID}" ]]; then
        echo "ERROR: PGDATA ownership mismatch." >&2
        echo "  ${NEW_PGDATA} is owned by UID ${DATA_OWNER_UID}, but the 'postgres'" >&2
        echo "  user on this instance is UID ${POSTGRES_UID}. PostgreSQL will fail to" >&2
        echo "  start because it cannot access its data directory." >&2
        echo "  This script does not modify the existing data. After confirming that" >&2
        echo "  UID ${DATA_OWNER_UID} was the old postgres user, fix it manually with:" >&2
        echo "    chown -R postgres:postgres ${NEW_PGDATA}" >&2
        echo "  then re-run this script. Aborting." >&2
        exit 1
    fi
    log "Existing PGDATA ownership matches the postgres user (UID ${POSTGRES_UID}) -- OK"
fi

if grep -q "^data_directory" "${PG_CONF_DIR}/postgresql.conf"; then
    sed -i "s|^data_directory.*|data_directory = '${NEW_PGDATA}'|" "${PG_CONF_DIR}/postgresql.conf"
else
    echo "data_directory = '${NEW_PGDATA}'" >> "${PG_CONF_DIR}/postgresql.conf"
fi

# On Debian, postgresql.service is only a oneshot "umbrella" wrapper that is
# ordered *After* the real per-cluster instance unit
# (postgresql@${PG_VERSION}-main.service), which is what actually runs the
# database. Putting the mount dependency on the umbrella would therefore be
# too late: the instance would start (and fail, since PGDATA isn't mounted)
# before the umbrella ever pulls in the mount. So the override must go on the
# instance unit itself.
PG_INSTANCE_UNIT="postgresql@${PG_VERSION}-main.service"

log "Configuring systemd override so ${PG_INSTANCE_UNIT} requires ${MOUNT_UNIT} before starting"

# This is the explicit, deterministic alternative to x-systemd.automount:
# the PostgreSQL instance will not start until the data volume mount unit has
# successfully mounted, and systemd will order/start the mount first
# automatically when the instance is started or enabled at boot.
OVERRIDE_DIR="/etc/systemd/system/${PG_INSTANCE_UNIT}.d"
mkdir -p "${OVERRIDE_DIR}"
cat > "${OVERRIDE_DIR}/data-volume.conf" <<EOF
[Unit]
RequiresMountsFor=${DATA_MOUNT}
After=${MOUNT_UNIT}
EOF

systemctl daemon-reload

log "Enabling PostgreSQL to start at boot"
# Debian enables the service on install, but make boot-start intent explicit.
# Enabling the umbrella is the documented Debian mechanism; the instance unit
# (with our mount override) is pulled in and ordered after its mount at boot.
systemctl enable postgresql

log "Starting PostgreSQL with relocated data directory"
systemctl start postgresql
sleep 3
systemctl status postgresql --no-pager

# ---------------------------------------------------------------------------
# 6. Create roles, databases, and enable btree_gist per database
# ---------------------------------------------------------------------------

# Escapes a value for use inside a single-quoted SQL string literal (doubles
# embedded single quotes). Used for passwords and for names when they appear
# in a WHERE clause comparison rather than as an identifier.
sql_literal() {
    printf '%s' "${1//\'/\'\'}"
}

# Quotes a value as a SQL identifier (doubles embedded double quotes and
# wraps in double quotes). Used for database/role names wherever they are
# used as identifiers (CREATE ROLE/DATABASE, OWNER), so names containing
# characters like spaces, quotes, or -- for role/database names, though not
# realistically colons since those are consumed by the file parser -- don't
# break the SQL or get executed as unintended SQL.
sql_ident() {
    printf '"%s"' "${1//\"/\"\"}"
}

create_db_and_role() {
    local db_name="$1"
    local role_name="$2"
    local role_password="$3"

    local role_ident db_ident role_lit db_lit pw_lit
    role_ident="$(sql_ident "${role_name}")"
    db_ident="$(sql_ident "${db_name}")"
    role_lit="$(sql_literal "${role_name}")"
    db_lit="$(sql_literal "${db_name}")"
    pw_lit="$(sql_literal "${role_password}")"

    log "Setting up role '${role_name}' and database '${db_name}'"

    # The password is only set when the role is first created. If the role
    # already exists (e.g. on a re-run with a different *_DB_PASSWORD), this
    # does NOT update it -- the original password is kept. That's fine here
    # because this script is intended to be run once on a fresh instance, but
    # warn loudly so a re-run with a "new" password isn't silently ignored.
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${role_lit}'" | grep -q 1; then
        log "WARNING: role '${role_name}' already exists -- its password was" \
            "NOT changed. The password you supplied has been ignored; the" \
            "existing password is unchanged. To rotate it, run manually:" \
            "  sudo -u postgres psql -c \"ALTER ROLE ${role_ident} PASSWORD '...';\""
    else
        sudo -u postgres psql -v ON_ERROR_STOP=1 \
            -c "CREATE ROLE ${role_ident} WITH LOGIN PASSWORD '${pw_lit}';"
    fi

    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${db_lit}'" | grep -q 1; then
        sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${db_ident} OWNER ${role_ident};"
    else
        log "Database ${db_name} already exists -- skipping creation"
    fi

    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${db_name}" -c "CREATE EXTENSION IF NOT EXISTS btree_gist;"
}

for i in "${!DB_NAMES[@]}"; do
    create_db_and_role "${DB_NAMES[$i]}" "${DB_USERS[$i]}" "${DB_PASSWORDS[$i]}"
done

# ---------------------------------------------------------------------------
# 7. Configure network access (UZH-internal only, no public/global access)
#
#    Two changes are needed for Postgres to accept connections from other
#    hosts at all (e.g. the ScienceCluster, or your own workstation),
#    since by default it only listens on localhost and only trusts local
#    Unix-socket connections:
#
#      a) postgresql.conf: listen_addresses -- which network interfaces
#         Postgres listens on. Set to '*' here, i.e. listen on all local
#         interfaces.
#
#      b) pg_hba.conf: which source IPs/networks are allowed to connect,
#         to which databases, as which roles, using which auth method.
#         Set to ALLOWED_NETWORK (default 0.0.0.0/0, i.e. no restriction
#         at the Postgres level -- see config section above for the
#         rationale and the tradeoff this implies).
#
#    ACTUAL network-level access control for this instance is the
#    ScienceCloud Security Group (no public floating IP, inbound 5432
#    restricted to UZH-internal traffic) -- not pg_hba.conf. Role
#    passwords (scram-sha-256) are still required regardless, so this
#    is not the same as having no authentication at all, but be aware
#    that pg_hba.conf is not adding network-level restriction here.
# ---------------------------------------------------------------------------

log "Configuring listen_addresses in postgresql.conf"
if grep -q "^listen_addresses" "${PG_CONF_DIR}/postgresql.conf"; then
    sed -i "s|^listen_addresses.*|listen_addresses = '*'|" "${PG_CONF_DIR}/postgresql.conf"
else
    echo "listen_addresses = '*'" >> "${PG_CONF_DIR}/postgresql.conf"
fi

log "Configuring pg_hba.conf (source range: ${ALLOWED_NETWORK})"
# Note: scram-sha-256 is used as the auth method below because it's the
# default password_encryption setting since PostgreSQL 14 -- the CREATE
# ROLE statements above already produce scram-sha-256-compatible password
# hashes without any extra configuration on supported Debian images.
PG_HBA="${PG_CONF_DIR}/pg_hba.conf"
HBA_MARKER_BEGIN="# --- begin setup_butler_postgres.sh managed block ---"
HBA_MARKER_END="# --- end setup_butler_postgres.sh managed block ---"

# The managed block is fully removed and rewritten on every run (rather than
# skipped if already present), so that re-running with a changed database
# list -- e.g. an added database -- always converges pg_hba.conf to match
# DB_LIST_FILE, instead of silently leaving newly-added databases
# unreachable over the network because a stale block from a previous run
# was left in place.
cp "${PG_HBA}" "${PG_HBA}.bak.$(date +%s)"
if grep -qF "${HBA_MARKER_BEGIN}" "${PG_HBA}"; then
    log "Removing previous managed pg_hba.conf block before regenerating it"
    sed -i "/^${HBA_MARKER_BEGIN}\$/,/^${HBA_MARKER_END}\$/d" "${PG_HBA}"
fi

{
    echo ""
    echo "${HBA_MARKER_BEGIN}"
    echo "# Allow the Butler roles to connect to their respective databases,"
    echo "# using scram-sha-256 password auth. Source range is ${ALLOWED_NETWORK} --"
    echo "# network-level access is actually restricted by the ScienceCloud"
    echo "# Security Group (no public IP, UZH-internal only), not by this file."
    echo "# This block is fully regenerated by setup_butler_postgres.sh on every"
    echo "# run from the current DB_LIST_FILE -- do not edit it by hand, manual"
    echo "# edits between the begin/end markers will be discarded on the next run."
    for i in "${!DB_NAMES[@]}"; do
        echo "host    ${DB_NAMES[$i]}    ${DB_USERS[$i]}    ${ALLOWED_NETWORK}    scram-sha-256"
    done
    echo "${HBA_MARKER_END}"
} >> "${PG_HBA}"

log "Restarting PostgreSQL to apply listen_addresses and pg_hba.conf changes"
systemctl restart postgresql
sleep 3
systemctl status postgresql --no-pager

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------

log "Setup complete."
cat <<SUMMARY
PostgreSQL is running with PGDATA relocated to: ${NEW_PGDATA}
Volume ${DATA_DEVICE} (UUID=${VOL_UUID}) is mounted at ${DATA_MOUNT}.
The fstab entry uses 'noauto' (so a missing volume never blocks instance
boot), and ${PG_INSTANCE_UNIT} has an explicit systemd override
(RequiresMountsFor + After=${MOUNT_UNIT}) so the volume is always mounted
deterministically before PostgreSQL starts -- no automount/idle-timeout
is used here, since that pattern doesn't suit a database data directory
that's continuously in use.

Databases created (from ${DB_LIST_FILE}):
SUMMARY
for i in "${!DB_NAMES[@]}"; do
    echo "  - ${DB_NAMES[$i]}  (owner: ${DB_USERS[$i]})"
done
cat <<SUMMARY
All have the btree_gist extension enabled, as required by Butler.

Network access:
  - listen_addresses = '*' (Postgres listens on all local interfaces)
  - pg_hba.conf allows connections from ${ALLOWED_NETWORK}, per-database/
    per-role, using scram-sha-256 password authentication.
  - ACTUAL network-level restriction to UZH-internal traffic comes from
    the ScienceCloud Security Group (no public floating IP on this
    instance), not from pg_hba.conf. If ALLOWED_NETWORK is 0.0.0.0/0,
    the Security Group is the only thing preventing broader access --
    keep that in mind if the Security Group configuration ever changes.

STILL TO DO (not handled by this script):
  1. Confirm the ScienceCloud Security Group allows inbound TCP 5432
     from UZH-internal sources only (e.g. ScienceCluster, your own
     workstation via UZH network/VPN), and has no public-facing rule --
     this is done in the ScienceCloud Web Interface, not on the instance
     itself, and is the actual boundary protecting this database.
  2. Point your Butler repo configs (db-auth.yaml) at:
SUMMARY
for i in "${!DB_NAMES[@]}"; do
    echo "       postgresql://<this-host>:5432/${DB_NAMES[$i]}  (user: ${DB_USERS[$i]})"
done
cat <<SUMMARY
  3. Set up backups: run setup_butler_backups.sh for daily pg_dump backups
     on a cron schedule, then arrange an off-instance copy separately (see
     README.md, section "Backups").
  4. Consider locking the instance in the ScienceCloud Web Interface
     once you've confirmed everything works, to guard against accidental
     deletion.
SUMMARY
