# Debug the private PostgreSQL host

Use this procedure to inspect or open the current database VM. The command derives the generated
instance and zone on every run. It never adds a public address, metadata key, firewall rule, or
service-account key.

## Start

Run from the repository root:

```sh
. ./.envrc
./ops/verify-operator-env.sh --github
```

The active Google account must receive the access configured by
`INFRA_DATABASE_OPERATOR_PRINCIPALS`, directly or through a listed group. An account from another
Google organization also needs OS Login External User from its own administrator.

## Inspect the host

Choose the database in your local session: `authentication` or `json-keys`. For example:

```sh
export DATABASE_SERVICE=authentication
```

```sh
./ops/database-host.sh inspect "${DATABASE_SERVICE:?}"
```

The command prints the private VM, preserved disk, snapshot policy, firewall rules, and alerts. It
must end with `PASS database host inspection`. The final foundation audit is the IAM check.

## Create or reuse the SSH key

The default is `$HOME/.ssh/a-novel-gcp-ed25519`. When neither half exists, the command creates a
new Ed25519 pair. Set a passphrase when prompted. Ed25519 is an elliptic-curve key.

```sh
./ops/database-host.sh key
```

To reuse an existing Ed25519 or ECDSA pair, pass its private path:

```sh
./ops/database-host.sh key --key-file "$HOME/.ssh/id_ed25519"
```

Both the private file and `<path>.pub` must exist. A half-existing or non-EC pair fails closed. This
command checks only the local pair; the private key never leaves the workstation.

## Connect through IAP

The SSH command checks the local key, discovers the current host, uploads the public key to OS Login
for one hour, and connects:

```sh
./ops/database-host.sh ssh "${DATABASE_SERVICE:?}"
```

Use the same `--key-file` option when reusing another pair. Repeat the SSH command to renew the
one-hour key registration. If login fails, collect the bounded Google diagnostic:

```sh
./ops/database-host.sh troubleshoot "${DATABASE_SERVICE:?}"
```

The optional network-connectivity portion may report that Network Management API is disabled. Do
not enable an API ad hoc; OS Login, IAM, key, and IAP diagnostics still apply. Add an API through a
reviewed foundation change only when it becomes an operating requirement.

Do not enable tracing, print environment variables, inspect files below `/run/agora`, run an
unfiltered `docker inspect`, or request a metadata access token.

## Run safe host checks

Paste each line separately in the remote COS Bash session. Derive the service locally on that VM; your workstation environment is not forwarded:

```bash
DATABASE_SERVICE="$(curl -q --fail --silent --show-error --max-time 10 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/agora-database-service)"
```

An idle pre-release host has no database containers:

```bash
sudo docker ps --filter 'name=agora-postgres-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
sudo findmnt --noheadings --output SOURCE,TARGET,FSTYPE,OPTIONS /mnt/disks/agora-data
sudo df --output=source,size,used,avail,pcent,target /mnt/disks/agora-data
```

An enabled release has one healthy container and one bounded bridge on the selected VM:

```bash
sudo docker ps --filter 'name=agora-postgres-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}'
sudo docker network inspect "agora-database-${DATABASE_SERVICE:?}" --format '{{.Name}} internal={{.Internal}} subnet={{range .IPAM.Config}}{{.Subnet}}{{end}}'
sudo iptables -S AGORA-DATABASE-EGRESS
sudo iptables -S AGORA-DATABASE-HOST
sudo docker inspect "agora-postgres-${DATABASE_SERVICE:?}" --format '{{.Name}} running={{.State.Running}} health={{.State.Health.Status}} restart={{.HostConfig.RestartPolicy.Name}} memory={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}}'
```

After confirming the selected container is running, prove it cannot resolve external names or reach metadata:

```bash
for container in "agora-postgres-${DATABASE_SERVICE:?}"; do if sudo docker exec "$container" getent hosts example.com >/dev/null 2>&1; then printf 'STOP: %s resolved an external name.\n' "$container" >&2; false; else printf 'PASS %s external DNS denied.\n' "$container"; fi; done
for container in "agora-postgres-${DATABASE_SERVICE:?}"; do if sudo docker exec "$container" timeout 3 bash -c '</dev/tcp/169.254.169.254/80' >/dev/null 2>&1; then printf 'STOP: %s reached metadata.\n' "$container" >&2; false; else printf 'PASS %s metadata denied.\n' "$container"; fi; done
```

Exit the host when inspection is complete.

## Add or remove authorized operators

OS Login authorizes IAM principals on every login. Do not edit `authorized_keys` or project/instance
SSH metadata.

`INFRA_DATABASE_OPERATOR_PRINCIPALS` in `.envrc` is the reviewed, space-separated list. Entries use
`user:email` or `group:email` syntax. `INFRA_AUTH_INITIALIZER_PRINCIPALS` is separate; change it only
when the same person also needs the one-time Authentication initializer role.

Add the new principal to `.envrc` in a pull request and merge it. Then publish and plan the reviewed list:

```sh
git switch master
git pull --ff-only
. ./.envrc
./ops/foundation.sh configure
FOUNDATION_PLAN_ID="$(./ops/run-workflow.sh foundation plan foundation)"
```

Review the sanitized counts, then apply that exact plan:

```sh
./ops/run-workflow.sh foundation apply foundation "$FOUNDATION_PLAN_ID"
```

Have the new operator run `./ops/database-host.sh ssh authentication` successfully. Remove the old principal in a second pull request, then repeat the configure, plan, verification, and apply commands.

For a group principal, Workspace group membership is the user roster; the repository still reviews
which group receives the role. Never remove the last verified operator in the same plan that grants
an untested replacement.

## References

- [OS Login](https://cloud.google.com/compute/docs/oslogin)
- [SSH access best practices](https://cloud.google.com/compute/docs/connect/ssh-best-practices/login-access)
- [`gcloud compute ssh`](https://cloud.google.com/sdk/gcloud/reference/compute/ssh)
- [IAP TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- [`ssh-keygen`](https://man.openbsd.org/ssh-keygen.1)
