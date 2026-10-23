#!/usr/bin/bash
# Shared setup for every GW-Primo run script. Sourced, never executed.
# Same layout as DESGW/too_run/common.sh:
#   1. Sets up the LSST stack the way every other script in this repo does
#      (skipped when GWP_NO_STACK=1, which the sbatch driver uses because it
#      only submits jobs).
#   2. Defines log/die helpers and the job-submission helper.
#   3. Provides load_conf, which reads the per-field conf, fills in defaults
#      and builds the data queries. Nothing field-specific lives in this file.
#
# No `set -u`: the eups setup scripts reference unset variables. Required conf
# variables are checked explicitly in load_conf instead.

set -o pipefail

GWP_RUN_DIR=${GWP_RUN_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}
export GWP_RUN_DIR
GWP_DIR=$(cd "$GWP_RUN_DIR/.." && pwd)

FITS_ROOT=/shares/soares-santos.physik.uzh/fitsFiles
SLURM_LOGDIR=$FITS_ROOT/calibs/logs

if [[ ${GWP_NO_STACK:-0} != 1 ]]; then
    source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
    # `module` only exists in login shells (sbatch scripts use `bash -l`).
    type module &> /dev/null && module load miniforge3
    source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
    setup lsst_distrib -c
    # Must come after `setup lsst_distrib`, otherwise the conda obs_decam is
    # used silently, and it has neither the medium-band filters nor the
    # the_monster filter map (see the top-level README).
    setup -j -r $OBSDECAM
    export REPO LOGDIR
fi

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "[$(date '+%F %T')] ERROR: $*" >&2; exit 1; }

# Format a space- or comma-separated list as 'a','b','c' for a butler query.
sql_list() {
    local out="" item
    for item in ${1//,/ }; do out+="${out:+,}'$item'"; done
    echo "$out"
}

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

# load_conf [conf]
# Reads the conf (argument, or $GWP_CONF), applies defaults and builds the
# queries.
load_conf() {
    local conf=${1:-${GWP_CONF:-}}
    [[ -n $conf ]] || die "no conf given: pass it as an argument or set GWP_CONF"
    [[ -r $conf ]] || die "cannot read conf: $conf"
    GWP_CONF=$(readlink -f "$conf")
    export GWP_CONF
    # Drop every conf variable (and everything derived from them) left by an
    # earlier load_conf or load_set in this shell, so a field's selection comes
    # from its conf and the defaults below only.
    unset FIELD REGION BANDS SKYMAP DAY_OBS_MIN DAY_OBS_MAX PROGRAMS EXCLUDE_PROGRAMS EXTRA_WHERE \
        CALIB_COLLECTIONS PIPELINE NPROC NPROC_STEP3 OUTPUT_COLLECTION OVERSCAN_COLLECTION \
        OVERSCAN_SKIP_EXISTING_IN RAW_COLLECTION DRP_INPUTS REFCAT REFCAT_COLLECTION \
        VISIT_FILTER VISIT_QUERY STEP1_QUERY STEP2_QUERY STEP3_QUERY \
        STEP0_MIN_FRAC STEP1_MIN_FRAC STEP2_MIN_FRAC STEP3_MIN_FRAC METRICS_DIR EXPORT_PLOTS SKY_FRAMES
    # shellcheck disable=SC1090
    source "$GWP_CONF"

    : "${FIELD:?FIELD is not set in $GWP_CONF}"
    : "${REGION:?REGION is not set in $GWP_CONF}"
    # The butler query language takes ADQL-style region literals (degrees):
    # CIRCLE(ra, dec, radius), BOX(ra, dec, width, height) or
    # POLYGON(ra1, dec1, ra2, dec2, ...).
    local region_re='^(CIRCLE|BOX|POLYGON)\([-0-9., ]+\)$'
    [[ $REGION =~ $region_re ]] \
        || die "REGION must be CIRCLE(ra, dec, r), BOX(ra, dec, w, h) or POLYGON(...), got '$REGION'"

    BANDS=${BANDS:-"g r i z N395 M411 M438 M464 M490 M517 N540"}
    SKYMAP=${SKYMAP:-decam_rings_v1}
    DAY_OBS_MIN=${DAY_OBS_MIN:-}
    DAY_OBS_MAX=${DAY_OBS_MAX:-}
    PROGRAMS=${PROGRAMS:-}
    EXCLUDE_PROGRAMS=${EXCLUDE_PROGRAMS:-}
    EXTRA_WHERE=${EXTRA_WHERE:-}
    CALIB_COLLECTIONS=${CALIB_COLLECTIONS:-}

    PIPELINE=${PIPELINE:-$GWP_DIR/configs/gwprimo_drp.yaml}
    NPROC=${NPROC:-30}
    NPROC_STEP3=${NPROC_STEP3:-15}

    # Collections.
    OUTPUT_COLLECTION=${OUTPUT_COLLECTION:-DECam/GW-Primo/$FIELD/drp}
    OVERSCAN_COLLECTION=${OVERSCAN_COLLECTION:-DECam/GW-Primo/$FIELD/overscanRaw}
    # overscanRaw that already exists (the DESGW templates of the same sky)
    # and need not be rebuilt by step0.
    OVERSCAN_SKIP_EXISTING_IN=${OVERSCAN_SKIP_EXISTING_IN:-DECam/template/overscanRaw}
    RAW_COLLECTION=DECam/raw/all
    STEP0_INPUTS=DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded
    # Extra calibration collections first, so they win over DECam/calib. The
    # -i list must not change between the steps of one OUTPUT_COLLECTION:
    # pipetask refuses an existing output chain whose inputs differ.
    DRP_INPUTS=${CALIB_COLLECTIONS:+$CALIB_COLLECTIONS,}DECam/defaults,$OVERSCAN_COLLECTION
    REFCAT=${REFCAT:-the_monster_20250219}
    REFCAT_COLLECTION=${REFCAT_COLLECTION:-refcats/gen3}

    # Thresholds used by the check jobs (fractions are 0-1).
    STEP0_MIN_FRAC=${STEP0_MIN_FRAC:-0.95}
    STEP1_MIN_FRAC=${STEP1_MIN_FRAC:-0.8}
    STEP2_MIN_FRAC=${STEP2_MIN_FRAC:-0.9}
    STEP3_MIN_FRAC=${STEP3_MIN_FRAC:-0.5}

    # Metric tables and exported plots. LOGDIR comes from DESGW_CONFIGS, so
    # it is empty in the driver, which never uses these.
    METRICS_DIR=${METRICS_DIR:-${LOGDIR:-}/gwprimo/$FIELD}
    EXPORT_PLOTS=${EXPORT_PLOTS:-1}

    # skyCorr's sky-frame subtraction (see steps/step2.sh): auto turns it on
    # when every physical filter and night of the visits finds a certified sky
    # frame; on requires that (step2 fails otherwise); off never uses them.
    SKY_FRAMES=${SKY_FRAMES:-auto}
    [[ $SKY_FRAMES =~ ^(auto|on|off)$ ]] || die "SKY_FRAMES must be auto, on or off, got '$SKY_FRAMES'"

    build_queries
    # gwprimo_butler.py reads its settings from these.
    export FIELD REGION BANDS SKYMAP PIPELINE OUTPUT_COLLECTION OVERSCAN_COLLECTION \
        RAW_COLLECTION DRP_INPUTS REFCAT REFCAT_COLLECTION CALIB_COLLECTIONS \
        OVERSCAN_SKIP_EXISTING_IN VISIT_QUERY STEP1_QUERY STEP2_QUERY STEP3_QUERY \
        STEP0_MIN_FRAC STEP1_MIN_FRAC STEP2_MIN_FRAC STEP3_MIN_FRAC METRICS_DIR SKY_FRAMES
}

# Detector exclusions, as in DESGW: 61 and 31 are dead; detector 2 is bad
# before 2016-12-29. Kept in the simple CNF form the DESGW README recommends.
# Only step0/step1 need them; later steps only see what step1 produced.
DET_EXCL="detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229)"

build_queries() {
    local f
    f="instrument='DECam' AND band IN ($(sql_list "$BANDS"))"
    [[ -n $DAY_OBS_MIN ]] && f+=" AND visit.day_obs>=$DAY_OBS_MIN"
    [[ -n $DAY_OBS_MAX ]] && f+=" AND visit.day_obs<=$DAY_OBS_MAX"
    [[ -n $PROGRAMS ]] && f+=" AND visit.science_program IN ($(sql_list "$PROGRAMS"))"
    [[ -n $EXCLUDE_PROGRAMS ]] && f+=" AND visit.science_program NOT IN ($(sql_list "$EXCLUDE_PROGRAMS"))"
    [[ -n $EXTRA_WHERE ]] && f+=" AND ($EXTRA_WHERE)"
    VISIT_FILTER=$f
    # Whole visits whose footprint touches the region: steps 1 and 2 must see
    # complete visits (skyCorr, consolidateVisitSummary and jointcal work on
    # full focal planes), so they are selected by visit.region, never by tract
    # or patch.
    VISIT_QUERY="$VISIT_FILTER AND visit.region OVERLAPS $REGION"
    STEP1_QUERY="$VISIT_QUERY AND exposure.observation_type='science' AND $DET_EXCL"
    STEP2_QUERY="$VISIT_QUERY AND skymap='$SKYMAP'"
    # Coadds only for the patches that touch the region. Tract-level outputs
    # (objectTable_tract and the tract metrics) then cover those patches only.
    STEP3_QUERY="$VISIT_FILTER AND skymap='$SKYMAP' AND patch.region OVERLAPS $REGION"
}

step_query() {
    case $1 in
        0|1) echo "$STEP1_QUERY" ;;
        2) echo "$STEP2_QUERY" ;;
        3) echo "$STEP3_QUERY" ;;
        *) die "unknown step '$1'" ;;
    esac
}

# --------------------------------------------------------------------------
# Per-step context
# --------------------------------------------------------------------------

# init_step <name>   Sets LOGFILE and STATUS_FILE and starts the log.
init_step() {
    local name=${1:?usage: init_step <name>}
    LOGFILE=$LOGDIR/gwprimo_${FIELD}_${name}.log
    STATUS_FILE=$LOGDIR/gwprimo_${FIELD}_${name}.status
    date | tee "$LOGFILE"
    log "field=$FIELD step=$name conf=$GWP_CONF" | tee -a "$LOGFILE"
    log "pipeline=$PIPELINE output=$OUTPUT_COLLECTION" | tee -a "$LOGFILE"
}

# run_logged <cmd...>   Run a command, append its output to $LOGFILE, return its
# exit status (not tee's).
run_logged() {
    "$@" 2>&1 | tee -a "$LOGFILE"
    return "${PIPESTATUS[0]}"
}

# record_pipetask_status <rc> <what>
# pipetask exits non-zero when any quantum fails, which with detectors that
# routinely fail is not fatal. Record it and let the check job judge by what
# was actually produced.
record_pipetask_status() {
    local rc=$1 what=$2
    echo "$what $rc" >> "$STATUS_FILE"
    if [[ $rc -ne 0 ]]; then
        log "WARNING: $what exited with status $rc; the check job decides whether the output is usable" | tee -a "$LOGFILE"
    fi
}

# pipetask_drp <subset> <query> <nproc> [extra pipetask args...]
# One `pipetask run` of a subset of the GW-Primo pipeline into OUTPUT_COLLECTION.
#   --skip-existing                 safe to repeat; skips quanta already done
#                                   in the output chain
#   --no-raise-on-partial-outputs   one failed detector must not fail every
#                                   downstream quantum of its visit (DESGW
#                                   README, Gotchas)
pipetask_drp() {
    local subset=$1 query=$2 nproc=$3
    shift 3
    run_logged pipetask --long-log run --register-dataset-types -j "$nproc" \
        --skip-existing --no-raise-on-partial-outputs \
        -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
        -i "$DRP_INPUTS" \
        -o "$OUTPUT_COLLECTION" \
        -p "$PIPELINE#$subset" \
        -d "$query" "$@"
}

finish_step() {
    date | tee -a "$LOGFILE"
}

# --------------------------------------------------------------------------
# Job submission (used by the driver; it runs with GWP_NO_STACK=1)
# --------------------------------------------------------------------------

# Jobs of this field still queued or running, as "id name" lines.
queued_field_jobs() {
    squeue -h -u "${USER:-$(id -un)}" -o "%i %j" 2>/dev/null \
        | awk -v prefix="gwp_${FIELD}_" 'index($2, prefix) == 1'
}

# submit <name> <dependency-job-id or empty> <script> [args...]
# Prints the job id (a fake one when DRY_RUN=1). The command goes to stderr.
submit() {
    local name=$1 dep=$2 script=$3
    shift 3
    local cmd=(sbatch --parsable -J "gwp_${FIELD}_${name}"
        -o "$SLURM_LOGDIR/gwprimo_${FIELD}_${name}_%j.out"
        -e "$SLURM_LOGDIR/gwprimo_${FIELD}_${name}_%j.err"
        --export="ALL,GWP_RUN_DIR=$GWP_RUN_DIR,GWP_CONF=$GWP_CONF")
    [[ -n $dep ]] && cmd+=("--dependency=afterok:$dep")
    cmd+=("$script" "$@")
    if [[ ${DRY_RUN:-0} == 1 ]]; then
        echo "+ ${cmd[*]}" >&2
        echo "DRY_$name"
        return 0
    fi
    local job
    job=$("${cmd[@]}") || die "sbatch failed for $name"
    job=${job%%;*}
    echo "submitted $name as job $job" >&2
    echo "$job"
}
