#!/usr/bin/bash
# Shared setup for the GW-Primo calibration scripts (medium-band flats and
# sky frames). Sourced, never executed. Same pattern as ../run/common.sh:
# stack setup (skipped when GWP_NO_STACK=1, which the driver uses), helpers,
# and load_set, which reads one calibration-set conf (sets/<SET>.conf) and
# builds the data queries and collection names.
#
# No `set -u`: the eups setup scripts reference unset variables.

set -o pipefail

GWP_CALIB_DIR=${GWP_CALIB_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}
export GWP_CALIB_DIR

SLURM_LOGDIR=/shares/soares-santos.physik.uzh/fitsFiles/calibs/logs

if [[ ${GWP_NO_STACK:-0} != 1 ]]; then
    source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
    type module &> /dev/null && module load miniforge3
    source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
    setup lsst_distrib -c
    # After lsst_distrib: the conda obs_decam does not know the medium-band
    # filters at all.
    setup -j -r $OBSDECAM
    export REPO LOGDIR IMAGE_PROC_CONFIG_DIR
fi

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "[$(date '+%F %T')] ERROR: $*" >&2; exit 1; }

sql_list() {
    local out="" item
    for item in ${1//,/ }; do out+="${out:+,}'$item'"; done
    echo "$out"
}

# load_set [conf]   Reads a flat-set conf (argument, or $GWP_SET_CONF).
load_set() {
    local conf=${1:-${GWP_SET_CONF:-}}
    [[ -n $conf ]] || die "no set conf given: pass it as an argument or set GWP_SET_CONF"
    [[ -r $conf ]] || die "cannot read set conf: $conf"
    GWP_SET_CONF=$(readlink -f "$conf")
    export GWP_SET_CONF
    # Drop every conf variable (and everything derived from them) left by an
    # earlier load_set or load_conf in this shell, so a set (or a conf that
    # omits a required value) cannot inherit another one's values.
    unset SET SKY_ONLY SKY_GWPRIMO_FLATS SKY_SUPERSEDED_BY BANDS DAY_OBS_MIN DAY_OBS_MAX CERT_BEGIN CERT_END EXTRA_WHERE SKY_EXTRA_WHERE NPROC \
        CALIB_COLLECTION OVERSCAN_COLLECTION FLAT_COLLECTION VERIFY_COLLECTION SKY_COLLECTION \
        SKY_PIPELINE FLAT_QUERY SKY_QUERY SKY_BASE_QUERY FLAT_MIN_EXPOSURES SKY_MIN_EXPOSURES OVERSCAN_MAX_MISSING_FRAC \
        SKY_MIN_EXPTIME SKY_MAX_EXPOSURES SKY_EXPOSURE_LIST SKY_EXCLUDE_EXPOSURES
    # shellcheck disable=SC1090
    source "$GWP_SET_CONF"

    : "${SET:?SET is not set in $GWP_SET_CONF}"
    : "${BANDS:?BANDS is not set in $GWP_SET_CONF}"
    : "${DAY_OBS_MIN:?DAY_OBS_MIN is not set in $GWP_SET_CONF}"
    : "${DAY_OBS_MAX:?DAY_OBS_MAX is not set in $GWP_SET_CONF}"
    : "${CERT_BEGIN:?CERT_BEGIN is not set in $GWP_SET_CONF}"
    : "${CERT_END:?CERT_END is not set in $GWP_SET_CONF}"
    EXTRA_WHERE=${EXTRA_WHERE:-}
    SKY_EXTRA_WHERE=${SKY_EXTRA_WHERE:-}
    NPROC=${NPROC:-30}
    # SKY_ONLY=1: a set that only builds sky frames (the broad bands, whose
    # flats are already in DECam/calib); run_calib.sh refuses its flat steps.
    SKY_ONLY=${SKY_ONLY:-0}
    # SKY_GWPRIMO_FLATS=1 (with SKY_ONLY=1): the set's flats are the medium-band
    # ones the flat sets certified into CALIB_COLLECTION, not DECam's (sets/sky-2026.conf).
    SKY_GWPRIMO_FLATS=${SKY_GWPRIMO_FLATS:-0}
    # SKY_SUPERSEDED_BY=<set>: another set builds this set's sky frames, and
    # run_calib.sh refuses the sky steps here (two sky windows for one filter
    # cannot both be certified).
    SKY_SUPERSEDED_BY=${SKY_SUPERSEDED_BY:-}
    # Optional sky-frame selection: only science exposures at least
    # SKY_MIN_EXPTIME seconds long, and at most SKY_MAX_EXPOSURES per physical
    # filter, picked by the sky_select step into SKY_EXPOSURE_LIST (relative
    # to the conf's directory). Without SKY_MAX_EXPOSURES every exposure the
    # query selects is used.
    SKY_MIN_EXPTIME=${SKY_MIN_EXPTIME:-}
    SKY_MAX_EXPOSURES=${SKY_MAX_EXPOSURES:-}
    SKY_EXPOSURE_LIST=${SKY_EXPOSURE_LIST:-}
    # Exposure ids (space separated) left out of every sky step, e.g. ones
    # whose cpSkyImage fails every time ("All pixels masked"): one failed
    # quantum makes pipetask skip the whole filter's combine. sky.sh lists the
    # failures at the end of its log. Applied on top of the selection, so
    # sky_select's list stays as it was.
    SKY_EXCLUDE_EXPOSURES=${SKY_EXCLUDE_EXPOSURES:-}
    [[ -z $SKY_EXCLUDE_EXPOSURES || $SKY_EXCLUDE_EXPOSURES =~ ^[0-9]+( +[0-9]+)*$ ]] \
        || die "SKY_EXCLUDE_EXPOSURES must be exposure ids separated by spaces: '$SKY_EXCLUDE_EXPOSURES'"
    if [[ -n $SKY_MAX_EXPOSURES ]]; then
        [[ -n $SKY_EXPOSURE_LIST ]] || SKY_EXPOSURE_LIST=$SET.sky_exposures
        [[ $SKY_EXPOSURE_LIST == /* ]] || SKY_EXPOSURE_LIST=$(dirname "$GWP_SET_CONF")/$SKY_EXPOSURE_LIST
    fi

    # Collections. The flats are certified into a GW-Primo CALIBRATION
    # collection, not into the shared DECam/calib: the field confs put it in
    # CALIB_COLLECTIONS, ahead of DECam/calib.
    CALIB_COLLECTION=${CALIB_COLLECTION:-DECam/calib/GW-Primo}
    OVERSCAN_COLLECTION=${OVERSCAN_COLLECTION:-DECam/calib/GW-Primo/overscanRaw}
    FLAT_COLLECTION=${FLAT_COLLECTION:-DECam/calib/GW-Primo/flat/$SET}
    VERIFY_COLLECTION=${VERIFY_COLLECTION:-DECam/calib/GW-Primo/verify/flat/$SET}
    SKY_COLLECTION=${SKY_COLLECTION:-DECam/calib/GW-Primo/sky/$SET}
    # The same inputs as DESGW/startup/calib/build-flat-25-26.sh; the bias
    # comes from DECam/calib, where the 2025-26 bias is certified through
    # 2026-11-01.
    RAW_INPUTS=DECam/raw/all,DECam/calib/curated/19700101T000000Z,DECam/calib/unbounded
    FLAT_INPUTS=$RAW_INPUTS,DECam/calib,$OVERSCAN_COLLECTION
    # verify and the sky frames read the certified flats, so the GW-Primo
    # calibrations come first. A sky-only set's flats are DESGW's, in
    # DECam/calib, and CALIB_COLLECTION does not exist before the first
    # certify, so those sets leave it out (and must keep doing so: pipetask
    # refuses a different -i for an existing output chain).
    VERIFY_INPUTS=$RAW_INPUTS,$CALIB_COLLECTION,DECam/calib,$OVERSCAN_COLLECTION
    if [[ $SKY_ONLY == 1 && $SKY_GWPRIMO_FLATS != 1 ]]; then
        SKY_INPUTS=$RAW_INPUTS,DECam/calib,$OVERSCAN_COLLECTION
    else
        SKY_INPUTS=$VERIFY_INPUTS
    fi
    SKY_PIPELINE=${SKY_PIPELINE:-$GWP_CALIB_DIR/configs/gwprimo_cpSky.yaml}

    # Check thresholds.
    # A few raws are unreadable (truncated files) and fail overscan on every
    # run; the set goes on without them if they are at most this fraction of
    # its raws (rounded up). More means overscan has not finished.
    OVERSCAN_MAX_MISSING_FRAC=${OVERSCAN_MAX_MISSING_FRAC:-0.002}
    FLAT_MIN_EXPOSURES=${FLAT_MIN_EXPOSURES:-5}
    # Each sky pixel is a clipped mean over the exposures, with sources masked;
    # fewer than this many leaves too much noise and source residue.
    SKY_MIN_EXPOSURES=${SKY_MIN_EXPOSURES:-20}

    # Dome flats of the set's bands and nights. Detectors 61 and 31 are dead
    # and never processed (the science queries exclude them too).
    FLAT_QUERY="instrument='DECam' AND exposure.observation_type='dome flat' AND band IN ($(sql_list "$BANDS")) AND exposure.day_obs>=$DAY_OBS_MIN AND exposure.day_obs<=$DAY_OBS_MAX AND detector NOT IN (61,31)"
    [[ -n $EXTRA_WHERE ]] && FLAT_QUERY+=" AND ($EXTRA_WHERE)"
    # Sky frames come from the science exposures of the same bands and nights
    # (every program, not only GW-Primo's), so they share the flats' window.
    SKY_BASE_QUERY="instrument='DECam' AND exposure.observation_type='science' AND band IN ($(sql_list "$BANDS")) AND exposure.day_obs>=$DAY_OBS_MIN AND exposure.day_obs<=$DAY_OBS_MAX AND detector NOT IN (61,31)"
    [[ -n $SKY_MIN_EXPTIME ]] && SKY_BASE_QUERY+=" AND exposure.exposure_time>=$SKY_MIN_EXPTIME"
    [[ -n $SKY_EXTRA_WHERE ]] && SKY_BASE_QUERY+=" AND ($SKY_EXTRA_WHERE)"
    SKY_QUERY=$SKY_BASE_QUERY
    # With a selection, the later sky steps use exactly the listed exposures
    # (one IN clause, which the butler handles fine at a few hundred ids).
    if [[ -n $SKY_EXPOSURE_LIST && -r $SKY_EXPOSURE_LIST ]]; then
        local ids
        ids=$(grep -v '^#' "$SKY_EXPOSURE_LIST" | paste -sd, -)
        [[ -n $ids ]] || die "$SKY_EXPOSURE_LIST lists no exposures"
        SKY_QUERY+=" AND exposure IN ($ids)"
    fi
    [[ -n $SKY_EXCLUDE_EXPOSURES ]] && SKY_QUERY+=" AND exposure NOT IN ($(echo $SKY_EXCLUDE_EXPOSURES | tr -s ' ' ,))"

    export SET SKY_ONLY SKY_GWPRIMO_FLATS BANDS CALIB_COLLECTION OVERSCAN_COLLECTION FLAT_COLLECTION VERIFY_COLLECTION \
        SKY_COLLECTION FLAT_QUERY SKY_QUERY SKY_BASE_QUERY CERT_BEGIN CERT_END FLAT_MIN_EXPOSURES \
        SKY_MIN_EXPOSURES SKY_MAX_EXPOSURES SKY_EXPOSURE_LIST SKY_EXCLUDE_EXPOSURES OVERSCAN_MAX_MISSING_FRAC
}

# require_sky_selection   Steps that build sky frames call this: with a
# selection configured, the list must exist (sky_select writes it).
require_sky_selection() {
    if [[ -n $SKY_EXPOSURE_LIST && ! -r $SKY_EXPOSURE_LIST ]]; then
        die "$SKY_EXPOSURE_LIST does not exist: run the sky_select step first"
    fi
}

# The data query and collection a step works on: dome flats, or the science
# exposures of the sky frames.
step_query() {
    case $1 in
        flat) echo "$FLAT_QUERY" ;;
        sky) echo "$SKY_QUERY" ;;
        *) die "unknown calibration '$1' (flat or sky)" ;;
    esac
}

# query_without_overscan_gaps flat|sky   The query of the steps after
# overscan (flat, verify, sky): step_query without the raws that have no
# overscanRaw. Those are raws overscan could not read, which would fail their
# ISR quantum again, and pipetask skips everything downstream of a failed
# quantum: for a combine, the whole filter. Fails (logged) if they are more
# than OVERSCAN_MAX_MISSING_FRAC of the raws, i.e. overscan has not finished.
# Needs init_step first.
query_without_overscan_gaps() {
    local kind=$1 out query rc
    out=$(mktemp) || return 1
    run_logged python "$GWP_CALIB_DIR/gwprimo_flats.py" overscan-gaps --kind "$kind" --where-out "$out" >&2
    rc=$?
    if [[ $rc -eq 0 ]]; then
        query=$(step_query "$kind") || rc=1
        [[ -s $out ]] && query+=" AND $(cat "$out")"
        echo "$query"
    else
        log "ERROR: too many of the set's raws have no overscanRaw (see above): finish the overscan step first" \
            | tee -a "$LOGFILE" >&2
    fi
    rm -f "$out"
    return $rc
}

# init_step <name>   Sets LOGFILE and starts the log.
init_step() {
    local name=${1:?usage: init_step <name>}
    LOGFILE=$LOGDIR/gwprimo_calib_${SET}_${name}.log
    date | tee "$LOGFILE"
    log "calibration set=$SET step=$name conf=$GWP_SET_CONF" | tee -a "$LOGFILE"
}

run_logged() {
    "$@" 2>&1 | tee -a "$LOGFILE"
    return "${PIPESTATUS[0]}"
}

finish_step() {
    date | tee -a "$LOGFILE"
}

# latest_run <chain>   The newest RUN a pipetask -o <chain> wrote (pipetask
# puts each new RUN at the front of the chain).
latest_run() {
    butler query-collections "$REPO" "$1/*" | awk '$2 == "RUN" { print $1 }' | sort | tail -1
}

# own_runs <chain>   The RUNs named <chain>/..., comma separated (empty if
# none): what --skip-existing-in needs to skip work done by earlier runs of
# the chain. Plain --skip-existing looks only in the new, empty output RUN.
own_runs() {
    butler query-collections "$REPO" "$1/*" | awk '$2 == "RUN" { print $1 }' | paste -sd, -
}

# submit <name> <dependency-job-id or empty> <script> [args...]
submit() {
    local name=$1 dep=$2 script=$3
    shift 3
    local cmd=(sbatch --parsable -J "gwp_calib_${SET}_${name}"
        -o "$SLURM_LOGDIR/gwprimo_calib_${SET}_${name}_%j.out"
        -e "$SLURM_LOGDIR/gwprimo_calib_${SET}_${name}_%j.err"
        --export="ALL,GWP_CALIB_DIR=$GWP_CALIB_DIR,GWP_SET_CONF=$GWP_SET_CONF")
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
