#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8GB
#SBATCH --time=00:30:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_preflight_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_preflight_%j.err

# Read-only check that everything a run needs is in place, so it fails now rather
# than hours into a queue. Run it directly (the drivers do) or with sbatch.
#
#   00_preflight.sh <conf> [templates|search|all]
#
#   templates  the sky box and the DELVE table
#   search     PROPID, the injection catalog, the model package, the APDB, and
#              that templates exist and passed verify_templates.sh
#   all        both, except that templates need not exist yet (run_all.sh builds
#              them before the search phase)
#
# Exit status 0 only if every check passes.

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")" && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf "${1:-}"
WHAT=${2:-all}
[[ $WHAT == templates || $WHAT == search || $WHAT == all ]] || die "usage: 00_preflight.sh <conf> [templates|search|all]"

failures=0
ok()   { echo "ok       $*"; }
fail() { echo "FAIL     $*"; failures=$((failures + 1)); }
check() { # check <description> <command...>
    local what=$1
    shift
    if "$@" > /dev/null 2>&1; then ok "$what"; else fail "$what"; fi
}

echo "preflight for $EVENT ($WHAT), conf $TOO_RUN_CONF"

# The Butler and the collections every run reads.
required=(DECam/raw/all DECam/calib DECam/calib/curated/19700101T000000Z DECam/calib/unbounded "$SKYMAP_COLLECTION")
if [[ $WHAT != templates ]]; then
    if [[ -n $INJECTION_COLLECTION ]]; then
        required+=("$INJECTION_COLLECTION")
    else
        fail "INJECTION_COLLECTION is not set in the conf"
    fi
    required+=("$MODEL_COLLECTION")
fi
if [[ $WHAT == search ]]; then
    required+=("$TEMPLATE_COLLECTION")
fi
python "$TOO_RUN_DIR/verify_butler.py" check-collections \
    --collections "${required[@]}" --refcat the_monster_20250219 --refcat-collection refcats/gen3 \
    || failures=$((failures + 1))

# Pipeline definitions.
check "QuickTemplate.yaml" test -r "$IMAGE_PROC_CONFIG_DIR/configs/QuickTemplate.yaml"
check "desgw_ap_pipe.yaml" test -r "$IMAGE_PROC_CONFIG_DIR/configs/desgw_ap_pipe.yaml"
check "RunIsrForCrosstalkSources.yaml" test -r "$CP_PIPE_DIR/pipelines/DECam/RunIsrForCrosstalkSources.yaml"

# Somewhere to put the raws: the nearest existing parent must be writable.
parent=$RAW_ROOT
while [[ ! -d $parent ]]; do parent=$(dirname "$parent"); done
check "raw directory writable ($RAW_ROOT)" test -w "$parent"
check "log directory writable ($LOGDIR)" test -w "$LOGDIR"

# The NOIRLab archive (any HTTP response counts as reachable).
code=$(curl -s -o /dev/null -m 30 -w '%{http_code}' https://astroarchive.noirlab.edu/api/ 2>/dev/null)
if [[ -n $code && $code != 000 ]]; then ok "NOIRLab archive reachable (HTTP $code)"; else fail "NOIRLab archive not reachable"; fi

if [[ $WHAT != search ]]; then
    check "template sky box and window in the conf (RA_MIN..DEC_MAX)" test -n "$TEMPLATE_QUERY"
    check "DELVE exposure table ($TEMPLATE_CSV)" test -r "$TEMPLATE_CSV"
    check "template window is before the event ($TEMPLATE_END < $EVENT_DATE)" test "$TEMPLATE_END" -lt "$EVENT_DATE"
fi
if [[ $WHAT != templates ]]; then
    check "PROPID is set" test -n "$PROPID"
    check "APDB config ($APDB_CONFIG)" test -r "$APDB_CONFIG"
fi
if [[ $WHAT == search ]]; then
    check "templates verified (marker $TEMPLATES_OK_MARKER)" test -e "$TEMPLATES_OK_MARKER"
fi

if [[ $failures -gt 0 ]]; then
    echo "preflight FAILED: $failures check(s)"
    exit 1
fi
echo "preflight PASSED"
