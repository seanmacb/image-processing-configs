#!/usr/bin/bash
# Create the conf for a new GW-Primo field.
#
#   new_field.sh <FIELD> [--like <OTHER_FIELD>]
#
# Writes ../fields/<FIELD>/field.conf from field.conf.template (or from another
# field's conf with --like) and prints the variables still to fill in.

set -o pipefail
RUN_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
FIELDS_DIR=$(cd "$RUN_DIR/.." && pwd)/fields

die() { echo "ERROR: $*" >&2; exit 1; }

FIELD=${1:-}
[[ -n $FIELD && $FIELD != -* ]] || die "usage: new_field.sh <FIELD> [--like <OTHER_FIELD>]"
[[ $FIELD =~ ^[A-Za-z0-9_.-]+$ ]] || die "FIELD may only contain letters, digits, '_', '.', '-'"
shift
LIKE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --like) LIKE=${2:?--like needs a field}; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

dest=$FIELDS_DIR/$FIELD/field.conf
[[ -e $dest ]] && die "$dest already exists"
mkdir -p "$(dirname "$dest")"
if [[ -n $LIKE ]]; then
    src=$FIELDS_DIR/$LIKE/field.conf
    [[ -r $src ]] || die "no conf for field '$LIKE' ($src)"
    sed "s/^FIELD=.*/FIELD=$FIELD/" "$src" > "$dest"
else
    sed "s/^FIELD=.*/FIELD=$FIELD/" "$RUN_DIR/field.conf.template" > "$dest"
fi
echo "wrote $dest"
grep -nE '^(FIELD|REGION)=$' "$dest" | sed 's/^/  still empty: line /'
echo "next: \$EDITOR $dest, then $RUN_DIR/00_preflight.sh $dest"
