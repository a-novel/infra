-- The columns profile.yaml reads, granted to the role CloudNativePG runs it as. No picture or owner.
GRANT SELECT (username, picture_updated_at, created_at) ON profiles TO cnpg_metrics_exporter;
