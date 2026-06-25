-- aurora/01_setup.sql
-- Run this ON THE AURORA POSTGRESQL writer endpoint AFTER `terraform apply`
-- (phase 1) and BEFORE enabling the Postgres ClickPipe (phase 2).
--
-- Preferred way to run it (fills in the password placeholder for you):
--   cd ../mock_data && uv run run_migrations.py
--
-- Or manually with psql (replace __CLICKPIPES_USER_PASSWORD__ below by hand):
--   psql "host=<aurora_writer_endpoint> port=5432 dbname=appdb user=postgres password=..."
--
-- It creates the OLTP schema, the dedicated ClickPipes role, and the
-- publication ClickPipes uses for logical replication.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: logical replication must be ON (set via the TF param group).
--    Expected: rds.logical_replication = on
-- ---------------------------------------------------------------------------
SHOW rds.logical_replication;

-- ---------------------------------------------------------------------------
-- 0b. CDC replication-safety defaults (the ClickPipes "Review Postgres settings"
--     checks). The instance parameter group already sets these cluster-wide
--     (terraform aws_db_parameter_group.aurora_instance / CFN AuroraDbParameterGroup),
--     which is what ClickPipes reads. We ALSO pin the two timeouts on THIS database
--     as a version-controlled default, so a CDC source created without that
--     parameter group is still safe. They cap long-running / idle-in-transaction
--     sessions that hold back the catalog xmin and block logical replication;
--     5 min is generous for the workshop seed + initial snapshot. (ALTER DATABASE
--     SET applies to NEW sessions, so it won't time out this migration.)
--
--     NOTE: max_slot_wal_keep_size (bounds WAL kept for a lagging slot) is a
--     system-wide GUC and can ONLY be set in the instance parameter group, not
--     per-database — see the IaC. Default -1 (unlimited) is the unsafe value.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
   EXECUTE format('ALTER DATABASE %I SET statement_timeout = %L', current_database(), '5min');
   EXECUTE format('ALTER DATABASE %I SET idle_in_transaction_session_timeout = %L', current_database(), '5min');
END
$$;

-- Verify the safety settings (these reflect the instance parameter group; the
-- ALTER DATABASE above takes effect for sessions opened after this migration).
SHOW max_slot_wal_keep_size;
SHOW statement_timeout;
SHOW idle_in_transaction_session_timeout;

-- ---------------------------------------------------------------------------
-- 1. OLTP schema — a tiny e-commerce model for the fictional company "DataStream"
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS customers (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       TEXT        NOT NULL,
    email      TEXT        NOT NULL,
    country    TEXT        NOT NULL,
    tier       TEXT        NOT NULL DEFAULT 'free',  -- free | pro | enterprise
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT      NOT NULL REFERENCES customers (id),
    status      TEXT        NOT NULL DEFAULT 'pending', -- pending|paid|shipped|delivered|cancelled
    amount      NUMERIC(12,2) NOT NULL,
    currency    TEXT        NOT NULL DEFAULT 'USD',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status   ON orders (status);

-- CDC needs a way to identify rows on UPDATE/DELETE. A PRIMARY KEY satisfies
-- this. If a table had no PK you would set: ALTER TABLE t REPLICA IDENTITY FULL;

-- ---------------------------------------------------------------------------
-- 2. Dedicated ClickPipes role (least privilege, read-only + replication)
-- ---------------------------------------------------------------------------
-- NOTE: __CLICKPIPES_USER_PASSWORD__ is a placeholder. run_migrations.py
-- substitutes it with CLICKPIPES_USER_PASSWORD from your .env (matching
-- var.clickpipes_user_password in terraform.tfvars). Running this by hand?
-- Replace it with the literal password first.
DO $$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'clickpipes_user') THEN
      CREATE ROLE clickpipes_user WITH LOGIN PASSWORD '__CLICKPIPES_USER_PASSWORD__';
   END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO clickpipes_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO clickpipes_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO clickpipes_user;

-- The managed-Postgres replication role (Aurora / RDS specific).
GRANT rds_replication TO clickpipes_user;

-- ---------------------------------------------------------------------------
-- 3. Publication consumed by the ClickPipe (name must match TF
--    settings.publication_name = "clickpipes_pub")
-- ---------------------------------------------------------------------------
DROP PUBLICATION IF EXISTS clickpipes_pub;
CREATE PUBLICATION clickpipes_pub FOR TABLE customers, orders;

-- Verify
SELECT pubname FROM pg_publication;
SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'clickpipes_pub';
