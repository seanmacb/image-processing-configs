#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8GB
#SBATCH --time=01:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_sky_select_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_sky_select_%j.err

# Choose the science exposures the sky frames are built from, when the set
# caps them (SKY_MAX_EXPOSURES): gwprimo_flats.py select-sky writes at most
# that many per physical filter to SKY_EXPOSURE_LIST, spread over nights and
# pointings, and the later sky steps use exactly that list. The file sits next
# to the conf and records the choice; it is rewritten each time this runs, so
# rerun it only before rebuilding the set's sky frames.
#
# Without SKY_MAX_EXPOSURES (the medium-band sets) there is nothing to choose
# and this job only says so.
#
#   sky_select.sh        (GWP_SET_CONF and GWP_CALIB_DIR come from run_calib.sh)

GWP_CALIB_DIR=${GWP_CALIB_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_CALIB_DIR/common.sh"
load_set
init_step sky_select

if [[ -z $SKY_MAX_EXPOSURES ]]; then
    log "SKY_MAX_EXPOSURES unset: the sky frames use every exposure SKY_QUERY selects" | tee -a "$LOGFILE"
    finish_step
    exit 0
fi
run_logged python "$GWP_CALIB_DIR/gwprimo_flats.py" select-sky --output "$SKY_EXPOSURE_LIST"
rc=$?
finish_step
exit $rc
