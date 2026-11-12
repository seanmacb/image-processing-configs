#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8GB
#SBATCH --time=72:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_download_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_download_%j.err

# Download raw DECam exposures from the NOIRLab Astro Data Archive (anonymous).
#
#   download_raw.sh templates   Select exposures from the DELVE table
#                               ($TEMPLATE_CSV) inside the event's sky box and
#                               before the event, then fetch the ones that are
#                               not already ingested or on disk.
#   download_raw.sh search      Fetch every raw exposure of $PROPID on $NIGHT.
#
# Needs TOO_RUN_CONF (and NIGHT, PROPID for the search phase) in the environment;
# the drivers set them. Writes $RAWDIR/manifest.csv; verify_download.sh checks it.

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" download

if [[ $PHASE == templates ]]; then
    select_args=(--csv "$TEMPLATE_CSV"
        --ra-min "$RA_MIN" --ra-max "$RA_MAX" --dec-min "$DEC_MIN" --dec-max "$DEC_MAX"
        --start "$TEMPLATE_START" --end "$TEMPLATE_END" --bands $BANDS
        --exclude-propid $TEMPLATE_EXCLUDE_PROGRAMS $PROPID
        --out "$EXPOSURE_LIST")
    [[ -n $TEFF_MIN ]] && select_args+=(--teff-min "$TEFF_MIN")
    [[ -n $FWHM_MAX ]] && select_args+=(--fwhm-max "$FWHM_MAX")
    [[ -n $MAX_PER_BAND ]] && select_args+=(--max-per-band "$MAX_PER_BAND")
    run_logged python "$TOO_RUN_DIR/select_template_exposures.py" "${select_args[@]}" \
        || die "no template exposures selected from $TEMPLATE_CSV"

    # Exposures already in the Butler need neither a download nor an ingest.
    tail -n +2 "$EXPOSURE_LIST" | cut -d, -f1 > "$RAWDIR/selected_expnums.txt"
    python "$TOO_RUN_DIR/verify_butler.py" ingested-expnums \
        --expnums-file "$RAWDIR/selected_expnums.txt" \
        > "$RAWDIR/already_ingested.txt" 2>> "$LOGFILE" \
        || die "could not query the Butler for ingested exposures (see $LOGFILE)"
    log "$(wc -l < "$RAWDIR/already_ingested.txt") of $(wc -l < "$RAWDIR/selected_expnums.txt") selected exposures are already ingested" | tee -a "$LOGFILE"

    # Files fetched for earlier runs live in these directories; reuse them
    # (same lookup get_templates.py does).
    skip_dirs=()
    for d in "$FITS_ROOT/desgw/templates_desgw" "$FITS_ROOT/desgw/templates_gwmmads" "$FITS_ROOT/gw-primo/templates"; do
        [[ -d $d ]] && skip_dirs+=(--skip-dir "$d")
    done
    run_logged python "$TOO_RUN_DIR/get_raw_images.py" --outdir "$RAWDIR" \
        --exposure-list "$EXPOSURE_LIST" --skip-expnums "$RAWDIR/already_ingested.txt" \
        "${skip_dirs[@]}" --workers "$DOWNLOAD_WORKERS"
else
    run_logged python "$TOO_RUN_DIR/get_raw_images.py" --outdir "$RAWDIR" \
        --propid "$PROPID" --night "$NIGHT" --workers "$DOWNLOAD_WORKERS"
fi
rc=$?
finish_step
exit $rc
