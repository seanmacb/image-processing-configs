#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apPipe_desgw_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apPipe_desgw_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

LOGFILE=$LOGDIR/run_apPipe_desgw_S250830bp.log

date | tee $LOGFILE
DATAQUERY="instrument='DECam' AND exposure.observation_type='science' AND exposure.target_name='LVK_S250830bp' AND detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229) AND NOT (detector=53 AND exposure=915609)"

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
pipetask --long-log run --register-dataset-types -j 30 \
--no-raise-on-partial-outputs \
--skip-existing \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib,skymaps,refcats/gen3,DECam/calib/template/S250830bp/overscanRaw,u/smacbr/desgw/pilot/injection_catalog,DECam/templates/S250830bp,pretrained_models/tac_cnn_lsstcam_2026-02-26 \
-o DECam/search/S250830bp \
-p $IMAGE_PROC_CONFIG_DIR/configs/desgw_ap_pipe.yaml \
-d "$DATAQUERY" \
2>&1 | tee -a $LOGFILE

date | tee -a $LOGFILE
