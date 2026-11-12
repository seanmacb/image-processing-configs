#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=36:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringeSky_%x_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringeSky_%x_%j.err

# z-band fringe frames of one epoch from on-sky science exposures.
#
#   sbatch -J Y4 build-fringe-sky.sh Y4        (epochs: Y1-Y3 Y4 Y5 Y6-Y11)
#
# The epochs, their exposure selection and their validity windows are defined
# in fringe_sky.py (see its docstring). This job reads <epoch>.exposures, which
# `python fringe_sky.py select` writes; run that first and commit the lists, so
# a rebuild uses the same exposures.
#
# 1. overscanRaw for the epoch's exposures (RunIsrForCrosstalkSources): ISR's
#    crosstalk correction reads every detector of the exposure from it.
#    DECam/overscanRaw/desgw (EXISTING_OVERSCAN) already holds it for all z
#    science raws in the repo as of 2026-11; DECam/calib/template/overscanRaw/*
#    cover dome flats only. Anything missing from EXISTING_OVERSCAN and from
#    earlier runs of OVERSCAN_COLLECTION is made into
#    OVERSCAN_COLLECTION/<epoch>/<UTC time>, so this step is normally a no-op.
# 2. Raws overscan could not read (truncated files, "CCD not read out" stubs)
#    are left out of the fringe query, in CNF (fringe_sky.py overscan-gaps): a
#    failed cpFringeIsr quantum makes pipetask skip that detector's combine.
# 3. cpFringe with configs/desgw_cpFringeSky.yaml into
#    DECam/calib/fringe/sky/<epoch>. If that chain already has a RUN, the job
#    extends it (--extend-run --skip-existing) so a job that hit its time limit
#    resumes; FRINGE_FRESH=1 in the environment starts a new RUN instead.
# 4. fringe_sky.py check: a fringe for all 62 detectors, or the job fails.
#
# Certification is separate, once every epoch has passed its check:
# certify-fringe-sky.sh.

EPOCH=${1:?usage: build-fringe-sky.sh <epoch>   (Y1-Y3 Y4 Y5 Y6-Y11)}
HERE=/shares/soares-santos.physik.uzh/repos/image-processing-configs/DECam/DESGW/calib/fringe
NPROC=${SLURM_CPUS_PER_TASK:-30}

# DESGW_CONFIGS loads the stack and sets up the DESGW obs_decam fork. Do not
# `setup lsst_distrib` again afterwards: that would put back the stack's obs_decam.
source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS

OVERSCAN_COLLECTION=DECam/calib/template/overscanRaw/fringe-sky
EXISTING_OVERSCAN=DECam/overscanRaw/desgw
FRINGE_COLLECTION=DECam/calib/fringe/sky/$EPOCH
PIPELINE=$IMAGE_PROC_CONFIG_DIR/configs/desgw_cpFringeSky.yaml
INPUTS=DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib
LOGFILE=$LOGDIR/cpFringeSky_$EPOCH.log

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOGFILE"; }

: > "$LOGFILE"
QUERY=$(python "$HERE/fringe_sky.py" query "$EPOCH") || { log "ERROR: no exposure list for $EPOCH"; exit 1; }
log "epoch $EPOCH: $(grep -cv '^#' "$HERE/$EPOCH.exposures") exposures from $HERE/$EPOCH.exposures"

# 1. overscanRaw
DONE_RUNS=$(butler query-collections "$REPO" "$OVERSCAN_COLLECTION/*" --collection-type RUN --chains no 2>/dev/null \
            | awk 'NR>2 {print $1}' | paste -sd, -)
DONE_RUNS=$EXISTING_OVERSCAN${DONE_RUNS:+,$DONE_RUNS}
log "overscanRaw into $OVERSCAN_COLLECTION, skipping what exists in $DONE_RUNS"
pipetask --long-log run --register-dataset-types -j "$NPROC" \
    --skip-existing-in "$DONE_RUNS" \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i "$INPUTS" \
    -o "$OVERSCAN_COLLECTION" \
    --output-run "$OVERSCAN_COLLECTION/$EPOCH/$(date -u +%Y%m%dT%H%M%SZ)" \
    -p "$CP_PIPE_DIR/pipelines/DECam/RunIsrForCrosstalkSources.yaml" \
    -d "$QUERY" \
    2>&1 | tee -a "$LOGFILE"
log "overscan pipetask exit status ${PIPESTATUS[0]} (overscan-gaps decides whether to go on;" \
    "an empty quantum graph, i.e. nothing left to make, also exits non-zero)"
# OVERSCAN_COLLECTION only exists once a run has made something.
OVERSCAN_IN=$EXISTING_OVERSCAN
butler query-collections "$REPO" "$OVERSCAN_COLLECTION" 2>/dev/null | awk 'NR>2' | grep -q . \
    && OVERSCAN_IN=$OVERSCAN_COLLECTION,$EXISTING_OVERSCAN

# 2. leave out raws without overscanRaw
GAPS=$(mktemp)
python "$HERE/fringe_sky.py" overscan-gaps "$EPOCH" --collection "$OVERSCAN_IN" --where-out "$GAPS" \
    2>&1 | tee -a "$LOGFILE"
[[ ${PIPESTATUS[0]} -eq 0 ]] || { log "ERROR: overscan incomplete, not building the fringe"; rm -f "$GAPS"; exit 1; }
[[ -s $GAPS ]] && QUERY+=" AND $(cat "$GAPS")"
rm -f "$GAPS"

# 3. cpFringe
RESUME=()
if [[ ${FRINGE_FRESH:-0} != 1 ]] && butler query-collections "$REPO" "$FRINGE_COLLECTION/*" --collection-type RUN \
        --chains no 2>/dev/null | awk 'NR>2' | grep -q .; then
    RESUME=(--extend-run --skip-existing)
    log "resuming the newest RUN of $FRINGE_COLLECTION (FRINGE_FRESH=1 starts a new RUN)"
fi
log "cpFringe ($PIPELINE) into $FRINGE_COLLECTION"
pipetask --long-log run --register-dataset-types -j "$NPROC" \
    "${RESUME[@]}" \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i "$INPUTS,$OVERSCAN_IN" \
    -o "$FRINGE_COLLECTION" \
    -p "$PIPELINE" \
    -d "$QUERY" \
    2>&1 | tee -a "$LOGFILE"
log "cpFringe pipetask exit status ${PIPESTATUS[0]}"

# 4. completeness
python "$HERE/fringe_sky.py" check --epochs "$EPOCH" 2>&1 | tee -a "$LOGFILE"
rc=${PIPESTATUS[0]}
log "done (check exit status $rc)"
exit $rc
