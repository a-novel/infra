# bootstrap

The management project's durable pieces, which must survive a rebuild of everything else: the
OpenTofu state bucket, the backup buckets, the secret containers and the CI identities with their
GitHub federation. Secret values never live here. Bootstrap also runs the Cloud Workflows that need
an exact clock, which GitHub's schedules lack.

The very first apply is [local](../docs/runbooks/setup.md#rebuild-from-nothing). After that,
`deploy.yaml` applies it whenever its [inputs](../docs/runbooks/deployments.md#what-a-deploy-runs)
change.
