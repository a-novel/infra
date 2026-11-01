-- The columns authentication.yaml reads, granted to the role CloudNativePG runs it as. No email,
-- code, target or password.
GRANT SELECT (role, created_at) ON credentials TO cnpg_metrics_exporter;
GRANT SELECT (usage, created_at, expires_at, deleted_at, deleted_comment) ON short_codes TO cnpg_metrics_exporter;
