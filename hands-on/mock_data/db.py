"""Small psycopg helpers shared by the Postgres scripts."""
from __future__ import annotations

import contextlib
import time
from collections.abc import Iterator

import psycopg

import config

# Per-attempt connect timeout (seconds). Keeps a down-window attempt from hanging.
CONNECT_TIMEOUT = 10

# Connection-level errors that should trigger a reconnect (NOT programming/SQL
# errors like SyntaxError — those are real bugs and must surface loudly).
RETRYABLE = (psycopg.OperationalError, psycopg.InterfaceError)


@contextlib.contextmanager
def connect() -> Iterator[psycopg.Connection]:
    conn = psycopg.connect(config.pg_conninfo(), autocommit=True, connect_timeout=CONNECT_TIMEOUT)
    try:
        yield conn
    finally:
        conn.close()


def connect_with_retry(
    *, base_delay: float = 1.0, max_delay: float = 30.0, max_attempts: int | None = None
) -> psycopg.Connection:
    """Open a connection, retrying on connection errors with exponential backoff.

    Blocks until it succeeds (or max_attempts is exhausted, if set). Built for
    long-running generators on flaky networks: it rides out transient Aurora:5432
    reachability blips instead of crashing. Ctrl-C interrupts the wait.
    """
    attempt = 0
    delay = base_delay
    while True:
        attempt += 1
        try:
            return psycopg.connect(
                config.pg_conninfo(), autocommit=True, connect_timeout=CONNECT_TIMEOUT
            )
        except RETRYABLE as e:
            if max_attempts is not None and attempt >= max_attempts:
                raise
            reason = str(e).strip().splitlines()[0]
            print(f"  cannot reach Aurora (attempt {attempt}): {reason}")
            print(f"  retrying in {delay:.0f}s... (Ctrl-C to stop)")
            time.sleep(delay)
            delay = min(delay * 2, max_delay)


def fetch_ids(conn: psycopg.Connection, table: str) -> list[int]:
    with conn.cursor() as cur:
        cur.execute(f"SELECT id FROM {table}")
        return [r[0] for r in cur.fetchall()]
