#!/usr/bin/env bash
#
# butler_pg_monitor.sh
#
# Lightweight, READ-ONLY load/capacity logger for the Butler PostgreSQL host.
# Samples OS + PostgreSQL saturation signals on a fixed interval and appends
# them to CSV files. Analyse a run afterwards with butler_pg_report.py.
#
# Read-only by construction: each psql session runs default_transaction_read_only
# plus short statement/lock timeouts, so it cannot write, block, or stall a
# sample. No extension, config change, restart or schema. Connects as the local
# `postgres` superuser over the Unix socket (needed for full pg_stat_activity).
#
# USAGE
#   sudo butler_pg_monitor.sh --loop            # sample every INTERVAL s (Ctrl-C to stop)
#   sudo butler_pg_monitor.sh mark "some text"  # annotate the active run (e.g. test start/end)
#
# Run --loop inside `screen` (or nohup) for a multi-hour test so an SSH
# disconnect doesn't kill it.
#
# Each --loop invocation creates a fresh run directory so runs never mix:
#   ${MONITOR_DIR}/run_<UTC start>/
#       instance_<UTC date>.csv   one row per sample: OS + cluster gauges
#       database_<UTC date>.csv   one row per database per sample: pg_stat_database
#       markers.csv               ts_utc,label rows written by `mark`
#   ${MONITOR_DIR}/latest -> run_<UTC start>     (where `mark` writes)
# A run crossing UTC midnight rolls over to a new dated file in the same dir.
#
# ENV
#   MONITOR_DIR   base output dir           (default: ./pgmon)
#   INTERVAL      seconds between samples   (default: 15)
#   DATA_MOUNT    data volume mount point   (default: /mnt/pgdata; falls back to /)
#   MONITOR_DB    database to connect to    (default: postgres)
#
set -euo pipefail
export LC_ALL=C   # stable numeric formatting in awk/printf (no locale decimal comma)

MONITOR_DIR="${MONITOR_DIR:-./pgmon}"
INTERVAL="${INTERVAL:-15}"
DATA_MOUNT="${DATA_MOUNT:-/mnt/pgdata}"
MONITOR_DB="${MONITOR_DB:-postgres}"

# ---------------------------------------------------------------------------
# CSV schemas (keep in sync with butler_pg_report.py)
# ---------------------------------------------------------------------------

INSTANCE_HEADER="ts_utc,hostname,ncpu,load1,load5,load15,cpu_util_pct,\
psi_cpu_some_avg10,psi_mem_some_avg10,psi_io_some_avg10,\
mem_total_kb,mem_avail_kb,swap_total_kb,swap_free_kb,\
disk_total_kb,disk_used_kb,disk_avail_kb,disk_used_pct,\
disk_read_kbps,disk_write_kbps,disk_util_pct,pg_up,pg_status,\
max_connections,total_conn,active_conn,idle_conn,idle_in_xact_conn,waiting_on_lock,\
oldest_xact_secs,longest_query_secs,longest_idle_xact_secs,autovac_workers,\
wal_bytes,max_datfrozenxid_age"

# 12 cluster columns; emitted empty when Postgres is unreachable.
EMPTY_CLUSTER=",,,,,,,,,,,"

DATABASE_HEADER="ts_utc,datname,numbackends,xact_commit,xact_rollback,\
blks_read,blks_hit,blk_read_time,blk_write_time,\
tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,\
temp_files,temp_bytes,deadlocks"

# ---------------------------------------------------------------------------
# psql wrapper -- read-only, fail-fast
# ---------------------------------------------------------------------------

if [[ "$(id -un)" == "postgres" ]]; then
    PG_WRAP=(env)
else
    PG_WRAP=(sudo -u postgres env)
fi

psql_ro() {
    "${PG_WRAP[@]}" \
        PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=2000 -c idle_in_transaction_session_timeout=10000 -c application_name=butler_pg_monitor' \
        psql -X -q -v ON_ERROR_STOP=1 -d "${MONITOR_DB}" "$@"
}

CLUSTER_SQL="COPY (
  SELECT
    current_setting('max_connections')::int,
    count(*) FILTER (WHERE backend_type = 'client backend'),
    count(*) FILTER (WHERE backend_type = 'client backend' AND state = 'active'),
    count(*) FILTER (WHERE backend_type = 'client backend' AND state = 'idle'),
    count(*) FILTER (WHERE backend_type = 'client backend' AND state LIKE 'idle in transaction%'),
    count(*) FILTER (WHERE backend_type = 'client backend' AND wait_event_type = 'Lock'),
    coalesce(round(extract(epoch FROM max(now() - xact_start)
        FILTER (WHERE backend_type = 'client backend'))::numeric, 1), 0),
    coalesce(round(extract(epoch FROM max(now() - query_start)
        FILTER (WHERE backend_type = 'client backend' AND state = 'active'))::numeric, 1), 0),
    coalesce(round(extract(epoch FROM max(now() - state_change)
        FILTER (WHERE backend_type = 'client backend' AND state LIKE 'idle in transaction%'))::numeric, 1), 0),
    count(*) FILTER (WHERE backend_type = 'autovacuum worker'),
    (SELECT CASE WHEN pg_is_in_recovery()
                 THEN pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '0/0')
                 ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0') END)::bigint,
    (SELECT max(age(datfrozenxid)) FROM pg_database)
  FROM pg_stat_activity
  WHERE pid <> pg_backend_pid()   -- don't count the sampler's own backend
) TO STDOUT WITH (FORMAT csv)"

DATABASE_SQL="COPY (
  SELECT d.datname, s.numbackends,
         s.xact_commit, s.xact_rollback, s.blks_read, s.blks_hit,
         s.blk_read_time, s.blk_write_time,
         s.tup_returned, s.tup_fetched, s.tup_inserted, s.tup_updated, s.tup_deleted,
         s.temp_files, s.temp_bytes, s.deadlocks
  FROM pg_stat_database s
  JOIN pg_database d ON d.oid = s.datid
  WHERE d.datname NOT LIKE 'template%' AND d.datallowconn
  ORDER BY d.datname
) TO STDOUT WITH (FORMAT csv)"

# ---------------------------------------------------------------------------
# OS sampling helpers
# ---------------------------------------------------------------------------

# PSI "some avg10" for one resource; "" if the kernel lacks PSI.
psi_some_avg10() {
    [[ -r "$1" ]] || return 0
    awk '/^some /{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub(/avg10=/,"",$i); print $i; exit}}' "$1"
}

# Echoes "busy total" jiffies from /proc/stat's aggregate cpu line.
read_cpu() {
    local _l user nice sys idle iowait irq softirq steal
    read -r _l user nice sys idle iowait irq softirq steal _ < /proc/stat
    local idle_all=$(( idle + iowait ))
    local total=$(( user + nice + sys + idle + iowait + irq + softirq + steal ))
    echo "$(( total - idle_all )) ${total}"
}

# Block device behind DATA_MOUNT; "" if unresolvable (disk I/O cols then blank).
resolve_disk_kname() {
    local src
    src="$(findmnt -nfo SOURCE --target "${DATA_MOUNT}" 2>/dev/null)" || return 0
    [[ -n "${src}" ]] || return 0
    lsblk -nro KNAME "${src}" 2>/dev/null | head -n1
}

# Echoes diskstats fields 6/10/13: sectors read, sectors written, ms doing I/O.
read_disk() {
    [[ -n "${DISK_KNAME}" ]] || return 0
    awk -v d="${DISK_KNAME}" '$3==d{print $6, $10, $13; exit}' /proc/diskstats
}

# (cur-prev)*scale/dt; blank if first call, input missing, or counter wrapped.
rate() {  # $1=cur $2=prev $3=dt $4=scale (default 1)
    awk -v c="$1" -v p="$2" -v dt="$3" -v s="${4:-1}" \
        'BEGIN{ if(c=="" || p=="" || dt<=0 || c<p) exit; printf "%.1f", (c-p)*s/dt }'
}

# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------

DISK_KNAME="$(resolve_disk_kname || true)"
ERR_TMP=""   # set by cmd_loop; holds the last psql invocation's stderr
prev_cpu_busy=""; prev_cpu_total=""
prev_s_r=""; prev_s_w=""; prev_io_ms=""; prev_disk_time=""

take_sample() {
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local now_re="${EPOCHREALTIME}"

    # --- OS: load / mem / swap ---
    local load1 load5 load15
    read -r load1 load5 load15 _ < /proc/loadavg
    local ncpu; ncpu="$(nproc)"

    local mem_total="" mem_avail="" swap_total="" swap_free="" k v
    while read -r k v _; do
        case "${k}" in
            MemTotal:)     mem_total="${v}"  ;;
            MemAvailable:) mem_avail="${v}"  ;;
            SwapTotal:)    swap_total="${v}" ;;
            SwapFree:)     swap_free="${v}"  ;;
        esac
    done < /proc/meminfo

    # --- OS: data-volume space ---
    local df_target="${DATA_MOUNT}"
    [[ -d "${df_target}" ]] || df_target="/"
    local disk_total disk_used disk_avail disk_pct
    read -r disk_total disk_used disk_avail disk_pct \
        < <(df -kP "${df_target}" | awk 'NR==2{gsub(/%/,"",$5); print $2, $3, $4, $5}')

    # --- OS: CPU-busy % since last sample ---
    local cpu_busy cpu_total cpu_util_pct=""
    read -r cpu_busy cpu_total < <(read_cpu)
    if [[ -n "${prev_cpu_total}" ]]; then
        cpu_util_pct="$(awk -v b="$cpu_busy" -v pb="$prev_cpu_busy" \
            -v t="$cpu_total" -v pt="$prev_cpu_total" \
            'BEGIN{ dt=t-pt; if(dt>0) printf "%.1f", 100*(b-pb)/dt }')"
    fi
    prev_cpu_busy="${cpu_busy}"; prev_cpu_total="${cpu_total}"

    # --- OS: PSI pressure ---
    local psi_cpu psi_mem psi_io
    psi_cpu="$(psi_some_avg10 /proc/pressure/cpu    || true)"
    psi_mem="$(psi_some_avg10 /proc/pressure/memory || true)"
    psi_io="$(psi_some_avg10  /proc/pressure/io     || true)"

    # --- OS: data-volume disk I/O since last sample ---
    local s_r="" s_w="" io_ms="" disk_read_kbps="" disk_write_kbps="" disk_util_pct=""
    read -r s_r s_w io_ms < <(read_disk) || true
    if [[ -n "${prev_disk_time}" ]]; then
        local dt; dt="$(awk -v a="$now_re" -v b="$prev_disk_time" 'BEGIN{print a-b}')"
        disk_read_kbps="$(rate  "${s_r:-}"   "${prev_s_r}"   "${dt}" 0.5)"   # sectors*512/1024
        disk_write_kbps="$(rate "${s_w:-}"   "${prev_s_w}"   "${dt}" 0.5)"
        disk_util_pct="$(awk -v c="${io_ms:-}" -v p="${prev_io_ms}" -v dt="${dt}" \
            'BEGIN{ if(c=="" || p=="" || dt<=0 || c<p) exit; u=100*(c-p)/(dt*1000); if(u>100)u=100; printf "%.1f", u }')"
    fi
    prev_s_r="${s_r:-}"; prev_s_w="${s_w:-}"; prev_io_ms="${io_ms:-}"; prev_disk_time="${now_re}"

    # --- PostgreSQL (read-only) ---
    # Classify a failed sample: a full connection ceiling or a sample-query
    # timeout means the server is UP and the load test found a limit -- only a
    # genuine connect failure is pg_up=0.
    local pg_up=1 pg_status=ok cluster_csv db_csv rc=0
    cluster_csv="$(psql_ro -c "${CLUSTER_SQL}" 2>"${ERR_TMP}")" || rc=$?
    if [[ "${rc}" -ne 0 || -z "${cluster_csv}" ]]; then
        case "$(cat "${ERR_TMP}" 2>/dev/null)" in
            *"too many clients"*|*"remaining connection slots"*|*"reserved for"*)
                pg_status=too_many_clients ;;
            *"due to statement timeout"*|*"due to lock timeout"*|*"canceling statement"*)
                pg_status=timeout ;;
            *"could not connect"*|*"Connection refused"*|*"No such file or directory"*|\
            *"system is starting up"*|*"system is shutting down"*|*"terminating connection"*)
                pg_status=unreachable; pg_up=0 ;;
            *)
                pg_status=error; pg_up=0 ;;
        esac
        cluster_csv="${EMPTY_CLUSTER}"
    fi
    db_csv=""
    if [[ "${pg_status}" == "ok" ]]; then
        db_csv="$(psql_ro -c "${DATABASE_SQL}" 2>/dev/null || true)"
    fi

    # --- Write rows ---
    local day; day="$(date -u +%Y%m%d)"
    local inst_file="${RUN_DIR}/instance_${day}.csv"
    local db_file="${RUN_DIR}/database_${day}.csv"
    [[ -f "${inst_file}" ]] || printf '%s\n' "${INSTANCE_HEADER}" > "${inst_file}"
    [[ -f "${db_file}"   ]] || printf '%s\n' "${DATABASE_HEADER}" > "${db_file}"

    local host inst_lead
    host="$(hostname 2>/dev/null || echo "${HOSTNAME:-unknown}")"
    # 23 gauge columns here; 12 cluster columns appended from cluster_csv.
    printf -v inst_lead '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' \
        "${ts}" "${host}" "${ncpu}" \
        "${load1}" "${load5}" "${load15}" "${cpu_util_pct}" \
        "${psi_cpu}" "${psi_mem}" "${psi_io}" \
        "${mem_total}" "${mem_avail}" "${swap_total}" "${swap_free}" \
        "${disk_total}" "${disk_used}" "${disk_avail}" "${disk_pct}" \
        "${disk_read_kbps}" "${disk_write_kbps}" "${disk_util_pct}" "${pg_up}" "${pg_status}"
    printf '%s,%s\n' "${inst_lead}" "${cluster_csv}" >> "${inst_file}"

    if [[ -n "${db_csv}" ]]; then
        printf '%s\n' "${db_csv}" | sed "s/^/${ts},/" >> "${db_file}"
    fi
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

csv_escape() { printf '"%s"' "${1//\"/\"\"}"; }

cmd_loop() {
    if ! awk -v i="${INTERVAL}" 'BEGIN{ exit !(i ~ /^[0-9]+(\.[0-9]+)?$/ && i+0 > 0) }'; then
        echo "butler_pg_monitor: INTERVAL must be a positive number (got '${INTERVAL}')" >&2
        exit 1
    fi
    [[ -d "${DATA_MOUNT}" ]] || echo "butler_pg_monitor: WARN ${DATA_MOUNT} not present -- disk space + I/O columns will describe '/' instead" >&2

    mkdir -p "${MONITOR_DIR}"
    local run_start; run_start="$(date -u +%Y%m%dT%H%M%SZ)"
    RUN_DIR="${MONITOR_DIR}/run_${run_start}"
    mkdir -p "${RUN_DIR}"
    ln -sfn "run_${run_start}" "${MONITOR_DIR}/latest"

    ERR_TMP="$(mktemp)"
    trap 'rm -f "${ERR_TMP}"; echo; echo "butler_pg_monitor: stopped at $(date -u +%Y-%m-%dT%H:%M:%SZ)"; exit 0' INT TERM HUP

    echo "butler_pg_monitor: sampling every ${INTERVAL}s into ${RUN_DIR}"
    [[ -n "${DISK_KNAME}" ]] || echo "butler_pg_monitor: NOTE could not resolve a disk device for ${DATA_MOUNT} -- disk I/O columns will be blank" >&2

    while true; do
        local t0="${EPOCHREALTIME}"
        take_sample || echo "butler_pg_monitor: WARN sample failed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
        local sleep_for
        sleep_for="$(awk -v i="${INTERVAL}" -v a="${EPOCHREALTIME}" -v b="${t0}" \
            'BEGIN{r=i-(a-b); print (r>0)?r:0}')"
        sleep "${sleep_for}"
    done
}

cmd_mark() {
    local label="${1:-}"
    [[ -n "${label}" ]] || { echo "Usage: $0 mark \"label text\"" >&2; exit 1; }
    local run_dir="${MONITOR_DIR}/latest"
    [[ -d "${run_dir}" ]] || { echo "No active run under ${MONITOR_DIR} (start '$0 --loop' first)." >&2; exit 1; }
    local mk="${run_dir}/markers.csv"
    [[ -f "${mk}" ]] || printf 'ts_utc,label\n' > "${mk}"
    printf '%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(csv_escape "${label}")" >> "${mk}"
    echo "marked: ${label}"
}

case "${1:-}" in
    --loop) cmd_loop ;;
    mark)   shift; cmd_mark "$@" ;;
    *)
        echo "Usage: $0 --loop | mark \"label text\"" >&2
        exit 1
        ;;
esac
