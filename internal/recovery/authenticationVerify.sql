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
  -- Older retained backups may contain the retired read-only login.
  AND NOT EXISTS (
    SELECT FROM pg_roles WHERE rolname = 'agora_authentication_backup'
      AND (NOT rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole
        OR rolreplication OR rolbypassrls
        OR NOT pg_has_role(oid, 'pg_read_all_data', 'MEMBER'))
  );
