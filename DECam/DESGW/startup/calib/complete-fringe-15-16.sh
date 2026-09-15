#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=64GB
#SBATCH --time=2:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringe_15-16_complete_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/cpFringe_15-16_complete_%j.err

# Completes the 2015-2016 z-band fringe set after the initial build-fringe-15-16.sh
# run finished with 52/62 detectors.
#
# Ten (exposure, detector) raws in the 2016-06-01 dome-flat sequence are DECam
# "CCD not read out" placeholders: 100x100 pixel HDUs filled with the constant
# 32768 instead of the real 2160x4146 frame. IsrTask skips overscan for every amp
# of such a stub (the amp bboxes are not contained in the 100x100 exposure bbox)
# and then raises UnboundLocalError on 'noiseProvenanceString' in
# defineEffectivePtc, because that name is only bound inside a
# zip(amps, overscans) loop that never iterates. The ten crashes cascaded to
# FAILED_DEP on cpFringeCombine/Bin8/Bin64 for their detectors and on both mosaics.
#
# There is nothing to recover from those stubs - they contain no signal. Excluding
# them lets cpFringeCombine run on the remaining 82 exposures per affected
# detector (the other 52 detectors used 83), which is a 1.2% change in input
# count and scientifically equivalent.
#
# Every cpFringeIsr/cpFringeMeasure output already exists, so --extend-run
# --skip-existing reduces this to 32 quanta: 10 combine, 10+10 binning, 2 mosaics.

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

LOGFILE=$LOGDIR/cpFringe_15-16_complete.log

# Written in CNF. The equivalent NOT((exposure=X AND detector=Y) OR ...) form
# makes the butler predicate normalizer expand De Morgan combinatorially and die
# with MemoryError, so keep the per-exposure negations AND-ed as below.
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
pipetask --long-log run --register-dataset-types -j 10 \
--extend-run --skip-existing \
-b $REPO --instrument lsst.obs.decam.DarkEnergyCamera \
-i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib/template/overscanRaw,DECam/calib \
-o DECam/calib/fringe/15-16 \
-p $CP_PIPE_DIR/pipelines/DECam/cpFringe.yaml \
-d "$DATAQUERY" \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE
