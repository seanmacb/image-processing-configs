#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64GB
#SBATCH --time=01:00:00
#SBATCH --array=0-3
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apPipe_desgw_qgraph_%A_%a.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apPipe_desgw_qgraph_%A_%a.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

# The real culprit, isolated via six small diagnostic pipetask-qgraph runs
# (jobs 6146172/6146173/6146268/6146518/6146671/6146788) on 2026-09-19:
# the 56-term flat "OR of (detector=X AND visit=Y)" exclusion clause we'd
# added to DATAQUERY. A SINGLE visit with that clause alone OOM-killed at
# >64GB in 9 minutes; the same visit with a trivial query used 1.2GB in
# 68 seconds. Regrouping it by detector (56 terms -> 15) still blew past
# 32GB. It has nothing to do with --skip-existing-in, --clobber-outputs,
# or scope size (per-night sharding never had a chance to help, since the
# clause's cost doesn't depend on how many visits/nights are in scope) --
# this is a daf_butler query-expression-evaluation blowup on a large
# disjunctive boolean expression, unrelated to the AP pipeline itself.
#
# Fix: the exclusion clause is gone. The 56 injectVisit/13
# consolidateMatchAssocDiaSrc quanta it was avoiding will simply fail
# again during execution -- which is fine: --no-raise-on-partial-outputs
# and the default (non---fail-fast) executor already tolerate isolated
# task failures without blocking the rest of the run (that's exactly how
# the original 2026-09-17 run got 106,500/107,968 quanta done despite
# 1,468 failures). Re-excluding them would need a cheaper mechanism than
# an inline DATAQUERY clause (e.g. graph-editing after a cheap build, or
# an upstream code fix) -- not attempted here.
#
# Per-night sharding is kept as a cheap safety margin (four small builds
# in parallel beat one big one), and --mem dropped back down since the
# actual cost driver is gone; diagnostics never pushed a full night past
# single-digit GB once the exclusion clause was removed.
#
# Also still fixing the false-success bug from the previous version: it
# printed "Saved quantum graph..." unconditionally with no exit-status
# check, so an OOM-killed build (job 6098548) claimed success while
# $QGRAPHDIR was empty.
DAY_OBS_LIST=(20250831 20250905 20250913 20250924)
DAY_OBS=${DAY_OBS_LIST[$SLURM_ARRAY_TASK_ID]}

LOGFILE=$LOGDIR/run_apPipe_desgw_S250830bp_${DAY_OBS}.log
QGRAPHDIR=$REPO/qgraphs
QGRAPH=$QGRAPHDIR/desgw_ap_pipe_S250830bp_afterburn_${DAY_OBS}.qgraph
mkdir -p $QGRAPHDIR

date | tee -a $LOGFILE
DATAQUERY="instrument='DECam' AND exposure.observation_type='science' AND exposure.target_name='LVK_S250830bp' AND exposure.day_obs=$DAY_OBS AND detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229) AND NOT (detector=53 AND exposure=915609)"

pipetask qgraph \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib,skymaps,refcats/gen3,DECam/calib/template/S250830bp/overscanRaw,u/smacbr/desgw/pilot/injection_catalog,DECam/templates/S250830bp,pretrained_models/tac_cnn_lsstcam_2026-02-26 \
-o DECam/search/S250830bp \
--extend-run \
-p $IMAGE_PROC_CONFIG_DIR/configs/desgw_ap_pipe.yaml \
-d "$DATAQUERY" \
--skip-existing-in DECam/search/S250830bp/20260916T223122Z \
--clobber-outputs \
--qgraph-datastore-records \
-q $QGRAPH \
2>&1 | tee -a $LOGFILE
PIPETASK_STATUS=${PIPESTATUS[0]}

date | tee -a $LOGFILE
if [ $PIPETASK_STATUS -ne 0 ]; then
    echo "FAILED building qgraph for day_obs=$DAY_OBS (pipetask exit $PIPETASK_STATUS); $QGRAPH was NOT written." | tee -a $LOGFILE
    exit 1
fi
echo "Saved quantum graph to $QGRAPH -- submit run-ap-pipe-afterburn-execute.sh next." | tee -a $LOGFILE
