#!/usr/bin/bash -l
#SBATCH --job-name=templatePsf
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=01:00:00
#SBATCH --array=0-2
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/templatePsf_%A_%a.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/templatePsf_%A_%a.err

# One array task per band (default g r i; z is left out until it is reprocessed).
#
# Usage: sbatch run-measure-template-psf-bands.sh <collection> <label> [measure_template_psf.py args]
#   e.g. sbatch run-measure-template-psf-bands.sh DECam/templates/bestSeeing_wide_gri bestSeeing_wide_gri
#
# Each task measures only its band and writes template_psf_per_patch.csv and
# template_psf_per_tract.csv to $LOGDIR/templatePsf/<label>/<band>/. A visit belongs to a
# single band, so splitting by band also keeps each worker's visit cache a third the size.
# Worker count follows --cpus-per-task above; each worker holds one Postgres connection.
#
# Different bands: BANDS="g r i z" sbatch --array=0-3 run-measure-template-psf-bands.sh ...
# (the array range must be 0..<number of bands>-1).
#
# The notebook takes one per-patch CSV, so once all tasks finish, concatenate them:
#   python -I -c "import glob, pandas as pd; d='$LOGDIR/templatePsf/<label>'; \
#   pd.concat(map(pd.read_csv, sorted(glob.glob(d+'/?/template_psf_per_patch.csv')))) \
#   .to_csv(d+'/template_psf_per_patch.csv', index=False)"
# and set PRECOMPUTED_CSV in evaluate_template_psf_quality.ipynb to the merged file.

COLLECTION=${1:?usage: sbatch run-measure-template-psf-bands.sh <collection> <label> [args]}
LABEL=${2:?usage: sbatch run-measure-template-psf-bands.sh <collection> <label> [args]}
shift 2

BANDS=(${BANDS:-g r i})
BAND=${BANDS[${SLURM_ARRAY_TASK_ID:?run through sbatch so the array index is set}]}
if [[ -z $BAND ]]; then
    echo "ERROR: array index $SLURM_ARRAY_TASK_ID is outside BANDS=(${BANDS[*]})" >&2
    exit 1
fi

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

OUTDIR=$LOGDIR/templatePsf/$LABEL/$BAND
mkdir -p $OUTDIR

echo "collection=$COLLECTION band=$BAND output=$OUTDIR"
date
python $IMAGE_PROC_CONFIG_DIR/verify/measure_template_psf.py \
--repo $REPO \
--collection $COLLECTION \
--bands $BAND \
--output-dir $OUTDIR \
--workers $SLURM_CPUS_PER_TASK \
"$@"
STATUS=$?
date
exit $STATUS
