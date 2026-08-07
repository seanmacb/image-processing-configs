# utilities/

## `test_butler_postgres.py`

Python equivalent of `scripts/test_butler_postgres.sh`, for machines that
don't have the `postgresql-client` package (`psql`, `pg_isready`) installed.
Same behaviour, same `databases.conf` file format, same env vars/args --
except it never handles passwords itself: the password field in
`databases.conf` is ignored, and authentication relies on `~/.pgpass` (or
`PGPASSFILE`/`PGPASSWORD`) already being set up for each role/database/host,
see `examples/pgpass.example`.

Setup:

```bash
pip install -r requirements.txt
```

Usage:

```bash
./test_butler_postgres.py databases.conf [CLOUD-IP-ADDRESS]
```

## `pull_butler_backups.sh`

See the script's own header comment, and README.md at the repo root
("Off-instance copy").
