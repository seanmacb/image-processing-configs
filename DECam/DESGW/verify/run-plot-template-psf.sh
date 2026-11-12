#!/usr/bin/bash -l
#SBATCH --job-name=templatePsfPlots
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=16GB
#SBATCH --time=00:30:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/templatePsfPlots_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/templatePsfPlots_%j.err

# Usage: sbatch run-plot-template-psf.sh [config.yaml] [plot_template_psf.py args]
#   e.g. sbatch run-plot-template-psf.sh
#        sbatch run-plot-template-psf.sh template_psf_events.yaml --events S250830bp,S250725j
#
# Makes the three template-PSF figures for every event in the config (default
# template_psf_events.yaml next to this script); see plot_template_psf.py. A relative
# config path is looked up in the current directory first, then next to this script.
# Needs the per-patch CSVs from run-measure-template-psf-bands.sh.

source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM

VERIFY_DIR=$IMAGE_PROC_CONFIG_DIR/verify
CONFIG=${1:-$VERIFY_DIR/template_psf_events.yaml}
[[ $# -gt 0 ]] && shift
if [[ ! -r $CONFIG && -r $VERIFY_DIR/$CONFIG ]]; then
    CONFIG=$VERIFY_DIR/$CONFIG
fi

date
python $VERIFY_DIR/plot_template_psf.py --config "$CONFIG" "$@"
STATUS=$?
date
exit $STATUS
