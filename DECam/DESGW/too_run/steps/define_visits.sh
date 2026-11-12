#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32GB
#SBATCH --time=12:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_visits_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_visits_%j.err

# Define visits for the newly ingested exposures.
#
# This is the same call as startup/ingestion/update_visits.sh. It is already an
# incremental update: --prefilter (the default) drops exposures that are
# already associated with a visit before computing anything, so running it
# after every ingest only does the new work. If the exposure records ever
# change (e.g. a metadata translator fix), add --update-records.
#
#   define_visits.sh <templates|search>

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" visits

run_logged butler define-visits "$REPO" lsst.obs.decam.DarkEnergyCamera
rc=$?
finish_step
exit $rc
