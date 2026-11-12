#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=120
#SBATCH --mem=472GB
#SBATCH --time=48:00:00
#SBATCH --array=0-3
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/quickTemplate_bestSeeing_DESGW_%A_%a.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/quickTemplate_bestSeeing_DESGW_%A_%a.err

# One array task per band (g r i z). The template pipeline has no cross-band
# dependencies, so each band is an independent pipetask run on its own
# 120-core / 472 GB node (116 workers, ~4 GB each).
#
# Each band writes to its own RUN collection,
# DECam/templates/bestSeeing_wide/<band>/<timestamp> (see OUTPUT below). Because
# `pipetask run -g` is given no -o, no CHAINED collection is created; there are
# only the bare RUNs. Chain them once all tasks finish (list the RUNs with
#   butler query-collections $REPO "DECam/templates/bestSeeing_wide/*"):
#   butler collection-chain $REPO DECam/templates/bestSeeing_wide \
#       DECam/templates/bestSeeing_wide/g/<ts> DECam/templates/bestSeeing_wide/r/<ts> \
#       DECam/templates/bestSeeing_wide/i/<ts> DECam/templates/bestSeeing_wide/z/<ts>
# (This name is deliberately not the event-area DECam/templates/
# pilotProc_bestSeeing_avoidCorrupted chain: collection-chain would redefine it.)
#
# Resuming after a timeout (or any interrupted run). Both options extend the
# existing RUN, skip quanta that already have all their outputs, and clobber
# the partial outputs of quanta that were killed mid-write:
#   sbatch --export=ALL,RESUME=1 build-template.sh
#       rebuilds a (smaller) graph that excludes finished quanta.
#   sbatch --export=ALL,RESUME_JOBID=<array job id of the timed-out run> build-template.sh
#       skips the graph build and reuses that run's saved graph,
#       $LOGDIR/buildTemplate-DESGW_<band>_<jobid>_<ITER>.qg.
# Do not change QuickTemplateBestSeeing.yaml (or QuickTemplate.yaml) between
# attempts: --extend-run refuses to continue a RUN whose recorded task configs
# differ.
#
# Visit selection: QuickTemplateBestSeeing.yaml swaps the upstream quantile
# selector for BestSeeingSelectVisitsTask, keeping at most 5 visits per patch
# and none with a visit-mean PSF FWHM above 1.5". Patches where no visit passes
# the cut get no template ("No good images found").
#
# Single-frame inputs: this script does not run isr or calibrateImage. It runs
# only the makeTemplate and makeMetrics subsets (consolidateVisitSummary, visit
# selection, warps, coadd, metrics) and reads the single-frame products from the
# earlier full-archive run, the latest RUN under DECam/templates/pilotProc/<band>/.
# That run is complete for g, r and z but only ~47% calibrated for i, so run
# complete-single-frame.sh for i first; its output RUN (if any) under
# DECam/templates/singleFrameCompletion/<band>/ is added to the inputs
# automatically. (--skip-existing-in is not used: the old run also holds
# selection and coadd outputs from the quantile selector, which would be reused
# instead of rebuilt.)
#
# Sky/time restriction: the whole archive by default, which is what the
# single-frame run covered. To restrict, e.g. to the S250830bp test box:
#   sbatch --export=ALL,EXTRA_QUERY="AND exposure.day_obs<20250829 AND (exposure.tracking_ra>315 AND exposure.tracking_ra<335) AND (exposure.tracking_dec>-80 AND exposure.tracking_dec<-75)" build-template.sh

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

set -o pipefail

BANDS=(g r i z)
BAND=${BANDS[${SLURM_ARRAY_TASK_ID:-0}]}
NPROC=120

ITER=3  # Bump for a fresh run; keep it unchanged when resuming (RESUME / RESUME_JOBID).
LOGFILE=$LOGDIR/buildTemplate-DESGW_${BAND}_${ITER}.log
QGRAPH=$LOGDIR/buildTemplate-DESGW_${BAND}_${SLURM_ARRAY_JOB_ID:-local}_${ITER}.qg
OUTPUT=DECam/templates/bestSeeing_wide/$BAND

# Where the single-frame products live (RUNs: <prefix>/<band>/<timestamp>).
SF_PREFIX=DECam/templates/pilotProc
SF_COMPLETION_PREFIX=DECam/templates/singleFrameCompletion
PIPELINE="$IMAGE_PROC_CONFIG_DIR/configs/QuickTemplateBestSeeing.yaml#makeTemplate,makeMetrics"

# Latest RUN under a collection prefix (timestamps sort chronologically).
latest_run() { butler query-collections $REPO "$1/*" | awk '$2=="RUN"{print $1}' | sort | tail -1; }

# RESUME_JOBID implies RESUME. With RESUME set, extend the existing RUN
# instead of starting a new one, and append to (not truncate) the band log.
[ -n "$RESUME_JOBID" ] && RESUME=1
EXTEND_FLAGS=""
RUN_ARGS=""
if [ -n "$RESUME" ]; then
    EXTEND_FLAGS="--extend-run --clobber-outputs"
    if [ -n "$RESUME_JOBID" ]; then
        QGRAPH=$LOGDIR/buildTemplate-DESGW_${BAND}_${RESUME_JOBID}_${ITER}.qg
        # Graphs saved by the first version of this script have no ITER suffix.
        [ -f "$QGRAPH" ] || QGRAPH=$LOGDIR/buildTemplate-DESGW_${BAND}_${RESUME_JOBID}.qg
    fi
    echo "=== RESUME (job ${SLURM_ARRAY_JOB_ID:-local}) ===" | tee -a $LOGFILE

    # Both `pipetask qgraph` and `pipetask run -g` need an explicit output
    # collection when --extend-run is given. (`run -g` loads the graph through
    # the same code as `qgraph`, which rejects --extend-run with no -o /
    # --output-run before it ever reads the RUN name from the graph header.)
    # There is no output chain to use with -o, because `pipetask run -g` only
    # ever creates the bare RUN, so name the band's latest existing RUN.
    # It must equal the RUN recorded in the graph; `run` errors out if not.
    EXISTING_RUN=$(latest_run $OUTPUT)
    if [ -z "$EXISTING_RUN" ]; then
        echo "ERROR: no existing RUN under $OUTPUT/ to resume" | tee -a $LOGFILE
        exit 1
    fi
    echo "Extending existing RUN $EXISTING_RUN" | tee -a $LOGFILE
    RUN_ARGS="--output-run $EXISTING_RUN"
else
    : > $LOGFILE
fi

date | tee -a $LOGFILE
echo "Band: $BAND  Output: $OUTPUT  Qgraph: $QGRAPH  Flags: $EXTEND_FLAGS" | tee -a $LOGFILE

# Exposure 915609 detector 53 has a truncated raw (cfitsio decompression error),
# so its ISR cannot succeed. Had isr run in this graph, that failure would block
# consolidateVisitSummary for the visit and with it selectTemplateCoaddVisits for
# every patch the visit overlaps. Kept excluded so the query matches the
# single-frame jobs.
DATAQUERY="instrument='DECam' AND exposure.observation_type='science' AND detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229) AND NOT (detector=53 AND exposure=915609) AND band='$BAND' AND exposure.science_program NOT IN ('2023B-851374','2024A-781233', '2024B-305328', '2025A-227091','2025B-485252') $EXTRA_QUERY"

# Build the quantum graph first and save it, so a failed or restarted run can
# reuse it. `pipetask qgraph` uses a read-only butler, so the four array tasks
# can build concurrently. The new-format .qg extension avoids a slow
# conversion to the old .qgraph format.
if [ -n "$RESUME_JOBID" ]; then
    # Reuse the saved graph from the interrupted run; nothing to build.
    if [ ! -f "$QGRAPH" ]; then
        echo "ERROR: $QGRAPH not found; check RESUME_JOBID=$RESUME_JOBID" | tee -a $LOGFILE
        exit 1
    fi
    echo "Reusing saved quantum graph $QGRAPH" | tee -a $LOGFILE
else
    # Single-frame products come from earlier runs rather than being recomputed.
    SF_RUN=$(latest_run $SF_PREFIX/$BAND)
    if [ -z "$SF_RUN" ]; then
        echo "ERROR: no single-frame RUN under $SF_PREFIX/$BAND/" | tee -a $LOGFILE
        exit 1
    fi
    INPUTS=DECam/defaults,$SF_RUN
    SF_COMPLETION_RUN=$(latest_run $SF_COMPLETION_PREFIX/$BAND)
    [ -n "$SF_COMPLETION_RUN" ] && INPUTS=$INPUTS,$SF_COMPLETION_RUN
    echo "Inputs: $INPUTS" | tee -a $LOGFILE

    # A fresh run writes a new timestamped RUN under the -o chain; a resume
    # extends the existing RUN named in RUN_ARGS (see above).
    pipetask --long-log qgraph $EXTEND_FLAGS \
    -b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
    -i $INPUTS \
    ${RUN_ARGS:--o $OUTPUT} \
    -p "$PIPELINE" \
    -d "$DATAQUERY" \
    -q $QGRAPH \
    2>&1 | tee -a $LOGFILE
    if [ $? -ne 0 ]; then
        echo "Quantum graph build failed for band $BAND" | tee -a $LOGFILE
        exit 1
    fi
fi

# Dataset types are registered here (the qgraph step is read-only). Stagger
# the array tasks so they do not all register at the same instant.
sleep $(( ${SLURM_ARRAY_TASK_ID:-0} * 30 ))

pipetask --long-log run -j $NPROC --register-dataset-types $EXTEND_FLAGS $RUN_ARGS \
--no-raise-on-partial-outputs \
-b $REPO \
-g $QGRAPH \
2>&1 | tee -a $LOGFILE
# pipefail makes this pipetask's exit status, not tee's. Exit with it so a
# failed run shows as FAILED in sacct instead of COMPLETED.
STATUS=$?

date | tee -a $LOGFILE
exit $STATUS
