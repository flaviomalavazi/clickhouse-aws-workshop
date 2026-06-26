-- 03_demo_queries.sql
-- Run in the ClickHouse Cloud SQL console to demo the workshop story.

-- ===========================================================================
-- A) STREAMING SIDE — read finalized aggregates from the AggregatingMergeTree
--    via the -Merge combinators. This is what a real-time dashboard would query.
-- ===========================================================================

-- Live events / unique users / unique sessions / revenue per minute & type
SELECT
    minute,
    event_type,
    countMerge(events_count)        AS events,
    uniqMerge(uniq_users)           AS users,
    uniqMerge(uniq_sessions)        AS sessions,
    round(sumMerge(revenue), 2)     AS revenue
FROM marts.events_by_minute
GROUP BY minute, event_type
ORDER BY minute DESC, event_type
LIMIT 50;

-- Conversion funnel over the last 15 minutes (sub-second on millions of rows)
SELECT
    event_type,
    countMerge(events_count) AS events,
    uniqMerge(uniq_users)    AS users
FROM marts.events_by_minute
WHERE minute >= now() - INTERVAL 15 MINUTE
GROUP BY event_type
ORDER BY events DESC;

-- Compare to scanning the raw table directly (same answer, more work) — useful
-- to show WHY the incremental MV exists.
SELECT count() AS raw_events FROM raw.events_raw;

-- ===========================================================================
-- B) CDC SIDE — Aurora -> ClickHouse via ClickPipes (ReplacingMergeTree)
-- ===========================================================================

-- Current state of orders (latest version, deletes excluded)
SELECT status, count() AS orders, round(sum(amount), 2) AS gmv
FROM marts.orders_current
GROUP BY status
ORDER BY gmv DESC;

-- Show CDC freshness: the most recently synced rows
SELECT id, customer_id, status, amount, updated_at, _peerdb_synced_at
FROM raw.orders FINAL
WHERE _peerdb_is_deleted = 0
ORDER BY _peerdb_synced_at DESC
LIMIT 20;

-- ===========================================================================
-- C) THE UNIFIED STORY — join streaming clickstream with CDC business data
--    (the slide message: "observability/event data IS business data")
-- ===========================================================================

-- Revenue (from CDC orders) vs. purchase events (from the stream) per customer tier
SELECT
    c.tier                                   AS tier,
    count(DISTINCT o.id)                     AS orders,
    round(sum(o.amount), 2)                  AS gmv
FROM raw.orders AS o FINAL
INNER JOIN raw.customers AS c FINAL ON c.id = o.customer_id
WHERE o._peerdb_is_deleted = 0 AND c._peerdb_is_deleted = 0
GROUP BY tier
ORDER BY gmv DESC;

-- ===========================================================================
-- D) STREAM × CDC — joining the two pipelines on the minute axis
--    The synthetic data has no shared *entity* key (the clickstream keys on
--    user-NNNNN / SKU-NNNN strings; CDC keys on integer customers.id /
--    orders.customer_id), so the meaningful cross-source join is *temporal*:
--    purchase activity observed in the Kinesis stream vs. orders actually
--    booked in Aurora, per minute. One query, both engines:
--      - streaming side reads pre-aggregated states from the AggregatingMergeTree
--        via -Merge (the fast path);
--      - CDC side reads the ReplacingMergeTree through marts.orders_current
--        (FINAL + delete filter).
-- ===========================================================================
WITH
    stream AS (
        SELECT
            minute,
            countMerge(events_count)    AS stream_purchase_events,
            uniqMerge(uniq_users)       AS stream_buyers,
            round(sumMerge(revenue), 2) AS stream_revenue
        FROM marts.events_by_minute
        WHERE event_type = 'purchase'
        GROUP BY minute
    ),
    cdc AS (
        SELECT
            toStartOfMinute(created_at) AS minute,
            count()                     AS orders_booked,
            round(sum(amount), 2)       AS cdc_gmv
        FROM marts.orders_current       -- raw.orders FINAL, deletes excluded
        GROUP BY minute
    )
SELECT
    minute,
    stream_purchase_events,
    stream_buyers,
    stream_revenue,                     -- from the append-only event stream
    orders_booked,
    cdc_gmv                             -- from the OLTP system via CDC
FROM stream
FULL OUTER JOIN cdc USING (minute)      -- keep minutes present in only one source
ORDER BY minute DESC
LIMIT 30;
