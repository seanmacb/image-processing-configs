#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_step1_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_step1_%j.err

# Step 1: single-frame processing (isr, calibrateImage, transformPreSourceTable)
# of every detector of every visit whose footprint touches REGION.
#
#   step1.sh        (GWP_CONF and GWP_RUN_DIR come from the driver's --export)

GWP_RUN_DIR=${GWP_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_RUN_DIR/common.sh"
load_conf
init_step step1
: > "$STATUS_FILE"

pipetask_drp step1 "$STEP1_QUERY" "$NPROC"
record_pipetask_status $? "pipetask(step1)"
finish_step
exit 0
