#!/usr/bin/bash
# Shared setup for every too_run script. Sourced, never executed.
#
# What it does, in order:
#   1. Sets up the LSST stack the same way every other script in this repo does
#      (skipped when TOO_RUN_NO_STACK=1, which the sbatch drivers use because
#      they only submit jobs).
#   2. Defines log/die helpers and the job-chaining helpers used by the drivers.
#   3. Provides load_conf, which reads the per-event conf, fills in defaults
#      and builds the data queries. Nothing event-specific lives in this file.
#
# No `set -u`: the eups setup scripts reference unset variables. Required conf
# variables are checked explicitly in load_conf instead.

set -o pipefail

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}
export TOO_RUN_DIR

FITS_ROOT=/shares/soares-santos.physik.uzh/fitsFiles
SLURM_LOGDIR=$FITS_ROOT/calibs/logs

if [[ ${TOO_RUN_NO_STACK:-0} != 1 ]]; then
    source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
    # `module` only exists in login shells (sbatch scripts use `bash -l`).
    type module &> /dev/null && module load miniforge3
    source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
    setup lsst_distrib -c
    # Must come after `setup lsst_distrib`, otherwise the conda obs_decam is
    # used silently (see the top-level README).
    setup -j -r $OBSDECAM
    # DESGW_CONFIGS defines these as plain shell variables; the Python helpers
    # read REPO from the environment.
    export REPO LOGDIR IMAGE_PROC_CONFIG_DIR
fi

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "[$(date '+%F %T')] ERROR: $*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

# Day before a YYYYMMDD date, as YYYYMMDD.
day_before() {
    date -d "${1:0:4}-${1:4:2}-${1:6:2} -1 day" +%Y%m%d
}

# Format a space- or comma-separated list as 'a','b','c' for a butler query.
sql_list() {
    local out="" item
    for item in ${1//,/ }; do out+="${out:+,}'$item'"; done
    echo "$out"
}

# load_conf [conf]
# Reads the conf (argument, or $TOO_RUN_CONF), applies defaults and builds the
# queries. NIGHT and PROPID may come from the environment (drivers pass them
# with --export) and take precedence over the conf for PROPID.
load_conf() {
    local conf=${1:-${TOO_RUN_CONF:-}}
    [[ -n $conf ]] || die "no conf given: pass it as an argument or set TOO_RUN_CONF"
    [[ -r $conf ]] || die "cannot read conf: $conf"
    local env_propid=${PROPID:-} env_night=${NIGHT:-}
    TOO_RUN_CONF=$(readlink -f "$conf")
    export TOO_RUN_CONF
    # shellcheck disable=SC1090
    source "$TOO_RUN_CONF"
    [[ -n $env_propid ]] && PROPID=$env_propid
    [[ -n $env_night ]] && NIGHT=$env_night

    : "${EVENT:?EVENT is not set in $TOO_RUN_CONF}"
    : "${EVENT_DATE:?EVENT_DATE (YYYYMMDD) is not set in $TOO_RUN_CONF}"
    [[ $EVENT_DATE =~ ^[0-9]{8}$ ]] || die "EVENT_DATE must be YYYYMMDD, got '$EVENT_DATE'"

    DESGW_DIR=$(cd "$TOO_RUN_DIR/.." && pwd)
    PROPID=${PROPID:-}
    NIGHT=${NIGHT:-}
    # The exposures selected from the DELVE table are written next to the conf,
    # so each event directory records exactly which template inputs were chosen.
    EVENT_DIR=$(dirname "$TOO_RUN_CONF")
    EXPOSURE_LIST=$EVENT_DIR/template_exposures.csv

    # Templates: sky box and window.
    TEMPLATE_CSV=${TEMPLATE_CSV:-$DESGW_DIR/../data/delve_dr3qr_combo_v10.csv}
    TEMPLATE_START=${TEMPLATE_START:-20130101}
    TEMPLATE_END=${TEMPLATE_END:-$(day_before "$EVENT_DATE")}
    BANDS=${BANDS:-"g r i z"}
    TEFF_MIN=${TEFF_MIN:-}
    FWHM_MAX=${FWHM_MAX:-}
    MAX_PER_BAND=${MAX_PER_BAND:-}
    # Programs never used as templates: the DESGW ToO programs themselves, so
    # follow-up images (which may contain the transient) cannot enter a
    # template. Same list as startup/templates/build-template.sh; the event's
    # own PROPID is added automatically.
    TEMPLATE_EXCLUDE_PROGRAMS=${TEMPLATE_EXCLUDE_PROGRAMS:-"2023B-851374 2024A-781233 2024B-305328 2025A-227091 2025B-485252"}

    # Run settings.
    TARGET_NAME=${TARGET_NAME:-LVK_$EVENT}
    NPROC=${NPROC:-30}
    DOWNLOAD_WORKERS=${DOWNLOAD_WORKERS:-4}
    # Each ingest worker holds a Postgres connection; keep this modest.
    INGEST_PROCESSES=${INGEST_PROCESSES:-8}
    APDB_CONFIG=${APDB_CONFIG:-/shares/soares-santos.physik.uzh/ButlerProjects/desgw_apdb/apdb_config.yaml}
    INJECTION_COLLECTION=${INJECTION_COLLECTION:-}
    MODEL_COLLECTION=${MODEL_COLLECTION:-pretrained_models/tac_cnn_lsstcam_2026-02-26}
    RAW_ROOT=${RAW_ROOT:-$FITS_ROOT/desgw/$EVENT}

    # Thresholds used by the verify scripts (fractions are 0-1).
    MIN_RAW_PER_EXPOSURE=${MIN_RAW_PER_EXPOSURE:-50}
    OVERSCAN_MAX_MISSING_FRAC=${OVERSCAN_MAX_MISSING_FRAC:-0.05}
    TEMPLATE_MIN_COVERAGE=${TEMPLATE_MIN_COVERAGE:-0.5}
    SEARCH_TEMPLATE_MIN_COVERAGE=${SEARCH_TEMPLATE_MIN_COVERAGE:-0.8}
    TEMPLATE_FWHM_WARN=${TEMPLATE_FWHM_WARN:-1.5}
    TEMPLATE_PSF_CHECK=${TEMPLATE_PSF_CHECK:-1}
    AP_MIN_ISR_FRAC=${AP_MIN_ISR_FRAC:-0.8}
    AP_MIN_DIFF_FRAC=${AP_MIN_DIFF_FRAC:-0.7}

    # Collections. Overscan sources are shared by both phases (and all nights).
    OVERSCAN_COLLECTION=DECam/calib/template/$EVENT/overscanRaw
    TEMPLATE_COLLECTION=DECam/templates/$EVENT
    SEARCH_COLLECTION=DECam/search/$EVENT
    RAW_COLLECTION=DECam/raw/all
    CALIB_INPUTS=DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded,DECam/calib
    SKYMAP_COLLECTION=skymaps
    # Written by verify_templates.sh, required by the search phase. LOGDIR comes
    # from DESGW_CONFIGS, so it is empty in the drivers, which never use this.
    TEMPLATES_OK_MARKER=${LOGDIR:-}/too_run_${EVENT}_templates.ok

    build_queries
}

# Detector exclusions shared by every query, kept in the simple form the README
# recommends (no NOT((A AND B) OR ...) disjunctions, which blow up the butler
# query normalizer). 61 and 31 are dead; detector 2 is bad before 2016-12-29.
DET_EXCL="detector NOT IN (61,31) AND NOT (detector=2 AND exposure.day_obs<20161229)"

build_queries() {
    local ra_clause programs
    if [[ -n ${RA_MIN:-} && -n ${RA_MAX:-} && -n ${DEC_MIN:-} && -n ${DEC_MAX:-} ]]; then
        # RA_MIN > RA_MAX means the box wraps through RA=0.
        if awk -v a="$RA_MIN" -v b="$RA_MAX" 'BEGIN{exit !(a<=b)}'; then
            ra_clause="(tracking_ra>$RA_MIN AND tracking_ra<$RA_MAX)"
        else
            ra_clause="(tracking_ra>$RA_MIN OR tracking_ra<$RA_MAX)"
        fi
        programs=$(sql_list "$TEMPLATE_EXCLUDE_PROGRAMS ${PROPID:-}")
        TEMPLATE_QUERY="instrument='DECam' AND exposure.observation_type='science' AND exposure.day_obs>=$TEMPLATE_START AND exposure.day_obs<=$TEMPLATE_END AND $ra_clause AND (tracking_dec>$DEC_MIN AND tracking_dec<$DEC_MAX) AND band IN ($(sql_list "$BANDS")) AND exposure.science_program NOT IN ($programs)"
    else
        TEMPLATE_QUERY=""
    fi
    if [[ -n $PROPID && -n $NIGHT ]]; then
        SEARCH_QUERY="instrument='DECam' AND exposure.observation_type='science' AND exposure.science_program='$PROPID' AND exposure.day_obs=$NIGHT"
    else
        SEARCH_QUERY=""
    fi
}

# --------------------------------------------------------------------------
# Per-step context
# --------------------------------------------------------------------------

# init_step <phase> <step>
# Sets PHASE, TAG, RAWDIR, MANIFEST, PHASE_QUERY, LOGFILE and STATUS_FILE and
# starts the log. Call load_conf first.
init_step() {
    PHASE=${1:?usage: init_step <templates|search> <step>}
    local step=${2:?usage: init_step <templates|search> <step>}
    case $PHASE in
        templates)
            [[ -n $TEMPLATE_QUERY ]] || die "templates phase needs RA_MIN/RA_MAX/DEC_MIN/DEC_MAX in $TOO_RUN_CONF"
            TAG=templates
            RAWDIR=$RAW_ROOT/templates
            PHASE_QUERY=$TEMPLATE_QUERY
            ;;
        search)
            [[ -n $PROPID ]] || die "search phase needs PROPID (conf or --propid)"
            [[ -n $NIGHT ]] || die "search phase needs NIGHT (--night)"
            [[ $NIGHT =~ ^[0-9]{8}$ ]] || die "NIGHT must be YYYYMMDD, got '$NIGHT'"
            TAG=search_$NIGHT
            RAWDIR=$RAW_ROOT/$NIGHT
            PHASE_QUERY=$SEARCH_QUERY
            ;;
        *) die "phase must be 'templates' or 'search', got '$PHASE'" ;;
    esac
    MANIFEST=$RAWDIR/manifest.csv
    LOGFILE=$LOGDIR/too_run_${EVENT}_${TAG}_${step}.log
    STATUS_FILE=$LOGDIR/too_run_${EVENT}_${TAG}_${step}.status
    mkdir -p "$RAWDIR"
    date | tee "$LOGFILE"
    log "event=$EVENT phase=$PHASE tag=$TAG step=$step conf=$TOO_RUN_CONF" | tee -a "$LOGFILE"
}

# run_logged <cmd...>   Run a command, append its output to $LOGFILE, return its
# exit status (not tee's).
run_logged() {
    "$@" 2>&1 | tee -a "$LOGFILE"
    return "${PIPESTATUS[0]}"
}

# record_pipetask_status <rc> <what>
# pipetask exits non-zero when any quantum fails, which with detectors that
# routinely fail (see --no-raise-on-partial-outputs in the README) is not
# fatal. Record it and let the verify job judge by what was actually produced.
record_pipetask_status() {
    local rc=$1 what=$2
    echo "$rc" > "$STATUS_FILE"
    if [[ $rc -ne 0 ]]; then
        log "WARNING: $what exited with status $rc; the verify job decides whether the output is usable" | tee -a "$LOGFILE"
    fi
}

finish_step() {
    date | tee -a "$LOGFILE"
}

# --------------------------------------------------------------------------
# Job chaining (used by the drivers; they run with TOO_RUN_NO_STACK=1)
# --------------------------------------------------------------------------

STEPS_templates="download ingest visits overscan templates"
STEPS_search="download ingest visits overscan ap"

step_script() {
    case $1 in
        download)  echo download_raw.sh ;;
        ingest)    echo ingest_raw.sh ;;
        visits)    echo define_visits.sh ;;
        overscan)  echo build_overscan.sh ;;
        templates) echo build_templates.sh ;;
        ap)        echo run_ap_pipe.sh ;;
        *) die "unknown step '$1'" ;;
    esac
}

step_verify_script() {
    case $1 in
        download)  echo verify_download.sh ;;
        ingest)    echo verify_ingest.sh ;;
        visits)    echo verify_visits.sh ;;
        overscan)  echo verify_overscan.sh ;;
        templates) echo verify_templates.sh ;;
        ap)        echo verify_ap_pipe.sh ;;
        *) die "unknown step '$1'" ;;
    esac
}

# queued_chain_ends
# Prints (colon separated) the ids of this event's chains that are still queued or
# running, identified by their last job: verify_templates or verify_ap_pipe. A new
# chain uses them as its GATE so it never writes to the Butler or the APDB at the
# same time as an earlier one.
queued_chain_ends() {
    squeue -h -u "${USER:-$(id -un)}" -o "%i %j" 2>/dev/null \
        | awk -v prefix="too_${EVENT}_" 'index($2, prefix) == 1 && ($2 ~ /_verify_ap$/ || $2 ~ /_verify_templates$/) { print $1 }' \
        | paste -sd: -
}

# submit <name> <dependency-job-ids, colon separated or empty> <script> [args...]
# Prints the job id (a fake one when DRY_RUN=1). The command goes to stderr.
submit() {
    local name=$1 dep=$2 script=$3
    shift 3
    local cmd=(sbatch --parsable -J "too_${EVENT}_${name}"
        -o "$SLURM_LOGDIR/too_run_${EVENT}_${name}_%j.out"
        -e "$SLURM_LOGDIR/too_run_${EVENT}_${name}_%j.err"
        --export="ALL,TOO_RUN_DIR=$TOO_RUN_DIR,TOO_RUN_CONF=$TOO_RUN_CONF,NIGHT=${NIGHT:-},PROPID=${PROPID:-}")
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

# submit_chain <phase> [from-step]
# Submits step -> verify for each step of the phase, each depending on the
# previous verify. GATE (colon-separated job ids) is added to the dependencies
# of the first step that is not the download, so a download can start early but
# nothing writes to the Butler until the gate jobs are done. Sets LAST_JOB.
submit_chain() {
    local phase=$1 from=${2:-} steps step started=1 prev="" gate=${GATE:-} job vjob tag deps
    eval "steps=\$STEPS_$phase"
    [[ -n $from ]] && started=0
    if [[ $phase == templates ]]; then tag=templates; else tag=search_$NIGHT; fi
    for step in $steps; do
        [[ $step == "$from" ]] && started=1
        [[ $started == 1 ]] || continue
        deps=$prev
        if [[ $step != download && -n $gate ]]; then
            deps=${deps:+$deps:}$gate
            gate=""
        fi
        job=$(submit "${tag}_$step" "$deps" "$TOO_RUN_DIR/steps/$(step_script "$step")" "$phase") || exit 1
        vjob=$(submit "${tag}_verify_$step" "$job" "$TOO_RUN_DIR/steps/$(step_verify_script "$step")" "$phase") || exit 1
        prev=$vjob
    done
    LAST_JOB=$prev
}
