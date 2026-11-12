#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=120
#SBATCH --mem=472GB
#SBATCH --time=24:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_step0_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_step0_%j.err

# Step 0: the 'overscanRaw' crosstalk sources that step1's isr consumes
# (connections.crosstalkSources: overscanRaw), for every raw step1 will read.
# Same pipeline and inputs as DESGW/too_run/steps/build_overscan.sh; it
# cannot be a subset of gwprimo_drp.yaml because overscanRaw is a
# prerequisite input of isr there.
#
# Exposures that already have overscanRaw in OVERSCAN_SKIP_EXISTING_IN (the
# DESGW templates of the same sky, which DECam/defaults also contains) are
# skipped; step1 finds those through DECam/defaults.
#
#   step0.sh        (GWP_CONF and GWP_RUN_DIR come from the driver's --export)

GWP_RUN_DIR=${GWP_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_RUN_DIR/common.sh"
load_conf
init_step step0
: > "$STATUS_FILE"
# Also skip what earlier step0 runs built (plain --skip-existing would look
# only in the new, empty RUN).
DONE_RUNS=$(own_runs "$OVERSCAN_COLLECTION")

run_logged pipetask --long-log run --register-dataset-types -j "$NPROC" \
    --skip-existing-in "$OVERSCAN_SKIP_EXISTING_IN${DONE_RUNS:+,$DONE_RUNS}" \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i "$STEP0_INPUTS" \
    -o "$OVERSCAN_COLLECTION" \
    -p "$CP_PIPE_DIR/pipelines/DECam/RunIsrForCrosstalkSources.yaml" \
    -d "$STEP1_QUERY"
record_pipetask_status $? "pipetask(step0)"
finish_step
exit 0
