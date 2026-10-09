#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=116
#SBATCH --mem=472GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/build-overscanRaw-templates-DESGW_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/build-overscanRaw-templates-DESGW_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

LOGFILE=$LOGDIR/overscanRaw_template_DESGW_5.log

date | tee $LOGFILE
pipetask --long-log run --register-dataset-types -j 116 --extend-run --skip-existing-in DECam/overscanRaw/desgw --clobber-outputs \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded \
-o DECam/overscanRaw/desgw \
-p $CP_PIPE_DIR/pipelines/DECam/RunIsrForCrosstalkSources.yaml \
-d "instrument='DECam' and exposure.observation_type='science' AND band IN ('g','r','i','z')" \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE
