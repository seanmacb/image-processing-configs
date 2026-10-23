#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=24:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_cpFlat_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_cpFlat_%j.err

# Combined dome flats, one per (physical filter, detector), with cp_pipe's
# DECam cpFlat.yaml: the same call as DESGW/startup/calib/build-flat-25-26.sh,
# for the set's medium bands and nights. Bias, crosstalk and the other ISR
# calibrations come from DECam/calib.
#
# No --skip-existing, on purpose: check.sh and certify.sh read the newest RUN
# of FLAT_COLLECTION, which must hold the complete set. With --skip-existing a
# rerun would leave flats finished earlier in an older RUN.
#
# The job exits 0 even if some quanta failed; check.sh decides from what was
# produced (every detector needs a flat before anything is certified).
#
#   flat.sh        (GWP_SET_CONF and GWP_CALIB_DIR come from run_calib.sh)

GWP_CALIB_DIR=${GWP_CALIB_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_CALIB_DIR/common.sh"
load_set
init_step flat

run_logged pipetask --long-log run --register-dataset-types -j "$NPROC" \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i "$FLAT_INPUTS" \
    -o "$FLAT_COLLECTION" \
    -p "$CP_PIPE_DIR/pipelines/DECam/cpFlat.yaml" \
    -d "$FLAT_QUERY"
rc=$?
[[ $rc -ne 0 ]] && log "WARNING: pipetask exited with status $rc; check.sh decides whether the flats are usable" | tee -a "$LOGFILE"
finish_step
exit 0
