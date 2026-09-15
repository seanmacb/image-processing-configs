#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/build-overscanRaw-templates-S250830bp%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/build-overscanRaw-templates-S250830bp%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

LOGFILE=$LOGDIR/overscanRaw_template_S250830bp.log

date | tee $LOGFILE
pipetask --long-log run --register-dataset-types -j 30 \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded \
-o DECam/calib/template/S250830bp/overscanRaw \
-p $CP_PIPE_DIR/pipelines/DECam/RunIsrForCrosstalkSources.yaml \
-d "instrument='DECam' AND exposure.observation_type='science' AND exposure.day_obs<20250829 AND (tracking_ra>315 AND tracking_ra<335) AND (tracking_dec>-80 AND tracking_dec<-75)" \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE
