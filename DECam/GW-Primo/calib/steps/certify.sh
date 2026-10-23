#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16GB
#SBATCH --time=01:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_certify_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_certify_%j.err

# Certify the set's flats (`flat`) or sky frames (`sky`) into CALIB_COLLECTION
# (DECam/calib/GW-Primo, created on first use) for [CERT_BEGIN, CERT_END).
# Run it only after the matching check passed; run_calib.sh chains it that
# way. The shared DECam/calib is not touched.
#
# The input is the newest RUN, not the FLAT_COLLECTION/SKY_COLLECTION chain:
# the chain flattens to include DECam/calib itself, which makes the lookup
# ambiguous (same reason as DESGW/startup/calib/certify-fringe-15-16.sh).
#
# certify-calibrations refuses a window that overlaps one already certified
# for the same dataset. To redo a set, decertify it first:
#   python gwprimo_flats.py decertify --dataset-type <flat|sky> --confirm
#
#   certify.sh [flat|sky]   (GWP_SET_CONF and GWP_CALIB_DIR come from run_calib.sh)

GWP_CALIB_DIR=${GWP_CALIB_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_CALIB_DIR/common.sh"
load_set
KIND=${1:-flat}
case $KIND in
    flat) init_step certify; COLL=$FLAT_COLLECTION ;;
    sky) init_step sky_certify; COLL=$SKY_COLLECTION ;;
    *) die "usage: certify.sh [flat|sky]" ;;
esac

RUN=$(latest_run "$COLL")
[[ -n $RUN ]] || die "no RUN under $COLL: build the $KIND calibrations first"
log "certifying $KIND of $RUN into $CALIB_COLLECTION for [$CERT_BEGIN, $CERT_END)" | tee -a "$LOGFILE"
run_logged butler certify-calibrations "$REPO" "$RUN" "$CALIB_COLLECTION" "$KIND" \
    --begin-date "$CERT_BEGIN" --end-date "$CERT_END"
rc=$?
finish_step
exit $rc
