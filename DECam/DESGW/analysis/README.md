# template_coadd QA (analysis_tools)

`template_coadd_analysis.yaml` (subset `template_coadd_qa`) adds QA products for the
DESGW difference-imaging templates (`template_coadd`, built by
`../configs/QuickTemplateBestSeeing.yaml`). `template_coadd_analysis.sh` runs it.

It is **additive**. The template pipeline's `makeMetrics` subset (ap_pipe
`QuickTemplate.yaml`, which pulls tasks from drp_pipe `base-v2.yaml` and analysis_tools
`coaddDepthMetrics.yaml`) already writes binned coadds, whole-tract plots, mask-fraction
metrics and the n_image depth table/metrics. This pipeline reads those and adds only
what `makeMetrics` never produces.

## Run

The script sources `DESGW_CONFIGS` (stack, `$REPO`, `$LOGDIR`); all settings are env vars.

Build and save the graph only (no execution, nothing written to the repo):

```bash
MODE=qgraph BAND=g bash template_coadd_analysis.sh
```

One tract:

```bash
MODE=qgraph TRACT=4250 BAND=g bash template_coadd_analysis.sh
```

Run on the cluster:

```bash
sbatch --export=ALL,BAND=g template_coadd_analysis.sh
```

All of g, r and i in one job. Set a band list in front of `sbatch`, not inside
`--export=`, because `--export` splits on commas and `--export=ALL,BAND=g,r,i` would give `BAND=g`:

```bash
INPUT_COLLECTION=DECam/templates/bestSeeing_wide_gri BAND=g,r,i sbatch --export=ALL template_coadd_analysis.sh
```

Another template collection:

```bash
sbatch --export=ALL,INPUT_COLLECTION=DECam/templates/bestSeeing_wide/r/<ts>,BAND=r template_coadd_analysis.sh
```

| variable | default | notes |
|---|---|---|
| `INPUT_COLLECTION` | `DECam/templates/bestSeeing_wide/g/20261027T133747Z` | must hold the upstream `makeMetrics` outputs |
| `TRACT` | empty, meaning all tracts | |
| `BAND` | empty, meaning all bands | one band or a list (`g`, `g,r,i`, `"g r i"`); becomes `band IN (...)` and also restricts the band-parameterized depth whole-sky plots |
| `SKYMAP` | `decam_rings_v1` | the data query must constrain skymap when it names a tract |
| `SKYMAP_COLLECTION` | `skymaps` | appended to the inputs; template RUNs don't contain `skyMap` |
| `OUTPUT` | `DECam/templates/analysis/<input w/o DECam/templates/ and timestamp>/<UTC ts>` | output RUN |
| `MODE` | `run` | `qgraph` builds the graph and saves it to `$LOGDIR/templateCoaddAnalysis_<ts>.qg` |
| `JOBS` | `$SLURM_CPUS_PER_TASK` or 8 | `pipetask -j` |

The equivalent raw commands:

```bash
pipetask build -p template_coadd_analysis.yaml --show pipeline --show config
```

```bash
pipetask qgraph -b $REPO -i DECam/templates/bestSeeing_wide/g/20261027T133747Z,skymaps \
    --output-run DECam/templates/analysis/bestSeeing_wide/g/<ts> \
    -p "template_coadd_analysis.yaml#template_coadd_qa" \
    -c "coaddDepthWholeSkyPlotTemplate:bands=['g']" \
    -d "skymap='decam_rings_v1' AND band='g'"
```

## Tasks

| label | class | reads (already in the collection) | writes |
|---|---|---|---|
| `coaddDepthPlotTemplate` | `CoaddDepthSummaryPlotTask` | `template_coadd_n_image` {band,patch,skymap,tract}, `skyMap` | `coadd_depth_template_n_image_CoaddDepthPlot` (Plot, {skymap,tract}) |
| `makeCoaddDepthMetricTableTemplate` | `MakeMetricTableTask` | `template_coadd_depth_summary_metrics` {skymap,tract} | `coadd_depth_summary_metrics_table_template` (ArrowAstropy, {skymap}) |
| `coaddDepthWholeSkyPlotTemplate` | `WholeSkyAnalysisTask` (`config/coaddDepthMetricsWholeSkyPlot.py`) | table above | `coadd_depth_template_coadd_depth_summary_metrics_depth_above_threshold_{1,2,3,5,12}_mean_WholeSkyPlot` (Plot, {band,skymap}) |
| `makeMaskFractionMetricTableTemplate` | `MakeMetricTableTask` | `template_coadd_tract_mask_fraction_metrics` {band,skymap,tract} | `coadd_tract_mask_fraction_metrics_table_template` (ArrowAstropy, {band,skymap}) |
| `maskFractionWholeSkyPlotTemplate` | `WholeSkyAnalysisTask` (`config/aggregatedMaskFractionsWholeSkyPlot.py`) | table above | `coadd_mask_fraction_template_{NO_DATA,CLIPPED,DETECTED,NOT_DEBLENDED}_fraction_mean_WholeSkyPlot` (Plot, {band,skymap}) |
| `analyzeAssembleTemplateCoaddMetadataTemplate` | `TaskMetadataAnalysisTask` + `TaskMetadataMetricTool` | `assembleTemplateCoadd_metadata` {band,patch,skymap,tract} | `assembleTemplateCoadd_metadata_template_metrics` (`interpolated_pixel_count` from `assembleTemplateCoadd:interpImage`) |
| `makeAssembleMetadataMetricTableTemplate` | `MakeMetricTableTask` | metrics above | `assembleTemplateCoadd_metadata_metrics_table_template` (ArrowAstropy, {band,skymap}; tract and patch columns) |

All new dataset types end in `_template` or contain `_template_`. Before this was written,
none of these names existed in the repo, and none collides with the `deep_*` or upstream
`template_*` QA products.

## Not included, and why

| task | reason |
|---|---|
| `MakeBinnedCoaddTask` | `template_coadd_bin` and `template_coadd_n_image_bin` already exist for every patch (upstream: binFactor 16, `doBinInnerBBox: true`). |
| `WholeTractImageAnalysisTask` | The whole-tract plots (`template_coaddImage_`, `template_clippedMask_`, `template_coaddImagePostageStamp_`, `template_nImage_WholeTractImage`) already exist. |
| `WholeTractMaskFractionAnalysisTask` | `template_coadd_tract_mask_fraction_metrics` already exists; this pipeline only tabulates and plots it. |
| `CoaddDepthSummaryTask`, `CoaddDepthTableTractAnalysisTask` | `template_coadd_depth_table` and `template_coadd_depth_summary_metrics` already exist. |
| `CalexpSummaryAnalysisTask` | Dimensions are hard-wired to {visit,band,detector}, and `template_coadd.summaryStats` is `None` (CompareWarpAssembleCoaddTask doesn't fill it). |
| PSF size / noise | No analysis_tools task measures these on a coadd. This was left out by choice; a custom task would be needed. |

To run the omitted upstream tasks yourself (for example on tracts that lack them), use the
`makeMetrics` subset of `$AP_PIPE_DIR/pipelines/DECam/QuickTemplate.yaml`.

## Known issues

- **44 tracts have templates but no upstream tract-level QA**, and there are no logs for
  them either. In `bestSeeing_wide/g/20261027T133747Z` those tracts are 152, 153, 247,
  248, 255, 314, 377, 378, 381, 451, 2105, 2258, 2404, 2420, 2570, 2581, 3657, 3730, 3731,
  3853, 4051, 4126, 4184, 4592, 4593, 4803, 4915, 5016, 5568–5571, 5670, 5899, 5904, 5906,
  6351, 6586, 6709, 6942, 7052, 7180, 7290 and 7892.
  - They are missing from the depth and mask-fraction tables and whole-sky plots.
  - `coaddDepthPlotTemplate` and the metadata metrics still cover them, because those
    tasks read `template_coadd_n_image` and `assembleTemplateCoadd_metadata` directly.
  - Fix: run the upstream `makeMetrics` subset on those tracts, then rerun this pipeline.
- **`assembleTemplateCoadd_metadata` has 16,304 entries but there are only 15,670 coadds.**
  The extra quanta wrote metadata without an `interpImage` entry, so the metadata task
  ends them with NoWorkFound (`raiseNoWorkFoundOnIncompleteMetadata: true`). Expect those
  quanta to be reported as "no work", not as failures.
- **The depth whole-sky plots are band-parameterized** over `config.bands`, which defaults
  to `ugrizy`. The script narrows this to `BAND` when one is given. Without `BAND`, the
  plots for bands absent from the collection get an all-NaN metric column and may fail.
  Always set `BAND` to the bands the collection actually holds (e.g. `g,r,i` for
  `bestSeeing_wide_gri`).
- **The depth table and depth whole-sky plots lose bands on a CHAINED input.**
  `template_coadd_depth_summary_metrics` has dimensions {skymap, tract} with no band. Each
  band's template RUN writes its own copy, so in `bestSeeing_wide_gri` a tract present in
  several band RUNs resolves to the first RUN in the chain only.
  - In `coadd_depth_summary_metrics_table_template` from the first gri run, g has all 542
    tracts, but r has 429 of 709 and i has 77 of 938.
  - Mask fractions, the metadata metrics and the per-tract depth plots are unaffected,
    since their inputs carry a band dimension.
  - The review notebook detects the loss and rebuilds the missing bands from each band RUN
    (`RECOVER_SHADOWED_DEPTH`). For correct pipeline products, run the depth table and
    whole-sky tasks on each band RUN separately.
- **The first gri run (job 8248977) hit the 6 h limit** after 18,664 of 63,071 quanta, with
  0 failures. That is about 0.86 quanta/s at `-j 16`, so the rest needs about 14 h more.
  Finish it with the resume mode below, giving the job enough time.

## Resuming an interrupted run

`RESUME=1` extends the newest existing RUN under the default output prefix instead of
creating a new one. `RESUME_RUN=<RUN>` names the RUN explicitly. Use the same
`INPUT_COLLECTION` and `BAND` as the original run:

```bash
INPUT_COLLECTION=DECam/templates/bestSeeing_wide_gri BAND=g,r,i RESUME=1 sbatch --export=ALL --time=16:00:00 template_coadd_analysis.sh
```

- The script passes `--extend-run --skip-existing --clobber-outputs`. Quanta whose
  outputs are all in the RUN are skipped, and partial outputs of quanta killed mid-write
  are replaced.
- It compares the inputs and bands with the original run's log
  (`$LOGDIR/templateCoaddAnalysis_run_<RUN timestamp>.log`) and stops if they differ.
  `--extend-run` would refuse differing task configs anyway.
- `TRACT` is refused in run mode when resuming. The survey-level tables and whole-sky
  plots would cover only that tract, and a later full resume would skip them as done.
- To preview what is left without running anything, add `MODE=qgraph`. A `TRACT` keeps
  the preview fast and avoids the login-node memory limit. For tract 973 of the first
  gri run, the preview correctly generated 39 metadata quanta, skipped the 17 done, and
  dropped the finished depth plot and depth table.

## Reviewing a run

`review_template_coadd_analysis.ipynb` (LSST Science Pipelines kernel) reviews an output
RUN. Set `ANALYSIS_RUN` (default: the newest RUN under `DECam/templates/analysis/`) and
`INPUT_COLLECTION`, then run all cells. It shows:

1. Execution status per task (finished, no-work, failed, not attempted)
2. Per-band n_image depth, including the shadowing check and recovery
3. Mask fractions
4. Interpolated-pixel fractions
5. The whole-sky and per-tract depth plots
6. Coverage gaps and flagged tracts

It works on partial runs. When a survey-level table hasn't been written yet, it reads the
per-tract or per-patch metric bundles instead. That takes a few minutes for about 60k
patches; set `MAX_BUNDLES` for a quick sampled look.

## Expected output size (gri, `bestSeeing_wide_gri`)

These are estimates scaled from measured sizes of similar existing outputs; there has been
no test run.

| part | count | total |
|---|---|---|
| `analyzeAssembleTemplateCoaddMetadataTemplate` (metadata, log and one metric file per patch, ~7 KB per quantum) | 62,012 quanta (from the gri graph build), ~185k files | ~0.4 GB |
| `coaddDepthPlotTemplate` (one plot per tract covering all bands; ~190 KB, measured range of stand-in plots 100–650 KB) | 1,051 quanta, i.e. distinct tracts, since the task's dimensions are {skymap, tract} and have no band | ~0.2 GB (0.1–0.7 GB) |
| tables and whole-sky plots | 9 quanta, about 50 files | < 50 MB |

The total is about 0.65 GB (0.45–1.2 GB) in about 190k files. The metadata task produces
about 98% of the files. Dropping it and its table from the subset leaves about 3.5k files.

Build the gri graph on a compute node, not the login node. On u24-login-2 (`ulimit -v`
4 GB) the gri `qgraph` was killed twice at the same stage, while the g-only graph
(16,895 quanta) built fine. `sbatch` runs build the graph inside the job, which has 64 GB.

