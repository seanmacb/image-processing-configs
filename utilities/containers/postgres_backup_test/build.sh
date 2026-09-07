#!/usr/bin/env bash
#
# build.sh
#
# Builds postgres_backup_test.def into a .sif on THIS machine - built and
# run wherever you're testing a backup from, unlike ../lsst_pipeline which
# ships to a remote cluster, so there's no arch-matching concern here.
#
# USAGE:
#   ./build.sh [path/to/build.args]
#
# Requires apptainer (https://apptainer.org) with fakeroot support.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ARGS_FILE="${1:-${SCRIPT_DIR}/build.args}"

if ! command -v apptainer >/dev/null 2>&1; then
    echo "ERROR: apptainer not found. Install it first: https://apptainer.org/docs/user/main/quick_start.html" >&2
    exit 1
fi

if [[ ! -f "${BUILD_ARGS_FILE}" ]]; then
    echo "ERROR: build args file '${BUILD_ARGS_FILE}' not found." >&2
    exit 1
fi

if ! grep -q "^$(whoami):" /etc/subuid 2>/dev/null || ! grep -q "^$(whoami):" /etc/subgid 2>/dev/null; then
    echo "WARNING: no /etc/subuid or /etc/subgid entry for $(whoami)." >&2
    echo "  --fakeroot likely won't work as an unprivileged user. Either:" >&2
    echo "  - ask your machine's admin to add a subuid/subgid range for your user, or" >&2
    echo "  - drop --fakeroot below and run this script with sudo instead." >&2
fi

PG_MAJOR="$(grep -E '^PG_MAJOR=' "${BUILD_ARGS_FILE}" | cut -d= -f2-)"
if [[ -z "${PG_MAJOR}" ]]; then
    echo "ERROR: PG_MAJOR not set in ${BUILD_ARGS_FILE}." >&2
    exit 1
fi

OUT_SIF="${SCRIPT_DIR}/postgres_backup_test_pg${PG_MAJOR}.sif"

echo ">>> Building ${OUT_SIF} from postgres_backup_test.def (PG_MAJOR=${PG_MAJOR})"

apptainer build --fakeroot --build-arg-file "${BUILD_ARGS_FILE}" \
    "${OUT_SIF}" "${SCRIPT_DIR}/postgres_backup_test.def"

echo ">>> Built ${OUT_SIF}"
ls -lh "${OUT_SIF}"
