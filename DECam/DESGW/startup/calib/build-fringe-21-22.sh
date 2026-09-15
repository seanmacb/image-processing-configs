#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=36:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringe_21-22_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringe_21-22_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

LOGFILE=$LOGDIR/cpFringe_21-22.log

date | tee $LOGFILE
pipetask --long-log run --register-dataset-types -j 30  \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/calib/fringe/21-22/20260909T202527Z \
-o DECam/calib/fringe/21-22_finalize \
-p $CP_PIPE_DIR/pipelines/DECam/cpFringe.yaml#cpFringeMeasure,cpFringeCombine \
-d "instrument='DECam' AND exposure.observation_type='dome flat' AND exposure.day_obs >= 20210000 AND exposure.day_obs <= 20229999 AND band='z' AND detector IN (40,46)" \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE

#-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib/template/overscanRaw/21-22,DECam/calib,DECam/calib/flat/21-22,DECam/calib,DECam/calib/fringe/21-22\

