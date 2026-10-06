-- Capture with writes quiesced through backup completion, using PostgreSQL 18.
-- Include both persisted tables without returning credentials or decrypted short codes.
BEGIN READ ONLY;
SET LOCAL search_path = pg_catalog;
SET LOCAL timezone = 'UTC';
SET LOCAL datestyle = 'ISO, YMD';
SET LOCAL statement_timeout = '30s';
WITH rows AS (
  SELECT 'credentials' AS relation, id, jsonb_build_array(
    id, email, password, created_at, updated_at, role
  ) AS data FROM public.credentials
  UNION ALL
  SELECT 'short_codes', id, jsonb_build_array(
    id, code, usage, target, encode(data, 'hex'), created_at, expires_at, deleted_at, deleted_comment
  ) FROM public.short_codes
)
SELECT encode(sha256(COALESCE(string_agg(
  sha256(convert_to(jsonb_build_array(relation, data)::text, 'UTF8')),
  ''::bytea ORDER BY relation, id
), ''::bytea)), 'hex') FROM rows;
COMMIT;
