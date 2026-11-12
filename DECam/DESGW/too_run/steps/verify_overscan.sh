#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32GB
#SBATCH --time=04:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_overscan_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_overscan_%j.err

# Check the output of build_overscan.sh: an overscanRaw dataset exists for every
# (exposure, detector) the phase's data query selects, allowing up to
# $OVERSCAN_MAX_MISSING_FRAC to be missing (detectors that fail ISR).
#
#   verify_overscan.sh <templates|search>

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" verify_overscan

status_file=$LOGDIR/too_run_${EVENT}_${TAG}_overscan.status
[[ -r $status_file ]] && log "pipetask exit status: $(cat "$status_file")" | tee -a "$LOGFILE"
run_logged python "$TOO_RUN_DIR/verify_butler.py" check-datasets \
    --dataset-type overscanRaw --collections "$OVERSCAN_COLLECTION" \
    --raw-collection "$RAW_COLLECTION" --where "$PHASE_QUERY AND $DET_EXCL" \
    --max-missing-frac "$OVERSCAN_MAX_MISSING_FRAC"
rc=$?
finish_step
exit $rc
