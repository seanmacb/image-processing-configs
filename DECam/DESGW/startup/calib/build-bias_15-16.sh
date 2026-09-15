#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpBias_15-16_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpBias_15-16_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

LOGFILE=$LOGDIR/cpBias_15-16.log

date | tee $LOGFILE
pipetask --long-log run --register-dataset-types -j 30 \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded \
-o DECam/calib/template/bias/15-16 \
-p $CP_PIPE_DIR/pipelines/DECam/cpBias.yaml \
-d "instrument='DECam' AND exposure.observation_type='zero' AND exposure.day_obs >= 20160101 AND exposure.day_obs <= 20160102" \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE
