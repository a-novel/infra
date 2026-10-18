# bootstrap

The management project's durable pieces: what must survive a rebuild of everything else. It holds
the OpenTofu state bucket and the backup buckets, the secret containers but never their values, and
the CI identities with their GitHub federation. It also runs the two Cloud Workflows that need an
exact clock, which GitHub's schedules lack: the planned downtime announcements and the dispatch of
the `.github` workflows.

The very first apply is local (see [setup](../docs/runbooks/setup.md#rebuild-from-nothing)). After
that, `deploy.yaml` applies it whenever its directory, `.opentofu-version`, `.github/actions/tofu/`
or `deploy.yaml` changes.
