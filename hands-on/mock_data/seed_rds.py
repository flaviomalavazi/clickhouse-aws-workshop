"""Seed the Aurora PostgreSQL tables with an initial batch of customers + orders.

This is the data the Postgres ClickPipe picks up in its initial snapshot.

    uv run seed_rds.py
"""
from __future__ import annotations

import random

from faker import Faker

import config
from db import connect

fake = Faker()

TIERS = ["free", "free", "free", "pro", "pro", "enterprise"]  # weighted
STATUSES = ["pending", "paid", "paid", "shipped", "delivered", "cancelled"]
CURRENCIES = ["USD", "USD", "USD", "EUR", "BRL", "MXN"]


def seed_customers(conn, n: int) -> None:
    rows = [
        (
            fake.name(),
            fake.unique.email(),
            fake.country_code(),
            random.choice(TIERS),
        )
        for _ in range(n)
    ]
    with conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO customers (name, email, country, tier) VALUES (%s, %s, %s, %s)",
            rows,
        )
    print(f"  inserted {n} customers")


def seed_orders(conn, n: int) -> None:
    customer_ids = [r[0] for r in _all_ids(conn, "customers")]
    if not customer_ids:
        raise SystemExit("No customers found — seed customers first.")
    rows = [
        (
            random.choice(customer_ids),
            random.choice(STATUSES),
            round(random.uniform(5, 2500), 2),
            random.choice(CURRENCIES),
        )
        for _ in range(n)
    ]
    with conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO orders (customer_id, status, amount, currency) VALUES (%s, %s, %s, %s)",
            rows,
        )
    print(f"  inserted {n} orders")


def _all_ids(conn, table: str):
    with conn.cursor() as cur:
        cur.execute(f"SELECT id FROM {table}")
        return cur.fetchall()


def main() -> None:
    print(f"Seeding Aurora PostgreSQL ({config.PG_HOST}:{config.PG_PORT}/{config.PG_DB})")
    with connect() as conn:
        seed_customers(conn, config.SEED_CUSTOMERS)
        seed_orders(conn, config.SEED_ORDERS)
    print("Done. The Postgres ClickPipe will snapshot these rows on creation.")


if __name__ == "__main__":
    main()
