#!/usr/bin/env bash
#
# run_backup_test.sh
#
# Host-side wrapper around `apptainer exec` for postgres_backup_test.sif -
# restore+summary logic lives in scripts/restore_and_verify.sh (baked into
# the image); this gets the container invocation flags right.
#
# USAGE:
#   ./run_backup_test.sh <path-to-backup-dir> [database ...]
#
# <path-to-backup-dir> is BACKUP_DIR from butler_pg_backup.sh (or a local
# copy, e.g. via ../../postgres-setup/utilities/pull_butler_backups.sh) -
# bind-mounted READ-ONLY. With no database names given, every database
# with a dump for the chosen backup run is restored; set BACKUP_TIMESTAMP
# to pick a specific run (see restore_and_verify.sh). LOG_DIR: host path
# for restore logs, written directly there to survive a kill mid-restore.
#
# PGDATA/socket/logs live on Apptainer's "sessiondir" tmpfs, which defaults
# to 64MiB (apptainer.conf(5)) - far too small for a real restore, and not
# adjustable via a CLI flag (apptainer/apptainer#3674 is open, unmerged).
# So this generates a private apptainer.conf with a larger
# "sessiondir max size" and points Apptainer at it via APPTAINER_CONFIG_FILE
# ("only supported for non-root users in non-setuid mode" per apptainer's
# docs; this repo's images are built with --fakeroot, not setuid). Apptainer
# grows the tmpfs on demand rather than reserving it upfront. On a shared
# host, keep SCRATCH_TMPFS_MIB modest - apptainer/apptainer#1313's reporter
# warns large --writable-tmpfs can eat RAM on shared systems.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BACKUP_DIR="${1:?Usage: run_backup_test.sh <path-to-backup-dir> [database ...]}"
shift

SIF="${SIF:-}"
if [[ -z "${SIF}" ]]; then
    # shellcheck disable=SC2012
    SIF="$(ls "${SCRIPT_DIR}"/postgres_backup_test_pg*.sif 2>/dev/null | head -1)"
fi

if [[ -z "${SIF}" || ! -f "${SIF}" ]]; then
    echo "ERROR: no postgres_backup_test_pg*.sif found next to this script." >&2
    echo "Run ./build.sh first, or set SIF=path/to/image.sif." >&2
    exit 1
fi

if ! command -v apptainer >/dev/null 2>&1; then
    echo "ERROR: apptainer not found. Install it first: https://apptainer.org/docs/user/main/quick_start.html" >&2
    exit 1
fi

if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "ERROR: backup dir '${BACKUP_DIR}' not found." >&2
    exit 1
fi
BACKUP_DIR="$(cd "${BACKUP_DIR}" && pwd)"

# Optional: persist restore logs to a real host directory - WORKDIR itself
# disappears with the container otherwise.
LOG_BIND_ARGS=()
if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p "${LOG_DIR}"
    LOG_DIR="$(cd "${LOG_DIR}" && pwd)"
    LOG_BIND_ARGS=(--bind "${LOG_DIR}:/logs" --env "PG_TEST_LOG_DIR=/logs")
fi

# Raise this for a bigger backup - see header comment.
SCRATCH_TMPFS_MIB="${SCRATCH_TMPFS_MIB:-8192}"

SYSTEM_APPTAINER_CONF="${APPTAINER_SYSTEM_CONF:-}"
if [[ -z "${SYSTEM_APPTAINER_CONF}" ]]; then
    for candidate in /etc/apptainer/apptainer.conf /usr/local/etc/apptainer/apptainer.conf; do
        if [[ -f "${candidate}" ]]; then
            SYSTEM_APPTAINER_CONF="${candidate}"
            break
        fi
    done
fi

if [[ -z "${SYSTEM_APPTAINER_CONF}" || ! -f "${SYSTEM_APPTAINER_CONF}" ]]; then
    echo "ERROR: could not find the system apptainer.conf (checked" >&2
    echo "/etc/apptainer/apptainer.conf and /usr/local/etc/apptainer/apptainer.conf)." >&2
    echo "Set APPTAINER_SYSTEM_CONF to its actual path." >&2
    exit 1
fi

CUSTOM_CONF="$(mktemp)"
cleanup() { rm -f "${CUSTOM_CONF}"; }
trap cleanup EXIT

cp "${SYSTEM_APPTAINER_CONF}" "${CUSTOM_CONF}"
if grep -q '^sessiondir max size' "${CUSTOM_CONF}"; then
    sed -i "s/^sessiondir max size.*/sessiondir max size = ${SCRATCH_TMPFS_MIB}/" "${CUSTOM_CONF}"
else
    echo "sessiondir max size = ${SCRATCH_TMPFS_MIB}" >> "${CUSTOM_CONF}"
fi

# --no-mount tmp: the host's real /tmp is bind-mounted by default and would
# shadow the enlarged sessiondir tmpfs at that path.
APPTAINER_CONFIG_FILE="${CUSTOM_CONF}" \
    apptainer exec --writable-tmpfs --no-mount tmp \
        --bind "${BACKUP_DIR}:/backups:ro" \
        "${LOG_BIND_ARGS[@]}" \
        "${SIF}" /opt/postgres_backup_test/restore_and_verify.sh /backups "$@"
