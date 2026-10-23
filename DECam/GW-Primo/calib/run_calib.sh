#!/usr/bin/bash
# Build, check, certify and verify the calibrations of one calibration set
# (sets/<SET>.conf): medium-band flats, then sky frames. Each step is its own
# Slurm job, chained with sbatch --dependency=afterok:
#
#   overscan -> flat -> check -> certify -> verify                  (flats)
#     -> sky_select -> sky_overscan -> sky -> sky_check -> sky_certify   (sky frames)
#
# so nothing is certified unless its check passed, and the sky frames (built
# from flat-fielded science exposures) never start before the flats are
# certified and verified. A sensible pass stops before each certify, to read
# the check summary first:
#
#   run_calib.sh sets/2026-06.conf --steps overscan,flat,check --dry-run
#   run_calib.sh sets/2026-06.conf --steps overscan,flat,check
#   run_calib.sh sets/2026-06.conf --steps certify,verify
#   run_calib.sh sets/2026-06.conf --steps sky_select,sky_overscan,sky,sky_check
#   run_calib.sh sets/2026-06.conf --steps sky_certify
#
# Sky-only sets (SKY_ONLY=1, the broad-band sets/sky-*.conf, whose flats are
# in DECam/calib) have only the sky steps; `all` means those for them.
#
#   run_calib.sh <set conf> --steps <list> [--dry-run]
#
# <list> is comma separated, in the order above, consecutive; `flats` (the
# first five), `skies` (the five sky steps), or `all`. --dry-run prints the
# sbatch commands without submitting anything.
#
# `gwprimo_flats.py inventory` shows the set's state without changing anything:
#   GWP_SET_CONF=<conf> bash -lc 'source common.sh; load_set; python gwprimo_flats.py inventory'

GWP_NO_STACK=1
GWP_CALIB_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$GWP_CALIB_DIR/common.sh"

FLAT_STEPS=(overscan flat check certify verify)
SKY_STEPS=(sky_select sky_overscan sky sky_check sky_certify)
ALL_STEPS=("${FLAT_STEPS[@]}" "${SKY_STEPS[@]}")
# step -> "script [args]"
step_command() {
    case $1 in
        overscan) echo "overscan.sh flat" ;;
        flat) echo "flat.sh" ;;
        check) echo "check.sh flat" ;;
        certify) echo "certify.sh flat" ;;
        verify) echo "verify.sh" ;;
        sky_select) echo "sky_select.sh" ;;
        sky_overscan) echo "overscan.sh sky" ;;
        sky) echo "sky.sh" ;;
        sky_check) echo "check.sh sky" ;;
        sky_certify) echo "certify.sh sky" ;;
    esac
}

CONF=${1:-}
[[ -n $CONF && $CONF != -* ]] || die "usage: run_calib.sh <set conf> --steps <list> [--dry-run]"
shift
STEPS="" DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --steps) STEPS=${2:?--steps needs a list}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
export DRY_RUN
[[ -n $STEPS ]] || die "--steps is required (e.g. --steps overscan,flat,check or --steps all)"

load_set "$CONF"

case $STEPS in
    all) if [[ $SKY_ONLY == 1 ]]; then STEPS=$(IFS=,; echo "${SKY_STEPS[*]}")
         else STEPS=$(IFS=,; echo "${ALL_STEPS[*]}"); fi ;;
    flats) STEPS=$(IFS=,; echo "${FLAT_STEPS[*]}") ;;
    skies) STEPS=$(IFS=,; echo "${SKY_STEPS[*]}") ;;
esac
IFS=, read -r -a STEP_LIST <<< "$STEPS"

# Steps must be known, in order and consecutive: each needs the one before.
prev=-1
for s in "${STEP_LIST[@]}"; do
    idx=-1
    for i in "${!ALL_STEPS[@]}"; do [[ ${ALL_STEPS[$i]} == "$s" ]] && idx=$i; done
    [[ $idx -ge 0 ]] || die "unknown step '$s' (one of ${ALL_STEPS[*]})"
    [[ $prev -lt 0 || $idx -eq $((prev + 1)) ]] || die "steps must be consecutive, in the order ${ALL_STEPS[*]}; got '$STEPS'"
    [[ $SKY_ONLY == 1 && $idx -lt ${#FLAT_STEPS[@]} ]] && die "set $SET is sky-only (SKY_ONLY=1): its flats come from DECam/calib, so it has no '$s' step"
    prev=$idx
done

if [[ $DRY_RUN == 0 ]]; then
    running=$(squeue -h -u "${USER:-$(id -un)}" -o "%i %j" 2>/dev/null | awk -v p="gwp_calib_${SET}_" 'index($2, p) == 1')
    [[ -z $running ]] || die "jobs for calibration set $SET are still queued or running; wait or scancel them first:
$running"
fi

last=""
for s in "${STEP_LIST[@]}"; do
    read -r script args <<< "$(step_command "$s")"
    # shellcheck disable=SC2086
    last=$(submit "$s" "$last" "$GWP_CALIB_DIR/steps/$script" $args) || exit 1
done
echo "calibration set $SET: steps $STEPS submitted; last job $last"
echo "logs: \$LOGDIR/gwprimo_calib_${SET}_<step>.log; check/verify summaries: \$LOGDIR/gwprimo_calib_${SET}_{flat_check,flat_verify,sky_check}.txt"
