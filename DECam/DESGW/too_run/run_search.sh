#!/usr/bin/bash
# Phase 2: process one night of an event. Submits, chained with
# sbatch --dependency=afterok, each step followed by its verify job:
#
#   download -> verify -> ingest -> verify -> define visits -> verify
#            -> overscanRaw -> verify -> ap_pipe -> verify_ap_pipe
#
# Run it once per observed night; the nights of an event are independent apart
# from sharing the output collections and the APDB. If an earlier night's (or the
# templates') jobs are still queued, this night's downloads start straight away
# but everything that touches the Butler waits for them to finish.
#
#   run_search.sh <conf> --night YYYYMMDD [--propid ID] [--from <step>]
#                 [--dry-run] [--skip-preflight]
#
# --propid overrides PROPID in the conf (a program can change between nights).
# <step> is one of: download ingest visits overscan ap. Every step is safe to
# repeat. --dry-run prints the sbatch commands without submitting anything.

TOO_RUN_NO_STACK=1
TOO_RUN_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$TOO_RUN_DIR/common.sh"

CONF=${1:-}
[[ -n $CONF && $CONF != -* ]] || die "usage: run_search.sh <conf> --night YYYYMMDD [--propid ID] [--from <step>] [--dry-run] [--skip-preflight]"
shift
FROM="" DRY_RUN=0 SKIP_PREFLIGHT=0 NIGHT="" PROPID=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --night) NIGHT=${2:?--night needs YYYYMMDD}; shift 2 ;;
        --propid) PROPID=${2:?--propid needs an id}; shift 2 ;;
        --from) FROM=${2:?--from needs a step}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
export DRY_RUN NIGHT PROPID
[[ $NIGHT =~ ^[0-9]{8}$ ]] || die "--night YYYYMMDD is required"

load_conf "$CONF"
[[ -n $PROPID ]] || die "no PROPID: set it in $TOO_RUN_CONF or pass --propid"
export PROPID
if [[ $DRY_RUN == 0 && $SKIP_PREFLIGHT == 0 ]]; then
    "$TOO_RUN_DIR/00_preflight.sh" "$TOO_RUN_CONF" search || die "preflight failed"
fi

GATE=$(queued_chain_ends)
submit_chain search "$FROM"
echo "search chain for $EVENT night $NIGHT submitted; last job: $LAST_JOB"
