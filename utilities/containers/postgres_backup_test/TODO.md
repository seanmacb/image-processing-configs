# TODO

## Comparing against the live database

Given `LIVE_HOST` (+ role/db/`.pgpass` auth, same pattern as
`../../postgres-setup/utilities/test_butler_postgres.py` - this tool
should never handle a password itself), connect out to the live database
and compare something cheap per table - e.g. row counts - against the
just-restored copy, as a sanity signal beyond "did it restore at all."

Needs to account for the live database having moved on since the dump was
taken - the live count will usually be `>=` the restored count, not `==`,
and that's expected, not a failure.

## Basic Butler checks against the restored registry

Run `lsst_pipeline.sif` Butler CLI queries (`query-collections`,
`query-dataset-types`, `query-datasets` without materializing artifacts -
no datastore is restored here, only the registry) against the database
this tool just restored, as a deeper check than table/row presence.

Not a small addition - `lsst_pipeline.sif` and `postgres_backup_test.sif`
are separate images/containers with separate mount namespaces. Feasible
without merging them: run Postgres as a long-lived `apptainer instance`
listening on loopback TCP (Apptainer shares the host network namespace by
default) instead of the current one-shot, unix-socket-only `exec`, then a
separate `apptainer exec lsst_pipeline.sif ...` invocation can reach it via
`127.0.0.1:<port>`.

Open questions before implementing:
- **Credentials**: globals restore only gives role password *hashes*, and
  this tool deliberately never handles passwords (same reasoning as
  `LIVE_HOST`) - likely fix is minting a fresh test role post-restore
  rather than reusing original credentials.
- **Butler repo config**: instantiating a Butler needs a
  `butler.yaml`/db-auth matching each database's schema (`namespace`, e.g.
  `decam`/`desgw`) - unclear where that comes from for this tool
  (reconstruct from `butler_attributes`? ship per-repo config alongside
  the backup?).
- **Lifecycle change**: moves this tool from one-shot batch job to
  coordinating two containers with a start/stop lifecycle.
