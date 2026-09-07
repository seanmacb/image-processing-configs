#!/usr/bin/env python3
"""
test_butler_postgres.py

Python equivalent of scripts/test_butler_postgres.sh, for machines that
don't have the postgresql-client package (psql, pg_isready) installed but
do have Python + psycopg2.

Quick reachability test for the Butler Postgres databases set up by
setup_butler_postgres.sh: checks the port is open, then connects as each
role from a database list file and runs a couple of sanity queries
(current_database()/current_user, and that btree_gist is enabled).

Uses the same "database_name:role_name:password" file format as
setup_butler_postgres.sh (see examples/butler_databases.conf.example), but
the password field is ignored -- this script never handles passwords
itself. Authentication is left to libpq's usual mechanisms, i.e. a
~/.pgpass entry (or PGPASSFILE/PGPASSWORD) for each role/database/host
combination. See https://www.postgresql.org/docs/current/libpq-pgpass.html
and examples/pgpass.example.

Requires psycopg2 -- see requirements.txt (pip install -r requirements.txt).

USAGE:
    ./test_butler_postgres.py [path/to/databases.conf] [host]

Both arguments are optional:
    - databases.conf defaults to DB_LIST_FILE env var, or "databases.conf"
    - host defaults to HOST env var, or 172.23.211.243

Other settings via env vars: PORT (default 5432), CONNECT_TIMEOUT (default 5).
"""
import os
import re
import socket
import sys

import psycopg2

NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def log(msg):
    print(f"\n>>> {msg}\n")


def read_db_list(path):
    """Parses "database_name:role_name:password" lines, same rules as
    setup_butler_postgres.sh / test_butler_postgres.sh -- but the password
    field is ignored, since this script never handles passwords itself
    (see module docstring: auth is via ~/.pgpass)."""
    if not os.path.isfile(path):
        print(f"ERROR: database list file '{path}' not found.", file=sys.stderr)
        print(
            "Pass its path as the first argument, or set DB_LIST_FILE, "
            "e.g. see examples/butler_databases.conf.example.",
            file=sys.stderr,
        )
        sys.exit(1)

    entries = []
    with open(path) as f:
        for line_num, raw_line in enumerate(f, start=1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue

            parts = line.split(":", 2)
            if len(parts) not in (2, 3):
                print(
                    f"ERROR: {path}:{line_num}: expected "
                    f"'database_name:role_name[:password]', got '{line}'.",
                    file=sys.stderr,
                )
                sys.exit(1)

            db_name, role_name = (p.strip() for p in parts[:2])

            if not db_name or not role_name:
                print(
                    f"ERROR: {path}:{line_num}: expected "
                    f"'database_name:role_name[:password]', got '{line}'.",
                    file=sys.stderr,
                )
                sys.exit(1)

            if not NAME_RE.match(db_name) or not NAME_RE.match(role_name):
                print(
                    f"ERROR: {path}:{line_num}: invalid database/role name in '{line}'.",
                    file=sys.stderr,
                )
                sys.exit(1)

            entries.append((db_name, role_name))

    if not entries:
        print(f"ERROR: {path} contains no database entries.", file=sys.stderr)
        sys.exit(1)

    return entries


def check_port(host, port, timeout):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError as exc:
        print(f"WARNING: could not reach {host}:{port} -- {exc}", file=sys.stderr)
        return False


def test_one_db(host, port, connect_timeout, db_name, role_name):
    try:
        conn = psycopg2.connect(
            host=host,
            port=port,
            user=role_name,
            dbname=db_name,
            connect_timeout=connect_timeout,
        )
    except psycopg2.Error as exc:
        print(f"  FAIL  {db_name} (user: {role_name}) -- could not connect/query:")
        print(f"        {exc}".strip())
        return False

    try:
        with conn.cursor() as cur:
            cur.execute("SELECT current_database() || ' / ' || current_user;")
            whoami_out = cur.fetchone()[0]

            cur.execute(
                "SELECT 1 FROM pg_extension WHERE extname = 'btree_gist';"
            )
            row = cur.fetchone()
    except psycopg2.Error as exc:
        print(
            f"  FAIL  {db_name} (user: {role_name}) -- connected ({whoami_out}) "
            "but could not check extensions:"
        )
        print(f"        {exc}".strip())
        return False
    finally:
        conn.close()

    if row is None:
        print(
            f"  WARN  {db_name} (user: {role_name}) -- connected ({whoami_out}), "
            "but btree_gist is NOT enabled"
        )
        return False

    print(f"  OK    {db_name} (user: {role_name}) -- {whoami_out}, btree_gist enabled")
    return True


def main():
    db_list_file = (
        sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DB_LIST_FILE", "databases.conf")
    )
    host = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("HOST", "172.23.211.243")
    port = int(os.environ.get("PORT", "5432"))
    connect_timeout = int(os.environ.get("CONNECT_TIMEOUT", "5"))

    log(f"Reading database list from {db_list_file}")
    entries = read_db_list(db_list_file)
    db_names = [e[0] for e in entries]
    log(f"Found {len(entries)} database(s) to test: {' '.join(db_names)}")

    log(f"Checking port {port} on {host} is reachable")
    if check_port(host, port, connect_timeout):
        print("Network/port OK.")
    else:
        print(
            "This is almost always the ScienceCloud Security Group or network "
            "(not Postgres itself) -- see README.md. Continuing with per-database "
            "connection attempts anyway, but they will likely also fail.",
            file=sys.stderr,
        )

    log("Testing each database")
    fail_count = 0
    for db_name, role_name in entries:
        if not test_one_db(host, port, connect_timeout, db_name, role_name):
            fail_count += 1

    print()
    if fail_count == 0:
        print(f"All {len(entries)} database(s) reachable and OK.")
        sys.exit(0)
    else:
        print(
            f"{fail_count} of {len(entries)} database(s) FAILED. See above for details.",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
