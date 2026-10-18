# Secrets

This runbook covers adding, rotating and auditing secret values. OpenTofu manages the secret
containers, in the management project. Their **values** are added by humans with `gcloud`, so they
never reach state, plans or Git. Each workload reads the numeric version pinned in its root's
`terraform.tfvars`, so a new value takes effect only once a pull request pins it.

## Rotate a secret

This is the general procedure. Database passwords, the SMTP password, the waitlist secret and the
pgBackRest certificates rotate differently, because something besides the service reads them.
`production-json-keys-app-master-key` has no rotation procedure: it encrypts the signing keys JSON
Keys stores, and a new value cannot decrypt them.

1. Add a version. Paste the value at the prompt; it is not echoed.

   ```bash
   SECRET=production-<service>-<name>
   read -rs VALUE && printf '%s' "$VALUE" | gcloud secrets versions add "$SECRET" --project="$MGMT" --data-file=- && unset VALUE
   gcloud secrets versions list "$SECRET" --project="$MGMT" --limit=3
   ```

   | Secret                | Format                                                              |
   | --------------------- | ------------------------------------------------------------------- |
   | `*-postgres-password` | 32–128 characters, `[A-Za-z0-9_-]`, different per service           |
   | `*-app-password`      | the same format, different from the service's `*-postgres-password` |
   | `*-app-master-key`    | 64 hexadecimal characters                                           |
   | `*-waitlist-secret`   | at least 32 characters                                              |
   | `*-openai-api-key`    | an OpenAI project key restricted to the Responses API               |

2. Pin the new number in a pull request (`secret_versions` in the service root) and merge. Deploy
   rolls out a new revision that reads it.
3. Once the deploy is healthy, disable the old version. Destroying it is final after 30 days.

   ```bash
   gcloud secrets versions disable <old> --secret="$SECRET" --project="$MGMT"
   gcloud secrets versions destroy <old> --secret="$SECRET" --project="$MGMT"
   ```

   Run the second command only when you are sure the version is no longer needed.

Disabling a version does not revoke the credential where it was issued. For a leak, also revoke it
there: the Google account, the database role, and so on.

### Database passwords

The database host sets its owner password at boot, from the version in foundation's
`database_releases.<service>.password_version`. The service reads the same secret through
`secret_versions.postgres-password` in its root.

1. Add the version.
2. In **one** pull request, bump both values.
3. Merge it as a [database host change](database.md#change-a-database-host), during a planned
   downtime. The deploy gives the service the new version, then the rollout restarts the host, which
   sets it. The services refuse work during the downtime, so nothing fails in between.

## SMTP (Google Workspace relay)

Authentication sends mail through `smtp-relay.gmail.com:587` with authenticated STARTTLS:

- the account is `geoffroy.vincent@agorastoryverse.com`;
- the sender is `no-reply@agorastoryverse.com`;
- the password is a Google **app password**.

The relay rule is in Google Admin under **Apps → Google Workspace → Gmail → Routing → SMTP relay
service**: "only addresses in my domains", "require SMTP authentication" and "require TLS", with no
IP allowlist.

To rotate the app password:

1. In [App passwords](https://myaccount.google.com/apppasswords), create a new one.
2. Add it as a version of `production-authentication-smtp-sender-password`.
3. Bump `smtp-sender-password` in the authentication root and merge.
4. Check that health reports `client:smtp` up, and that a real email arrives.
5. Revoke the old app password, then disable the old version.

Changing the Google account's password revokes every app password.

## Waitlist

To turn it on:

1. Add a version of `production-authentication-waitlist-secret`.
2. In the authentication root, set `waitlist_url` and `secret_versions.waitlist-secret`, and merge.

The Apps Script behind the waitlist must use the same secret, so update both together. Requests
fail while they differ. To turn it off, remove both settings.

## GitHub dispatch tokens

GitHub starts scheduled workflows hours late. The `github-dispatch` workflow starts each org's
timed `.github` workflows instead, and only those its schedules list. It uses one fine-grained
personal access token per org. Create
each one in [Fine-grained tokens](https://github.com/settings/personal-access-tokens/new):

- **Resource owner:** the org, `a-novel` or `a-novel-kit`. An org that reviews tokens asks an owner
  to approve it.
- **Repository access:** only `<org>/.github`.
- **Permissions:** Actions, read and write. Nothing else.
- **Expiration:** the longest the org allows. The `.github` repository's daily `token-expiry`
  workflow posts to Discord before it lapses.

Add each one as a version of `production-github-dispatch-<org>`, as in
[Rotate a secret](#rotate-a-secret), and pin it in bootstrap's `github_dispatch_token_versions`. The
next dispatch after the deploy reads it. It can start, rerun, cancel and delete workflow runs in that
one repository. For a leak, revoke it on GitHub as well as disabling its version.

## pgBackRest TLS certificates

The database and repository hosts authenticate each other with certificates from an offline CA.
The hourly check fails 30 days before any certificate expires.

| Secret                                       | Contents                                       |
| -------------------------------------------- | ---------------------------------------------- |
| `production-<service>-pgbackrest-ca`         | CA certificate only, never its key             |
| `production-<service>-pgbackrest-database`   | client certificate followed by its private key |
| `production-<service>-pgbackrest-repository` | server certificate followed by its private key |

- **Client CN:** `agora-database.a-novel-production-prod` for JSON Keys, or
  `agora-authentication-database.a-novel-production-prod` for Authentication.
- **Server DNS name:** `agora-pgbackrest-<service>.europe-west1-d.c.a-novel-production-prod.internal`.

The CA's private key stays offline with its custodian, and never reaches a VM or Secret Manager.
`host-credentials` checks each bundle when a host starts, and refuses it unless:

- the CA secret holds only CA certificates, currently valid;
- each identity secret holds one unencrypted private key and its certificate, plus any
  intermediates, chaining to that CA and valid now;
- a client certificate allows TLS client authentication and has the client CN above;
- a server certificate allows TLS server authentication and has the server DNS name above;
- neither identity certificate is a CA.

To renew:

1. Issue the certificates offline, with the same names and purposes.
2. Upload each PEM file:

   ```bash
   gcloud secrets versions add production-<service>-pgbackrest-database --project="$MGMT" --data-file=database.pem
   ```

3. Bump the versions in one pull request:
   - for the database host: `native_backups.<service>.ca_version` / `identity_version` in
     foundation;
   - for the repository VM: `backup_repository.runtime.ca_version` / `identity_version` in the
     service root.
4. Merge it as a [database host change](database.md#change-a-database-host), during a planned
   downtime. The rollout restarts the database host, then the repository VM, which load the new
   certificates.

Delete the local PEM files afterwards.

## Audit access

```bash
gcloud logging read 'protoPayload.serviceName="secretmanager.googleapis.com" AND protoPayload.resourceName:"/secrets/'"$SECRET"'"' \
  --project="$MGMT" --limit=20 --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
```
