#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/ingest_flat_17-18_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/ingest_flat_17-18_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

FLATFILES=/shares/soares-santos.physik.uzh/fitsFiles/calibs/flat/dome_flat_17-18/*.fits.fz
LOGFILE=$LOGDIR/ingest_flat_17-18.log

date | tee $LOGFILE
butler ingest-raws $REPO $FLATFILES --transfer link \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE
