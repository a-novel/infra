# State

This runbook is about OpenTofu's state.

Each root's state is one object, `<prefix>/default.tfstate`, in the bucket
`gs://a-novel-management-prod-232403541574-tofu-state`. The prefix is the root's directory name,
such as `foundation` or `cluster`, or `recovery-cluster/<project>` and `recovery-database/<project>`
for a drill. The bucket keeps a replaced version until 90 days after its replacement and until 50
newer versions exist. It keeps a deleted object for 7 days. State holds no secret values, but it is
private. Never paste it anywhere.

## Remove a stale lock

A cancelled deploy can leave `default.tflock` behind, and the next run then fails with "Error
acquiring the state lock".

1. Make sure no `deploy` run is in progress:

   ```bash
   gh run list --repo a-novel/infra --workflow deploy.yaml --limit 3
   ```

2. Delete the lock of the root named in the error:

   ```bash
   ROOT=foundation
   gcloud storage rm "gs://a-novel-management-prod-232403541574-tofu-state/$ROOT/default.tflock"
   ```

3. Re-run the failed deploy:

   ```bash
   RUN="<ID of the failed run>"
   gh run rerun "$RUN" --repo a-novel/infra --failed
   ```

## Restore an older version

Use this only when a state object is corrupt or was overwritten. Resources themselves are not
affected.

1. Freeze deploys:

   ```bash
   gh workflow disable deploy.yaml --repo a-novel/infra
   ```

2. List the versions, newest first, and choose one:

   ```bash
   ROOT=foundation
   OBJ="gs://a-novel-management-prod-232403541574-tofu-state/$ROOT/default.tfstate"
   gcloud storage ls -a -l "$OBJ" | sort -k2 -r | head
   ```

3. Copy it over the live object. The precondition makes the copy fail if someone wrote in the
   meantime.

   ```bash
   LIVE="<current generation>"
   OLD="<chosen generation>"
   gcloud storage cp "$OBJ#$OLD" "$OBJ" --if-generation-match="$LIVE"
   ```

4. Check the result with a drift run. Its plan should show only what changed since that version.
   Fix any remaining difference with a pull request.

   ```bash
   gh workflow run drift.yaml --repo a-novel/infra
   ```

5. Resume deploys:

   ```bash
   gh workflow enable deploy.yaml --repo a-novel/infra
   ```

To undo, repeat step 3 with the generation you replaced.

## Move, adopt or forget a resource

Do it in code, in a pull request, with the `moved`, `import` and `removed` blocks
[Ops basics](../ops-basics.md#opentofu) introduces, and let the plan prove it. A `removed` block
needs the deletion label. Delete `import` blocks once they are applied.
