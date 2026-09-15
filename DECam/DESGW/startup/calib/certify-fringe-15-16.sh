#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16GB
#SBATCH --time=1:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/certify_fringe_15-16_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/certify_fringe_15-16_%j.err

# Certifies the 2015-2016 z-band fringe set into DECam/calib.
#
# Run this only once complete-fringe-15-16.sh has brought the run to all 62
# detectors - certifying a partial set would leave ISR silently without a fringe
# for the missing ones.
#
# The validity window closes the gap between the two ranges already certified in
# DECam/calib:
#   fringe/14     [2014-01-01, 2014-12-31T23:59:59)
#   fringe/17-18  [2017-01-01, 2018-12-31T23:59:59)
#
# The input is the RUN, not the DECam/calib/fringe/15-16 chain: that chain
# flattens to include DECam/calib itself, whose overlapping validity ranges make
# an untimestamped fringe lookup ambiguous.

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

RUN=DECam/calib/fringe/15-16/20260906T164233Z

butler certify-calibrations $REPO $RUN DECam/calib fringe \
  --begin-date 2015-01-01T00:00:00 --end-date 2016-12-31T23:59:59
