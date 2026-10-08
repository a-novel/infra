# Secrets

Secret containers live in the management project and are managed by OpenTofu. **Values** are added
by humans with `gcloud`, so they never reach state, plans or Git. Workloads read the numeric version
pinned in their root's `terraform.tfvars`.

## Rotate a secret

1. Add a version. Paste the value at the prompt; it is not echoed.

   ```bash
   SECRET=production-json-keys-postgres-password
   read -rs VALUE && printf '%s' "$VALUE" | gcloud secrets versions add "$SECRET" --project="$MGMT" --data-file=- && unset VALUE
   gcloud secrets versions list "$SECRET" --project="$MGMT" --limit=3
   ```

   | Secret                | Format                                                    |
   | --------------------- | --------------------------------------------------------- |
   | `*-postgres-password` | 32–128 characters, `[A-Za-z0-9_-]`, different per service |
   | `*-app-master-key`    | 64 hexadecimal characters                                 |
   | `*-waitlist-secret`   | at least 32 characters                                    |

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

The database host reads its password at boot, using foundation's
`database_releases.<service>.password_version`.

1. Add the version.
2. In **one** pull request, bump both that value and the service root's `postgres-password`.
3. Merge. As soon as the deploy finishes, roll the host:

   ```bash
   gh workflow run roll-database.yaml --repo a-novel/infra -f service=<service>
   ```

Database connections fail for a few minutes, between the deploy and the end of the roll.

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

The Apps Script behind the waitlist must use the same secret, so update both together; requests
fail while they differ. To turn it off, remove both settings.

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

To renew:

1. Issue the certificates offline.
2. Upload each PEM file:

   ```bash
   gcloud secrets versions add production-<service>-pgbackrest-database --project="$MGMT" --data-file=database.pem
   ```

3. Bump the versions:
   - for the database host: `native_backups.<service>.ca_version` / `identity_version` in
     foundation;
   - for the repository: `backup_repository.runtime.ca_version` / `identity_version` in the
     service root.
4. Merge, and [roll the hosts](database.md#change-the-database-image-startup-or-os-image).

Delete the local PEM files afterwards.

## Audit access

```bash
gcloud logging read 'protoPayload.serviceName="secretmanager.googleapis.com" AND protoPayload.resourceName:"/secrets/'"$SECRET"'"' \
  --project="$MGMT" --limit=20 --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
```
