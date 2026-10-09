#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32GB
#SBATCH --time=04:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apPipe_desgw_magBins_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apPipe_desgw_magBins_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

LOGFILE=$LOGDIR/run_apPipe_desgw_S250830bp_magBins.log

date | tee $LOGFILE
DATAQUERY="instrument='DECam' AND exposure.observation_type='science' AND exposure.target_name='LVK_S250830bp' AND detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229) AND NOT (detector=53 AND exposure=915609)"

# Task subset (#analyzeAssocDiaFakesDetectorVisitMagBins,...) restricts this
# run to just the two 1-mag-bin analysis tasks added to desgw_ap_pipe.yaml.
# Both only read the fakes_{coaddName}Diff_matchAssocDiaSrc /
# ..._matchAssocDiaSourceTable tables a prior full run of this same pipeline
# already wrote into the -o chain, so no upstream tasks (isr, calibrateImage,
# associateApdb, ...) are rerun -- --register-dataset-types is still needed
# since numFoundFakesDiaMag*Metric is a new dataset type from this addition.
pipetask --long-log run --register-dataset-types -j 8 \
--skip-existing \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib,skymaps,refcats/gen3,DECam/calib/template/S250830bp/overscanRaw,u/smacbr/desgw/pilot/injection_catalog,DECam/templates/S250830bp,pretrained_models/tac_cnn_lsstcam_2026-02-26 \
-o DECam/search/S250830bp \
-p "$IMAGE_PROC_CONFIG_DIR/configs/desgw_ap_pipe.yaml#analyzeAssocDiaFakesDetectorVisitMagBins,analyzeAssocDiaFakesVisitMagBins" \
-d "$DATAQUERY" \
2>&1 | tee -a $LOGFILE

date | tee -a $LOGFILE
