-- 02_clickhouse_mvs.sql
-- Run this in the ClickHouse Cloud SQL console AFTER both ClickPipes are
-- Running and data has started landing in `raw.events_raw` and `raw.orders`.
--
-- This is the core of the "Incremental Materialized View + AggregatingMergeTree"
-- lab. The pattern:  append-only source  ->  incremental MV  ->  AggregatingMergeTree
--
-- Why an incremental MV here (and not on the CDC tables)? Incremental MVs fire
-- on every INSERT into their source table. The Kinesis events table is
-- append-only, so each insert is a clean new fact — perfect for incremental
-- pre-aggregation. CDC tables (ReplacingMergeTree) receive UPDATE/DELETE replays
-- as versioned rows, so we query those with FINAL instead (see section 3).

CREATE DATABASE IF NOT EXISTS marts;

-- ---------------------------------------------------------------------------
-- 1. AggregatingMergeTree target — stores partial aggregate *states*, not finals
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marts.events_by_minute
(
    minute        DateTime,
    event_type    LowCardinality(String),
    events_count  AggregateFunction(count),
    uniq_users    AggregateFunction(uniq, String),
    uniq_sessions AggregateFunction(uniq, String),
    revenue       AggregateFunction(sum, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY (minute, event_type);

-- ---------------------------------------------------------------------------
-- 2. Incremental MV — transforms each batch of inserted rows into states
--    and writes them to the target above. Runs at insert time, automatically.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS marts.events_by_minute_mv
TO marts.events_by_minute
AS
SELECT
    toStartOfMinute(event_ts)                         AS minute,
    event_type,
    countState()                                      AS events_count,
    uniqState(user_id)                                AS uniq_users,
    uniqState(session_id)                             AS uniq_sessions,
    sumState(if(event_type = 'purchase', price, 0.0)) AS revenue
FROM raw.events_raw
GROUP BY minute, event_type;

-- OPTIONAL backfill: an MV only sees rows inserted AFTER it is created. To fold
-- in events that landed before the MV existed, run this once:
-- INSERT INTO marts.events_by_minute
-- SELECT
--     toStartOfMinute(event_ts) AS minute,
--     event_type,
--     countState(),
--     uniqState(user_id),
--     uniqState(session_id),
--     sumState(if(event_type = 'purchase', price, 0.0))
-- FROM raw.events_raw
-- GROUP BY minute, event_type;

-- ---------------------------------------------------------------------------
-- 3. (CDC side) Querying the ReplacingMergeTree tables fed by Postgres CDC.
--    ClickPipes adds _peerdb_* bookkeeping columns; FINAL collapses each row to
--    its latest version, and we exclude soft-deleted rows.
-- ---------------------------------------------------------------------------
-- A convenience view so analysts never forget FINAL / the delete filter:
CREATE VIEW IF NOT EXISTS marts.orders_current AS
SELECT *
FROM raw.orders FINAL
WHERE _peerdb_is_deleted = 0;
