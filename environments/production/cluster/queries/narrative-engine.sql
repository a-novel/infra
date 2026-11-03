-- The columns narrative-engine.yaml reads, granted to the role CloudNativePG runs it as. No title,
-- premise, owner or content.
GRANT SELECT (created_at, bytes, stored_bytes) ON projects TO cnpg_metrics_exporter;
