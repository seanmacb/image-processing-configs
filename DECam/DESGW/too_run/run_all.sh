#!/usr/bin/bash
# A whole event in one command: preflight, phase 1 (templates), then phase 2
# (search) for each night in turn. The nights run strictly one after another
# (they share the APDB and the output collections); each night's downloads start
# immediately, the rest of its chain waits for the previous chain's last verify.
#
#   run_all.sh <conf> --nights N1,N2,... [--propid ID] [--skip-templates]
#              [--dry-run] [--skip-preflight]
#
# --skip-templates reuses templates that already passed verify_templates.sh
# (the marker must exist). Nights observed later can be added with run_search.sh.
# --dry-run prints every sbatch command without submitting anything.

TOO_RUN_NO_STACK=1
TOO_RUN_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$TOO_RUN_DIR/common.sh"

CONF=${1:-}
[[ -n $CONF && $CONF != -* ]] || die "usage: run_all.sh <conf> --nights N1,N2,... [--propid ID] [--skip-templates] [--dry-run] [--skip-preflight]"
shift
NIGHTS="" DRY_RUN=0 SKIP_PREFLIGHT=0 SKIP_TEMPLATES=0 PROPID=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --nights) NIGHTS=${2:?--nights needs a comma-separated list}; shift 2 ;;
        --propid) PROPID=${2:?--propid needs an id}; shift 2 ;;
        --skip-templates) SKIP_TEMPLATES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
export DRY_RUN PROPID
[[ -n $NIGHTS ]] || die "--nights is required"
for n in ${NIGHTS//,/ }; do
    [[ $n =~ ^[0-9]{8}$ ]] || die "bad night '$n' (expected YYYYMMDD)"
done

load_conf "$CONF"
[[ -n $PROPID ]] || die "no PROPID: set it in $TOO_RUN_CONF or pass --propid"
export PROPID
if [[ $DRY_RUN == 0 && $SKIP_PREFLIGHT == 0 ]]; then
    # With templates still to be built, they cannot be checked yet.
    "$TOO_RUN_DIR/00_preflight.sh" "$TOO_RUN_CONF" $([[ $SKIP_TEMPLATES == 1 ]] && echo search || echo all) \
        || die "preflight failed"
fi

GATE=$(queued_chain_ends)
if [[ $SKIP_TEMPLATES == 0 ]]; then
    [[ -n $TEMPLATE_QUERY ]] || die "$TOO_RUN_CONF needs RA_MIN, RA_MAX, DEC_MIN and DEC_MAX"
    NIGHT="" submit_chain templates
    GATE=$LAST_JOB
fi

for night in ${NIGHTS//,/ }; do
    NIGHT=$night
    export NIGHT
    submit_chain search
    GATE=$LAST_JOB
done
echo "event $EVENT submitted; last job: $LAST_JOB"
