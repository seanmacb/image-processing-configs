# image-processing-configs

Pipeline configurations, Slurm job scripts and utilities for processing survey
imaging with the [LSST Science Pipelines](https://pipelines.lsst.io/) on the
S3IT cluster at UZH. Everything here is meant to run against shared Butler
repositories (PostgreSQL-backed) under `/shares/soares-santos.physik.uzh/`.

## Layout

| Path | Contents |
|---|---|
| [`DECam/DESGW/`](DECam/DESGW/README.md) | DECam / DESGW gravitational-wave follow-up processing: calibrations, template building, the AP (difference-imaging) pipeline with fake injection, and verification. **The active part of this repo.** |
| `DECam/GW-Primo/` | Placeholder (empty README). |
| `DECam/README.md` | Placeholder (empty README). |
| [`utilities/postgres-setup/`](utilities/postgres-setup/README.md) | Scripts to deploy and back up the PostgreSQL server that hosts the Butler registries (UZH Science Cloud, Debian 13). |
| [`utilities/containers/postgres_backup_test/`](utilities/containers/postgres_backup_test/README.md) | Apptainer container that restores a Postgres backup into a throwaway instance to prove it is restorable. |
| `utilities/prune_collection_datasets.py` | Report or reclaim disk used by a Butler collection's datasets, keeping only chosen dataset types (default: `template_coadd`). Run with `--dry-run` first; without it, deletion is permanent. |

## Environment

The job scripts do not hard-code the Butler location. Each one starts with

```bash
source /shares/soares-santos.physik.uzh/repos/Butler-imports/s3it_setup/DESGW_CONFIGS
module load miniforge3
source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.sh
setup lsst_distrib -c
setup -j -r $OBSDECAM
```

`DESGW_CONFIGS` (kept in the separate `Butler-imports` repo, not here) defines:

| Variable | Meaning |
|---|---|
| `REPO` | Butler repo, `/shares/soares-santos.physik.uzh/ButlerProjects/desgw_postgres` |
| `LOGDIR` | Per-run logs, `$REPO/logs` |
| `OBSDECAM` | The DESGW fork of `obs_decam` (the_monster filter map, PRIMO filters) |
| `IMAGE_PROC_CONFIG_DIR` | `DECam/DESGW` of this repo; scripts reference configs as `$IMAGE_PROC_CONFIG_DIR/configs/...` |

The stack is `lsst_distrib` from `envs/lsst_stack` (currently the
`lsst-scipipe-13.1.0` environment). `setup -j -r $OBSDECAM` must come after
`setup lsst_distrib`, otherwise the conda `obs_decam` is used silently.

## Running things

Scripts are Slurm batch scripts; submit with `sbatch`. They are written for
the S3IT `standard` partition, whose nodes come in a few shapes:

| Cores | Memory | Nodes | Typical use here |
|---|---|---|---|
| 30 | ~116 GB | 30 | Default for most scripts (`-j 30`) |
| 120 | ~472 GB | 9 | Large builds (templates, fringe) |
| 92 | ~708 GB | 12 | |
| 8 | ~30 GB | 10 | Light jobs |

Check live availability with `sinfo`; the
[S3IT hardware page](https://docs.s3it.uzh.ch/cluster/resources/) has the
authoritative table. Request roughly 4 GB of memory per `pipetask -j` worker.

Many scripts are templates tied to one event, night or band (for example
`S250830bp`); read the header comment and edit the query before submitting.

## Conventions

- **Butler collections** follow a hierarchy: `DECam/raw/all`, `DECam/calib/...`,
  `DECam/templates/<event or pilotProc>/...`, `DECam/search/<event>`, with
  per-user collections under `u/<user>/...`.
- **Logs** go to `$LOGDIR/<name>.log` (via `tee`) and Slurm `.out`/`.err` under
  `/shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/`.
- **Long comments in scripts and YAML are intentional**: they record why a
  workaround exists (failed jobs, root causes, job IDs). Read them before
  "simplifying" a query or removing a flag.
