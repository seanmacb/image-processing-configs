# DECam / DESGW

Processing for the DESGW gravitational-wave follow-up with DECam: calibration
products, good-seeing templates, the AP (alert-production style
difference-imaging) pipeline with synthetic source injection, and verification
of the results. See the [top-level README](../../README.md) for the environment
variables (`$REPO`, `$LOGDIR`, `$IMAGE_PROC_CONFIG_DIR`) every script relies on.

## Layout

| Path | Purpose |
|---|---|
| `configs/` | Pipeline YAML and Python support code (below). |
| `startup/` | One-time / backlog setup of the Butler: ingestion, calibrations, injection catalogs, bulk template building. |
| `calib/base/` | `cp_verify` runs for the bias and flat calibrations, per era. |
| `pilot/` | Event-specific runs for the pilot event `S250830bp`: its templates, the AP pipeline, and afterburners. |
| `verify/` | Quality checks: `ap_verify` with fakes, and template PSF measurement. |

### `configs/`

| File | What it is |
|---|---|
| `QuickTemplate.yaml` | DECam template-building pipeline (ISR, `calibrateImage`, warps, good-seeing coadd). Uses `the_monster_20250219` as the astrometric and photometric reference catalog, and tolerates a missing Gaussian-flux aperture correction so z-band detectors are not lost. |
| `desgw_ap_pipe.yaml` | The production AP pipeline: `ApPipeWithFakes` with solar-system association removed, templates as inputs, and 1-mag-bin fake-recovery analysis tasks. Its header lists the prerequisites. |
| `fakes_mag_bins_afterburner.yaml` | Afterburner: recomputes fake-recovery metrics in 1-mag bins (15-24) from an existing AP run without rerunning anything upstream. (A copy lives in `pilot/`.) |
| `desgw_injection_catalog.yaml` | Parameters for generating injection catalogs (not a pipeline). |
| `desgw_verify_bias.yaml`, `desgw_verify_flat.yaml` | `cp_verify` pipelines with a workaround for the DECam `MJD` / `MJD-OBS` header mismatch. |
| `desgw_isr_statistics.py` | `IsrStatisticsTask` subclass that backfills `MJD`, used by the two verify pipelines. It must be on `PYTHONPATH` in the worker processes. |

## Workflow

The stages roughly run in this order. Each directory holds the scripts for one
stage, and most scripts are per-era (`14`, `15-16`, `17-18`, `19-20`, `21-22`,
`23-24`, `25-26`, meaning 2014-2026).

1. **Ingest raws** (`startup/ingestion/`). Bias and flat frames per era
   (`ingest_bias_*.sh`, `ingest_flat_*.sh`), and the template exposures
   (`ingest_templates_desgw.sh`, `ingest_templates_gwmmads.sh`), all with
   `butler ingest-raws --transfer link`. `update_visits.sh` runs
   `butler define-visits` afterwards (`pilot/define_visits.sh` is the same step).
2. **Calibrations** (`startup/calib/`). `build-overscanRaw_flats_*.sh` produces
   the crosstalk-source `overscanRaw` images, then `build-bias_*.sh`,
   `build-flat-*.sh` and `build-fringe-*.sh` run the `cp_pipe` pipelines into
   `DECam/calib/template/<type>/<era>`. `certify-fringe-15-16.sh` certifies a
   finished set into `DECam/calib`. `complete-fringe-15-16.sh` finishes the
   2015-16 z-band fringe after the initial run (see its header).
3. **Verify calibrations** (`calib/base/verify-bias-*.sh`, `verify-flat-*.sh`)
   with `cp_verify`, writing to `DECam/calib/verify/<type>/<era>`.
4. **Templates** (`startup/templates/`). See [Building templates](#building-templates).
5. **Injection catalogs** (`startup/injection/`). `make_injection_catalog.sh`
   generates one catalog per band from `configs/desgw_injection_catalog.yaml`,
   and `ingest_injection_catalog.sh` ingests it (shards by HTM7 trixel).
   `submit_ingest_injection_catalog.sh` is the Slurm wrapper for the full-sky
   catalogs; they are ~6.5 GB per band, so budget hours. The ingested
   collection must exist before the AP pipeline's quantum graph is built.
6. **AP pipeline** (`pilot/run-ap-pipe.sh`) runs `configs/desgw_ap_pipe.yaml`
   for one event into `DECam/search/<event>`. Prerequisites are in the yaml
   header: calibrations, templates, `overscanRaw`, an APDB, the injection
   catalog, and the RBTransiNet model package in `-i`.
   - `run-ap-pipe-afterburn.sh` then `run-ap-pipe-afterburn-execute.sh` split
     the run into a per-night quantum-graph build (4-task array) and a
     per-night execution (4-task array).
   - `run-ap-pipe-magFake.sh` and `fakes_mag_bins_afterburner.yaml` rerun only
     the fake-recovery analysis tasks.
7. **Verification** (`verify/`). `run-ap-verify-fakes.sh` is a template for
   `ApVerifyWithFakes.yaml` (edit `TARGET_NAME` first, and use a dedicated
   APDB, not the production one). `run-measure-template-psf.sh <event>` runs
   `measure_template_psf.py` in parallel and writes per-patch and per-tract PSF
   CSVs to `$LOGDIR/templatePsf/<event>/`; `evaluate_template_psf_quality.ipynb`
   plots them.

## Building templates

`startup/templates/build-template.sh` builds good-seeing templates for the
whole DESGW archive, all four bands at once, as a Slurm array: one task per
band (`g r i z`), each on its own 120-core / 472 GB node.

```bash
sbatch startup/templates/build-template.sh
```

Why an array: the template pipeline has no cross-band dependencies, so each
band is an independent graph and scales out across nodes, which a single
`pipetask -j` cannot do.

Each task:

1. Builds a quantum graph with `pipetask qgraph` and saves it as
   `$LOGDIR/buildTemplate-DESGW_<band>_<jobid>.qg`. This step only reads the
   repo, so the four tasks can run it concurrently. The new `.qg` format is
   much faster to write than the old `.qgraph`.
2. Runs `pipetask run -g <graph> -j 120 --register-dataset-types
   --no-raise-on-partial-outputs`. Tasks start 30 s apart so they do not
   register dataset types simultaneously.

Outputs go to `DECam/templates/pilotProc/<band>`. When all four finish, chain
them:

```bash
butler collection-chain $REPO DECam/templates/pilotProc \
    DECam/templates/pilotProc/{g,r,i,z}
```

The data query excludes detectors 61 and 31, detector 2 before 2016-12-29, and
several science programs (see `DATAQUERY`). If the run is interrupted, rebuild
the graph rather than reusing the old one, because `--skip-existing-in` is
evaluated when the graph is built.

`build-overscanRaw-templates-desgw.sh` produces the `overscanRaw` crosstalk
sources needed before template building. The `pilot/` scripts do the same for
a single event on 30 cores.

## Gotchas

These were learned the hard way; the scripts carry the detailed write-ups.

- **`--no-raise-on-partial-outputs`** is needed on template and AP runs.
  Without it one failed `calibrateImage` detector fails every downstream
  quantum of its whole visit.
- **Write exclusion lists in CNF**, as in `(exposure != X OR detector NOT IN (...))`
  clauses. `NOT ((exposure=X AND detector=Y) OR ...)` makes the Butler query
  normalizer blow up in time and memory. A long flat disjunction in a data query
  can also OOM `pipetask qgraph` (see the header of `run-ap-pipe-afterburn.sh`).
- **`pipetask` workers are spawned, not forked.** Monkeypatching in a pipeline
  `python:` block does not reach them. Put custom classes in an importable module
  and export `PYTHONPATH` (as the `verify-*.sh` scripts do for
  `desgw_isr_statistics.py`).
- **`pipetask qgraph` has no `--register-dataset-types`.** Register at `run`
  time.
- **Do not `--extend-run` over a broken run.** The `verify-*.sh` scripts start a
  fresh RUN under the same chain on purpose, because the earlier RUNs have
  different recorded configs.
- **Raw "CCD not read out" stubs** (100x100 HDUs of constant 32768) crash ISR
  and are excluded in `build-fringe-15-16.sh` and `complete-fringe-15-16.sh`.
- **z band is the weakest:** it is sky-limited, so a share of its detectors
  fail calibration. That is why `QuickTemplate.yaml` relaxes the aperture
  correction.
- **Several `pilot/` scripts hard-code a run timestamp** (for example
  `--skip-existing-in DECam/search/S250830bp/<timestamp>`). Check it before
  reusing them for another event.
