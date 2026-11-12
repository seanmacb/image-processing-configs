#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apVerifyFakes_desgw_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/run_apVerifyFakes_desgw_%j.err

# Runs $AP_VERIFY_DIR/pipelines/DECam/ApVerifyWithFakes.yaml -- the DECam AP
# pipeline instrumented with lsst.verify metrics, with synthetic source
# injection -- against a real (non ap_verify-dataset) butler repo, the same
# way pilot/run-ap-pipe.sh runs the production desgw_ap_pipe.yaml. This is
# for checking pipeline performance/completeness metrics on a known
# injection set, not for producing search-ready DECam/search/<target> output.
#
# Edit TARGET_NAME (and DATAQUERY, if the visit/detector exclusions differ)
# before submitting; this is a template, not a script meant to run as-is.
#
# Prerequisites, same as desgw_ap_pipe.yaml (configs/desgw_ap_pipe.yaml):
#   (0) Median calibration products and goodSeeing template coadds must exist
#       for the data being processed.
#   (1) $AP_PIPE_DIR/pipelines/DECam/RunIsrForCrosstalkSources.yaml must have
#       already been run, producing the 'overscanRaw' crosstalk sources this
#       pipeline's isr step consumes (see ApVerifyWithFakes.yaml's header).
#   (2) An APDB must exist for this run, e.g.
#         apdb-cli create-sql "sqlite:////path/to/verify_association.db" apdb_config_verify.yaml
#         apdb-cli metadata set apdb_config_verify.yaml instrument DECam
#       Use a dedicated APDB/file here -- do not point APDB_CONFIG at the
#       production desgw_apdb one, or verify runs will pollute/consume from
#       the real search association history.
#   (3) The 'injection_catalog' that injectVisit consumes must already be
#       ingested (startup/injection/make_injection_catalog.sh +
#       ingest_injection_catalog.sh), and included in -i below.
#   (4) The pretrained RBTransiNet model package collection must be included
#       in -i (computeReliability/RBTransiNetTask resolves the model from the
#       input collections, not a config field).

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

TARGET_NAME=S250830bp
APDB_CONFIG=/shares/soares-santos.physik.uzh/ButlerProjects/desgw_apdb/apdb_config_verify.yaml
INJECTION_COLLECTION=u/smacbr/desgw/pilot/injection_catalog
MODEL_COLLECTION=pretrained_models/tac_cnn_lsstcam_2026-02-26

LOGFILE=$LOGDIR/run_apVerifyFakes_desgw_${TARGET_NAME}.log

date | tee $LOGFILE
# Update the data-query to match the query from the run_apdb call 
DATAQUERY="instrument='DECam' AND exposure.observation_type='science' AND exposure.target_name='LVK_S250830bp' AND detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229) AND NOT (detector=53 AND exposure=915609)"

# --no-raise-on-partial-outputs: see pilot/run-ap-pipe.sh -- calibrateImage's
# AnnotatedPartialOutputsError otherwise fails every downstream quantum of a
# visit over one bad detector. Kept here for the same reason.
pipetask --long-log run --register-dataset-types -j 30 \
--no-raise-on-partial-outputs \
--skip-existing \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib,skymaps,refcats/gen3,DECam/calib/template/${TARGET_NAME}/overscanRaw,${INJECTION_COLLECTION},DECam/templates/${TARGET_NAME},${MODEL_COLLECTION} \
-o DECam/verify/ap/${TARGET_NAME} \
-p $AP_VERIFY_DIR/pipelines/DECam/ApVerifyWithFakes.yaml \
-d "$DATAQUERY" \
-c "parameters:apdb_config=${APDB_CONFIG}" \
2>&1 | tee -a $LOGFILE

date | tee -a $LOGFILE
