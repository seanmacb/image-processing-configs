#!/usr/bin/bash
# Submit GW-Primo DRP steps for one field. Each step is followed by its check
# job (steps/metrics.sh: analysis_tools metrics, completeness per band, metric
# summary), and everything is chained with sbatch --dependency=afterok:
#
#   step0 -> metrics0 -> step1 -> metrics1 -> step2 -> metrics2 -> step3 -> metrics3
#
# (metrics0 is only the overscanRaw check: step 0 has no analysis_tools tasks.)
#
# so a failed check stops the chain before the next step starts. Run one step
# at a time to look at its metrics before going on, or several in a row.
#
#   run_drp.sh <conf> --steps <list> [--dry-run] [--skip-preflight]
#
# <list> is comma separated from 0,1,2,3 (consecutive), or `all`. Examples:
#   run_drp.sh ../fields/S250830bp/field.conf --steps 0,1 --dry-run
#   run_drp.sh ../fields/S250830bp/field.conf --steps 2
# --dry-run prints the sbatch commands without submitting anything.
# Every step is safe to repeat (pipetask --skip-existing).

GWP_NO_STACK=1
GWP_RUN_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$GWP_RUN_DIR/common.sh"

CONF=${1:-}
[[ -n $CONF && $CONF != -* ]] || die "usage: run_drp.sh <conf> --steps <list> [--dry-run] [--skip-preflight]"
shift
STEPS="" DRY_RUN=0 SKIP_PREFLIGHT=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --steps) STEPS=${2:?--steps needs a list}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
export DRY_RUN
[[ -n $STEPS ]] || die "--steps is required (e.g. --steps 0,1 or --steps all)"
[[ $STEPS == all ]] && STEPS=0,1,2,3
IFS=, read -r -a STEP_LIST <<< "$STEPS"
prev=""
for s in "${STEP_LIST[@]}"; do
    [[ $s =~ ^[0-3]$ ]] || die "steps must be 0-3, got '$s'"
    [[ -z $prev || $s -eq $((prev + 1)) ]] || die "steps must be consecutive (each needs the one before), got '$STEPS'"
    prev=$s
done

load_conf "$CONF"

if [[ $DRY_RUN == 0 ]]; then
    running=$(queued_field_jobs)
    [[ -z $running ]] || die "jobs for field $FIELD are still queued or running; wait or scancel them first:
$running"
    if [[ $SKIP_PREFLIGHT == 0 ]]; then
        "$GWP_RUN_DIR/00_preflight.sh" "$GWP_CONF" || die "preflight failed"
    fi
fi

last=""
for s in "${STEP_LIST[@]}"; do
    job=$(submit "step$s" "$last" "$GWP_RUN_DIR/steps/step$s.sh") || exit 1
    last=$(submit "metrics$s" "$job" "$GWP_RUN_DIR/steps/metrics.sh" "$s") || exit 1
done
echo "field $FIELD: steps $STEPS submitted; last job $last"
echo "metrics and plots will be in \$LOGDIR/gwprimo/$FIELD (step<N>_check.txt, step<N>_summary.txt, step<N>_plots/)"
