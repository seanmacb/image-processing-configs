#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_overscan_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_overscan_%j.err

# Build the 'overscanRaw' crosstalk sources that the ISR step of both the
# template and AP pipelines consumes (connections.crosstalkSources: overscanRaw).
# Same pipeline as pilot/build-overscanRaw-templates-S250830bp.sh.
#
# Both phases and every night write to the one chain $OVERSCAN_COLLECTION: each
# run adds a new RUN to the chain, and --skip-existing skips what an earlier run
# already produced, so the AP pipeline finds its inputs there. The -i list must
# stay identical between runs because pipetask rejects an existing output chain
# whose inputs differ.
#
#   build_overscan.sh <templates|search>

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" overscan

run_logged pipetask --long-log run --register-dataset-types -j "$NPROC" \
    --skip-existing \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded \
    -o "$OVERSCAN_COLLECTION" \
    -p "$CP_PIPE_DIR/pipelines/DECam/RunIsrForCrosstalkSources.yaml" \
    -d "$PHASE_QUERY AND $DET_EXCL"
record_pipetask_status $? "pipetask (overscanRaw)"
finish_step
exit 0
