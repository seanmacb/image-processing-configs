#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32GB
#SBATCH --time=24:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_ingest_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_ingest_%j.err

# Ingest the downloaded raws into the Butler (default raw run, DECam/raw/all),
# with the same `butler ingest-raws --transfer link` call as startup/ingestion/.
# Files come from the download manifest: those fetched into $RAWDIR, plus the
# ones the download step found already on disk in another directory. Exposures
# already in the Butler are skipped (--skip-existing), so re-running is safe.
#
#   ingest_raw.sh <templates|search>

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" ingest

[[ -r $MANIFEST ]] || die "no manifest at $MANIFEST: run the download step first"
# manifest columns: expnum filename md5sum filesize band propid caldat status note
mapfile -t FILES < <(awk -F, -v dir="$RAWDIR" '
    NR > 1 && ($8 == "downloaded" || $8 == "present") { print dir "/" $2 }
    NR > 1 && $8 == "skipped_elsewhere" { printf "%s/DECam_%08d.fits.fz\n", $9, $1 }' "$MANIFEST")
log "${#FILES[@]} files to ingest" | tee -a "$LOGFILE"
if [[ ${#FILES[@]} -eq 0 ]]; then
    log "nothing to ingest (everything is already in the Butler)" | tee -a "$LOGFILE"
    finish_step
    exit 0
fi

rc=0
# Chunked so a template run with thousands of files stays well under ARG_MAX.
for ((i = 0; i < ${#FILES[@]}; i += 2000)); do
    run_logged butler ingest-raws "$REPO" "${FILES[@]:i:2000}" \
        --transfer link --skip-existing -j "$INGEST_PROCESSES" || rc=$?
done
finish_step
exit $rc
