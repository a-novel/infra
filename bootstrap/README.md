# bootstrap

The management project's durable pieces:

- the OpenTofu state bucket;
- the backup buckets;
- secret containers (never their values);
- the CI identities and their GitHub federation.

The very first apply is local (see [setup](../docs/runbooks/setup.md#rebuild-from-nothing)). After
that, `deploy.yaml` applies it like any other root.
