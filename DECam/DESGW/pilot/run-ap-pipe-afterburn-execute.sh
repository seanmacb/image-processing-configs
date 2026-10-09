#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH --array=0-3
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apPipe_desgw_%A_%a.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apPipe_desgw_%A_%a.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

# Matches the per-night sharding in run-ap-pipe-afterburn.sh -- one array
# task per saved qgraph, so all four nights execute in parallel instead
# of one job trying to run the whole survey's graph serially.
DAY_OBS_LIST=(20250831 20250905 20250913 20250924)
DAY_OBS=${DAY_OBS_LIST[$SLURM_ARRAY_TASK_ID]}

LOGFILE=$LOGDIR/run_apPipe_desgw_S250830bp_${DAY_OBS}.log
QGRAPH=$REPO/qgraphs/desgw_ap_pipe_S250830bp_afterburn_${DAY_OBS}.qgraph

if [ ! -f "$QGRAPH" ]; then
    echo "ERROR: $QGRAPH not found -- run run-ap-pipe-afterburn.sh (the build step) first, and confirm it actually reported success for day_obs=$DAY_OBS (check its log for a FAILED line, not just that it ran)." | tee -a $LOGFILE
    exit 1
fi

date | tee -a $LOGFILE

# Execution-only step, run from the graph saved by run-ap-pipe-afterburn.sh.
# -g supersedes -i/-p/-d (the pipeline and data query are already baked
# into the saved graph); -b/-o/--extend-run are still required so pipetask
# knows where to write outputs.
#
# --no-raise-on-partial-outputs: calibrateImage wraps AlgorithmError failures
# (aperture correction, PSF shapelets) in AnnotatedPartialOutputsError. By
# default that propagates as a hard failure, which marks every downstream
# quantum of the same VISIT as FAILED_DEP -- one bad detector out of 60 loses
# the whole visit's warps and coadds. With this flag the quantum is a qualified
# success instead, so nothing is blocked; the partial image itself is then
# de-selected by PsfWcsSelectImagesTask (no WCS/photoCalib) and never reaches
# the coadd. Verified on tract 308 / patch 10 z-band: the coadd built this way
# is bit-identical to one built by running calibrateImage and the coadd tasks
# as two separate pipetask invocations.
pipetask --long-log run -g $QGRAPH \
-b $REPO \
-o DECam/search/S250830bp \
--extend-run \
--clobber-outputs \
--register-dataset-types \
--no-raise-on-partial-outputs \
-j 30 \
2>&1 | tee -a $LOGFILE
PIPETASK_STATUS=${PIPESTATUS[0]}

date | tee -a $LOGFILE
if [ $PIPETASK_STATUS -ne 0 ]; then
    echo "pipetask run exited $PIPETASK_STATUS for day_obs=$DAY_OBS." | tee -a $LOGFILE
    exit 1
fi
