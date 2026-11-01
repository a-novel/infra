-- The columns genai.yaml reads, granted to the role CloudNativePG runs it as. No payload or
-- response. owner_id is counted, never exported.
GRANT SELECT (status, error, attempt, created_at, start_requested_at, checked_at, settled_at, expires_at) ON generations TO cnpg_metrics_exporter;
GRANT SELECT (generation_id, owner_id, model, class, tier, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens, created_at) ON generation_usage TO cnpg_metrics_exporter;
