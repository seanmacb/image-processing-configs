#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=120
#SBATCH --mem=472GB
#SBATCH --time=48:00:00
#SBATCH --array=0-3
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/quickTemplate_DESGW_%A_%a.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/quickTemplate_DESGW_%A_%a.err

# One array task per band (g r i z). The template pipeline has no cross-band
# dependencies, so each band is an independent pipetask run on its own
# 120-core / 472 GB node (116 workers, ~4 GB each).
#
# Each band writes to its own run collection, DECam/templates/pilotProc/<band>.
# Chain them once all tasks finish, e.g.:
#   butler collection-chain $REPO DECam/templates/pilotProc \
#       DECam/templates/pilotProc/{g,r,i,z}

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

set -o pipefail

BANDS=(g r i z)
BAND=${BANDS[${SLURM_ARRAY_TASK_ID:-0}]}
NPROC=120

LOGFILE=$LOGDIR/buildTemplate-DESGW_${BAND}.log
QGRAPH=$LOGDIR/buildTemplate-DESGW_${BAND}_${SLURM_ARRAY_JOB_ID:-local}.qg
OUTPUT=DECam/templates/pilotProc/$BAND

date | tee $LOGFILE
echo "Band: $BAND  Output: $OUTPUT  Qgraph: $QGRAPH" | tee -a $LOGFILE

DATAQUERY="instrument='DECam' AND exposure.observation_type='science' AND detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229) AND band='$BAND' AND exposure.science_program NOT IN ('2023B-851374','2024A-781233', '2024B-305328', '2025A-227091','2025B-485252')"

# Build the quantum graph first and save it, so a failed or restarted run can
# reuse it. `pipetask qgraph` uses a read-only butler, so the four array tasks
# can build concurrently. The new-format .qg extension avoids a slow
# conversion to the old .qgraph format.
pipetask --long-log qgraph \
--skip-existing-in DECam/templates \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/defaults \
-o $OUTPUT \
-p $IMAGE_PROC_CONFIG_DIR/configs/QuickTemplate.yaml \
-d "$DATAQUERY" \
-q $QGRAPH \
2>&1 | tee -a $LOGFILE
if [ $? -ne 0 ]; then
    echo "Quantum graph build failed for band $BAND" | tee -a $LOGFILE
    exit 1
fi

# Dataset types are registered here (the qgraph step is read-only). Stagger
# the array tasks so they do not all register at the same instant.
sleep $(( ${SLURM_ARRAY_TASK_ID:-0} * 30 ))

pipetask --long-log run -j $NPROC --register-dataset-types \
--no-raise-on-partial-outputs \
-b $REPO \
-g $QGRAPH \
2>&1 | tee -a $LOGFILE

date | tee -a $LOGFILE
