#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=12:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_overscan_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_calib_overscan_%j.err

# overscanRaw crosstalk sources for the set's dome flats (`flat`) or for the
# science exposures its sky frames are built from (`sky`); cpFlatIsr and
# cpSkyIsr read them (connections.crosstalkSources: overscanRaw). Same
# pipeline and inputs as DESGW/startup/calib/build-overscanRaw_flats_25-26.sh,
# whose 2025-26 run predates the medium-band flats and covers only g r i z.
#
# Every set and both kinds write to the one chain OVERSCAN_COLLECTION, so the
# -i list is the same for all of them. Each run gets its own RUN,
# OVERSCAN_COLLECTION/<SET>/<kind>/<UTC time>: pipetask's default name is only
# the chain plus a timestamp, which two sets starting in the same second share.
# --skip-existing-in every RUN of the chain makes a rerun cheap (plain
# --skip-existing looks only in the new, empty RUN). (A field's DRP step0
# builds its own overscanRaw for the same science exposures into its own
# collection; the duplication is cheap, overscan only.)
#
# Sets may run side by side: pipetask rewrites the chain from what it read a
# moment earlier, so two jobs starting together can drop one's RUN from it.
# Afterwards, whether pipetask succeeded or not, `gwprimo_flats.py
# relink-overscan` puts every RUN under OVERSCAN_COLLECTION/ that is missing
# from the chain back at its front, before the next step reads the chain. So a
# RUN taken out of the chain by hand comes back with the next overscan;
# `butler remove-runs` it instead.
#
# A few raws are unreadable (truncated files) and fail on every run, so the
# job's status comes from `gwprimo_flats.py overscan-gaps`, not from pipetask:
# 0 if at most OVERSCAN_MAX_MISSING_FRAC of the set's raws lack overscanRaw
# (the flat, verify and sky steps leave those out). A killed job (time limit)
# never gets there and fails as before; rerun this step to finish it.
#
#   overscan.sh [flat|sky]   (GWP_SET_CONF and GWP_CALIB_DIR come from run_calib.sh)

GWP_CALIB_DIR=${GWP_CALIB_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_CALIB_DIR/common.sh"
load_set
KIND=${1:-flat}
[[ $KIND == sky ]] && require_sky_selection
QUERY=$(step_query "$KIND") || exit 1
[[ $KIND == flat ]] && init_step overscan || init_step sky_overscan
DONE_RUNS=$(own_runs "$OVERSCAN_COLLECTION")

run_logged pipetask --long-log run --register-dataset-types -j "$NPROC" \
    ${DONE_RUNS:+--skip-existing-in "$DONE_RUNS"} \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i "$RAW_INPUTS" \
    -o "$OVERSCAN_COLLECTION" \
    --output-run "$OVERSCAN_COLLECTION/$SET/$KIND/$(date -u +%Y%m%dT%H%M%SZ)" \
    -p "$CP_PIPE_DIR/pipelines/DECam/RunIsrForCrosstalkSources.yaml" \
    -d "$QUERY"
prc=$?
[[ $prc -ne 0 ]] && log "WARNING: pipetask exited with status $prc; overscan-gaps decides whether enough overscanRaw exists" | tee -a "$LOGFILE"
run_logged python "$GWP_CALIB_DIR/gwprimo_flats.py" relink-overscan
rc=$?
run_logged python "$GWP_CALIB_DIR/gwprimo_flats.py" overscan-gaps --kind "$KIND" \
    --summary-file "$LOGDIR/gwprimo_calib_${SET}_${KIND}_overscan_gaps.txt" || rc=1
finish_step
exit $rc
