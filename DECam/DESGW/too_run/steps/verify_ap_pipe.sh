#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32GB
#SBATCH --time=04:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_ap_pipe_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_ap_pipe_%j.err

# Check the output of run_ap_pipe.sh for the night: for the visit-detectors the
# data query selects, the calibrated image, difference image, DIA source tables
# and fake-injection matches exist in $SEARCH_COLLECTION (calibrated and
# difference images above $AP_MIN_ISR_FRAC / $AP_MIN_DIFF_FRAC; detectors without
# template overlap legitimately lack a difference image), no quanta were left
# unrun, and the fake-recovery 1-mag-bin analysis products exist. pipetask's exit
# status and failed-quantum count are reported. Writes
# $LOGDIR/too_run_<event>_<night>_summary.txt.
#
#   verify_ap_pipe.sh search

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" verify_ap_pipe

run_logged python "$TOO_RUN_DIR/verify_butler.py" check-ap \
    --collection "$SEARCH_COLLECTION" --raw-collection "$RAW_COLLECTION" \
    --where "$SEARCH_QUERY AND $DET_EXCL" \
    --min-isr-frac "$AP_MIN_ISR_FRAC" --min-diff-frac "$AP_MIN_DIFF_FRAC" \
    --log "$LOGDIR/too_run_${EVENT}_${TAG}_ap.log" \
    --status-file "$LOGDIR/too_run_${EVENT}_${TAG}_ap.status" \
    --summary-file "$LOGDIR/too_run_${EVENT}_${NIGHT}_summary.txt"
rc=$?
log "summary: $LOGDIR/too_run_${EVENT}_${NIGHT}_summary.txt" | tee -a "$LOGFILE"
finish_step
exit $rc
