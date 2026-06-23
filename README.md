# ClickHouse × AWS — Workshop técnico

Materiales para el workshop con el equipo de Solutions Architecture de AWS:
la parte teórica (deck) y la parte práctica (hands-on), pensadas para entrelazarse.

## Contenido

| Pieza | Qué es |
|-------|--------|
| `ClickHouse_AWS_Workshop_ES.pptx` | Deck teórico (38 slides, español): la tecnología, ClickHouse Cloud, integraciones AWS, ClickStack y Langfuse/LLMOps. |
| `deck/build_deck.js` | Generador del deck (pptxgenjs) — reproducible/editable: `cd deck && npm i pptxgenjs react-icons react react-dom sharp && node build_deck.js`. |
| `hands-on/` | Proyecto práctico en inglés: Terraform (ClickHouse Cloud + Aurora CDC + Kinesis + ClickPipes), SQL (MV incremental + AggregatingMergeTree) y generadores de datos en Python. Ver `hands-on/README.md`. |

## Cómo se entrelazan deck y hands-on

| Sección del deck (mañana) | Lab |
|---------------------------|-----|
| ClickHouse Cloud → Ingesta (Flink · S3 · BigQuery · ClickPipes) | `hands-on/terraform/clickpipes.tf` (Aurora CDC + Kinesis) |
| Compute-storage / compute-compute | `hands-on/terraform/clickhouse.tf` |
| Hands-on: Ingesta desde RDS y Kinesis | Lab 1 — `terraform/` + `sql/01` + `mock_data/` |
| Hands-on: Incremental MV + AggregatingMergeTree | Lab 2 — `sql/02_clickhouse_mvs.sql`, `sql/03_demo_queries.sql` |
| Hands-on: Agentic Data Stack (y cómo observarlo) | Lab 3 — `hands-on/agentic-data-stack/` |
| Tarde: Langfuse — Observabilidad / Prompts / Experimentos | `hands-on/langfuse/` |

Empieza por `hands-on/README.md` para el orden de ejecución completo.
