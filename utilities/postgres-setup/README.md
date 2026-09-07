# Setup Script for Postgres Running on Science Cloud

- Instance with attached storage volume
  - To host the PGDATA
- Operating system is assumed to be non-persistent
  - OS is Debian 13


## Cloud UZH Butler Setup

Config files are documented in the internal WIKI.



## General Steps for Setup

- Create the cloud volume (did 200GB)
- Create the cloud instance
  - Associate to correct security group
  - Set the correct SSH key
- Add the following rule to the security group:
  - `Ingress 	IPv4 	TCP 	5432 	0.0.0.0/0 	- 	Butler Postgres Access - Allow from everywhere Machine is only reachable in the UZH internal network!`
- Start the instance
- Associate the volume to the instance
- On your machine, replace the dummy content in `configs/uzh-butler-postgres-databases.conf`
  and `configs/uzh-butler-postgres-pull-keys.conf` with the config files found
  in the internal WIKI.
- From your machine, copy the setup scripts and config over with
  `./deploy_to_cloud.sh <ssh-alias|hostname|IP>`.
- Login to the machine and run the setup script against the deployed config:
  `sudo ./setup_butler_postgres.sh uzh-butler-postgres-databases.conf`
- Setup the database backup dumping:
  `sudo ./setup_butler_backups.sh uzh-butler-postgres-pull-keys.conf`


## Testing the Connection

To check all databases at once, use `scripts/test_butler_postgres.sh`.
It reads the same `database:role:password` file format as `setup_butler_postgres.sh`
(see `examples/butler_databases.conf.example`), checks the port, then connects as
each role and verifies `btree_gist` is enabled:

```bash
./scripts/test_butler_postgres.sh databases.conf [CLOUD-IP-ADDRESS]
```



## Backups

Daily logical backups (`pg_dump`), scheduled via cron, written to the data
volume alongside PGDATA, plus a dedicated SSH account so a separate
(secondary) machine can pull those backups off-instance on its own
schedule.

### Files

| Script | Role |
|---|---|
| `scripts/setup_butler_backups.sh` | One-time SOURCE-side setup (run with `sudo` *after* `setup_butler_postgres.sh`) |
| `scripts/butler_pg_backup.sh` | The worker -- runs daily via `/etc/cron.d/butler-pg-backup` as the `postgres` user |
| `utilities/pull_butler_backups.sh` | Runs on the SECONDARY machine -- pulls the backup dir from the source instance |

### One-time setup (on the instance)

```bash
# Copy the scripts + configs/uzh-butler-postgres-pull-keys.conf to the instance, then:
sudo ./setup_butler_backups.sh uzh-butler-postgres-pull-keys.conf
```

This creates `/mnt/pgdata/backups/postgresql` (owned by `postgres`, mode
700), installs the worker into `/usr/local/bin`, writes a cron.d entry that
runs it daily at 03:00 (system timezone), and creates a dedicated
`butler-backup-pull` SSH account (see "Off-instance copy" below). Each run
of the worker:

- `pg_dump -Fc` (custom format, restorable with `pg_restore`) for every
  database on the instance, auto-discovered from `pg_database` -- new databases
  are picked automatically.
- `pg_dumpall --globals-only` for roles/grants (cluster-wide, not part of
  any per-database dump)
- prunes dump files older than `RETENTION_DAYS` (default 14)


Adjust via env vars, e.g.:

```bash
sudo RETENTION_DAYS=30 CRON_SCHEDULE="0 2 * * *" ./setup_butler_backups.sh
```

### Running a backup manually

```bash
sudo /usr/local/bin/butler_pg_backup.sh
```

Logs go to `/var/log/butler_pg_backup.log` (rotated weekly, 8 kept).

### Restoring

```bash
# Per-database dump (custom format):
pg_restore -d <scratch_or_target_db> /mnt/pgdata/backups/postgresql/<db>/<db>_<timestamp>.dump

# Roles/grants (plain SQL):
psql -f /mnt/pgdata/backups/postgresql/globals_<timestamp>.sql
```

Test a restore at least once against a scratch database -- a dump file
existing is not the same as it being restorable. This is automated in
`../containers/postgres_backup_test/` -- an Apptainer image that restores
a backup run into a throwaway, local-only Postgres instance and prints a
summary of what landed, without touching the live database:

```bash
../containers/postgres_backup_test/run_backup_test.sh /mnt/pgdata/backups/postgresql
```


### Off-instance copy

`BACKUP_DIR` lives on the same data volume as PGDATA, so it survives
instance rebuild/replacement but not loss of that volume. `setup_butler_backups.sh`
sets up a dedicated `butler-backup-pull` account on the instance (SSH
pubkey login only) so a separate machine can pull a copy on its own
schedule:

- Public keys allowed to log in as `butler-backup-pull` come from
  `configs/uzh-butler-postgres-pull-keys.conf` (one per line,
  `authorized_keys` format -- see `examples/butler_pull_keys.conf.example`
  for how to generate a dedicated key pair for this). Edit that file and
  re-run `setup_butler_backups.sh` to add/remove keys; `authorized_keys` is
  regenerated in full each run.
- Each key is restricted (forced `command=`) to running `rsync --server
  ...` under NOPASSWD `sudo` as `postgres` -- enough to read `BACKUP_DIR`
  (`postgres`-owned, mode 700) and nothing else, even if a key leaks.

On the secondary machine, run/schedule `utilities/pull_butler_backups.sh`:

```bash
SOURCE_HOST=butler-backup-pull@<this-host> ./pull_butler_backups.sh
```

See the script's own header comment for the full env var list (`DEST_DIR`,
`RETENTION_DAYS`, `SSH_OPTS`, ...) and an example crontab entry -- it also
reports how many *new* backup files were pulled each run, so a `MAILTO`'d
cron doubles as a daily "did the backup actually run" check.

## Monitoring & Load Testing

To check whether the instance holds up under load, there is a lightweight,
**read-only** sampler that appends OS + PostgreSQL saturation signals to CSV
files. Analyse a run afterwards with a small pandas script.

It does **not** modify the database in any way — no extensions, no
`postgresql.conf` changes, **no restart**, no schema, nothing to undo. Every
`psql` session runs with `default_transaction_read_only = on` plus short
`statement_timeout` / `lock_timeout`, so it cannot write, cannot hold a lock,
and cannot stall a sample. It connects as the local `postgres` superuser over
the Unix socket only (needed for full `pg_stat_activity` visibility), so it
adds **no new network attack surface**.

### Files (in `scripts/`)

| File | Role |
|---|---|
| `butler_pg_monitor.sh` | The sampler. `--loop` writes CSV rows every `INTERVAL` s; `mark "text"` annotates the active run |
| `butler_pg_report.py` | Reads a run's CSVs (pandas) and prints peak gauges + per-DB counter deltas over a chosen window |

Nothing to install: copy the two files to the instance and run them.

### What it samples (every 15 s by default)

`instance_<date>.csv` — one row per sample:

- **OS**: load average vs `nproc`, CPU-busy %, PSI pressure
  (`/proc/pressure/{cpu,memory,io}`), total / available RAM, swap used,
  data-volume space + used %, and data-volume disk I/O (read/write KB/s and
  busy %, from `/proc/diskstats`).
- **Cluster**: client-backend count vs `max_connections` (default 100 —
  likely the first ceiling under many parallel `pipetask` jobs; see
  `examples/conf.d/10-butler-max-connections.conf.example` to raise it to 300),
  how many are
  active / idle / idle-in-transaction / blocked on a lock, age of the oldest
  transaction / longest active query / longest idle-in-transaction, running
  autovacuum workers, cumulative WAL bytes (delta = write pressure), and the
  oldest `datfrozenxid` age (wraparound headroom).

`database_<date>.csv` — one row per database per sample: the raw cumulative
`pg_stat_database` counters (commits, rollbacks, block hits / reads, tuples
in / out / changed, temp-file spills, deadlocks) plus `numbackends`. Deltas
are computed at report time. `blk_read_time` / `blk_write_time` are logged
but only non-zero if you separately enable `track_io_timing` (the sampler
does not).

Every column of both files is documented in
[`docs/monitoring-csv-columns.md`](docs/monitoring-csv-columns.md).

### Output layout

Each `--loop` run creates a fresh directory so runs never mix; a run crossing
UTC midnight rolls over to a new dated file in the same directory:

```
pgmon/
  run_20260907T101500Z/
    instance_20260907.csv
    database_20260907.csv
    markers.csv
  latest -> run_20260907T101500Z      # where `mark` writes
```

Files are tiny; prune old `run_*` directories by hand when done.

### Running a load test

```bash
# On the instance, inside `screen` so an SSH drop doesn't kill it — keep this
# running for the whole test (detach: Ctrl-A D; reattach: screen -r pgmon):
screen -S pgmon
sudo MONITOR_DIR=~/pgmon INTERVAL=15 DATA_MOUNT=/mnt/pgdata \
    ./butler_pg_monitor.sh --loop

# In another shell, bracket the test:
sudo MONITOR_DIR=~/pgmon ./butler_pg_monitor.sh mark "decam ingest run 1 START"
# ... drive load against the Butler DBs from wherever ...
sudo MONITOR_DIR=~/pgmon ./butler_pg_monitor.sh mark "decam ingest run 1 END"

# Then, anywhere with pandas (matplotlib only for --plot):
python butler_pg_report.py ~/pgmon/latest                         # whole run
python butler_pg_report.py ~/pgmon/latest --label "run 1 START"   # marker -> next marker
python butler_pg_report.py ~/pgmon/latest --since 30min
python butler_pg_report.py ~/pgmon/latest --from 2026-09-07T10:00Z --to 2026-09-07T11:00Z
python butler_pg_report.py ~/pgmon/latest --plot run1.png
```

The report prints the window, worst-case saturation gauges (peak connections
vs the limit, load-per-core, peak CPU %, PSI, min free RAM, swap used, peak
disk I/O, data-volume growth, WAL written, longest query / transaction, lock
waits) and per-database counter deltas (commits, cache-hit %, tuples changed,
temp spill, deadlocks). A sample the sampler couldn't complete is classified
in the `pg_status` column: a genuine connect failure (`pg_up = 0`) is reported
separately from hitting the connection ceiling or a sample-query timeout —
those mean the server is up and the test found a limit, not an outage.

> **Note:** This reveals behaviour *under load you generate* — not long-term
> extrapolation. Run a representative ingest/query batch to see where the
> connection / CPU / RAM / I/O ceilings actually are.
