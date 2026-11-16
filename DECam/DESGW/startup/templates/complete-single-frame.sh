#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=120
#SBATCH --mem=472GB
#SBATCH --time=7-00:00:00
#SBATCH --array=2
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/singleFrameCompletion_DESGW_%A_%a.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/singleFrameCompletion_DESGW_%A_%a.err

# Finish the single-frame products (isr + calibrateImage) that the first
# full-archive run (RUNs DECam/templates/pilotProc/<band>/<ts>) did not produce,
# so that build-template.sh can take them as inputs. That run is complete for
# g, r and z (>99.9% of the images) but only ~47% calibrated for i, so the array
# defaults to task 2 (band i). Array index -> band: 0=g 1=r 2=i 3=z.
#
# Only the `singleFrame` subset runs. `--skip-existing-in` the old RUN skips every
# quantum that already succeeded there; the rest (including images that failed
# before, which may fail again) run into a new RUN,
#   DECam/templates/singleFrameCompletion/<band>/<timestamp>
# build-template.sh adds the latest such RUN to its inputs automatically. There is
# no CHAINED collection to make; build-template.sh looks the RUN up by name.
#
# Resume after a timeout (extends the latest completion RUN, skips finished
# quanta, clobbers partial outputs of quanta killed mid-write):
#   sbatch --export=ALL,RESUME=1 complete-single-frame.sh
# Do not change QuickTemplateBestSeeing.yaml between attempts.
#
# Use the same sky/time restriction as build-template.sh (EXTRA_QUERY, empty by
# default = whole archive), so that this job covers what that job will read.
#
# From scratch (FROM_SCRATCH=1): rerun every single-frame quantum, ignoring
# what the old pilotProc RUN already holds, and write a new RUN next to it,
#   DECam/templates/pilotProc/<band>/<timestamp>
# build-template.sh takes the latest RUN under that prefix, so it picks up the
# new one with no changes. The old RUN is left untouched. E.g. for z:
#   sbatch --array=3 --export=ALL,FROM_SCRATCH=1 complete-single-frame.sh
# Resume it with FROM_SCRATCH=1 and RESUME=1 together; that refuses to extend
# the original full-archive RUN (one holding template_coadd).

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

set -o pipefail

BANDS=(g r i z)
BAND=${BANDS[${SLURM_ARRAY_TASK_ID:-2}]}
NPROC=120

ITER=0  # Bump for a fresh run; keep it unchanged when resuming (RESUME).
SF_RUN_PREFIX=DECam/templates/pilotProc
if [ -n "$FROM_SCRATCH" ]; then
    LOGNAME_BASE=singleFrameScratch-DESGW_${BAND}
    OUTPUT=$SF_RUN_PREFIX/$BAND
else
    LOGNAME_BASE=singleFrameCompletion-DESGW_${BAND}
    OUTPUT=DECam/templates/singleFrameCompletion/$BAND
fi
LOGFILE=$LOGDIR/${LOGNAME_BASE}_${ITER}.log
QGRAPH=$LOGDIR/${LOGNAME_BASE}_${SLURM_ARRAY_JOB_ID:-local}_${ITER}.qg
PIPELINE="$IMAGE_PROC_CONFIG_DIR/configs/QuickTemplateBestSeeing.yaml#singleFrame"

# Latest RUN under a collection prefix (timestamps sort chronologically).
latest_run() { butler query-collections $REPO "$1/*" | awk '$2=="RUN"{print $1}' | sort | tail -1; }

if [ -n "$FROM_SCRATCH" ]; then
    # Nothing is reused from the old RUN: no --skip-existing-in, raws and
    # calibs only as inputs.
    SF_RUN=""
    INPUTS=DECam/defaults
    SKIP_FLAGS=""
else
    SF_RUN=$(latest_run $SF_RUN_PREFIX/$BAND)
    if [ -z "$SF_RUN" ]; then
        echo "ERROR: no single-frame RUN under $SF_RUN_PREFIX/$BAND/"
        exit 1
    fi
    INPUTS=DECam/defaults,$SF_RUN
    SKIP_FLAGS="--skip-existing-in $SF_RUN"
fi

EXTEND_FLAGS=""
RUN_ARGS=""
if [ -n "$RESUME" ]; then
    EXTEND_FLAGS="--extend-run --clobber-outputs"
    # --extend-run needs an explicit output collection (see build-template.sh).
    EXISTING_RUN=$(latest_run $OUTPUT)
    if [ -z "$EXISTING_RUN" ]; then
        echo "ERROR: no existing RUN under $OUTPUT/ to resume" | tee -a $LOGFILE
        exit 1
    fi
    # With FROM_SCRATCH the latest RUN under pilotProc/<band> could still be
    # the original full-archive run if the scratch job never got as far as
    # writing; extending that would clobber its outputs. It is the one with
    # coadds in it, which a singleFrame-only run never produces.
    if [ -n "$FROM_SCRATCH" ] && python -c "
import sys
from lsst.daf.butler import Butler
s = Butler('$REPO').registry.getCollectionSummary('$EXISTING_RUN')
sys.exit(0 if 'template_coadd' in s.dataset_types.names else 1)
"; then
        echo "ERROR: $EXISTING_RUN holds template_coadd, so it is the original run, not a scratch run; refusing to extend it" | tee -a $LOGFILE
        exit 1
    fi
    echo "=== RESUME (job ${SLURM_ARRAY_JOB_ID:-local}) extending $EXISTING_RUN ===" | tee -a $LOGFILE
    RUN_ARGS="--output-run $EXISTING_RUN"
else
    : > $LOGFILE
fi

date | tee -a $LOGFILE
echo "Band: $BAND  Output: $OUTPUT  From scratch: ${FROM_SCRATCH:-no}  Existing single-frame RUN: ${SF_RUN:-none}  Qgraph: $QGRAPH  Flags: $EXTEND_FLAGS $SKIP_FLAGS" | tee -a $LOGFILE

# Same query as build-template.sh. Exposure 915609 detector 53 has a truncated raw
# (cfitsio decompression error), so its ISR cannot succeed.
DATAQUERY="instrument='DECam' AND exposure.observation_type='science' AND detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229) AND NOT (detector=53 AND exposure=915609) AND band='$BAND' AND exposure.science_program NOT IN ('2023B-851374','2024A-781233', '2024B-305328', '2025A-227091','2025B-485252') $EXTRA_QUERY"

pipetask --long-log qgraph $EXTEND_FLAGS $SKIP_FLAGS \
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

pipetask --long-log run -j $NPROC --register-dataset-types $EXTEND_FLAGS $RUN_ARGS \
--no-raise-on-partial-outputs \
-b $REPO \
-g $QGRAPH \
2>&1 | tee -a $LOGFILE
# pipefail makes this pipetask's exit status, not tee's.
STATUS=$?

date | tee -a $LOGFILE
exit $STATUS
