SELECT
  (SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension) = 'pg_cron,plpgsql,uuid-ossp'
  AND public.uuid_generate_v4() IS NOT NULL
  AND (SELECT count(*) >= 0 FROM public.generations)
  AND (SELECT count(*) >= 0 FROM public.generation_attempts)
  AND (SELECT count(*) >= 0 FROM public.generation_payloads)
  AND (SELECT count(*) >= 0 FROM public.generation_usage)
  AND NOT EXISTS (
    SELECT FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'public' AND NOT c.convalidated
  )
  AND EXISTS (SELECT FROM pg_roles WHERE rolname = 'agora_genai' AND rolcanlogin)
  AND EXISTS (
    SELECT FROM pg_roles WHERE rolname = 'agora_genai_app'
      AND rolcanlogin AND NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
  )
  -- Retention runs only while both purge schedules come back with the data.
  AND (SELECT string_agg(jobname || '=' || schedule, ',' ORDER BY jobname) FROM cron.job)
    = 'service-genai-purge-cron-runs=0 4 * * *,service-genai-purge-settled=10 seconds';
