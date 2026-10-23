#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=24:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_cpSky_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_cpSky_%j.err

# Sky frames, one per (physical filter, detector), from the science exposures
# of the set's bands and nights (configs/gwprimo_cpSky.yaml, cp_pipe cpSky).
# Needs the set's flats certified in CALIB_COLLECTION first: the sky frame is
# the pattern left after flat-fielding.
#
# No --skip-existing, as in flat.sh: sky_check and sky_certify read only the
# newest RUN of SKY_COLLECTION, which must hold the complete set. The job exits
# 0 even if some quanta failed; sky_check decides from what was produced.
#
#   sky.sh        (GWP_SET_CONF and GWP_CALIB_DIR come from run_calib.sh)

GWP_CALIB_DIR=${GWP_CALIB_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_CALIB_DIR/common.sh"
load_set
require_sky_selection
init_step sky

run_logged pipetask --long-log run --register-dataset-types -j "$NPROC" \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i "$SKY_INPUTS" \
    -o "$SKY_COLLECTION" \
    -p "$SKY_PIPELINE" \
    -d "$SKY_QUERY"
rc=$?
[[ $rc -ne 0 ]] && log "WARNING: pipetask exited with status $rc; sky_check decides whether the sky frames are usable" | tee -a "$LOGFILE"
finish_step
exit 0
