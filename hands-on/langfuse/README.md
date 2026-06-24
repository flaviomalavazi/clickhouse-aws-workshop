# Lab 5 (optional, afternoon) — Langfuse workshop

> [← Hands-on guide](../README.md) · [Workshop README](../../README.md) · comes after: [Agentic stack](../agentic-data-stack/README.md)

Maps to the afternoon agenda: *Observability & LLMOps in agentic systems —
Langfuse (Observability, Prompt Management, Experiments)* + the optional
hands-on.

This lab is delivered from a dedicated repo (kept separate so attendees can run
it standalone). We point at it rather than duplicating it here.

## Primary hands-on

**Repo:** https://github.com/flaviomalavazi/langfuse-workshop-python

You instrument the chatbot of the fictional **DataStream** company and walk the
production-to-eval loop: **trace → score → dataset → experiment**.

Two ways to follow along:
- **Human** — follow the repo README step by step.
- **Agentic** — let Claude Code / Codex instrument the code for you.

### Prerequisites
- `uv` (Python environment manager)
- An LLM API key (a small model is fine)
- A Langfuse environment — either a dedicated cloud project or a local Docker setup

```bash
git clone https://github.com/flaviomalavazi/langfuse-workshop-python
cd langfuse-workshop-python
# follow the README: set LANGFUSE_* + your model key, then run the steps
```

## How it connects to the morning

The Agentic Data Stack (`../agentic-data-stack`) already emits Langfuse traces
for every agent question over the workshop's ClickHouse data. In this lab you go
from *just tracing* to a real evaluation practice on top of those traces:

1. **Observability** — traces, observations, sessions, cost & latency.
2. **Prompt Management** — versioned prompts, labels, SDK retrieval + caching.
3. **Experiments** — datasets + `run_experiment()` to compare prompts/models
   before you ship.

## Going further
- **Langfuse Academy:** https://langfuse.com/academy
- **Langfuse Skills (teach Claude to instrument code):** https://github.com/langfuse/skills
- **Docs:** https://langfuse.com/docs/evaluation/overview
- Remember: Langfuse stores its traces in **ClickHouse** — the same engine you
  provisioned this morning. Agent observability *is* an analytics workload.
