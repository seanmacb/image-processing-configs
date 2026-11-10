#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64GB
#SBATCH --time=06:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/templateCoaddAnalysis_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/templateCoaddAnalysis_%j.err

# Run template_coadd_analysis.yaml (subset template_coadd_qa) on a template
# collection. See README.md in this directory.
#
# All settings are environment variables (pass with sbatch --export=ALL,VAR=...):
#   INPUT_COLLECTION  template RUN/CHAINED collection
#                     (default DECam/templates/bestSeeing_wide/g/20261027T133747Z)
#   TRACT             one tract id, or empty for all tracts in the collection
#   BAND              one band, or empty for all bands in the collection
#   SKYMAP            skymap name (default decam_rings_v1; needed for tract constraints)
#   SKYMAP_COLLECTION collection holding the skyMap dataset, appended to the inputs
#                     (default skymaps; template RUNs do not contain it)
#   OUTPUT            output RUN collection (default
#                     DECam/templates/analysis/<input minus DECam/templates/ and its
#                     trailing timestamp>/<UTC timestamp>)
#   MODE              qgraph (build + save graph only) or run (default run)
#   JOBS              pipetask -j (default: SLURM_CPUS_PER_TASK or 8)
#
# Examples:
#   MODE=qgraph TRACT=4250 BAND=g bash template_coadd_analysis.sh
#   sbatch --export=ALL,BAND=g template_coadd_analysis.sh
#
# Requires the upstream makeMetrics outputs (template_coadd_depth_summary_metrics,
# template_coadd_tract_mask_fraction_metrics) in INPUT_COLLECTION; tracts without
# them are simply absent from the tables and whole-sky plots.

# The stack's activate hooks reference unset variables, so strict mode is only
# switched on after the environment is loaded.
source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
set -euo pipefail

HERE=$IMAGE_PROC_CONFIG_DIR/analysis
PIPELINE="$HERE/template_coadd_analysis.yaml#template_coadd_qa"

INPUT_COLLECTION=${INPUT_COLLECTION:-DECam/templates/bestSeeing_wide/g/20261027T133747Z}
TRACT=${TRACT:-}
BAND=${BAND:-}
SKYMAP=${SKYMAP:-decam_rings_v1}
SKYMAP_COLLECTION=${SKYMAP_COLLECTION:-skymaps}
MODE=${MODE:-run}
JOBS=${JOBS:-${SLURM_CPUS_PER_TASK:-8}}

TS=$(date -u +%Y%m%dT%H%M%SZ)
if [[ -z "${OUTPUT:-}" ]]; then
    tag=${INPUT_COLLECTION#DECam/templates/}
    tag=$(sed -E 's#/[0-9]{8}T[0-9]{6}Z$##' <<<"$tag")
    OUTPUT=DECam/templates/analysis/$tag/$TS
fi

INPUTS=$INPUT_COLLECTION,$SKYMAP_COLLECTION

QUERY="skymap='$SKYMAP'"
[[ -n "$TRACT" ]] && QUERY+=" AND tract=$TRACT"
[[ -n "$BAND" ]] && QUERY+=" AND band='$BAND'"

# The depth whole-sky plots are band-parameterized over config.bands (default
# ugrizy); restrict them to BAND when one is given.
CONFIG_ARGS=()
[[ -n "$BAND" ]] && CONFIG_ARGS+=(-c "coaddDepthWholeSkyPlotTemplate:bands=['$BAND']")

LOGFILE=$LOGDIR/templateCoaddAnalysis_${MODE}_$TS.log
QGRAPH=$LOGDIR/templateCoaddAnalysis_$TS.qg

echo "repo:     $REPO"        | tee "$LOGFILE"
echo "inputs:   $INPUTS" | tee -a "$LOGFILE"
echo "output:   $OUTPUT"      | tee -a "$LOGFILE"
echo "query:    $QUERY"       | tee -a "$LOGFILE"
echo "mode:     $MODE (jobs=$JOBS)" | tee -a "$LOGFILE"
date | tee -a "$LOGFILE"

case "$MODE" in
    qgraph)
        pipetask qgraph \
            -b "$REPO" \
            -i "$INPUTS" \
            --output-run "$OUTPUT" \
            -p "$PIPELINE" \
            "${CONFIG_ARGS[@]}" \
            -d "$QUERY" \
            --save-qgraph "$QGRAPH" \
            2>&1 | tee -a "$LOGFILE"
        echo "graph saved to $QGRAPH" | tee -a "$LOGFILE"
        ;;
    run)
        pipetask --long-log run \
            -b "$REPO" \
            -i "$INPUTS" \
            --output-run "$OUTPUT" \
            -p "$PIPELINE" \
            "${CONFIG_ARGS[@]}" \
            -d "$QUERY" \
            -j "$JOBS" \
            --register-dataset-types \
            2>&1 | tee -a "$LOGFILE"
        ;;
    *)
        echo "MODE must be 'qgraph' or 'run', got '$MODE'" >&2
        exit 2
        ;;
esac

date | tee -a "$LOGFILE"
