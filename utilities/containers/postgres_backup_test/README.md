# postgres_backup_test (Apptainer)

Tests that a Butler Postgres backup produced by
`../../postgres-setup/scripts/butler_pg_backup.sh` is actually restorable,
without touching the live database and without leaving anything behind.

## What it does

One-shot batch job, not a persistent service:

1. Spins up a throwaway PostgreSQL instance - unix socket only, no TCP
   listener. State (`PGDATA`, socket, restore logs) lives on the
   container's RAM-backed writable overlay and disappears with it. See
   "Sizing the scratch space" - Apptainer's default overlay (64MiB) isn't
   enough for a real restore, so `run_backup_test.sh` raises it first.
2. Restores one backup run (`globals_<timestamp>.sql` +
   `<db>/<db>_<timestamp>.dump`), using the same commands
   `postgres-setup/README.md`'s "Restoring" section documents manually.
3. Prints a summary per database: size, extensions, and an estimated row
   count per table across every user schema (`pg_class.reltuples` after
   `ANALYZE`, not `SELECT COUNT(*)` - a real registry can have tables too
   large to fully scan here). Not restricted to `public` - Butler's
   Postgres registry backend supports a non-default schema (`namespace`
   config), so a `public`-only check could report a healthy restore as
   empty.

Exit status reflects whether real data came back for every requested
database, not `pg_restore`'s exit code - `pg_restore` exits non-zero on
any error, including the role/ownership skew `butler_pg_backup.sh` already
documents as an accepted, non-fatal side effect of restoring globals and a
per-database dump separately.

## Why Apptainer + one-shot, not Docker + a service

This is a batch check against a known backup location, not a stateful
service to keep running and query - no port to publish, no inter-container
network, no volumes to tear down. A one-shot `apptainer exec` matches that
directly and keeps this consistent with `../lsst_pipeline`'s tooling
rather than introducing Docker into a repo that doesn't otherwise use it.

## Layout

```
postgres_backup_test.def   build definition (FROM the official postgres image)
build.args                  PG_MAJOR pin, see below
build.sh                    builds the .sif locally
run_backup_test.sh          host-side wrapper: gets apptainer exec's flags right
scripts/
    restore_and_verify.sh       baked into the image - the actual restore+summary logic
```

## Build

```bash
./build.sh                    # uses build.args
# or:
./build.sh path/to/other.args
```

Produces `postgres_backup_test_pg<PG_MAJOR>.sif` next to this README.

`PG_MAJOR` (in `build.args`) must be the same as, or newer than, the
PostgreSQL major version that wrote the dumps being tested - check the
source instance with `pg_lsclusters`.

## Run

```bash
./run_backup_test.sh /path/to/backup_dir              # every database in that backup run
./run_backup_test.sh /path/to/backup_dir some_db       # just some_db
```

`/path/to/backup_dir` is `BACKUP_DIR` from `butler_pg_backup.sh` - either
directly on an instance that has one, or a local copy pulled off-instance
by `../../postgres-setup/utilities/pull_butler_backups.sh`. Bind-mounted
**read-only**; nothing here ever writes into it.

Env vars:

| Var | Default | Effect |
|---|---|---|
| `SIF` | newest `postgres_backup_test_pg*.sif` next to this script | image to run |
| `BACKUP_TIMESTAMP` | most recent `globals_*.sql` found | which backup run to restore (must match `butler_pg_backup.sh`'s `TIMESTAMP`, e.g. `20260101-030000`) |
| `SCRATCH_TMPFS_MIB` | `8192` | size (MiB) of the RAM-backed scratch space inside the container - raise for a larger registry |
| `LOG_DIR` | unset (logs live only in the container, lost on exit) | host directory bind-mounted in; restore logs are written there directly (not copied out afterward), so they survive a kill mid-restore |
| `APPTAINER_SYSTEM_CONF` | auto-detected (`/etc/apptainer/apptainer.conf` or `/usr/local/etc/apptainer/apptainer.conf`) | path to the real system `apptainer.conf`, if elsewhere |

Must run as a normal (non-root) user - PostgreSQL refuses to
`initdb`/start as root, and Apptainer without `--fakeroot` already runs as
your own host UID, so `sudo` is never needed here.

### Sizing the scratch space

`PGDATA`/socket/restore logs live on Apptainer's "sessiondir" tmpfs, which
defaults to 64MiB (`apptainer.conf(5)`, `sessiondir max size`) - far too
small for a real restore. There's no per-invocation CLI flag for this
(proposed in [apptainer/apptainer#3674](https://github.com/apptainer/apptainer/issues/3674),
unmerged), so `run_backup_test.sh` copies the system `apptainer.conf`,
raises `sessiondir max size` to `SCRATCH_TMPFS_MIB` in that copy, and
points Apptainer at it via `APPTAINER_CONFIG_FILE` for that one
invocation - supported for non-root users on non-setuid installs (this
repo's images are built with `--fakeroot`, not setuid). Apptainer grows
the tmpfs on demand rather than reserving it up front, but on a shared
host keep `SCRATCH_TMPFS_MIB` modest and/or restore fewer databases per
run - a large `--writable-tmpfs` can otherwise eat a shared machine's RAM.

### Inspecting a restored database manually

By default (`apptainer exec`), PostgreSQL is never stopped explicitly -
the container tears down as soon as `restore_and_verify.sh` exits, taking
PostgreSQL with it. To poke around instead, run interactively and invoke
the script yourself:

```bash
APPTAINER_CONFIG_FILE=<generated-conf> apptainer shell --writable-tmpfs --no-mount tmp \
    --bind /path/to/backup_dir:/backups:ro \
    postgres_backup_test_pg17.sif
Apptainer> /opt/postgres_backup_test/restore_and_verify.sh /backups
Apptainer> psql -h <socket dir printed at the end> -U postgres -d <db>
Apptainer> exit   # tears everything down
```

(`run_backup_test.sh` generates its `APPTAINER_CONFIG_FILE` fresh each run
and removes it on exit - for a manual `shell` session, regenerate it the
same way, e.g. by copying the relevant lines out of `run_backup_test.sh`.)

### Picking one backup run consistently

A single `butler_pg_backup.sh` run writes `globals_<ts>.sql` once, then
every database's `<db>_<ts>.dump` with that same `<ts>`.
`restore_and_verify.sh` matches globals and per-database dumps by that
shared timestamp, not "newest of each independently" - the latter could
pair files from two different runs (e.g. if one run's globals dump
succeeded but a database's dump failed, per `butler_pg_backup.sh`'s
`FAILURES` handling).

### Live-database comparison (planned)

`LIVE_HOST` is recognized but not implemented - `restore_and_verify.sh`
fails loudly if it's set, so that gap can't be silently skipped. See
`TODO.md`.

## Known gaps

- Only covers per-database dumps + globals, i.e. what
  `butler_pg_backup.sh` produces today - no point-in-time/WAL-based
  recovery, since this Postgres setup doesn't do that (see
  `postgres-setup/README.md`'s "Backups" section).

See `TODO.md` for planned follow-up work (live-database comparison,
Butler-level registry checks).
