SELECT
  (SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension) = 'plpgsql,uuid-ossp'
  AND public.uuid_generate_v4() IS NOT NULL
  AND (SELECT count(*) >= 0 FROM public.credentials)
  AND (SELECT count(*) >= 0 FROM public.short_codes)
  AND NOT EXISTS (SELECT FROM public.credentials WHERE email = '' OR role = '')
  AND NOT EXISTS (
    SELECT FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'public' AND NOT c.convalidated
  )
  AND EXISTS (SELECT FROM pg_roles WHERE rolname = 'agora_authentication' AND rolcanlogin)
  AND EXISTS (
    SELECT FROM pg_roles WHERE rolname = 'agora_authentication_backup'
      AND rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole
      AND NOT rolreplication AND NOT rolbypassrls
  )
  AND pg_has_role('agora_authentication_backup', 'pg_read_all_data', 'MEMBER');
