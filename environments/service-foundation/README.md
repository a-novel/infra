# Single-service foundation root (inactive)

This protected root assembles one service's runtime prerequisites, Cloud Deploy control plane and
application-job access. It supports JSON Keys and Authentication; the rollout verifier currently
supports JSON Keys only. **No live workflow or root allowlist selects this directory.** Production
and retained recovery evidence remain unchanged.

## Owners and state

| Owner                                                                    | Resources                                                                                                                              |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Shared foundation and [workload project](../../modules/workload-project) | Projects, APIs, Google agents, release identity, storage namespaces, Shared VPC and host network policy.                               |
| This root                                                                | Application identity, runtime-secret grants, repositories, operations channel, and the optionally composed rollout/job-access modules. |
| [Service release](../service-release)                                    | Application job specifications, bootstrapped directly in their destination state.                                                      |
| Cloud Deploy                                                             | API specification, revisions and traffic after an approved handoff.                                                                    |

The native backend uses the published management `state_bucket` and
`foundation/services/PROJECT/default.tfstate`. Only the default workspace is accepted. The existing
`foundation/` grants supply the protected administrator and read-only plan access; routine release
and disposable recovery have separate prefixes. This is separation from routine release, not a new
administrator per service. No storage grant is added here. Inspect inherited IAM before activation.

Authorize project, region and bucket against the published foundation coordinates **before init**.
The bucket-name validation establishes syntax only. Use a fresh working directory and disallow backend
overrides. Keep private state backup, exact saved-plan custody and deletion authorization. Native
[GCS locking](https://opentofu.org/docs/language/settings/backends/gcs/) covers this root only;
foundation changes, service releases, migrations and scheduled mutations still require coordinated exclusion.

## Runtime prerequisites

`main.tf` owns the application identity, two runtime-secret grants, repositories and operations email
channel directly. It reads no secret payload. Authentication receives its PostgreSQL and SMTP secret
containers; JSON Keys receives its PostgreSQL credential and master key. Neither receives peer,
backup or initializer credentials. Numeric enabled-version selection remains release policy.

`agora-production` holds application images and grants the project-local release identity Writer.
`agora-tooling` keeps verifier publication separate. Both repositories have immutable tags, deletion
guards and no age-based cleanup; recovery can read retained images. A separately approved publisher
must promote and verify the tooling digest. No verifier writer is granted here.

Publish the version-1 `runtime` output to approved consumers without sharing foundation state.
The same object supplies the child modules' identity and operations channel; callers cannot override
those with a peer's coordinates. Its output waits for runtime-secret and application-publisher grants.
Channel creation still needs a delivery test.

## Bootstrap sequence

The optional inputs describe which prerequisites already exist. They do not attest successful
bootstrap, execute a job or activate the pilot. Keep each enabled configuration in the protected
inputs; dropping it is resource removal, subject to its lifecycle guards and deletion review.

1. Establish the service project, agents, host network grants and approved foundation executor.
   Apply this root with `rollout = null` and `manage_job_access = false` to create runtime prerequisites.
2. After reviewed verifier promotion, supply `rollout` with `verification_image`, `network` and
   `subnetwork`. The root derives the fixed JSON Keys API name, service-local artifact bucket and
   management receipt bucket. The image must belong to this project's separate tooling repository.
   The [rollout module](../../modules/cloud-run-rollout) remains hard-suspended, with target approval
   required. Authentication rejects this opt-in until its own verifier is implemented.
3. After the selected database and approved images exist, protected bootstrap creates application jobs
   in [service-release state](../service-release#bootstrap-before-routine-release). Reconcile exact
   job UIDs and state before setting `manage_job_access = true`. The [job-access module](../../modules/service-job-access)
   installs exact-job authority, monitoring and JSON Keys' hard-paused rotation schedule. It owns no
   job specification. A missing job fails its IAM operation; it is not recreated here.
4. Verify allowed/denied IAM and network paths, remove temporary bootstrap authority and prove
   zero-change convergence before connecting routine release. Neither switch unsuspends Cloud Deploy
   nor resumes rotation. Their separate activation and interruption drills remain required.

Steps 2 and 3 consume different prerequisites and can be reviewed independently. OpenTofu composes
the dependency graph; there is no setup script, `-target` bootstrap or automatic existence discovery.
The existing protected foundation account has repository, identity and monitoring administration from
`workload-project`. Its rollout/Run job administration, scheduler administration and exact identity
attachment permissions still require the reviewed executor setup; this root does not grant itself
those powers. Management secret-IAM maintenance and bucket access are separate prerequisites too.

An existing pilot owner requires a private state backup and explicit removal/import map before this
root adopts its resources. Import cannot move a legacy workload into another project. Keep the old
writer until its separate workload cutover is verified. Databases/backups, protected input publication
and workflow callers, same-service exclusion, receipt completion and live failure drills remain
unfinished activation work. The active coordinator is retained until its replacement is proven.

## Cloud-blind validation

The existing validation job checks both inactive service roots with pinned providers and disabled
backends. Plan-only tests mock every provider, preserve the modules' security cases and exercise their
composition with each service. These tests do not prove effective cloud permissions or live health.

```sh
tofu -chdir=environments/service-foundation init -backend=false -input=false -lockfile=readonly
tofu -chdir=environments/service-foundation validate
tofu -chdir=environments/service-foundation test
```

The root uses native [flat module composition](https://opentofu.org/docs/language/modules/develop/composition/).
Storage authority follows [managed-folder inheritance](https://docs.cloud.google.com/storage/docs/managed-folders).
The [onboarding boundary](../../docs/runbooks/provision-service-projects.md) remains the live-operation gate.
