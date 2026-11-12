#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=04:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/templatePsf_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/templatePsf_%j.err

# Usage: sbatch run-measure-template-psf.sh <event> [extra measure_template_psf.py args]
#   e.g. sbatch run-measure-template-psf.sh S250830bp
#        sbatch run-measure-template-psf.sh S250830bp --tracts 195,196 --bands i,z
#
# Reads DECam/templates/<event> and writes template_psf_per_patch.csv and
# template_psf_per_tract.csv to $LOGDIR/templatePsf/<event>/. Worker count follows
# --cpus-per-task above; each worker holds one Postgres connection.

EVENT=${1:?usage: sbatch run-measure-template-psf.sh <event> [measure_template_psf.py args]}
shift

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

OUTDIR=$LOGDIR/templatePsf/$EVENT
mkdir -p $OUTDIR
LOGFILE=$LOGDIR/templatePsf-$EVENT.log

date | tee $LOGFILE
python $IMAGE_PROC_CONFIG_DIR/verify/measure_template_psf.py \
--repo $REPO \
--collection DECam/templates/pilotProc_bestSeeing_avoidCorrupted \
--output-dir $OUTDIR \
"$@" \
2>&1 | tee -a $LOGFILE
date | tee -a $LOGFILE

# --collection DECam/templates/$EVENT \
