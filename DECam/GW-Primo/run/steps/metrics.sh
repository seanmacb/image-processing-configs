#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=12:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_metrics_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_metrics_%j.err

# Quality check after a step. For steps 1-3:
#   1. runs the step's analysis_tools subset (stepN-metrics in
#      gwprimo_drp.yaml) into the same output chain;
#   2. gwprimo_butler.py check: completeness per band (thresholds
#      STEPn_MIN_FRAC in the conf); this decides the exit status, so a failed
#      check stops the Slurm chain (afterok);
#   3. gwprimo_butler.py summarize: every metric of the step's metric bundles
#      to $METRICS_DIR/stepN_metrics.csv, a per-band median table to
#      stepN_summary.txt, and (EXPORT_PLOTS=1) the step's plots to
#      stepN_plots/.
# Step 0 has no analysis_tools metrics; only the overscanRaw check runs.
#
#   metrics.sh <0|1|2|3>

GWP_RUN_DIR=${GWP_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_RUN_DIR/common.sh"
load_conf
STEP=${1:?usage: metrics.sh <0|1|2|3>}
[[ $STEP =~ ^[0-3]$ ]] || die "step must be 0, 1, 2 or 3, got '$STEP'"
init_step "metrics$STEP"
: > "$STATUS_FILE"
mkdir -p "$METRICS_DIR"
QUERY=$(step_query "$STEP")

status_file=$LOGDIR/gwprimo_${FIELD}_step${STEP}.status
[[ -r $status_file ]] && log "step$STEP pipetask exit status: $(tr '\n' ' ' < "$status_file")" | tee -a "$LOGFILE"

if [[ $STEP != 0 ]]; then
    pipetask_drp "step${STEP}-metrics" "$QUERY" "$NPROC"
    record_pipetask_status $? "pipetask(step${STEP}-metrics)"
fi

run_logged python "$GWP_RUN_DIR/gwprimo_butler.py" check --step "$STEP" \
    --summary-file "$METRICS_DIR/step${STEP}_check.txt"
rc=$?

if [[ $STEP != 0 ]]; then
    plots=()
    [[ $EXPORT_PLOTS == 1 ]] && plots=(--plots-dir "$METRICS_DIR/step${STEP}_plots")
    # Informational: a summary failure does not change the check result.
    run_logged python "$GWP_RUN_DIR/gwprimo_butler.py" summarize --step "$STEP" \
        --out-dir "$METRICS_DIR" "${plots[@]}" \
        || log "WARNING: metric summary failed; the check result stands" | tee -a "$LOGFILE"
fi

finish_step
exit $rc
