"""Continuously mutate Aurora rows so the Postgres CDC ClickPipe has live traffic
to replicate: INSERTs (new orders/customers), UPDATEs (order status changes),
and occasional DELETEs.

Watch the changes show up in ClickHouse `raw.orders FINAL` within seconds.

    uv run simulate_cdc.py            # runs until Ctrl-C
    uv run simulate_cdc.py --iterations 50 --sleep 1.0
"""
from __future__ import annotations

import argparse
import contextlib
import random
import time

import psycopg
from faker import Faker

import config
import db

fake = Faker()

NEXT_STATUS = {
    "pending": "paid",
    "paid": "shipped",
    "shipped": "delivered",
}
STATUSES = ["pending", "paid", "shipped", "delivered", "cancelled"]


def new_order(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM customers ORDER BY random() LIMIT 1")
        row = cur.fetchone()
        if not row:
            return
        cur.execute(
            "INSERT INTO orders (customer_id, status, amount, currency) "
            "VALUES (%s, 'pending', %s, 'USD')",
            (row[0], round(random.uniform(5, 2500), 2)),
        )


def advance_order_status(conn) -> None:
    """Move a random order to its next lifecycle state (an UPDATE -> CDC replay)."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id, status FROM orders "
            "WHERE status IN ('pending','paid','shipped') ORDER BY random() LIMIT 1"
        )
        row = cur.fetchone()
        if not row:
            return
        order_id, status = row
        nxt = NEXT_STATUS.get(status, "delivered")
        cur.execute(
            "UPDATE orders SET status = %s, updated_at = now() WHERE id = %s",
            (nxt, order_id),
        )


def cancel_order(conn) -> None:
    # Postgres UPDATE has no ORDER BY/LIMIT — pick the target row in a subquery.
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE orders SET status = 'cancelled', updated_at = now() WHERE id IN "
            "(SELECT id FROM orders WHERE status = 'pending' ORDER BY random() LIMIT 1)"
        )


def delete_order(conn) -> None:
    """Hard-delete a cancelled order (a DELETE -> CDC soft-delete in ClickHouse)."""
    with conn.cursor() as cur:
        cur.execute(
            "DELETE FROM orders WHERE id IN "
            "(SELECT id FROM orders WHERE status = 'cancelled' ORDER BY random() LIMIT 1)"
        )


# Weighted action mix: mostly status advances + new orders.
ACTIONS = (
    [new_order] * 4
    + [advance_order_status] * 5
    + [cancel_order] * 1
    + [delete_order] * 1
)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iterations", type=int, default=0, help="0 = run forever")
    ap.add_argument("--sleep", type=float, default=1.0, help="seconds between actions")
    args = ap.parse_args()

    print("Generating CDC traffic against Aurora (Ctrl-C to stop)...")
    n = 0
    # Preflight: wait (with backoff) until Aurora is reachable, so a network
    # down-window at startup doesn't crash the run.
    conn = db.connect_with_retry()
    print(f"  connected to {config.PG_HOST}")
    try:
        while args.iterations == 0 or n < args.iterations:
            try:
                action = random.choice(ACTIONS)
                action(conn)
                n += 1
                if n % 20 == 0:
                    print(f"  {n} mutations applied")
                time.sleep(args.sleep)
            except db.RETRYABLE as e:
                # Connection dropped mid-run (flaky network / NAT timeout): discard
                # the dead connection and reconnect, then carry on. SQL/programming
                # errors are NOT caught here — those still surface loudly.
                reason = str(e).strip().splitlines()[0]
                print(f"  connection lost after {n} mutations: {reason}")
                with contextlib.suppress(Exception):
                    conn.close()
                conn = db.connect_with_retry()
                print("  reconnected — resuming.")
    except KeyboardInterrupt:
        pass
    finally:
        with contextlib.suppress(Exception):
            conn.close()
    print(f"Stopped after {n} mutations.")


if __name__ == "__main__":
    main()
