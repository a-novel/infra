-- The columns json-keys.yaml reads, granted to the role CloudNativePG runs it as. No key material.
GRANT SELECT (usage, created_at, expires_at, deleted_at) ON keys TO cnpg_metrics_exporter;
