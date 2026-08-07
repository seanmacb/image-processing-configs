#!/usr/bin/env bash
#
# build.sh
#
# Builds lsst_pipeline.def into a .sif on THIS machine (your personal
# machine, or any machine with apptainer + fakeroot - deliberately NOT run
# on the target cluster, see README.md "Why build locally"). Ship the
# resulting .sif to the cluster with ship_to_s3it.sh.
#
# USAGE:
#   ./build.sh [path/to/build.args]
#
# Requires apptainer (https://apptainer.org) with fakeroot support. On a
# personal Linux machine: sudo apt install apptainer (or see apptainer.org
# install docs for your distro). On macOS/Windows, apptainer needs a Linux
# VM (e.g. Lima, Colima, WSL2) - there is no native build.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ARGS_FILE="${1:-${SCRIPT_DIR}/build.args}"

# Minimum free space (GB) we want to see in the tmp/cache dirs apptainer
# will actually use for the build. The physik cluster's equivalent
# ansible-installed lsst_stack (same LSST_VERSION) measures 156GB /
# 429,989 files - the fakeroot build needs room for that uncompressed
# tree AND the final squashfs .sif at the same time, so this is
# deliberately well above 156GB, not a tight fit.
MIN_FREE_GB="${MIN_FREE_GB:-250}"

if ! command -v apptainer >/dev/null 2>&1; then
    echo "ERROR: apptainer not found. Install it first: https://apptainer.org/docs/user/main/quick_start.html" >&2
    exit 1
fi

if [[ ! -f "${BUILD_ARGS_FILE}" ]]; then
    echo "ERROR: build args file '${BUILD_ARGS_FILE}' not found." >&2
    exit 1
fi

# --- Architecture check --------------------------------------------------
# The target (S3IT) is x86_64. Building on anything else produces a .sif
# that either won't run there at all, or (worse) silently runs under slow
# QEMU emulation without telling you. --arch amd64 below forces apptainer
# to pull amd64 base layers regardless of host arch, so a mismatch here
# fails loudly at build time instead of producing a broken image.
HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" != "x86_64" ]]; then
    echo "ERROR: this machine is '${HOST_ARCH}', not x86_64." >&2
    echo "Building here would either fail or silently emulate the wrong architecture." >&2
    echo "Build on an x86_64 Linux machine (or an x86_64 Linux VM), matching S3IT's nodes." >&2
    exit 1
fi

# --- Fakeroot check --------------------------------------------------------
# --fakeroot needs a subuid/subgid range for $(whoami); without it apptainer
# silently falls back to a plain root-mapped namespace (i.e. needs sudo
# instead), which is a confusing failure mode to hit mid-build.
if ! grep -q "^$(whoami):" /etc/subuid 2>/dev/null || ! grep -q "^$(whoami):" /etc/subgid 2>/dev/null; then
    echo "WARNING: no /etc/subuid or /etc/subgid entry for $(whoami)." >&2
    echo "  --fakeroot likely won't work as an unprivileged user. Either:" >&2
    echo "  - ask your machine's admin to add a subuid/subgid range for your user, or" >&2
    echo "  - drop --fakeroot below and run this script with sudo instead." >&2
fi

# --- Tmp/cache dir checks --------------------------------------------------
# Apptainer stages the build in APPTAINER_TMPDIR (falls back to TMPDIR,
# then /tmp) and caches pulled layers in APPTAINER_CACHEDIR (falls back to
# ~/.apptainer/cache). Both need real free space, and must NOT be on NFS
# (fakeroot's overlay mount doesn't work there).
BUILD_TMPDIR="${APPTAINER_TMPDIR:-${TMPDIR:-/tmp}}"
BUILD_CACHEDIR="${APPTAINER_CACHEDIR:-${HOME}/.apptainer/cache}"

check_dir() {
    local dir="$1"
    local label="$2"

    mkdir -p "${dir}"

    local fs_type
    fs_type="$(stat -f -c %T "${dir}" 2>/dev/null || echo unknown)"
    if [[ "${fs_type}" == "nfs" || "${fs_type}" == "nfs4" ]]; then
        echo "WARNING: ${label} (${dir}) looks like it's on NFS (${fs_type})." >&2
        echo "  fakeroot builds need a local filesystem. Set APPTAINER_TMPDIR/" >&2
        echo "  APPTAINER_CACHEDIR to a local path, e.g.:" >&2
        echo "    export APPTAINER_TMPDIR=/local/scratch/apptainer-tmp" >&2
    fi

    local free_gb
    free_gb="$(df -Pk "${dir}" | awk 'NR==2 {print int($4/1024/1024)}')"
    if [[ -n "${free_gb}" && "${free_gb}" -lt "${MIN_FREE_GB}" ]]; then
        echo "WARNING: only ${free_gb}GB free at ${label} (${dir}) - a full lsst_distrib" >&2
        echo "  build can need ${MIN_FREE_GB}GB+ of scratch space. Point it elsewhere with" >&2
        echo "  APPTAINER_TMPDIR/APPTAINER_CACHEDIR if this fills up mid-build." >&2
    fi
}

check_dir "${BUILD_TMPDIR}" "build tmpdir"
check_dir "${BUILD_CACHEDIR}" "build cachedir"

# shellcheck disable=SC1090
LSST_VERSION="$(grep -E '^LSST_VERSION=' "${BUILD_ARGS_FILE}" | cut -d= -f2-)"
if [[ -z "${LSST_VERSION}" ]]; then
    echo "ERROR: LSST_VERSION not set in ${BUILD_ARGS_FILE}." >&2
    exit 1
fi

OUT_SIF="${SCRIPT_DIR}/lsst_pipeline_${LSST_VERSION}.sif"

echo ">>> Building ${OUT_SIF} from lsst_pipeline.def (build args: ${BUILD_ARGS_FILE})"
echo ">>> This runs a full lsstinstall + eups distrib install lsst_distrib inside the"
echo ">>> build - expect it to take a long time and a lot of disk (tens of GB free"
echo ">>> in TMPDIR/apptainer's cache dir) on a first build."

apptainer build --arch amd64 --fakeroot --build-arg-file "${BUILD_ARGS_FILE}" \
    "${OUT_SIF}" "${SCRIPT_DIR}/lsst_pipeline.def"

echo ">>> Built ${OUT_SIF}"
ls -lh "${OUT_SIF}"
