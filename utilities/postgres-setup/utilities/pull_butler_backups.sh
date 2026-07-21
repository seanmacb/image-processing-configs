#!/usr/bin/env bash
#
# pull_butler_backups.sh
#
# Runs on the SECONDARY (off-instance) machine: pulls the Butler Postgres
# backup dir (see butler_pg_backup.sh / setup_butler_backups.sh) from the
# source instance to local disk here, via rsync over SSH.
#
# USAGE (env vars, SOURCE_HOST required):
#   SOURCE_HOST=<ssh-alias|hostname|IP> ./pull_butler_backups.sh
#
# SOURCE_HOST must be the dedicated pull user set up by
# setup_butler_backups.sh (default account name: butler-backup-pull),
# e.g. SOURCE_HOST=butler-backup-pull@lsst-butler-postgres -- that
# account's authorized_keys already forces every login straight into
# "sudo -n -u postgres rsync --server ...", so no --rsync-path/sudo needs
# to be requested from this side (and requesting one would just get
# rejected by the source's forced command, which only accepts a plain
# "rsync --server ..." command to wrap in that sudo call itself).
#
# Example root crontab entry. Deliberately NOT redirected to a log file:
# cron's own MAILTO mechanism mails stdout/stderr of every run to root (or
# whoever MAILTO is set to in the crontab), which is what surfaces the "0
# new backups" warning below as a daily reminder, run or not.
#   MAILTO=oncall@example.org
#   0 5 * * * SOURCE_HOST=butler-backup-pull@lsst-butler-postgres /path/to/pull_butler_backups.sh
# Schedule it a couple hours after the source's own backup cron (default
# 03:00) so there's a fresh dump to pull. DEST_DIR defaults to
# /mnt/data1/backups/cloud-butler-postgres.
#
set -euo pipefail

SOURCE_HOST="${SOURCE_HOST:?Set SOURCE_HOST to the source instance ssh alias/hostname/IP}"
SOURCE_BACKUP_DIR="${SOURCE_BACKUP_DIR:-/mnt/pgdata/backups/postgresql}"
DEST_DIR="${DEST_DIR:-/mnt/data1/backups/cloud-butler-postgres}"

RETENTION_DAYS="${RETENTION_DAYS:-30}"

# e.g. SSH_OPTS='-i /home/me/.ssh/id_butler_pull -o StrictHostKeyChecking=yes'
SSH_OPTS="${SSH_OPTS:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*"; }

mkdir -p "${DEST_DIR}"

# Guards the 'find -delete' below against a mistyped DEST_DIR, same pattern
# as BACKUP_DIR_MARKER in butler_pg_backup.sh.
DEST_DIR_MARKER=".pull_butler_backups_dir"
if [[ ! -f "${DEST_DIR}/${DEST_DIR_MARKER}" ]]; then
    if [[ -z "$(ls -A "${DEST_DIR}" 2>/dev/null)" ]]; then
        touch "${DEST_DIR}/${DEST_DIR_MARKER}"
    else
        echo "ERROR: ${DEST_DIR} is missing its ${DEST_DIR_MARKER} marker and is not empty -- refusing to prune it. Check DEST_DIR." >&2
        exit 1
    fi
fi

log "=== Pull starting: ${SOURCE_HOST}:${SOURCE_BACKUP_DIR}/ -> ${DEST_DIR}/ ==="

# --itemize-changes (-i) prefixes each transferred path with a change code,
# e.g. ">f+++++++++ path" for a brand-new file -- captured here so we can
# report how many *new* backup files actually landed (the whole point of
# mailing this cron's output: a silent 0 is the signal that either the
# source's backup cron or this pull is broken, not that "nothing to do").
# No --rsync-path here -- the source's authorized_keys forced command
# already runs the remote side as postgres via NOPASSWD sudo (see USAGE
# above); --no-owner/-group because there's no local postgres user to
# preserve ownership as.
# shellcheck disable=SC2086
RSYNC_OUTPUT="$(rsync -avi --no-owner --no-group \
    -e "ssh ${SSH_OPTS}" \
    "${SOURCE_HOST}:${SOURCE_BACKUP_DIR}/" "${DEST_DIR}/")"
echo "${RSYNC_OUTPUT}"

NEW_BACKUP_COUNT="$(grep -cE '^>f\+{9} .*(\.dump|globals_.*\.sql)$' <<< "${RSYNC_OUTPUT}" || true)"

log "OK: pull finished ($(du -sh "${DEST_DIR}" | cut -f1) total)"
if [[ "${NEW_BACKUP_COUNT}" -eq 0 ]]; then
    log "WARNING: 0 new backup files pulled this run -- check that the source's own backup cron is producing fresh dumps"
else
    log "New backup files pulled this run: ${NEW_BACKUP_COUNT}"
fi

log "Pruning local copies older than ${RETENTION_DAYS} days from ${DEST_DIR}"
# Independent of the source's own retention, and no --delete above -- this
# copy shouldn't mirror problems (bad prune, corruption) from the source.
find "${DEST_DIR}" -type f \( -name '*.dump' -o -name 'globals_*.sql' \) -mtime "+${RETENTION_DAYS}" -print -delete

log "=== Pull run finished successfully ==="
