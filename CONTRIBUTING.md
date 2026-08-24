# Contributing to infra

Platform setup and day-to-day workspace commands live in the [developer onboarding guide](https://github.com/a-novel-kit/.github/blob/master/README.md). Read the [README](./README.md) first for this repository's role, setup, and safety boundary.

---

## Validate a change

Install the pinned Node tooling once, then run the checks that cover the files you changed:

```bash
pnpm install --frozen-lockfile
pnpm lint
pnpm test

./ops/check-root.sh bootstrap
./ops/check-root.sh foundation
./ops/check-root.sh release
./tests/ops_test.sh
```

The root checker never configures a backend. Its OpenTofu tests mock the Google provider and require no Google credentials.

---

## Infrastructure-specific concepts

### Keep authority with its root

The `bootstrap`, `foundation`, and `release` roots have separate state and automation identities. Put a resource in the narrowest root whose lifecycle owns it. A routine release must not gain authority over project IAM, networking, preserved storage, backup retention, or state protection.

`ops/lib/roots.sh` is the single allowlist for user-supplied root names. Extend it only with an approved state and authority boundary. Never accept an arbitrary path from workflow input.

### Keep pull requests cloud-blind

Pull-request jobs use mocked providers and read-only GitHub permissions. They must not request `id-token: write`, select a protected environment, read a secret payload, run `gcloud`, initialize a remote backend, or publish a full plan.

Production-changing workflows run only from the protected `master` branch. Foundation and recovery changes require a reviewed environment approval. An apply consumes the exact reviewed plan; it never creates a new plan inside the apply step.

### Protect public output

OpenTofu plans can contain sensitive values even when a resource marks them sensitive. Public jobs may print only sanitized counts by action and resource type. Keep plan files, state, environment dumps, request bodies, authorization headers, DSNs, and secret values out of GitHub artifacts, summaries, annotations, and logs.

Add a Trivy ignore only when the finding is a verified false positive or an accepted temporary risk. The YAML ignore entry must name the affected path, state the narrow reason, and include an expiry date. A reviewer must approve it with the code that introduces it.

### Prefer a flat configuration

Keep singleton resources in their root. Create a local module after a second real call site appears or when one security invariant needs one implementation. Avoid wrappers that merely rename Google provider arguments.

### Preserve the deployment boundary

Container images and standard application protocols are the portable contract. Model Google resources directly. Add another runtime representation only after the project commits to operating that runtime.

---

## Questions?

[Open an issue](https://github.com/a-novel/infra/issues) with sanitized logs, the root name, and the failing check.
