-- Capture with writes quiesced through backup completion, using PostgreSQL 18. pg_cron's purge
-- keeps deleting during a downtime, so capture while no generation expires.
-- Hash the persisted rows, json columns as their stored text.
BEGIN READ ONLY;
SET LOCAL search_path = pg_catalog;
SET LOCAL timezone = 'UTC';
SET LOCAL datestyle = 'ISO, YMD';
SET LOCAL statement_timeout = '30s';
WITH rows AS (
  SELECT 'generations' AS relation, id, 0 AS attempt, jsonb_build_array(
    id, owner_id, purpose, provider, encode(request_key, 'hex'), error, status, attempt, max_attempts,
    run_at, start_requested_at, provider_call_id, cancel_requested_at, checked_at, created_at,
    updated_at, settled_at, expires_at, traceparent, outcome_unknown_at, streamed, first_start_requested_at
  ) AS data FROM public.generations
  UNION ALL
  SELECT 'generation_attempts', generation_id, attempt, jsonb_build_array(
    generation_id, attempt, response::text, created_at
  ) FROM public.generation_attempts
  UNION ALL
  SELECT 'generation_payloads', generation_id, 0, jsonb_build_array(
    generation_id, payload::text
  ) FROM public.generation_payloads
  UNION ALL
  SELECT 'generation_usage', generation_id, attempt, jsonb_build_array(
    generation_id, attempt, owner_id, purpose, provider, model, class, tier, input_tokens,
    cached_input_tokens, cache_write_tokens, output_tokens, reasoning_tokens, started_at, completed_at, created_at
  ) FROM public.generation_usage
)
SELECT encode(sha256(COALESCE(string_agg(
  sha256(convert_to(jsonb_build_array(relation, data)::text, 'UTF8')),
  ''::bytea ORDER BY relation COLLATE "C", id, attempt
), ''::bytea)), 'hex') FROM rows;
COMMIT;
