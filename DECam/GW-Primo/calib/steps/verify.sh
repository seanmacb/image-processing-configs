#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=64GB
#SBATCH --time=24:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_verify_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_verify_%j.err

# cp_verify of the certified flats: the dome flats, flat-fielded with the new
# flat, should come out flat. Uses DESGW's desgw_verify_flat.yaml, which
# carries the DECam MJD-backfill fix for cp_verify (see that file); its
# IsrStatistics subclass must be importable in the spawned pipetask workers,
# hence PYTHONPATH, as in DESGW/calib/base/verify-flat-25-26.sh.
#
# Then gwprimo_flats.py verify-summary prints cp_verify's pass/fail per filter
# and per exposure, and exits 1 if any filter failed. Nothing depends on this
# job: a failure only flags the set for a look (and possibly decertify).
# Like flat.sh, it leaves out the dome flats overscan could not read.
#
#   verify.sh        (GWP_SET_CONF and GWP_CALIB_DIR come from run_calib.sh)

GWP_CALIB_DIR=${GWP_CALIB_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_CALIB_DIR/common.sh"
load_set
init_step verify
export PYTHONPATH=$IMAGE_PROC_CONFIG_DIR/configs:$PYTHONPATH
QUERY=$(query_without_overscan_gaps flat) || { finish_step; exit 1; }

run_logged pipetask --long-log run --register-dataset-types -j "$NPROC" \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i "$VERIFY_INPUTS" \
    -o "$VERIFY_COLLECTION" \
    -p "$IMAGE_PROC_CONFIG_DIR/configs/desgw_verify_flat.yaml" \
    -d "$QUERY"
prc=$?
[[ $prc -ne 0 ]] && log "WARNING: pipetask exited with status $prc" | tee -a "$LOGFILE"

run_logged python "$GWP_CALIB_DIR/gwprimo_flats.py" verify-summary \
    --run "$(latest_run "$VERIFY_COLLECTION")" \
    --summary-file "$LOGDIR/gwprimo_calib_${SET}_flat_verify.txt"
rc=$?
finish_step
exit $rc
