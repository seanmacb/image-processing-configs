#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8GB
#SBATCH --time=01:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_preflight_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_preflight_%j.err

# Read-only check that everything a run needs is in place, so it fails now
# rather than hours into a queue. Run it directly (run_drp.sh does) or with
# sbatch. Submits nothing, writes nothing to the Butler.
#
#   00_preflight.sh <conf> [--no-build]
#
#   1. Files: the pipeline, cp_pipe's RunIsrForCrosstalkSources.yaml, and that
#      the obs_decam set up is the fork with the medium-band filters.
#   2. gwprimo_butler.py preflight: BANDS within the pipeline's
#      parameters.bands; collections, skymap and the refcat over the region;
#      visits and raws per band; bias, flat, crosstalk, defects and linearizer
#      (and fringe for z) for every physical filter's first and last night;
#      how much overscanRaw step0 still has to build.
#   3. Whether sky frames exist for every filter and night (decides skyCorr's
#      doSky in step2; a failure only when SKY_FRAMES=on).
#   4. `pipetask build` of the whole pipeline (skip with --no-build; it takes
#      a few minutes): applies every obs_decam config override and task
#      config, which is where a broken override shows up.
#
# Exit status 0 only if every check passes.

GWP_RUN_DIR=${GWP_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")" && pwd)}
source "$GWP_RUN_DIR/common.sh"
CONF=${1:-}
[[ -n $CONF && $CONF != -* ]] || die "usage: 00_preflight.sh <conf> [--no-build]"
shift
BUILD=1
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-build) BUILD=0; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
load_conf "$CONF"

failures=0
ok()   { echo "ok       $*"; }
fail() { echo "FAIL     $*"; failures=$((failures + 1)); }
check() { # check <description> <command...>
    local what=$1
    shift
    if "$@" > /dev/null 2>&1; then ok "$what"; else fail "$what"; fi
}

echo "preflight for field $FIELD, conf $GWP_CONF"
echo "region $REGION, bands $BANDS"

check "pipeline ($PIPELINE)" test -r "$PIPELINE"
check "RunIsrForCrosstalkSources.yaml" test -r "$CP_PIPE_DIR/pipelines/DECam/RunIsrForCrosstalkSources.yaml"
check "obs_decam has the medium-band filters ($OBS_DECAM_DIR)" \
    grep -q '"M411' "$OBS_DECAM_DIR/python/lsst/obs/decam/decamFilters.py"
check "log directory writable ($LOGDIR)" test -w "$LOGDIR"

python "$GWP_RUN_DIR/gwprimo_butler.py" preflight || failures=$((failures + 1))

# Sky frames decide skyCorr's doSky in step2 (SKY_FRAMES, see steps/step2.sh).
# Only an error when the conf insists on them.
if [[ $SKY_FRAMES == off ]]; then
    echo "info     SKY_FRAMES=off: skyCorr runs without sky frames"
elif python "$GWP_RUN_DIR/gwprimo_butler.py" sky-ready > "$LOGDIR/gwprimo_${FIELD}_preflight_sky.log" 2>&1; then
    ok "sky frames for every filter and night: step2 runs skyCorr with doSky"
elif [[ $SKY_FRAMES == on ]]; then
    fail "SKY_FRAMES=on but sky frames are missing (see $LOGDIR/gwprimo_${FIELD}_preflight_sky.log)"
else
    echo "info     not every filter and night has a sky frame: step2 runs skyCorr without them" \
        "(details in $LOGDIR/gwprimo_${FIELD}_preflight_sky.log)"
fi

if [[ $BUILD == 1 ]]; then
    # No Butler access, just the configs. A bare `pipetask build` only parses
    # the YAML; --show pipeline-graph makes it configure every task, which is
    # what applies the obs_decam overrides.
    if pipetask build -p "$PIPELINE" --show pipeline-graph \
            > "$LOGDIR/gwprimo_${FIELD}_preflight_build.log" 2>&1; then
        ok "pipetask build of $PIPELINE"
    else
        fail "pipetask build of $PIPELINE (see $LOGDIR/gwprimo_${FIELD}_preflight_build.log)"
        tail -5 "$LOGDIR/gwprimo_${FIELD}_preflight_build.log"
    fi
fi

if [[ $failures -gt 0 ]]; then
    echo "preflight FAILED: $failures check(s)"
    exit 1
fi
echo "preflight PASSED"
