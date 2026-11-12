#!/usr/bin/bash
# Start a new event: create events/<EVENT>/too_run.conf, the only file that holds
# anything event-specific.
#
#   new_event.sh <EVENT> [--like <OTHER_EVENT>]
#
# By default the conf is a copy of too_run.conf.template. With --like it starts
# from another event's conf instead (its EVENT is replaced; the dates and sky box
# still need editing).

set -o pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

usage() { echo "usage: new_event.sh <EVENT> [--like <OTHER_EVENT>]" >&2; exit 1; }
[[ $# -ge 1 && $1 != -* ]] || usage
EVENT=$1
shift
LIKE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --like) LIKE=${2:?--like needs an event}; shift 2 ;;
        *) usage ;;
    esac
done
[[ $EVENT =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: EVENT may only contain letters, digits, - and _" >&2; exit 1; }

dest=$HERE/events/$EVENT
[[ ! -e $dest/too_run.conf ]] || { echo "ERROR: $dest/too_run.conf already exists" >&2; exit 1; }
if [[ -n $LIKE ]]; then
    src=$HERE/events/$LIKE/too_run.conf
    [[ -r $src ]] || { echo "ERROR: no conf for event $LIKE ($src)" >&2; exit 1; }
else
    src=$HERE/too_run.conf.template
fi

mkdir -p "$dest"
sed -e "s/^EVENT=.*/EVENT=$EVENT/" "$src" > "$dest/too_run.conf"
echo "created $dest/too_run.conf"
echo "edit EVENT_DATE, the sky box, PROPID and INJECTION_COLLECTION, then:"
echo "  $HERE/run_all.sh $dest/too_run.conf --nights <YYYYMMDD,...> --dry-run"
