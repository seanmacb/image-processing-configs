#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=90
#SBATCH --mem=472GB
#SBATCH --time=36:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringe_15-16_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringe_15-16_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

LOGFILE=$LOGDIR/cpFringe_15-16.log

# Ten (exposure, detector) raws in the 2016-06-01 dome-flat sequence are DECam
# "CCD not read out" placeholders: 100x100 HDUs of constant 32768 rather than the
# real 2160x4146 frame. IsrTask skips overscan on every amp of such a stub and
# then dies with UnboundLocalError on 'noiseProvenanceString' in
# defineEffectivePtc, taking that detector's cpFringeCombine and both mosaics
# down with it. The stubs hold no signal, so drop them; each affected detector
# still combines 82 exposures instead of 83.
#
# Keep this in CNF - the NOT((exposure=X AND detector=Y) OR ...) form makes the
# butler predicate normalizer expand De Morgan combinatorially and hit MemoryError.
STUBS="\
 AND (exposure != 546380 OR detector NOT IN (7)) \
 AND (exposure != 546382 OR detector NOT IN (8, 38)) \
 AND (exposure != 546383 OR detector NOT IN (42)) \
 AND (exposure != 546385 OR detector NOT IN (18)) \
 AND (exposure != 546389 OR detector NOT IN (50)) \
 AND (exposure != 546390 OR detector NOT IN (9, 22)) \
 AND (exposure != 546393 OR detector NOT IN (30)) \
 AND (exposure != 546396 OR detector NOT IN (23))"

DATAQUERY="instrument='DECam' AND exposure.observation_type='dome flat' \
AND exposure.day_obs >= 20150000 AND exposure.day_obs <= 20169999 AND band='z'$STUBS"

date | tee $LOGFILE
pipetask --long-log run --register-dataset-types -j 90 \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib/template/overscanRaw,DECam/calib \
-o DECam/calib/fringe/15-16 \
-p $CP_PIPE_DIR/pipelines/DECam/cpFringe.yaml \
-d "$DATAQUERY" \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE
