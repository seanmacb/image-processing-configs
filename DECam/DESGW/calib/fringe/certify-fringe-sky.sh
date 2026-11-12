#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16GB
#SBATCH --time=1:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/certify_fringe_sky_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/certify_fringe_sky_%j.err

# Replaces the certified z-band fringes in DECam/calib with the on-sky set.
#
#   sbatch certify-fringe-sky.sh             dry run: what would change
#   sbatch certify-fringe-sky.sh --confirm   do it
#
# Refuses unless every epoch (Y1-Y3 Y4 Y5 Y6-Y11) has a RUN with a fringe for
# all 62 detectors. With --confirm it first decertifies every z fringe in
# DECam/calib from 2012-09-11T12:00 on (today: the dome-flat sets fringe/14,
# 15-16, 17-18, 19-20, 21-22, 23-24, 25-26; their RUNs stay, so they can be
# re-certified), then certifies each epoch's newest RUN for its window
# (fringe_sky.py: contiguous, the last one open-ended).
#
# The RUNs are certified, not the DECam/calib/fringe/sky/<epoch> chains: those
# flatten to include DECam/calib itself.

HERE=/shares/soares-santos.physik.uzh/repos/image-processing-configs/DECam/DESGW/calib/fringe
source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS

python "$HERE/fringe_sky.py" certify "$@" 2>&1 | tee -a "$LOGDIR/certify_fringe_sky.log"
exit ${PIPESTATUS[0]}
