#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_step2_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_step2_%j.err

# Step 2: recalibration, as the four drp_pipe DECam sub-steps, each its own
# `pipetask run` (and RUN) in the same output chain, in this order:
#   step2a  consolidatePreSourceTable, consolidateVisitSummary, skyCorr,
#           isolatedStarAssociation
#   step2b  jointcal (per tract and physical filter, against the_monster)
#   step2d  finalizeCharacterization, recalibrated source tables,
#           updateVisitSummary
#   step2e  makeCcdVisitTable, makeVisitTable
# Each sub-step needs the previous one's outputs, so they cannot share one
# graph build. A sub-step that partly fails does not stop the next: the
# check job judges what was produced.
#
# Sky frames: gwprimo_drp.yaml runs skyCorr with doSky false. Before step2a
# this script decides, from SKY_FRAMES in the conf, whether to pass
# `-c skyCorr:doSky=True`:
#   auto  on if gwprimo_butler.py sky-ready finds a certified sky frame for
#         every physical filter and night of the visits, otherwise off;
#   on    on, and fail if any is missing;
#   off   off.
# One skyCorr config covers every band, so the broad bands need sky frames
# too before auto turns it on. The choice must also match any skyCorr already
# run in OUTPUT_COLLECTION: --skip-existing would keep the old outputs, so a
# mismatch stops here (use a new OUTPUT_COLLECTION, or set SKY_FRAMES to match).
#
#   step2.sh [first sub-step]     e.g. `step2.sh step2d` to resume there

GWP_RUN_DIR=${GWP_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$GWP_RUN_DIR/common.sh"
load_conf
init_step step2
: > "$STATUS_FILE"

SUBSTEPS=(step2a step2b step2d step2e)
FIRST=${1:-step2a}

SKY_ARGS=()
if [[ $FIRST == step2a ]]; then
    want=False
    if [[ $SKY_FRAMES != off ]]; then
        if run_logged python "$GWP_RUN_DIR/gwprimo_butler.py" sky-ready; then
            want=True
        elif [[ $SKY_FRAMES == on ]]; then
            die "SKY_FRAMES=on but sky frames are missing (see above)"
        else
            log "not every filter and night has a sky frame: skyCorr runs without them (doSky false)" | tee -a "$LOGFILE"
        fi
    fi
    existing=$(python "$GWP_RUN_DIR/gwprimo_butler.py" skycorr-dosky | tail -1)
    if [[ $existing != none && $existing != "$want" ]]; then
        die "skyCorr already ran with doSky=$existing in $OUTPUT_COLLECTION, now doSky=$want: use a new OUTPUT_COLLECTION, or set SKY_FRAMES=$([[ $existing == True ]] && echo on || echo off) to continue the old way"
    fi
    log "skyCorr doSky=$want (SKY_FRAMES=$SKY_FRAMES)" | tee -a "$LOGFILE"
    [[ $want == True ]] && SKY_ARGS=(-c skyCorr:doSky=True)
fi

started=0
for sub in "${SUBSTEPS[@]}"; do
    [[ $sub == "$FIRST" ]] && started=1
    [[ $started == 1 ]] || continue
    log "=== $sub ===" | tee -a "$LOGFILE"
    if [[ $sub == step2a ]]; then
        pipetask_drp "$sub" "$STEP2_QUERY" "$NPROC" "${SKY_ARGS[@]}"
    else
        pipetask_drp "$sub" "$STEP2_QUERY" "$NPROC"
    fi
    record_pipetask_status $? "pipetask($sub)"
done
[[ $started == 1 ]] || die "unknown sub-step '$FIRST' (one of ${SUBSTEPS[*]})"
finish_step
exit 0
