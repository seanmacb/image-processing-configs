#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/quickTemplate_S250830bp_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/quickTemplate_S250830bp_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

LOGFILE=$LOGDIR/buildTemplate-S250830bp.log

date | tee $LOGFILE
DATAQUERY="instrument='DECam' AND exposure.observation_type='science' AND exposure.day_obs<20250829 AND (tracking_ra>315 AND tracking_ra<335) AND (tracking_dec>-80 AND tracking_dec<-75) AND detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229) AND NOT (detector=53 AND exposure=915609)"

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
--skip-existing-in DECam/templates/S250830bp \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib,DECam/calib/template/S250830bp/overscanRaw,skymaps,refcats/gen3 \
-o DECam/templates/S250830bp \
-p $IMAGE_PROC_CONFIG_DIR/configs/QuickTemplate.yaml \
-d "$DATAQUERY" \
2>&1 | tee -a $LOGFILE

date | tee -a $LOGFILE
