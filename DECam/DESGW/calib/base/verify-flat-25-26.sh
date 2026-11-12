#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=64GB
#SBATCH --time=36:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpVerifyFlat_25-26_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpVerifyFlat_25-26_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

# desgw_verify_{bias,flat}.yaml retargets IsrTask's isrStats subtask to a
# real class (configs/desgw_isr_statistics.py, the DECam MJD-backfill fix --
# see that yaml for why). pipetask multiprocessing always spawns fresh
# worker processes, so that class has to be importable there too.
export PYTHONPATH=$IMAGE_PROC_CONFIG_DIR/configs:$PYTHONPATH

LOGFILE=$LOGDIR/cpVerifyFlat_25-26.log

date | tee $LOGFILE

# Every previous run of this era predates the working MJD-backfill fix (see
# desgw_verify_{bias,flat}.yaml): verifyBiasDet/verifyFlatDet crashed on
# every single quantum, so nothing in any prior RUN under this -o chain is
# usable -- not even the ones SLURM reported as COMPLETED. That includes an
# earlier fix attempt that looked fine in a single-process (-j 1) smoke test
# but silently didn't work here at -j >1, since pipetask multiprocessing
# always spawns fresh worker processes. Deliberately NOT using --extend-run:
# it would try to reuse those broken RUNs, and verifyBiasIsr's/
# verifyFlatIsr's config has changed since, which pipetask would flag as a
# mismatch against what those RUNs already have recorded. A plain -o starts
# a fresh RUN under the same chain instead.
pipetask --long-log run --register-dataset-types -j 30 \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib \
-o DECam/calib/verify/flat/25-26 \
-p $IMAGE_PROC_CONFIG_DIR/configs/desgw_verify_flat.yaml \
-d "instrument='DECam' AND exposure.observation_type='dome flat' AND exposure.day_obs >= 20250000 AND exposure.day_obs <= 20261100 AND band in ('g','r','i','z')" \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE
