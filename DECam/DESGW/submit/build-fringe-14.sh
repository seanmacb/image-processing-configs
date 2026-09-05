#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=90
#SBATCH --mem=472GB
#SBATCH --time=36:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringe_14_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringe_14_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

LOGFILE=$LOGDIR/cpFringe_14.log

date | tee $LOGFILE
pipetask --long-log run --register-dataset-types -j 90 \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib/template/overscanRaw,DECam/calib \
-o DECam/calib/fringe/14 \
-p $CP_PIPE_DIR/pipelines/DECam/cpFringe.yaml \
-d "instrument='DECam' AND exposure.observation_type='dome flat' AND exposure.day_obs >= 20140000 AND exposure.day_obs <= 20149999 AND band='z'" \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE
