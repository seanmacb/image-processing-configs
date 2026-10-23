#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=16GB
#SBATCH --time=02:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_check_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_check_%j.err

# Gate before certification. Exit 1 stops the chain before the certify step.
#   flat   gwprimo_flats.py check: every filter of the set has at least
#          FLAT_MIN_EXPOSURES dome flats; the newest RUN of FLAT_COLLECTION has
#          a flat for every detector those exposures have; the binned flats
#          (flatBin64) have a median near 1 and no blank detectors (warnings).
#   sky    gwprimo_flats.py check-sky: every filter with science exposures has
#          at least SKY_MIN_EXPOSURES of them and a sky frame for every
#          detector in the newest RUN of SKY_COLLECTION; per-filter statistics
#          of the sky frames (non-finite pixels flagged).
#
#   check.sh [flat|sky]   (GWP_SET_CONF and GWP_CALIB_DIR come from run_calib.sh)

GWP_CALIB_DIR=${GWP_CALIB_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_CALIB_DIR/common.sh"
load_set
KIND=${1:-flat}
case $KIND in
    flat) init_step check; CMD=check; COLL=$FLAT_COLLECTION ;;
    sky) init_step sky_check; CMD=check-sky; COLL=$SKY_COLLECTION ;;
    *) die "usage: check.sh [flat|sky]" ;;
esac

run_logged python "$GWP_CALIB_DIR/gwprimo_flats.py" "$CMD" \
    --run "$(latest_run "$COLL")" \
    --summary-file "$LOGDIR/gwprimo_calib_${SET}_${KIND}_check.txt"
rc=$?
finish_step
exit $rc
