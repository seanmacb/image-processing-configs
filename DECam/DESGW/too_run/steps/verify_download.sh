#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16GB
#SBATCH --time=04:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_download_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_download_%j.err

# Check the output of download_raw.sh: manifest complete, every file present, the
# right size and a readable multi-extension FITS file with the expected EXPNUM
# (and PROPID in the search phase); in the templates phase, every exposure
# selected from the DELVE table is accounted for. Add --full-md5 to
# verify_raw_files.py to also re-read every file's checksum (slow).
#
#   verify_download.sh <templates|search>

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" verify_download

args=(--outdir "$RAWDIR" --workers 8)
if [[ $PHASE == templates ]]; then
    args+=(--exposure-list "$EXPOSURE_LIST")
else
    args+=(--propid "$PROPID")
fi
run_logged python "$TOO_RUN_DIR/verify_raw_files.py" "${args[@]}"
rc=$?
finish_step
exit $rc
