#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/ingest_bias_14_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/ingest_bias_14_%j.err

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c

BIASFILES=/shares/soares-santos.physik.uzh/fitsFiles/calibs/bias/zero_14/*.fits.fz
LOGFILE=$LOGDIR/ingest_bias_14.log

date | tee $LOGFILE
butler ingest-raws $REPO $BIASFILES --transfer link \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE
