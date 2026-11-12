#!/usr/bin/bash
# Phase 1: build the templates for an event. Submits, chained with
# sbatch --dependency=afterok, each step followed by its verify job:
#
#   download -> verify -> ingest -> verify -> define visits -> verify
#            -> overscanRaw -> verify -> build templates -> verify_templates
#
# A failed step or verify stops the chain. verify_templates writes the marker the
# search phase requires.
#
#   run_templates.sh <conf> [--from <step>] [--dry-run] [--skip-preflight]
#
# <step> is one of: download ingest visits overscan templates. Use --from to
# resume after fixing a failure; every step is safe to repeat.
# --dry-run prints the sbatch commands without submitting anything.

TOO_RUN_NO_STACK=1
TOO_RUN_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$TOO_RUN_DIR/common.sh"

CONF=${1:-}
[[ -n $CONF && $CONF != -* ]] || die "usage: run_templates.sh <conf> [--from <step>] [--dry-run] [--skip-preflight]"
shift
FROM="" DRY_RUN=0 SKIP_PREFLIGHT=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --from) FROM=${2:?--from needs a step}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
export DRY_RUN

load_conf "$CONF"
[[ -n $TEMPLATE_QUERY ]] || die "$TOO_RUN_CONF needs RA_MIN, RA_MAX, DEC_MIN and DEC_MAX"
if [[ $DRY_RUN == 0 && $SKIP_PREFLIGHT == 0 ]]; then
    "$TOO_RUN_DIR/00_preflight.sh" "$TOO_RUN_CONF" templates || die "preflight failed"
fi

GATE=$(queued_chain_ends)
submit_chain templates "$FROM"
echo "templates chain for $EVENT submitted; last job: $LAST_JOB"
