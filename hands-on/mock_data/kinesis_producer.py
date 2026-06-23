"""Produce a stream of clickstream events to Amazon Kinesis as JSON.

The JSON keys MUST match the columns declared on the Kinesis ClickPipe
destination table (see terraform/clickpipes.tf -> raw.events_raw):
    event_id, event_type, user_id, session_id, product_id, url, price, event_ts

    uv run kinesis_producer.py                  # ~10 events/sec until Ctrl-C
    uv run kinesis_producer.py --rate 50 --seconds 120
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import random
import time
import uuid

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from faker import Faker

import config

fake = Faker()

EVENT_TYPES = (
    ["page_view"] * 6
    + ["product_view"] * 4
    + ["add_to_cart"] * 2
    + ["purchase"] * 1
    + ["search"] * 2
)
URLS = ["/", "/catalog", "/product", "/cart", "/checkout", "/search", "/account"]


def make_event(user_id: str, session_id: str) -> dict:
    etype = random.choice(EVENT_TYPES)
    is_purchase = etype == "purchase"
    return {
        "event_id": str(uuid.uuid4()),
        "event_type": etype,
        "user_id": user_id,
        "session_id": session_id,
        "product_id": f"SKU-{random.randint(1, 500):04d}" if etype != "page_view" else "",
        "url": random.choice(URLS),
        # 0.0 for non-purchase keeps the column non-null and the revenue sum clean.
        "price": round(random.uniform(5, 500), 2) if is_purchase else 0.0,
        # DateTime64(3)-friendly UTC timestamp, millisecond precision.
        "event_ts": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rate", type=int, default=10, help="events per second")
    ap.add_argument("--seconds", type=int, default=0, help="0 = run forever")
    args = ap.parse_args()

    client = boto3.client("kinesis", region_name=config.AWS_REGION)
    stream = config.KINESIS_STREAM_NAME
    print(f"Producing ~{args.rate} events/s to Kinesis stream '{stream}' "
          f"({config.AWS_REGION}). Ctrl-C to stop.")

    # A small pool of users/sessions so uniq aggregates are interesting.
    users = [f"user-{i:05d}" for i in range(2000)]
    sessions = [str(uuid.uuid4()) for _ in range(500)]

    total = 0
    start = dt.datetime.now()
    try:
        while True:
            records = []
            for _ in range(args.rate):
                uid = random.choice(users)
                sid = random.choice(sessions)
                evt = make_event(uid, sid)
                records.append({"Data": json.dumps(evt).encode(), "PartitionKey": uid})

            # Kinesis PutRecords accepts up to 500 records / 5 MiB per call.
            try:
                for i in range(0, len(records), 500):
                    client.put_records(StreamName=stream, Records=records[i : i + 500])
            except (BotoCoreError, ClientError) as e:
                # Transient network/service error: skip this batch and keep going
                # rather than crashing the demo (boto3 already retried internally).
                print(f"  kinesis send failed ({type(e).__name__}); retrying shortly...")
                time.sleep(2)
                continue

            total += len(records)
            if total % (args.rate * 5) == 0:
                print(f"  sent {total} events")

            if args.seconds and (dt.datetime.now() - start).total_seconds() >= args.seconds:
                break
            _sleep_to_rate()
    except KeyboardInterrupt:
        pass
    print(f"Stopped after {total} events.")


def _sleep_to_rate() -> None:
    time.sleep(1.0)


if __name__ == "__main__":
    main()
