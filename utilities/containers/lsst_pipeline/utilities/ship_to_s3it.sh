#!/usr/bin/env bash
#
# ship_to_s3it.sh
#
# Copies a .sif built locally by build.sh to a destination host (e.g. an
# S3IT ScienceCluster login node) over rsync/SSH. Deliberately just a thin
# rsync wrapper - the interesting logic is in build.sh/lsst_pipeline.def.
#
# The physik cluster's equivalent lsst_stack install is 156GB - expect a
# similarly large .sif, so this uses --partial (keep partially-transferred
# data on interruption) + --partial-dir + --append-verify, so a dropped
# connection resumes rather than restarting a 150GB+ transfer from zero.
#
# USAGE (env vars, DEST_HOST and SIF required):
#   SIF=lsst_pipeline_w_2026_30.sif DEST_HOST=<ssh-alias|user@host> ./ship_to_s3it.sh
#
# DEST_DIR defaults to a scratch-ish path - override to wherever your S3IT
# project storage for shared images should live.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# build.sh writes the .sif one level up (utilities/lsst_pipeline/), not
# alongside this script (utilities/lsst_pipeline/utilities/).
BUILD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEST_HOST="${DEST_HOST:?Set DEST_HOST to the destination ssh alias/user@host}"
SIF="${SIF:?Set SIF to the .sif file to ship, e.g. lsst_pipeline_w_2026_30.sif}"
DEST_DIR="${DEST_DIR:-~/lsst_pipeline_images}"

SIF_PATH="${BUILD_DIR}/${SIF}"
if [[ ! -f "${SIF_PATH}" ]]; then
    echo "ERROR: ${SIF_PATH} not found - run build.sh first." >&2
    exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*"; }

log "=== Shipping ${SIF} (\"$(du -h "${SIF_PATH}" | cut -f1)\") to ${DEST_HOST}:${DEST_DIR}/ ==="

ssh "${DEST_HOST}" "mkdir -p ${DEST_DIR}"
rsync -avh --progress --partial --partial-dir=.rsync-partial --append-verify \
    "${SIF_PATH}" "${DEST_HOST}:${DEST_DIR}/"

log "OK: ${SIF} is now at ${DEST_HOST}:${DEST_DIR}/${SIF}"
log "Run it there with, e.g.:"
log "  apptainer exec --bind /path/to/butler:/butler ${DEST_DIR}/${SIF} pipetask run ..."
