#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=92
#SBATCH --mem=700GB
#SBATCH --time=5-00:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_step3_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_step3_%j.err

# Step 3: coaddition and multiband measurement for the patches that touch
# REGION: warps, deep coadds, detection, scarlet deblending, measurement,
# forced photometry (GAaP, PSF, CModel, Kron), MultiProFit fits and the
# object tables.
#
# Runs with NPROC_STEP3 workers (default: allocated memory / 8.8 GB, at most
# the CPUs, so 81 on the 92-CPU, 700 GB nodes this requests): the multiband
# deblender and MultiProFit hold all bands of a patch at once and need
# roughly twice the ~4 GB per worker of steps 1-2.
#
#   step3.sh        (GWP_CONF and GWP_RUN_DIR come from the driver's --export)

GWP_RUN_DIR=${GWP_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_RUN_DIR/common.sh"
load_conf
init_step step3
: > "$STATUS_FILE"

pipetask_drp step3 "$STEP3_QUERY" "$NPROC_STEP3"
record_pipetask_status $? "pipetask(step3)"
finish_step
exit 0
