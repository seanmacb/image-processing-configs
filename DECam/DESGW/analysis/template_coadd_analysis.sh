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
#   BAND              band or list of bands separated by commas and/or spaces
#                     (g, "g,r,i", "g r i"), or empty
#                     for all bands in the collection. Set it for any collection:
#                     it also restricts the band-parameterized depth whole-sky plots
#   SKYMAP            skymap name (default decam_rings_v1; needed for tract constraints)
#   SKYMAP_COLLECTION collection holding the skyMap dataset, appended to the inputs
#                     (default skymaps; template RUNs do not contain it)
#   OUTPUT            output RUN collection (default
#                     DECam/templates/analysis/<input minus DECam/templates/ and its
#                     trailing timestamp>/<UTC timestamp>)
#   MODE              qgraph (build + save graph only) or run (default run)
#   JOBS              pipetask -j (default: SLURM_CPUS_PER_TASK or 8)
#   RESUME            1 = finish an interrupted run: extend the newest existing RUN
#                     under the default OUTPUT prefix instead of making a new one
#   RESUME_RUN        the exact RUN to extend (implies RESUME); overrides OUTPUT
#
# Examples:
#   MODE=qgraph TRACT=4250 BAND=g bash template_coadd_analysis.sh
#   sbatch --export=ALL,BAND=g template_coadd_analysis.sh
#   INPUT_COLLECTION=DECam/templates/bestSeeing_wide_gri BAND=g,r,i \
#       sbatch --export=ALL template_coadd_analysis.sh
#   (For a band list, set the variables in front of sbatch as above, not inside
#   --export=...: --export splits on commas, so --export=ALL,BAND=g,r,i would
#   give BAND=g.)
#
# Resuming (after a timeout, or any interrupted run). Use the same
# INPUT_COLLECTION and BAND as the original run, and give the job enough time:
#   INPUT_COLLECTION=DECam/templates/bestSeeing_wide_gri BAND=g,r,i RESUME=1 \
#       sbatch --export=ALL --time=16:00:00 template_coadd_analysis.sh
# This passes --extend-run --skip-existing --clobber-outputs: quanta whose outputs
# are all in the RUN are skipped, and partial outputs of quanta killed mid-write
# are replaced. The script compares the inputs and bands with the original run's
# log and stops if they differ, since --extend-run refuses differing task
# configs anyway. MODE=qgraph RESUME=1 shows what is left without running
# anything. TRACT is refused with a resume in run mode: the survey-level tables
# and whole-sky plots would be written for that subset only, and a later full
# resume would then skip them as already done.
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

RESUME=${RESUME:-}
RESUME_RUN=${RESUME_RUN:-}
EXTEND_ARGS=()
if [[ -n "$RESUME_RUN" || -n "$RESUME" ]]; then
    if [[ -z "$RESUME_RUN" ]]; then
        # Newest RUN under the default OUTPUT prefix (names end in a UTC timestamp).
        prefix=${OUTPUT%/*}
        RESUME_RUN=$(butler query-collections "$REPO" "$prefix/*" --collection-type RUN 2>/dev/null \
                     | awk 'NR>2 {print $1}' | sort | tail -n 1)
        if [[ -z "$RESUME_RUN" ]]; then
            echo "RESUME: no existing RUN under $prefix/ to extend" >&2
            exit 1
        fi
    elif ! butler query-collections "$REPO" "$RESUME_RUN" 2>/dev/null | grep -q "^$RESUME_RUN "; then
        echo "RESUME_RUN: collection $RESUME_RUN does not exist" >&2
        exit 1
    fi
    OUTPUT=$RESUME_RUN
    EXTEND_ARGS=(--extend-run --skip-existing --clobber-outputs)
    if [[ -n "$TRACT" && "$MODE" == run ]]; then
        echo "RESUME: TRACT=$TRACT is not allowed when resuming in run mode; the survey-level" >&2
        echo "  tables would cover only that tract and a later full resume would skip them." >&2
        echo "  Unset TRACT (or use MODE=qgraph to preview one tract)." >&2
        exit 1
    fi
fi

QUERY="skymap='$SKYMAP'"
[[ -n "$TRACT" ]] && QUERY+=" AND tract=$TRACT"

# The depth whole-sky plots are band-parameterized over config.bands (default
# ugrizy); restrict them to BAND when given.
CONFIG_ARGS=()
if [[ -n "$BAND" ]]; then
    read -r -a BANDS <<<"${BAND//,/ }"
    quoted=$(printf "'%s'," "${BANDS[@]}")
    quoted=${quoted%,}                       # 'g','r','i'
    QUERY+=" AND band IN ($quoted)"
    CONFIG_ARGS+=(-c "coaddDepthWholeSkyPlotTemplate:bands=[$quoted]")
fi

if [[ ${#EXTEND_ARGS[@]} -gt 0 ]]; then
    # The original run's log is named after its RUN timestamp.
    orig_log=$LOGDIR/templateCoaddAnalysis_run_${OUTPUT##*/}.log
    if [[ -f "$orig_log" ]]; then
        orig_inputs=$(sed -n 's/^inputs: *//p' "$orig_log" | head -n 1)
        orig_bands=$(sed -n 's/^query: *//p' "$orig_log" | head -n 1 | grep -o "band IN ([^)]*)" || true)
        new_bands=$(grep -o "band IN ([^)]*)" <<<"$QUERY" || true)
        if [[ "$orig_inputs" != "$INPUTS" || "$orig_bands" != "$new_bands" ]]; then
            echo "RESUME: settings differ from the original run ($orig_log)" >&2
            echo "  inputs: original '$orig_inputs'  now '$INPUTS'" >&2
            echo "  bands:  original '$orig_bands'  now '$new_bands'" >&2
            exit 1
        fi
    else
        echo "RESUME: original log $orig_log not found; cannot check settings" >&2
    fi
fi

LOGFILE=$LOGDIR/templateCoaddAnalysis_${MODE}_$TS.log
QGRAPH=$LOGDIR/templateCoaddAnalysis_$TS.qg

echo "repo:     $REPO"        | tee "$LOGFILE"
echo "inputs:   $INPUTS" | tee -a "$LOGFILE"
echo "output:   $OUTPUT"      | tee -a "$LOGFILE"
echo "query:    $QUERY"       | tee -a "$LOGFILE"
echo "mode:     $MODE (jobs=$JOBS)" | tee -a "$LOGFILE"
[[ ${#EXTEND_ARGS[@]} -gt 0 ]] && echo "resume:   extending $OUTPUT (${EXTEND_ARGS[*]})" | tee -a "$LOGFILE"
date | tee -a "$LOGFILE"

case "$MODE" in
    qgraph)
        pipetask qgraph "${EXTEND_ARGS[@]}" \
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
        pipetask --long-log run "${EXTEND_ARGS[@]}" \
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
