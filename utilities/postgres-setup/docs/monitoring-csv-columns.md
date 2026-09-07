# Monitoring CSV columns

Reference for the files written by `scripts/butler_pg_monitor.sh` into
`${MONITOR_DIR}/run_<UTC start>/`. Analysed by `scripts/butler_pg_report.py`.

**Conventions**

- All timestamps are UTC ISO-8601 (`2026-09-07T10:15:00Z`).
- **Gauge** columns are point-in-time values at the sample instant.
- **Counter (cumulative)** columns are raw PostgreSQL counters since the last
  stats reset — meaningful only as a delta over a window (which the report
  script computes; it also flags a counter that went backwards, i.e. a reset).
- An empty cell means the value was unavailable for that sample (e.g. cluster
  columns when `pg_status <> ok`, rate columns on the first sample, PSI on a
  kernel without pressure stall information).
- `KiB` = 1024 bytes; disk-space columns come from `df` 1K-blocks, memory from
  `/proc/meminfo` (both 1024-based).

---

## `instance_<date>.csv` — one row per sample

| Column | Unit | Description |
|---|---|---|
| `ts_utc` | timestamp | Sample time. |
| `hostname` | text | Host the sampler ran on. |
| `ncpu` | count | Logical CPUs (`nproc`). |
| `load1` | runnable procs | 1-minute load average (`/proc/loadavg`). |
| `load5` | runnable procs | 5-minute load average. |
| `load15` | runnable procs | 15-minute load average. |
| `cpu_util_pct` | percent | CPU busy time since the previous sample, from `/proc/stat` (blank on the first sample). |
| `psi_cpu_some_avg10` | percent | Share of the last 10 s in which at least one task was stalled waiting for CPU (`/proc/pressure/cpu`). |
| `psi_mem_some_avg10` | percent | Same, stalled on memory reclaim (`/proc/pressure/memory`). |
| `psi_io_some_avg10` | percent | Same, stalled on I/O (`/proc/pressure/io`). |
| `mem_total_kb` | KiB | Total RAM (`MemTotal`). |
| `mem_avail_kb` | KiB | Memory available for new work without swapping (`MemAvailable`). |
| `swap_total_kb` | KiB | Total swap space. |
| `swap_free_kb` | KiB | Unused swap space. |
| `disk_total_kb` | KiB | Size of the filesystem holding `DATA_MOUNT` (falls back to `/`). |
| `disk_used_kb` | KiB | Used space on that filesystem. |
| `disk_avail_kb` | KiB | Space available to non-root on that filesystem. |
| `disk_used_pct` | percent | Used percentage of that filesystem. |
| `disk_read_kbps` | KiB/s | Read throughput on the data-volume block device since the previous sample (`/proc/diskstats`); blank if the device could not be resolved. |
| `disk_write_kbps` | KiB/s | Write throughput on that device since the previous sample. |
| `disk_util_pct` | percent | Fraction of wall-clock time that device had at least one I/O in flight since the previous sample (capped at 100). |
| `pg_up` | 0 / 1 | `1` if the cluster query ran, or failed only because of the connection ceiling or a sample-query timeout; `0` only on a genuine connect failure. |
| `pg_status` | enum | Outcome of the PostgreSQL sample: `ok`, `too_many_clients`, `timeout`, `unreachable`, or `error`. |
| `max_connections` | count | The cluster's `max_connections` setting. |
| `total_conn` | count | Client backends currently connected (the sampler's own backend is excluded). |
| `active_conn` | count | Client backends in state `active`. |
| `idle_conn` | count | Client backends in state `idle`. |
| `idle_in_xact_conn` | count | Client backends `idle in transaction` (including `aborted`). |
| `waiting_on_lock` | count | Client backends blocked on a lock (`wait_event_type = 'Lock'`). |
| `oldest_xact_secs` | seconds | Age of the oldest open client transaction (`0` if none). |
| `longest_query_secs` | seconds | Runtime of the longest-running active client query (`0` if none). |
| `longest_idle_xact_secs` | seconds | Time the longest `idle in transaction` backend has sat since its last state change (`0` if none). |
| `autovac_workers` | count | Autovacuum worker processes currently running. |
| `wal_bytes` | bytes | Current WAL write position as bytes from `0/0`; monotonic across restarts, so a window delta is "WAL written". |
| `max_datfrozenxid_age` | transactions (XIDs) | Largest transaction-ID age of any database's frozen-XID horizon — wraparound headroom (compare against `autovacuum_freeze_max_age`, default 200 M). |

Columns `max_connections` through `max_datfrozenxid_age` are empty whenever
`pg_status <> ok`.

---

## `database_<date>.csv` — one row per database per sample

Sourced from `pg_stat_database` (see the PostgreSQL docs for exact counter
semantics). All counters are cumulative since the last stats reset.

| Column | Unit | Description |
|---|---|---|
| `ts_utc` | timestamp | Sample time; matches the corresponding `instance` row. |
| `datname` | text | Database name. |
| `numbackends` | count (gauge) | Backends currently connected to this database. |
| `xact_commit` | count (cumulative) | Transactions committed in this database. |
| `xact_rollback` | count (cumulative) | Transactions rolled back in this database. |
| `blks_read` | blocks (cumulative) | Disk blocks read (8 KiB each by default) — cache misses. |
| `blks_hit` | blocks (cumulative) | Block requests served from the shared buffer cache. |
| `blk_read_time` | milliseconds (cumulative) | Time spent reading data blocks; `0` unless `track_io_timing` is enabled. |
| `blk_write_time` | milliseconds (cumulative) | Time spent writing data blocks; `0` unless `track_io_timing` is enabled. |
| `tup_returned` | rows (cumulative) | Rows returned by sequential and index scans. |
| `tup_fetched` | rows (cumulative) | Rows fetched via index lookups. |
| `tup_inserted` | rows (cumulative) | Rows inserted. |
| `tup_updated` | rows (cumulative) | Rows updated. |
| `tup_deleted` | rows (cumulative) | Rows deleted. |
| `temp_files` | count (cumulative) | Temp files created by queries spilling past `work_mem`. |
| `temp_bytes` | bytes (cumulative) | Total data written to those temp files. |
| `deadlocks` | count (cumulative) | Deadlocks detected in this database. |

---

## `markers.csv` — one row per `mark` call

| Column | Unit | Description |
|---|---|---|
| `ts_utc` | timestamp | When `butler_pg_monitor.sh mark` was run. |
| `label` | text | Free-text label given on that command (CSV-quoted). |
