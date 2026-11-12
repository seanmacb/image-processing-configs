# too_run: one ToO follow-up, end to end

Slurm scripts that take a gravitational-wave follow-up from raw archive images to
AP-pipeline output, with a verification job after every step. The code knows
nothing about any particular event: everything event-specific is in one file,
`events/<EVENT>/too_run.conf`. See the [DESGW README](../README.md) and the
[top-level README](../../../README.md) for the environment (`$REPO`, `$LOGDIR`,
`$IMAGE_PROC_CONFIG_DIR`) these scripts rely on.

## Quick start

```bash
cd DECam/DESGW/too_run
./new_event.sh S260101ab                  # creates events/S260101ab/too_run.conf
$EDITOR events/S260101ab/too_run.conf     # EVENT_DATE, sky box, PROPID, INJECTION_COLLECTION
./run_all.sh events/S260101ab/too_run.conf --nights 20260102,20260105 --dry-run   # look first
./run_all.sh events/S260101ab/too_run.conf --nights 20260102,20260105
```

`new_event.sh <EVENT> --like <OTHER>` starts from another event's conf instead of
the template. `events/S250830bp/too_run.conf` reproduces the pilot run. The
folder has no hard-coded paths of its own, so it can also be copied elsewhere.

## The two phases

**Phase 1, templates (once per event), `run_templates.sh <conf>`**

| Step | What it does | Its verify job checks |
|---|---|---|
| `download` | Selects exposures from the DELVE table (`DECam/data/delve_dr3qr_combo_v10.csv`) inside the sky box and before the event, drops those already in the Butler or on disk, downloads the rest as raws. | Manifest complete; every file present, right size, readable FITS with the right EXPNUM; every selected exposure accounted for. |
| `ingest` | `butler ingest-raws --transfer link`. | Every exposure has an `exposure` record and at least `MIN_RAW_PER_EXPOSURE` raws. |
| `visits` | `butler define-visits`. | A visit with a region and detector regions for every science exposure. |
| `overscan` | `RunIsrForCrosstalkSources.yaml` into `DECam/calib/template/<EVENT>/overscanRaw`. | `overscanRaw` exists for all but `OVERSCAN_MAX_MISSING_FRAC` of the selected (exposure, detector). |
| `templates` | `QuickTemplate.yaml` into `DECam/templates/<EVENT>`. | Per band, `template_coadd` exists for at least `TEMPLATE_MIN_COVERAGE` of the (tract, patch) cells the template exposures overlap; template PSF FWHM (warning only); writes the marker the search phase requires. |

**Phase 2, search (once per night), `run_search.sh <conf> --night YYYYMMDD [--propid ID]`**

| Step | What it does | Its verify job checks |
|---|---|---|
| `download` | Every raw exposure of `PROPID` on the night. | As above, plus the `PROPID` header. |
| `ingest`, `visits`, `overscan` | As in phase 1, with the night's data query. | As in phase 1; `visits` also checks that the target is `LVK_<EVENT>`. |
| `ap` | `desgw_ap_pipe.yaml` into `DECam/search/<EVENT>`. Before starting it requires the templates marker and that the templates cover the night's visits (`SEARCH_TEMPLATE_MIN_COVERAGE`). | Per visit-detector: calibrated image, difference image, DIA sources, fake matches (minimum shares `AP_MIN_ISR_FRAC`, `AP_MIN_DIFF_FRAC`); quanta left unrun; fake-recovery mag-bin products. Writes `$LOGDIR/too_run_<EVENT>_<night>_summary.txt`. |

`run_all.sh <conf> --nights N1,N2,...` runs preflight, phase 1 and then each night.
`--skip-templates` reuses templates that already passed.

Each step and its verify job are separate Slurm jobs chained with
`--dependency=afterok`, so a failed step or a failed check stops the chain and
leaves a log of exactly what failed. All the drivers take `--dry-run` (print the
`sbatch` commands, submit nothing), `--skip-preflight`, and, for a single phase,
`--from <step>` to resume. Every step is safe to repeat: downloads skip files
that are already complete, ingest uses `--skip-existing`, and `pipetask` uses
`--skip-existing`.

## Several nights of one event

Run `run_search.sh` once per night, whenever a night has been observed. The nights
share the output collections and one APDB, so they must not run at the same time:
a new chain looks for this event's chains that are still queued or running and
waits for them (its download starts at once, everything that writes to the Butler
waits). If an earlier job fails, jobs that depend on it stay pending with
`DependencyNeverSatisfied`; `scancel` them after fixing the problem, then re-run
the driver with `--from <step>`.

All nights write to the same overscan and `DECam/search/<EVENT>` chains; each
`pipetask run` adds a new timestamped RUN to the chain. The `-i` list does not
depend on the night, because `pipetask` refuses an existing output chain whose
inputs differ.

## Files

| File | Role |
|---|---|
| `too_run.conf.template`, `events/<EVENT>/too_run.conf` | Per-event settings; the template documents every variable. |
| `common.sh` | Stack setup, defaults, the data queries, per-step context, `sbatch` chaining. |
| `00_preflight.sh` | Read-only prerequisite check (collections, reference catalog, APDB, injection catalog, model package, archive reachable, templates marker). The drivers run it first. |
| `run_templates.sh`, `run_search.sh`, `run_all.sh` | Drivers. |
| `steps/*.sh` | One script per step and per verify job. Run directly with `TOO_RUN_CONF=<conf> [NIGHT=..] bash steps/<script> <phase>` to try a step without Slurm. |
| `select_template_exposures.py` | DELVE table to `events/<EVENT>/template_exposures.csv`. |
| `get_raw_images.py` | NOIRLab archive search and download. |
| `verify_raw_files.py`, `verify_butler.py` | The checks. |

## Notes

- **No credentials.** The archive search and download are anonymous.
  `get_raw_images.py` names files `DECam_<expnum>.fits.fz` and checks size and md5
  against the archive before keeping a file.
- **Template inputs exclude the follow-up programs** (`TEMPLATE_EXCLUDE_PROGRAMS`,
  plus the event's `PROPID`) so a template can never contain the transient.
- **`overscanRaw` is built for the search nights too.** `pilot/` built it only for
  the template footprint; `desgw_ap_pipe.yaml` points its ISR at `overscanRaw`
  for the science exposures as well, so the search phase produces it for them.
- **A step can succeed with a non-zero `pipetask` status.** Detectors routinely
  fail (see the `--no-raise-on-partial-outputs` notes in the scripts), so the step
  records the status in `$LOGDIR/too_run_<EVENT>_<tag>_<step>.status` and the verify
  job decides from what was actually produced. Thresholds are in the conf.
- **`DECam/data/` is untracked.** `delve_dr3qr_combo_v10.csv` is 53 MB; decide
  whether it belongs in git before committing it. Override its location with
  `TEMPLATE_CSV`.
- The APDB is not queried directly; the verify job checks the `dia_source_apdb`
  datasets the association step writes.
- Logs: `$LOGDIR/too_run_<EVENT>_<templates|search_NIGHT>_<step>.log`, Slurm
  output in `/shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/`.
