# Lab 4 — Agentic Data Stack (and how to observe it)

Maps to the morning hands-on bullet: *"ClickHouse Cloud: Agentic Data Stack (y
cómo observarlo)"* and to the afternoon Langfuse session.

The [ClickHouse Agentic Data Stack](https://github.com/ClickHouse/agentic-data-stack)
is a fully self-hosted, Docker-Compose bundle that puts a chat UI in front of
ClickHouse over MCP, with LLM observability built in. Tagline: *your chat, your
models, your data.*

## What's in the box

| Component | Role | Port |
|-----------|------|------|
| **LibreChat** | Chat UI for talking to your data | 3080 |
| LibreChat Admin Panel | User / config management | 3081 |
| **ClickHouse MCP server** | Lets the agent query ClickHouse ([`ClickHouse/mcp-clickhouse`](https://github.com/ClickHouse/mcp-clickhouse)) | 8000 |
| **Langfuse** | Traces every LLM call + tool call | 3000 |
| ClickHouse | The data + the Langfuse backend | 8123 |
| Postgres / MongoDB / Redis / MinIO / Meilisearch / pgvector | Supporting stores | — |

The agent reaches ClickHouse **only** through the MCP server, so every question
becomes a traced, inspectable SQL call — and every LLM step lands in Langfuse.
That is the bridge into the afternoon: *agent behaviour → traces → scores →
datasets → experiments.*

## Run it (two paths)

**Option A — one-click Railway (fastest):** deploy the "Lite" template (LibreChat
+ Admin Panel + Langfuse v3 + a ClickHouse MCP pointed at the public demo cluster
`sql-clickhouse.clickhouse.com`).

**Option B — self-host:**

```bash
git clone https://github.com/ClickHouse/agentic-data-stack
cd agentic-data-stack
./scripts/prepare-demo.sh     # interactive: set OpenAI/Anthropic/Google keys + Langfuse target
docker compose up -d
# LibreChat -> http://localhost:3080    Langfuse -> http://localhost:3000
```

## Point the agent at THIS workshop's data (optional)

Instead of the public demo cluster, configure the MCP server with your own
ClickHouse Cloud service from `../terraform` so the agent can answer questions
over `raw.orders`, `raw.events_raw`, and `marts.events_by_minute`:

```
CLICKHOUSE_HOST=<your-service>.clickhouse.cloud
CLICKHOUSE_PORT=8443
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=<clickhouse_password>
CLICKHOUSE_SECURE=true
```

Ask it things like *"What's GMV by customer tier this week?"* or *"How many
purchase events in the last 10 minutes?"* — then open Langfuse to see the trace,
the generated SQL, latency, and cost. That trace is the input to every Langfuse
lab in the afternoon (`../langfuse`).
