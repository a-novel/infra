-- Capture with writes quiesced through backup completion, using PostgreSQL 18.
-- Hash persisted rows, never the clock-dependent active_keys view or decrypted keys.
BEGIN READ ONLY;
SET LOCAL search_path = pg_catalog;
SET LOCAL timezone = 'UTC';
SET LOCAL datestyle = 'ISO, YMD';
SET LOCAL statement_timeout = '30s';
SELECT encode(sha256(COALESCE(string_agg(
  sha256(convert_to(jsonb_build_array(
    id, private_key, public_key, usage, created_at, expires_at, deleted_at, deleted_comment
  )::text, 'UTF8')), ''::bytea ORDER BY id
), ''::bytea)), 'hex') FROM public.keys;
COMMIT;
