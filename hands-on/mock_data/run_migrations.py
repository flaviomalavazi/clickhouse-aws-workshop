"""Connect to Aurora PostgreSQL and run the SQL migrations in sql/aurora/.

Each *.sql file in the target directory is executed in filename order, inside
its own transaction. Use this instead of pasting the files into psql.

    uv run run_migrations.py                 # run sql/aurora/*.sql
    uv run run_migrations.py --dry-run       # print what would run, connect, do nothing
    uv run run_migrations.py --dir ../sql/aurora --file 01_setup.sql

The __CLICKPIPES_USER_PASSWORD__ placeholder in the SQL is substituted with
CLICKPIPES_USER_PASSWORD from your .env before execution.
"""
from __future__ import annotations

import argparse
import pathlib

import psycopg

import config

# sql/aurora/ sits next to mock_data/, one level up from this file.
DEFAULT_SQL_DIR = pathlib.Path(__file__).resolve().parent.parent / "sql" / "aurora"
PLACEHOLDER = "__CLICKPIPES_USER_PASSWORD__"


def render(sql: str) -> str:
    """Substitute the clickpipes_user password placeholder, if present."""
    if PLACEHOLDER not in sql:
        return sql
    pw = config.CLICKPIPES_USER_PASSWORD
    if not pw:
        raise SystemExit(
            f"SQL contains {PLACEHOLDER} but CLICKPIPES_USER_PASSWORD is unset. "
            "Set it in ../.env (see ../.env.example) — it must match "
            "var.clickpipes_user_password in terraform.tfvars."
        )
    # Escape for a single-quoted SQL literal by doubling embedded quotes.
    return sql.replace(PLACEHOLDER, pw.replace("'", "''"))


def print_results(cur: psycopg.Cursor) -> None:
    """Print every result set produced by a (possibly multi-statement) execute."""
    while True:
        if cur.description is not None:  # this statement returned rows
            cols = [d.name for d in cur.description]
            for row in cur.fetchall():
                print("      " + ", ".join(f"{c}={v}" for c, v in zip(cols, row)))
        if not cur.nextset():
            break


def run_file(conn: psycopg.Connection, path: pathlib.Path) -> None:
    sql = render(path.read_text())
    with conn.cursor() as cur:
        cur.execute(sql)  # psycopg3 runs all ;-separated statements (no params)
        print_results(cur)
    conn.commit()


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Aurora PostgreSQL migrations.")
    parser.add_argument(
        "--dir",
        type=pathlib.Path,
        default=DEFAULT_SQL_DIR,
        help=f"Directory of .sql migrations (default: {DEFAULT_SQL_DIR}).",
    )
    parser.add_argument(
        "--file",
        action="append",
        help="Run only this filename within --dir (repeatable). Default: all *.sql.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Connect and list the migrations without executing them.",
    )
    args = parser.parse_args()

    sql_dir: pathlib.Path = args.dir
    if not sql_dir.is_dir():
        raise SystemExit(f"Migrations directory not found: {sql_dir}")

    if args.file:
        files = [sql_dir / name for name in args.file]
        missing = [str(p) for p in files if not p.is_file()]
        if missing:
            raise SystemExit("Migration file(s) not found: " + ", ".join(missing))
    else:
        files = sorted(sql_dir.glob("*.sql"))
    if not files:
        raise SystemExit(f"No .sql migrations found in {sql_dir}")

    print(f"Aurora PostgreSQL: {config.PG_HOST}:{config.PG_PORT}/{config.PG_DB} as {config.PG_USER}")
    print(f"Migrations from {sql_dir}:")
    for path in files:
        print(f"  - {path.name}")

    if args.dry_run:
        # Still open a connection so the dry run also validates connectivity/creds.
        with psycopg.connect(config.pg_conninfo()) as conn:
            conn.execute("SELECT 1")
        print("Dry run: connection OK, nothing executed.")
        return

    with psycopg.connect(config.pg_conninfo()) as conn:
        for path in files:
            print("Running migrations...")
            print(f"==> {path.name}")
            run_file(conn, path)
            print(f"    done: {path.name}")

    print("All migrations applied.")


if __name__ == "__main__":
    main()
