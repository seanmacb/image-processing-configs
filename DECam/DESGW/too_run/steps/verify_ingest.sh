#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16GB
#SBATCH --time=02:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_ingest_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_ingest_%j.err

# Check the output of ingest_raw.sh: every exposure of the manifest has an
# exposure record and a plausible number of raw datasets in DECam/raw/all
# (a full DECam exposure has ~60 working detectors; the minimum is
# $MIN_RAW_PER_EXPOSURE).
#
#   verify_ingest.sh <templates|search>

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" verify_ingest

run_logged python "$TOO_RUN_DIR/verify_butler.py" check-ingest \
    --manifest "$MANIFEST" --raw-collection "$RAW_COLLECTION" --min-raw "$MIN_RAW_PER_EXPOSURE"
rc=$?
finish_step
exit $rc
